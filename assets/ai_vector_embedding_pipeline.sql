--==============================================================================
-- Template: Pipeline de Embedding
--
-- Cobre: chunking de documentos longos, geração em lote, atualização
-- incremental quando documentos mudam, integração com modelos externos
-- via DBMS_VECTOR_CHAIN.
--
-- Cenário típico: documentos longos (laudos, contratos, artigos) com 10-50k caracteres.
-- Embedding direto de documento inteiro perde nuance — precisa chunking.
--
-- Revisado: nov/2026 contra a documentação Oracle AI Database 26ai (RU 23.26.4)
-- Tipo: Dependente de configuração — modelo ONNX no banco; provedor externo exige rede, ACL e credencial
-- RU mínimo: 23.26.0 (qualquer 26ai)
-- Edição Free: Parcial — chunking e embedding com modelo ONNX no banco rodam
--              no Free (limite de 2 GB de RAM pesa no modelo); a seção 6
--              (provedor externo) exige rede de saída, ACL e credencial; o
--              guia de licenças não lista Vector Search explicitamente p/ Free.
--==============================================================================


--==============================================================================
-- 1. Chunking — quebrar documento longo em pedaços
--
-- Cada modelo de embedding tem um limite de tokens de entrada (consulte o
-- model card). Além disso, UTL_TO_EMBEDDING aceita no máximo 4000 caracteres
-- por entrada. Documentos longos precisam ser fatiados antes.
--==============================================================================

-- 26ai — DBMS_VECTOR_CHAIN.UTL_TO_CHUNKS devolve VECTOR_ARRAY_T: cada elemento
-- é um JSON {chunk_id, chunk_offset, chunk_length, chunk_data}. Use-a no FROM
-- e extraia os campos de COLUMN_VALUE com JSON_VALUE.
SELECT JSON_VALUE(c.column_value, '$.chunk_id'     RETURNING NUMBER) AS id_chunk,
       JSON_VALUE(c.column_value, '$.chunk_offset' RETURNING NUMBER) AS posicao,
       JSON_VALUE(c.column_value, '$.chunk_length' RETURNING NUMBER) AS tamanho,
       JSON_VALUE(c.column_value, '$.chunk_data'   RETURNING VARCHAR2(4000)) AS texto
  FROM DBMS_VECTOR_CHAIN.UTL_TO_CHUNKS(
         'Texto longo do laudo aqui, com várias frases e parágrafos. ' ||
         'Pode ter dezenas de milhares de caracteres. ' ||
         'O chunker quebra em pedaços que cabem no modelo.',
         JSON('{
           "by"        : "words",
           "max"       : 100,
           "overlap"   : 10,
           "split"     : "sentence",
           "language"  : "portuguese",
           "normalize" : "all"
         }')
       ) c;

-- Parâmetros explicados (UTL_TO_CHUNKS):
--   by:        "words" (default) | "characters" (ou "chars") | "vocabulary"
--              ("vocabulary" conta tokens do tokenizer do modelo; exige
--               vocabulário carregado com DBMS_VECTOR_CHAIN.CREATE_VOCABULARY)
--   max:       words 10-1000 | characters 50-4000 | vocabulary 10-1000 (default 100)
--   overlap:   texto do chunk anterior repetido no próximo; 5% a 20% de max
--              (default 0)
--   split:     "recursively" (default: blankline → newline → space → none) |
--              "sentence" (só com by words/vocabulary) | "newline" |
--              "blankline" | "space" | "none" | "custom" (+ "custom_list")
--   language:  nome/abreviação de idioma NLS (default: NLS_LANGUAGE da sessão)
--   normalize: "all" (default em UTL_TO_CHUNKS) | "none" | "options"
--              (+ "norm_options": ["whitespace","punctuation","widechar"])
--   extended:  true eleva o limite do chunk para 32767 bytes

