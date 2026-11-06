--==============================================================================
-- Template: RAG Pattern Completo (Retrieval-Augmented Generation)
--
-- RAG = combinar busca semântica + LLM para responder perguntas baseadas
-- em corpus próprio. Padrão canônico para chatbots, assistentes técnicos,
-- knowledge bases internas.
--
-- Este template usa PL/SQL para orquestrar o fluxo, com Oracle AI Database
-- 26ai como vector store. A geração usa DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT,
-- que chama um LLM EXTERNO via REST (OCI Generative AI, OpenAI, Cohere,
-- Google AI, Hugging Face, Vertex AI, Mistral, Anthropic) ou local (Ollama);
-- a geração não usa o modelo ONNX carregado no banco.
--
-- Cenário típico: assistente para consulta de base documental técnica (laudos, manuais, regulações).
-- "Qual o procedimento para necropsia de óbito por overdose?"
-- → busca chunks relevantes → envia para LLM com chunks como contexto
-- → LLM responde citando os chunks.
--
-- Revisado: nov/2026 contra a documentação Oracle AI Database 26ai (RU 23.26.4)
-- Edição Free: Parcial — retrieval (seções 2-3) roda no Free; a geração
--              (seção 4) exige um LLM acessível por rede + ACL + credencial
--              (ou Ollama local); o guia de licenças não lista Vector Search
--              explicitamente para o Free.
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
  - ACL de rede para o host do LLM + credencial (ver seção 4)
*/


--==============================================================================
-- 2. Tabela de logs (auditoria — importante em ambiente forense)
--==============================================================================

CREATE TABLE log_consultas_rag (
  id              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pergunta        VARCHAR2(4000),
  contexto_usado  CLOB,
  resposta_llm    CLOB,
  modelo_llm      VARCHAR2(200),
  qtd_chunks      NUMBER,
  tempo_ms        NUMBER,
  usuario         VARCHAR2(128) DEFAULT USER,
  consultado_em   TIMESTAMP DEFAULT SYSTIMESTAMP
);


--==============================================================================
-- 3. Function de retrieval (etapa "R" do RAG)
--==============================================================================

-- 26ai
CREATE OR REPLACE FUNCTION retrieval_chunks_relevantes (
  p_pergunta      IN VARCHAR2,
  p_limite        IN PLS_INTEGER DEFAULT 5,
  p_max_distancia IN NUMBER DEFAULT 0.5
) RETURN CLOB IS
  l_contexto         CLOB;
  l_qtd_chunks       PLS_INTEGER := 0;
  l_vetor_pergunta   VECTOR(384, FLOAT32);
BEGIN
  DBMS_LOB.createtemporary(l_contexto, TRUE);

  -- Gera o embedding da pergunta UMA vez (VECTOR_EMBEDDING é função SQL)
  SELECT VECTOR_EMBEDDING(modelo_minilm_l12 USING p_pergunta AS data)
    INTO l_vetor_pergunta
    FROM dual;

  -- ORDER BY pela VECTOR_DISTANCE "pura" (sem ROUND) para permitir o índice;
  -- arredondamento só na exibição.
  FOR r_chunk IN (
    SELECT d.titulo, c.num_chunk, c.texto_chunk,
           VECTOR_DISTANCE(c.embedding, l_vetor_pergunta, COSINE) AS distancia
      FROM chunks_documentos c
      JOIN documentos_forenses d ON d.id = c.id_documento
     WHERE VECTOR_DISTANCE(c.embedding, l_vetor_pergunta, COSINE) <= p_max_distancia
     ORDER BY distancia
     FETCH APPROX FIRST p_limite ROWS ONLY
  ) LOOP
    DBMS_LOB.append(l_contexto,
      '[Documento: ' || r_chunk.titulo ||
      ' | Trecho ' || r_chunk.num_chunk ||
      ' | Relevância: ' || ROUND(1 - r_chunk.distancia, 2) || ']' || CHR(10) ||
      r_chunk.texto_chunk || CHR(10) || CHR(10)
    );
    l_qtd_chunks := l_qtd_chunks + 1;
  END LOOP;

  IF l_qtd_chunks = 0 THEN
    DBMS_LOB.append(l_contexto, '[Nenhum trecho relevante encontrado no corpus.]');
  END IF;

  RETURN l_contexto;
