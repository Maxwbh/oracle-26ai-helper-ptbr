--==============================================================================
-- Template: RAG Pattern Completo (Retrieval-Augmented Generation)
--
-- RAG = combinar busca semântica + LLM para responder perguntas baseadas
-- em corpus próprio. Padrão canônico para chatbots, assistentes técnicos,
-- knowledge bases internas.
--
-- Este template usa PL/SQL para orquestrar o fluxo, com Oracle 26ai como
-- vector store. LLM pode ser interno (DBMS_VECTOR.GENERATE em 26ai) ou
-- externo (OpenAI, Cohere, etc.).
--
-- Cenário típico: assistente para consulta de base documental técnica (laudos, manuais, regulações).
-- "Qual o procedimento para necropsia de óbito por overdose?"
-- → busca chunks relevantes → envia para LLM com chunks como contexto
-- → LLM responde citando os chunks.
--==============================================================================


--==============================================================================
-- 1. Pré-requisitos (cumpridos via templates anteriores)
--==============================================================================

/*
Antes de rodar este template, ter:
  - Tabela documentos_forenses populada
  - Tabela chunks_documentos com embeddings (via pipeline_embedding_pkg)
  - Modelo embedding carregado (modelo_minilm_l12)
  - Índice vetorial nos chunks (HNSW ou IVF)
  - Credential para LLM (se usar serviço externo)
*/


--==============================================================================
-- 2. Tabela de logs (auditoria — importante em ambiente forense)
--==============================================================================

CREATE TABLE log_consultas_rag (
  id              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pergunta        VARCHAR2(4000),
  contexto_usado  CLOB,
  resposta_llm    CLOB,
  modelo_llm      VARCHAR2(100),
  qtd_chunks      NUMBER,
  tempo_ms        NUMBER,
  usuario         VARCHAR2(50) DEFAULT USER,
  consultado_em   TIMESTAMP DEFAULT SYSTIMESTAMP
);


--==============================================================================
-- 3. Procedure de retrieval (etapa "R" do RAG)
--==============================================================================

CREATE OR REPLACE FUNCTION retrieval_chunks_relevantes (
  p_pergunta      IN VARCHAR2,
  p_limite        IN PLS_INTEGER DEFAULT 5,
  p_max_distancia IN NUMBER DEFAULT 0.5
) RETURN CLOB IS
  l_contexto    CLOB;
  l_qtd_chunks  PLS_INTEGER := 0;
BEGIN
  DBMS_LOB.createtemporary(l_contexto, TRUE);

  FOR r IN (
    SELECT d.titulo, c.num_chunk, c.texto_chunk,
           ROUND(VECTOR_DISTANCE(
             c.embedding,
             VECTOR_EMBEDDING(modelo_minilm_l12 USING p_pergunta AS data),
             COSINE
           ), 4) AS distancia
      FROM chunks_documentos c
      JOIN documentos_forenses d ON d.id = c.id_documento
     WHERE VECTOR_DISTANCE(
             c.embedding,
             VECTOR_EMBEDDING(modelo_minilm_l12 USING p_pergunta AS data),
             COSINE
           ) <= p_max_distancia
     ORDER BY distancia
     FETCH APPROX FIRST p_limite ROWS ONLY
  ) LOOP
    DBMS_LOB.append(l_contexto,
      '[Documento: ' || r.titulo ||
      ' | Trecho ' || r.num_chunk ||
      ' | Relevância: ' || ROUND(1 - r.distancia, 2) || ']' || CHR(10) ||
      r.texto_chunk || CHR(10) || CHR(10)
    );
    l_qtd_chunks := l_qtd_chunks + 1;
  END LOOP;

  IF l_qtd_chunks = 0 THEN
    DBMS_LOB.append(l_contexto, '[Nenhum trecho relevante encontrado no corpus.]');
  END IF;

  RETURN l_contexto;
END;
/


--==============================================================================
-- 4. Procedure de geração via LLM (etapa "G" do RAG)
--
-- Usa DBMS_VECTOR.GENERATE — função 26ai que envia prompt para LLM
-- configurado e retorna resposta.
--==============================================================================

CREATE OR REPLACE FUNCTION gerar_resposta_llm (
  p_pergunta IN VARCHAR2,
  p_contexto IN CLOB,
  p_modelo   IN VARCHAR2 DEFAULT 'cohere.command-r'
) RETURN CLOB IS
  l_prompt    CLOB;
  l_resposta  CLOB;
BEGIN
  -- Constrói prompt com contexto
  DBMS_LOB.createtemporary(l_prompt, TRUE);
  DBMS_LOB.append(l_prompt,
    'Você é um assistente técnico institucional. Responda a pergunta abaixo BASEADO ' ||
    'EXCLUSIVAMENTE no contexto fornecido. Se o contexto não tem a resposta, ' ||
    'diga isso claramente. Cite os documentos usados.' || CHR(10) || CHR(10) ||
    '=== CONTEXTO ===' || CHR(10)
  );
  DBMS_LOB.append(l_prompt, p_contexto);
  DBMS_LOB.append(l_prompt, CHR(10) || '=== PERGUNTA ===' || CHR(10));
  DBMS_LOB.append(l_prompt, p_pergunta);
  DBMS_LOB.append(l_prompt, CHR(10) || '=== RESPOSTA ===' || CHR(10));

  -- Chama LLM
  l_resposta := DBMS_VECTOR.GENERATE(
    prompt => l_prompt,
    params => JSON('{
      "provider"        : "ocigenai",
      "credential_name" : "CRED_OCI_GENAI",
      "url"             : "https://inference.generativeai.us-chicago-1.oci.oraclecloud.com/20231130/actions/generateText",
      "model"           : "' || p_modelo || '",
      "max_tokens"      : 1000,
      "temperature"     : 0.2
    }')
  );

  DBMS_LOB.freetemporary(l_prompt);
  RETURN l_resposta;