-- 26ai — alternativa em SQL puro: VECTOR_CHUNKS (função de tabela no FROM;
-- devolve CHUNK_OFFSET, CHUNK_LENGTH, CHUNK_TEXT). Informe os parâmetros na
-- ordem da doc. Atenção: em VECTOR_CHUNKS o NORMALIZE default é NONE.
SELECT c.chunk_offset, c.chunk_length, c.chunk_text
  FROM documentos_forenses d,
       VECTOR_CHUNKS(d.conteudo
                     BY words
                     MAX 100
                     OVERLAP 10
                     SPLIT BY sentence
                     LANGUAGE portuguese
                     NORMALIZE all) c
 WHERE d.id = 1;


--==============================================================================
-- 2. Tabela de chunks (relação 1:N com documento original)
--==============================================================================

-- 26ai
CREATE TABLE chunks_documentos (
  id              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_documento    NUMBER NOT NULL,
  num_chunk       NUMBER NOT NULL,
  texto_chunk     VARCHAR2(4000),
  embedding       VECTOR(384, FLOAT32),
  criado_em       DATE DEFAULT SYSDATE,
  CONSTRAINT fk_chunks_doc FOREIGN KEY (id_documento)
    REFERENCES documentos_forenses(id) ON DELETE CASCADE,
  CONSTRAINT uk_chunk_doc_num UNIQUE (id_documento, num_chunk)
);

CREATE INDEX idx_chunks_id_doc ON chunks_documentos(id_documento);

-- 26ai — índice vetorial nos chunks (usado pelo RAG; ver
-- ai_vector_index_strategies.sql para escolher HNSW x IVF)
CREATE VECTOR INDEX idx_chunks_embedding_hnsw
ON chunks_documentos (embedding)
ORGANIZATION INMEMORY NEIGHBOR GRAPH
DISTANCE COSINE
WITH TARGET ACCURACY 95
PARAMETERS (TYPE HNSW, NEIGHBORS 32, EFCONSTRUCTION 200);


--==============================================================================
-- 3. Pipeline completo: documento → chunks → embeddings (DML único)
--
-- Princípio Tim Hall: SQL puro em vez de loop PL/SQL.
--==============================================================================

-- 26ai — para um documento específico
INSERT INTO chunks_documentos (id_documento, num_chunk, texto_chunk, embedding)
SELECT d.id,
       JSON_VALUE(c.column_value, '$.chunk_id' RETURNING NUMBER),
       JSON_VALUE(c.column_value, '$.chunk_data' RETURNING VARCHAR2(4000)),
       VECTOR_EMBEDDING(modelo_minilm_l12 USING
         JSON_VALUE(c.column_value, '$.chunk_data' RETURNING VARCHAR2(4000)) AS data)
  FROM documentos_forenses d,
       DBMS_VECTOR_CHAIN.UTL_TO_CHUNKS(
         d.conteudo,
         JSON('{"by":"words","max":100,"overlap":10,"split":"sentence","language":"portuguese"}')
       ) c
 WHERE d.id = 1;

COMMIT;

-- 26ai — variante encadeada da doc (UTL_TO_CHUNKS → UTL_TO_EMBEDDINGS),
-- útil quando o modelo é trocado por parâmetro JSON ("provider":"database" =
-- ONNX no banco; dá para trocar por um provedor externo sem mudar o SQL):
-- SELECT d.id, et.embed_id, et.embed_data, TO_VECTOR(et.embed_vector)
--   FROM documentos_forenses d,
--        DBMS_VECTOR_CHAIN.UTL_TO_EMBEDDINGS(
--          DBMS_VECTOR_CHAIN.UTL_TO_CHUNKS(d.conteudo, JSON('{"normalize":"all"}')),
--          JSON('{"provider":"database", "model":"modelo_minilm_l12"}')) t,
--        JSON_TABLE(t.column_value, '$[*]' COLUMNS (
--          embed_id     NUMBER         PATH '$.embed_id',
--          embed_data   VARCHAR2(4000) PATH '$.embed_data',
--          embed_vector CLOB           PATH '$.embed_vector')) et;


--==============================================================================
-- 4. Package para chunking + embedding em batch
--==============================================================================

