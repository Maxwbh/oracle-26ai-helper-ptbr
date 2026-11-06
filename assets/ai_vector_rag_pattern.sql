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
-- Tipo: Dependente de configuração — LLM externo (OCI Generative AI) com ACL e credencial
-- RU mínimo: 23.26.0 (qualquer 26ai)
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

-- Dados sensíveis: pergunta, contexto e resposta podem conter dados pessoais
-- ou sigilosos. Por padrão o log guarda só o HASH da pergunta, o tamanho do
-- contexto e métricas; o texto integral é opt-in (p_registrar_texto) e deve
-- seguir a política de retenção/LGPD do órgão (expurgo na seção 5).
CREATE TABLE log_consultas_rag (
  id                NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pergunta_hash     RAW(32)        NOT NULL,   -- SHA-256 da pergunta
  pergunta          VARCHAR2(4000),            -- só com p_registrar_texto
  contexto_usado    CLOB,                      -- só com p_registrar_texto
  resposta_llm      CLOB,                      -- só com p_registrar_texto
  tamanho_contexto  NUMBER,
  modelo_llm        VARCHAR2(200),
  qtd_chunks        NUMBER,
  tempo_ms          NUMBER,
  situacao          VARCHAR2(10)   NOT NULL,   -- OK | ERRO
  erro              VARCHAR2(4000),
  usuario           VARCHAR2(128)  DEFAULT USER,
  consultado_em     TIMESTAMP      DEFAULT SYSTIMESTAMP
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
-- Valores reais NÃO ficam no script: são pedidos em tempo de execução
-- (SQLcl/SQL*Plus, ACCEPT ... HIDE) e descartados com UNDEFINE.
ACCEPT oci_user_ocid        CHAR PROMPT 'user_ocid: '
ACCEPT oci_tenancy_ocid     CHAR PROMPT 'tenancy_ocid: '
ACCEPT oci_compartment_ocid CHAR PROMPT 'compartment_ocid: '
ACCEPT oci_private_key      CHAR PROMPT 'private_key (sem BEGIN/END, uma linha): ' HIDE
ACCEPT oci_fingerprint      CHAR PROMPT 'fingerprint: '

DECLARE
  l_credencial JSON_OBJECT_T := JSON_OBJECT_T();
BEGIN
  l_credencial.put('user_ocid',        '&oci_user_ocid');
  l_credencial.put('tenancy_ocid',     '&oci_tenancy_ocid');
  l_credencial.put('compartment_ocid', '&oci_compartment_ocid');
  l_credencial.put('private_key',      '&oci_private_key');
  l_credencial.put('fingerprint',      '&oci_fingerprint');

  DBMS_VECTOR_CHAIN.CREATE_CREDENTIAL(
    credential_name => 'CRED_OCI_GENAI',
    params          => JSON(l_credencial.to_string)
  );
END;
/

UNDEFINE oci_user_ocid oci_tenancy_ocid oci_compartment_ocid oci_private_key oci_fingerprint

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

EXCEPTION
  WHEN OTHERS THEN
    -- Libera o LOB temporário também em caso de erro (evita vazamento de
    -- espaço temporário na sessão) e propaga o erro original
    IF DBMS_LOB.istemporary(l_prompt) = 1 THEN
      DBMS_LOB.freetemporary(l_prompt);
    END IF;
    RAISE;
END gerar_resposta_llm;
/


--==============================================================================
-- 5. Procedure orquestradora — RAG completo
--
-- Contrato transacional: consultar_rag NÃO faz COMMIT nem ROLLBACK. A
-- transação de negócio pertence ao chamador. A auditoria é gravada por
-- registrar_consulta_rag em transação AUTÔNOMA, para que o log sobreviva a
-- um ROLLBACK do chamador e não confirme nada da transação dele.
--==============================================================================

-- 26ai
CREATE OR REPLACE PROCEDURE registrar_consulta_rag (
  p_pergunta        IN VARCHAR2,
  p_contexto        IN CLOB,
  p_resposta        IN CLOB,
  p_modelo_llm      IN VARCHAR2,
  p_qtd_chunks      IN PLS_INTEGER,
  p_tempo_ms        IN NUMBER,
  p_situacao        IN VARCHAR2,
  p_erro            IN VARCHAR2,
  p_registrar_texto IN BOOLEAN
) IS
  PRAGMA AUTONOMOUS_TRANSACTION;
  l_pergunta  VARCHAR2(4000);
  l_contexto  CLOB;
  l_resposta  CLOB;
BEGIN
  -- Mascaramento: por padrão grava só o hash SHA-256 da pergunta e o tamanho
  -- do contexto. Texto integral (pergunta, contexto, resposta) só quando a
  -- política de privacidade/LGPD do órgão autorizar (p_registrar_texto).
  IF p_registrar_texto THEN
    l_pergunta := SUBSTR(p_pergunta, 1, 4000);
    l_contexto := p_contexto;
    l_resposta := p_resposta;
  END IF;

  INSERT INTO log_consultas_rag (
    pergunta_hash, pergunta, contexto_usado, resposta_llm, tamanho_contexto,
    modelo_llm, qtd_chunks, tempo_ms, situacao, erro
  ) VALUES (
    STANDARD_HASH(NVL(p_pergunta, ' '), 'SHA256'),
    l_pergunta, l_contexto, l_resposta,
    DBMS_LOB.getlength(p_contexto),
    p_modelo_llm, p_qtd_chunks, p_tempo_ms, p_situacao, SUBSTR(p_erro, 1, 4000)
  );
  COMMIT;   -- confirma APENAS a transação autônoma do log
END registrar_consulta_rag;
/

-- 26ai
CREATE OR REPLACE PROCEDURE consultar_rag (
  p_pergunta        IN  VARCHAR2,
  p_modelo_llm      IN  VARCHAR2,
  p_resposta        OUT CLOB,
  p_registrar_texto IN  BOOLEAN DEFAULT FALSE
) IS
  lc_nome_unidade CONSTANT VARCHAR2(60) := 'CONSULTAR_RAG';

  l_contexto    CLOB;
  l_inicio      TIMESTAMP;
  l_duracao     INTERVAL DAY TO SECOND;
  l_tempo_ms    NUMBER;
  l_qtd_chunks  PLS_INTEGER := 0;

  FUNCTION calcular_tempo_ms RETURN NUMBER IS
  BEGIN
    l_duracao := SYSTIMESTAMP - l_inicio;
    RETURN EXTRACT(HOUR   FROM l_duracao) * 3600000 +
           EXTRACT(MINUTE FROM l_duracao) * 60000 +
           EXTRACT(SECOND FROM l_duracao) * 1000;
  END calcular_tempo_ms;
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
  l_qtd_chunks := NVL(REGEXP_COUNT(l_contexto, '\[Documento:'), 0);

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

  l_tempo_ms := calcular_tempo_ms;

  -- Auditoria (transação autônoma — não interfere na do chamador)
  registrar_consulta_rag(
    p_pergunta        => p_pergunta,
    p_contexto        => l_contexto,
    p_resposta        => p_resposta,
    p_modelo_llm      => p_modelo_llm,
    p_qtd_chunks      => l_qtd_chunks,
    p_tempo_ms        => l_tempo_ms,
    p_situacao        => 'OK',
    p_erro            => NULL,
    p_registrar_texto => p_registrar_texto
  );

EXCEPTION
  WHEN OTHERS THEN
    -- Registra a falha (autônomo) e devolve o erro; o ROLLBACK, se
    -- necessário, é decisão do chamador.
    registrar_consulta_rag(
      p_pergunta        => p_pergunta,
      p_contexto        => l_contexto,
      p_resposta        => NULL,
      p_modelo_llm      => p_modelo_llm,
      p_qtd_chunks      => l_qtd_chunks,
      p_tempo_ms        => calcular_tempo_ms,
      p_situacao        => 'ERRO',
      p_erro            => SQLERRM,
      p_registrar_texto => p_registrar_texto
    );
    raise_application_error(-20999,
      'Erro em ' || lc_nome_unidade || ': ' || SQLERRM, TRUE);
END consultar_rag;
/

-- 26ai — retenção do log: expurgo periódico (agende com DBMS_SCHEDULER).
-- O prazo de retenção é definido pela política do órgão (LGPD, normas
-- forenses) — 90 dias é só um valor de exemplo.
CREATE OR REPLACE PROCEDURE expurgar_log_rag (
  p_dias_retencao IN PLS_INTEGER DEFAULT 90
) IS
BEGIN
  DELETE FROM log_consultas_rag
   WHERE consultado_em < SYSTIMESTAMP - NUMTODSINTERVAL(p_dias_retencao, 'DAY');
  -- Rotina de manutenção (job), não API de negócio: o COMMIT fica no job.
END expurgar_log_rag;
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

-- Consultas onde nenhum chunk foi encontrado (ajustar threshold ou enriquecer
-- corpus). "pergunta" só vem preenchida se o texto foi registrado (opt-in).
SELECT pergunta_hash, pergunta, consultado_em
  FROM log_consultas_rag
 WHERE qtd_chunks = 0
   AND situacao = 'OK'
 ORDER BY consultado_em DESC
 FETCH FIRST 20 ROWS ONLY;

-- Top 10 perguntas repetidas (oportunidade de FAQ) — agrupadas pelo hash
SELECT pergunta_hash, MAX(pergunta) AS pergunta_se_registrada, COUNT(*) AS qtd
  FROM log_consultas_rag
 GROUP BY pergunta_hash
 ORDER BY qtd DESC
 FETCH FIRST 10 ROWS ONLY;

-- Taxa de erro (falhas do provedor de LLM, rede, credencial)
SELECT situacao, COUNT(*) AS qtd
  FROM log_consultas_rag
 WHERE consultado_em > SYSTIMESTAMP - INTERVAL '7' DAY
 GROUP BY situacao;


--==============================================================================
-- 8. Anti-patterns RAG
--==============================================================================

/*
ANTI-PATTERN 1: Logar tudo (ou nada) sem política
  - Sem log, impossível auditar de onde veio cada resposta
  - Log integral sem política expõe dados pessoais/sigilosos (LGPD)
  - Padrão aqui: hash + métricas sempre; texto integral opt-in; expurgo por
    prazo definido pelo órgão; log em transação autônoma

ANTI-PATTERN 1b: COMMIT/ROLLBACK dentro de API reutilizável
  - Confirma ou desfaz trabalho do chamador sem ele saber
  - A transação é do chamador; só o log usa PRAGMA AUTONOMOUS_TRANSACTION

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