END;
/


--==============================================================================
-- 5. Procedure orchestradora — RAG completo
--==============================================================================

CREATE OR REPLACE PROCEDURE consultar_rag (
  p_pergunta IN VARCHAR2,
  p_resposta OUT CLOB
) IS
  lc_nome_unidade CONSTANT VARCHAR2(60) := 'CONSULTAR_RAG';
  
  l_contexto    CLOB;
  l_inicio      TIMESTAMP;
  l_tempo_ms    NUMBER;
  l_qtd_chunks  PLS_INTEGER;
BEGIN
  l_inicio := SYSTIMESTAMP;

  -- Validações básicas
  IF p_pergunta IS NULL OR LENGTH(TRIM(p_pergunta)) < 5 THEN
    raise_application_error(-20102,
      'Pergunta vazia ou muito curta em ' || lc_nome_unidade);
  END IF;

  -- Etapa R: retrieval
  l_contexto := retrieval_chunks_relevantes(
    p_pergunta      => p_pergunta,
    p_limite        => 5,
    p_max_distancia => 0.5
  );
  
  -- Conta chunks recuperados (parsing simples do contexto)
  SELECT REGEXP_COUNT(l_contexto, '\[Documento:') INTO l_qtd_chunks FROM dual;

  -- Etapa G: generation
  p_resposta := gerar_resposta_llm(
    p_pergunta => p_pergunta,
    p_contexto => l_contexto
  );

  -- Tempo total
  l_tempo_ms := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_inicio)) * 1000 +
                EXTRACT(MINUTE FROM (SYSTIMESTAMP - l_inicio)) * 60000;

  -- Auditoria
  INSERT INTO log_consultas_rag (
    pergunta, contexto_usado, resposta_llm,
    modelo_llm, qtd_chunks, tempo_ms
  ) VALUES (
    p_pergunta, l_contexto, p_resposta,
    'cohere.command-r', l_qtd_chunks, l_tempo_ms
  );
  COMMIT;

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    raise_application_error(-20999,
      'Erro em ' || lc_nome_unidade || ': ' || SQLERRM);
END consultar_rag;
/


--==============================================================================
-- 6. Uso
--==============================================================================

DECLARE
  l_resposta CLOB;
BEGIN
  consultar_rag(
    p_pergunta => 'Qual o protocolo de necropsia para óbito por overdose?',
    p_resposta => l_resposta
  );
  
  DBMS_OUTPUT.put_line('=== RESPOSTA ===');
  DBMS_OUTPUT.put_line(DBMS_LOB.substr(l_resposta, 4000, 1));
END;
/


--==============================================================================
-- 7. Análise de qualidade (queries de monitoramento)
--==============================================================================

-- Tempo médio por pergunta (últimas 100)
SELECT AVG(tempo_ms) AS tempo_medio_ms,
       MIN(tempo_ms) AS tempo_min_ms,
       MAX(tempo_ms) AS tempo_max_ms,
       COUNT(*) AS total
  FROM log_consultas_rag
 WHERE consultado_em > SYSTIMESTAMP - INTERVAL '7' DAY;

-- Perguntas onde nenhum chunk foi encontrado (ajustar threshold ou enriquecer corpus)
SELECT pergunta, consultado_em
  FROM log_consultas_rag
 WHERE qtd_chunks = 0
 ORDER BY consultado_em DESC
 FETCH FIRST 20 ROWS ONLY;

-- Top 10 perguntas mais frequentes (oportunidade de FAQ)
SELECT pergunta, COUNT(*) AS qtd
  FROM log_consultas_rag
 GROUP BY pergunta
 ORDER BY qtd DESC
 FETCH FIRST 10 ROWS ONLY;


--==============================================================================
-- 8. Anti-patterns RAG
--==============================================================================

/*
ANTI-PATTERN 1: Não logar contexto enviado ao LLM
  - Sem log, impossível auditar de onde veio cada resposta
  - Em ambientes regulados (forense, jurídico, financeiro), isso é OBRIGATÓRIO

ANTI-PATTERN 2: Limite de chunks muito alto
  - Top 100 chunks = prompt muito longo, LLM perde foco
  - 3-7 chunks é típico, ajuste conforme tamanho médio do chunk

ANTI-PATTERN 3: Threshold de distância muito permissivo
  - max_distancia = 0.9 traz chunks irrelevantes
  - 0.3-0.5 é típico para COSINE; teste empiricamente

ANTI-PATTERN 4: Não passar contexto explicitamente delimitado
  -- RUIM: prompt que mistura contexto com pergunta sem separadores
  -- BOM: tags claras "=== CONTEXTO ===" e "=== PERGUNTA ==="

ANTI-PATTERN 5: Temperature alta em RAG factual
  - temperature 0.7+ = LLM "improvisa", inventa fatos não no contexto
  - Para RAG factual: 0.0 - 0.3

ANTI-PATTERN 6: Não pedir citações
  - Sem isso, LLM dá resposta sem rastreabilidade
  - Sempre instruir "cite os documentos usados"

ANTI-PATTERN 7: RAG sem fallback
  - Se nenhum chunk encontrado, LLM ainda responde (alucina)
  - SEMPRE checar qtd_chunks antes de chamar LLM, ou instruir
    "se contexto vazio, diga que não tem informação"
*/