-- 26ai
CREATE OR REPLACE PACKAGE pipeline_embedding_pkg AS

  -- Reprocessa um documento (apaga e recria seus chunks).
  -- Contrato transacional: NÃO faz COMMIT. A transação pertence ao chamador
  -- (ex.: gravar o documento e seus chunks numa mesma unidade de trabalho).
  -- Em erro, desfaz só o próprio trabalho (ROLLBACK TO SAVEPOINT) e propaga.
  -- p_modelo: só modelos cadastrados em USER_MINING_MODELS são aceitos.
  PROCEDURE processar_documento (
    p_id_documento  IN NUMBER,
    p_modelo        IN VARCHAR2 DEFAULT NULL
  );

  -- Rotina de LOTE (job/agendamento), não API de negócio: processa documentos
  -- criados desde p_data_corte ou ainda sem chunks e confirma CADA documento
  -- (COMMIT por documento), para que uma falha não desfaça o lote inteiro.
  -- Não chame de dentro de uma transação de aplicação.
  PROCEDURE processar_pendentes_lote (
    p_data_corte IN DATE DEFAULT SYSDATE - 1
  );

END pipeline_embedding_pkg;
/

-- 26ai
CREATE OR REPLACE PACKAGE BODY pipeline_embedding_pkg AS

  gc_nome_pacote    CONSTANT VARCHAR2(30)  := 'PIPELINE_EMBEDDING_PKG';

  -- Configurações default
  gc_modelo_default CONSTANT VARCHAR2(128) := 'MODELO_MINILM_L12';
  gc_params_chunk   CONSTANT VARCHAR2(200) :=
    '{"by":"words","max":100,"overlap":10,"split":"sentence","language":"portuguese"}';

  PROCEDURE processar_documento (
    p_id_documento  IN NUMBER,
    p_modelo        IN VARCHAR2 DEFAULT NULL
  ) IS
    lc_nome_unidade CONSTANT VARCHAR2(60) := gc_nome_pacote || '.processar_documento';
    l_conteudo      CLOB;
    l_modelo        VARCHAR2(128);
    l_qtd_chunks    PLS_INTEGER;
  BEGIN
    -- Ponto de retorno para desfazer SÓ o trabalho desta procedure
    SAVEPOINT sp_processar_documento;

    -- O nome do modelo entra no SQL como identificador (VECTOR_EMBEDDING não
    -- aceita bind no nome) → valida contra SQL injection.
    l_modelo := DBMS_ASSERT.SIMPLE_SQL_NAME(NVL(p_modelo, gc_modelo_default));

    -- Allowlist: além da forma do nome, exige que o modelo exista no schema
    BEGIN
      SELECT m.model_name
        INTO l_modelo
        FROM user_mining_models m
       WHERE m.model_name = UPPER(l_modelo);
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        raise_application_error(-20104,
          'Modelo não cadastrado: ' || l_modelo || ' em ' || lc_nome_unidade);
    END;

    -- Recupera documento
    SELECT conteudo INTO l_conteudo
      FROM documentos_forenses
     WHERE id = p_id_documento;

    -- Apaga chunks anteriores (reprocessamento idempotente)
    DELETE FROM chunks_documentos WHERE id_documento = p_id_documento;

    -- Insere novos chunks com embedding
    EXECUTE IMMEDIATE q'[
      INSERT INTO chunks_documentos (id_documento, num_chunk, texto_chunk, embedding)
      SELECT :p_id,
             JSON_VALUE(c.column_value, '$.chunk_id' RETURNING NUMBER),
             JSON_VALUE(c.column_value, '$.chunk_data' RETURNING VARCHAR2(4000)),
             VECTOR_EMBEDDING(]' || l_modelo || q'[ USING
               JSON_VALUE(c.column_value, '$.chunk_data' RETURNING VARCHAR2(4000)) AS data)
        FROM DBMS_VECTOR_CHAIN.UTL_TO_CHUNKS(:p_conteudo, JSON(:p_params)) c
    ]' USING p_id_documento, l_conteudo, gc_params_chunk;

    l_qtd_chunks := SQL%ROWCOUNT;
    -- Sem COMMIT: a transação é do chamador

    DBMS_OUTPUT.put_line(
      lc_nome_unidade || ': documento ' || p_id_documento ||
      ' processado em ' || l_qtd_chunks || ' chunks'
    );

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      raise_application_error(-20101,
        'Documento não encontrado: ' || p_id_documento || ' em ' || lc_nome_unidade);
    WHEN OTHERS THEN
      -- Desfaz só o que esta procedure fez; o trabalho anterior do chamador
      -- permanece
      ROLLBACK TO sp_processar_documento;
      raise_application_error(-20999,
        'Erro em ' || lc_nome_unidade || ': ' || SQLERRM, TRUE);
  END processar_documento;


  PROCEDURE processar_pendentes_lote (
    p_data_corte IN DATE DEFAULT SYSDATE - 1
  ) IS
    lc_nome_unidade CONSTANT VARCHAR2(60) := gc_nome_pacote || '.processar_pendentes_lote';
    l_total_processados PLS_INTEGER := 0;
  BEGIN
    -- Loop por DOCUMENTO (não por linha de chunk): cada documento é uma
    -- unidade de COMMIT/reprocessamento independente.
    FOR r_documento IN (
      SELECT d.id
        FROM documentos_forenses d
       WHERE d.data_criacao >= p_data_corte
          OR NOT EXISTS (SELECT 1
                           FROM chunks_documentos c
                          WHERE c.id_documento = d.id)
    ) LOOP
      processar_documento(r_documento.id);
      COMMIT;   -- rotina de lote: confirma documento a documento
      l_total_processados := l_total_processados + 1;
    END LOOP;

    DBMS_OUTPUT.put_line(
      lc_nome_unidade || ': ' || l_total_processados || ' documentos processados'
    );
  END processar_pendentes_lote;