END retrieval_chunks_relevantes;
/


--==============================================================================
-- 4. Function de geração via LLM (etapa "G" do RAG)
--
-- DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT(data CLOB, params JSON) RETURN CLOB
-- (também existe DBMS_VECTOR.UTL_TO_GENERATE_TEXT). Não existe
-- "DBMS_VECTOR.GENERATE".
--
-- OCI Generative AI ("ocigenai"):
--   - url: https://inference.generativeai.<regiao>.oci.oraclecloud.com/20231130/actions/chat
--   - parâmetros específicos do provedor vão DENTRO de "chatRequest"
--     (ex.: "maxTokens"); fora dele não são repassados
--   - modo dedicado: "model" recebe o OCID do endpoint e chatRequest leva
--     "apiFormat": "COHERE" | "GENERIC"
-- OpenAI: url https://api.openai.com/v1/chat/completions; "max_tokens" e
--   "temperature" vão no nível de topo do JSON.
--==============================================================================

-- Setup (como SYS/DBA): ACL de saída para o host do LLM
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => 'inference.generativeai.us-chicago-1.oci.oraclecloud.com',
    ace  => xs$ace_type(privilege_list => xs$name_list('connect'),
                        principal_name => 'USUARIO_VETOR',
                        principal_type => xs_acl.ptype_db));
END;
/
GRANT CREATE CREDENTIAL TO usuario_vetor;

-- 26ai — Setup (como usuario_vetor): credencial OCI (chave de API do usuário OCI).
-- Valores reais NÃO devem ir para o Git.
DECLARE
  l_credencial JSON_OBJECT_T := JSON_OBJECT_T();
BEGIN
  l_credencial.put('user_ocid',        '<ocid1.user...>');
  l_credencial.put('tenancy_ocid',     '<ocid1.tenancy...>');
  l_credencial.put('compartment_ocid', '<ocid1.compartment...>');
  l_credencial.put('private_key',      '<chave_privada_sem_BEGIN_END>');
  l_credencial.put('fingerprint',      '<fingerprint>');

  DBMS_VECTOR_CHAIN.CREATE_CREDENTIAL(
    credential_name => 'CRED_OCI_GENAI',
    params          => JSON(l_credencial.to_string)
  );
END;
/

-- 26ai
CREATE OR REPLACE FUNCTION gerar_resposta_llm (
  p_pergunta IN VARCHAR2,
  p_contexto IN CLOB,
  p_modelo   IN VARCHAR2
) RETURN CLOB IS
  -- Ajuste a região do endpoint à sua tenancy
  lc_url_chat CONSTANT VARCHAR2(200) :=
    'https://inference.generativeai.us-chicago-1.oci.oraclecloud.com/20231130/actions/chat';
  l_prompt        CLOB;
  l_resposta      CLOB;
  l_params        JSON_OBJECT_T := JSON_OBJECT_T();
  l_chat_request  JSON_OBJECT_T := JSON_OBJECT_T();
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

  -- Monta os parâmetros com JSON_OBJECT_T (evita JSON quebrado por concatenação)
  l_chat_request.put('maxTokens', 1000);
  -- Temperatura baixa é desejável em RAG factual. A doc Oracle mostra só
  -- "maxTokens"/"topK" dentro de chatRequest para ocigenai.
  -- A VERIFICAR: nome/aceitação de "temperature" em chatRequest na API do
  -- OCI Generative AI antes de incluir.

  l_params.put('provider',        'ocigenai');
  l_params.put('credential_name', 'CRED_OCI_GENAI');
  l_params.put('url',             lc_url_chat);
  l_params.put('model',           p_modelo);
  l_params.put('chatRequest',     l_chat_request);

  -- Chama LLM
  l_resposta := DBMS_VECTOR_CHAIN.UTL_TO_GENERATE_TEXT(
    data   => l_prompt,
    params => JSON(l_params.to_string)
  );

  DBMS_LOB.freetemporary(l_prompt);
  RETURN l_resposta;
END gerar_resposta_llm;
/


--==============================================================================
-- 5. Procedure orquestradora — RAG completo
--==============================================================================