END pipeline_embedding_pkg;
/


--==============================================================================
-- 5. Search em chunks (RAG-friendly retrieval)
--==============================================================================

-- 26ai — top N chunks mais similares à pergunta, com o documento original
SELECT d.id        AS id_documento,
       d.titulo,
       c.num_chunk,
       c.texto_chunk,
       VECTOR_DISTANCE(
         c.embedding,
         VECTOR_EMBEDDING(modelo_minilm_l12 USING
           'qual a causa de morte no caso de trauma craniano' AS data),
         COSINE) AS distancia
  FROM chunks_documentos c
  JOIN documentos_forenses d ON d.id = c.id_documento
 ORDER BY distancia
 FETCH APPROX FIRST 5 ROWS ONLY;


--==============================================================================
-- 6. Pipeline com modelo externo (REST API)
--
-- Quando o modelo roda fora do banco (OpenAI, Cohere, OCI Generative AI,
-- Google AI, Hugging Face, Vertex AI, Mistral, Ollama...).
-- DBMS_VECTOR_CHAIN.UTL_TO_EMBEDDING faz a chamada HTTP e devolve VECTOR.
--==============================================================================

-- Setup 1 (como SYS/DBA): liberar saída HTTP para o host do provedor
-- (padrão de ACL; prefira o host exato em vez de '*')
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE(
    host => 'api.openai.com',
    ace  => xs$ace_type(privilege_list => xs$name_list('connect'),
                        principal_name => 'USUARIO_VETOR',
                        principal_type => xs_acl.ptype_db));
END;
/
GRANT CREATE CREDENTIAL TO usuario_vetor;
-- Se houver proxy corporativo: EXEC UTL_HTTP.SET_PROXY('<host-proxy>:<porta>');

-- 26ai — Setup 2 (como usuario_vetor): credential do provedor.
-- OpenAI, Cohere, Google AI, Hugging Face e Vertex AI usam {"access_token": ...}.
-- Só OCI Generative AI ("ocigenai") usa user_ocid/tenancy_ocid/
-- compartment_ocid/private_key/fingerprint.
-- Nunca deixe a chave real em script versionado: ela é pedida em tempo de
-- execução (SQLcl/SQL*Plus) e descartada com UNDEFINE.
ACCEPT chave_api_openai CHAR PROMPT 'Chave da API OpenAI: ' HIDE

DECLARE
  l_credencial JSON_OBJECT_T := JSON_OBJECT_T();
BEGIN
  l_credencial.put('access_token', '&chave_api_openai');
  DBMS_VECTOR_CHAIN.CREATE_CREDENTIAL(
    credential_name => 'CRED_OPENAI',
    params          => JSON(l_credencial.to_string)
  );
END;
/

UNDEFINE chave_api_openai

-- 26ai — geração via API externa: UTL_TO_EMBEDDING devolve UM VECTOR
-- (função escalar no SELECT). Para vários chunks de uma vez use
-- UTL_TO_EMBEDDINGS (no FROM, devolve VECTOR_ARRAY_T — ver seção 3).
-- Atenção: a dimensão do modelo externo precisa casar com a coluna VECTOR(n);
-- 384 (MiniLM) NÃO serve para modelos de outras dimensões.
SELECT DBMS_VECTOR_CHAIN.UTL_TO_EMBEDDING(
         'Texto a ser vetorizado',
         JSON('{
           "provider"        : "openai",
           "credential_name" : "CRED_OPENAI",
           "url"             : "https://api.openai.com/v1/embeddings",
           "model"           : "<modelo_embedding_openai>"
         }')
       ) AS embedding
  FROM dual;
-- "model": use um modelo de embedding vigente do provedor (a doc Oracle usa
-- "text-embedding-3-small" como exemplo). Opcionais: "transfer_timeout"
-- (default 60 s) e "max_count" (limita o nº de chamadas ao provedor).


--==============================================================================
-- 7. Anti-patterns
--==============================================================================

/*
ANTI-PATTERN 1: Embedding de documento inteiro de 50k caracteres
  - Tudo que passa do limite de tokens do modelo fica fora do vetor (ou a
    chamada falha, conforme o modelo/provedor); UTL_TO_EMBEDDING aceita no
    máximo 4000 caracteres por entrada
  - Faça chunking para qualquer documento maior que o limite do modelo

ANTI-PATTERN 2: Chunks sem overlap
  - Frases na borda perdem contexto
  - A faixa aceita é 5% a 20% de max; 10% é um bom ponto de partida

ANTI-PATTERN 3: Reprocessar TODO o corpus quando 1 doc muda
  -- RUIM
  TRUNCATE TABLE chunks_documentos;
  -- depois reprocessa tudo

  -- BOM: incremental
  DELETE FROM chunks_documentos WHERE id_documento = :id_modificado;
  -- e reprocessa só esse

ANTI-PATTERN 4: Não validar dimensão do modelo
  -- Tabela criada com VECTOR(384, FLOAT32) e modelo de 768 dimensões:
  INSERT INTO chunks_documentos (id_documento, num_chunk, embedding)
  VALUES (1, 1, VECTOR_EMBEDDING(modelo_768 USING 'teste' AS data));
  -- ORA-51803: Vector dimension count must match the dimension count
  --            specified in the column definition
  -- E comparar vetores de dimensões diferentes em VECTOR_DISTANCE gera
  -- ORA-51808. Vetores de modelos diferentes não são comparáveis mesmo
  -- quando a dimensão coincide.

ANTI-PATTERN 5: Embedding de campos identificadores (CPF, código)
  -- Embedding semântico de '12345678900' não traz valor — use índice B-tree
  -- Use vector apenas em campos com semântica (texto, descrição)

ANTI-PATTERN 6: Nome de modelo concatenado sem validação em SQL dinâmico
  -- VECTOR_EMBEDDING exige o nome do modelo como identificador: valide com
  -- DBMS_ASSERT.SIMPLE_SQL_NAME (como no package acima)
*/