-- 26ai
CREATE OR REPLACE PROCEDURE consultar_rag (
  p_pergunta   IN  VARCHAR2,
  p_modelo_llm IN  VARCHAR2,
  p_resposta   OUT CLOB
) IS
  lc_nome_unidade CONSTANT VARCHAR2(60) := 'CONSULTAR_RAG';

  l_contexto    CLOB;
  l_inicio      TIMESTAMP;
  l_duracao     INTERVAL DAY TO SECOND;
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
  l_qtd_chunks := REGEXP_COUNT(l_contexto, '\[Documento:');

  -- Etapa G: generation — sem contexto, NÃO chama o LLM (evita alucinação
  -- e custo de chamada)
  IF l_qtd_chunks = 0 THEN
    p_resposta := 'Não há informação no corpus para responder a esta pergunta.';
  ELSE
    p_resposta := gerar_resposta_llm(
      p_pergunta => p_pergunta,
      p_contexto => l_contexto,
      p_modelo   => p_modelo_llm
    );
  END IF;

  -- Tempo total
  l_duracao  := SYSTIMESTAMP - l_inicio;
  l_tempo_ms := EXTRACT(HOUR   FROM l_duracao) * 3600000 +
                EXTRACT(MINUTE FROM l_duracao) * 60000 +
                EXTRACT(SECOND FROM l_duracao) * 1000;

  -- Auditoria
  INSERT INTO log_consultas_rag (
    pergunta, contexto_usado, resposta_llm,
    modelo_llm, qtd_chunks, tempo_ms
  ) VALUES (
    p_pergunta, l_contexto, p_resposta,
    p_modelo_llm, l_qtd_chunks, l_tempo_ms
  );
  COMMIT;

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    raise_application_error(-20999,
      'Erro em ' || lc_nome_unidade || ': ' || SQLERRM, TRUE);
END consultar_rag;
/


--==============================================================================
-- 6. Uso
--==============================================================================

-- 26ai
DECLARE
  l_resposta CLOB;
BEGIN
  consultar_rag(
    p_pergunta   => 'Qual o protocolo de necropsia para óbito por overdose?',
    -- Use um modelo de chat disponível na sua região do OCI Generative AI.
    -- A doc Oracle cita, entre outros, "meta.llama-3.3-70b-instruct" e
    -- "cohere.command-r-08-2024"; o catálogo muda periodicamente.
    p_modelo_llm => '<modelo_chat_ocigenai>',
    p_resposta   => l_resposta
  );

  DBMS_OUTPUT.put_line('=== RESPOSTA ===');
  DBMS_OUTPUT.put_line(DBMS_LOB.substr(l_resposta, 4000, 1));
END;
/


--==============================================================================
-- 7. Análise de qualidade (queries de monitoramento)
--==============================================================================

-- Tempo médio por pergunta (últimos 7 dias)
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
  - 0.3-0.5 é típico para COSINE; teste empiricamente com o seu modelo

ANTI-PATTERN 4: Não passar contexto explicitamente delimitado
  -- RUIM: prompt que mistura contexto com pergunta sem separadores
  -- BOM: tags claras "=== CONTEXTO ===" e "=== PERGUNTA ==="

ANTI-PATTERN 5: Temperature alta em RAG factual
  - A doc Oracle recomenda começar com temperature 0 e, se precisar de
    variação, ficar entre 0 e 1; valores altos favorecem alucinação
  - Em ocigenai o parâmetro do provedor vai dentro de "chatRequest"

ANTI-PATTERN 6: Não pedir citações
  - Sem isso, LLM dá resposta sem rastreabilidade
  - Sempre instruir "cite os documentos usados"

ANTI-PATTERN 7: RAG sem fallback
  - Se nenhum chunk foi encontrado, o LLM ainda responde (alucina)
  - Cheque qtd_chunks ANTES de chamar o LLM (como em consultar_rag)

ANTI-PATTERN 8: Montar o JSON de parâmetros por concatenação de strings
  - Aspas no nome do modelo/URL quebram o JSON; use JSON_OBJECT_T ou JSON_OBJECT

ANTI-PATTERN 9: Chamar provedor externo sem limite de uso
  - Use "max_count" nos params para limitar o nº de chamadas ao provedor e
    "transfer_timeout" (default 60 s) para não travar a sessão
*/
