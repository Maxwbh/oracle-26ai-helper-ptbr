--==============================================================================
-- Template: Pipeline de Embedding
--
-- Cobre: chunking de documentos longos, geração em lote, atualização
-- incremental quando documentos mudam, integração com modelos externos
-- via DBMS_VECTOR_CHAIN.
--
-- Cenário típico: documentos longos (laudos, contratos, artigos) com 10-50k caracteres.
-- Embedding direto de documento inteiro perde nuance — precisa chunking.
--==============================================================================


--==============================================================================
-- 1. Chunking — quebrar documento longo em pedaços
--
-- Modelos de embedding têm limite de tokens (~512 para MiniLM, 8192 para
-- text-embedding-3). Documentos longos precisam ser fatiados.
--==============================================================================

-- DBMS_VECTOR_CHAIN.UTL_TO_CHUNKS: chunking nativo
SELECT chunk_data
  FROM TABLE(
    DBMS_VECTOR_CHAIN.UTL_TO_CHUNKS(
      data       => 'Texto longo do laudo aqui, com várias frases e parágrafos. ' ||
                    'Pode ter dezenas de milhares de caracteres. ' ||
                    'O chunker quebra em pedaços que cabem no modelo.',
      params     => JSON('{
        "by"        : "words",      
        "max"       : 100,           
        "overlap"   : 10,            
        "split"     : "sentence",    
        "language"  : "portuguese",  
        "normalize" : "all"
      }')
    )
  );

-- Parâmetros explicados:
--   by: "words", "characters", "tokens"
--   max: tamanho máximo do chunk
--   overlap: sobreposição entre chunks (preserva contexto na borda)
--   split: "sentence" (preserva sentenças) ou "newline" ou "none"
--   language: idioma para tokenização inteligente
--   normalize: "all" (lowercase, trim, remove duplicados de whitespace)


--==============================================================================
-- 2. Tabela de chunks (relação 1:N com documento original)
--==============================================================================

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


--==============================================================================
-- 3. Pipeline completo: documento → chunks → embeddings (DML único)
--
-- Princípio Tim Hall: SQL puro em vez de loop PL/SQL.
--==============================================================================

-- Para um documento específico:
INSERT INTO chunks_documentos (id_documento, num_chunk, texto_chunk, embedding)
SELECT 1 AS id_documento,
       chunk_offset AS num_chunk,
       chunk_data AS texto_chunk,
       VECTOR_EMBEDDING(modelo_minilm_l12 USING chunk_data AS data) AS embedding
  FROM TABLE(
    DBMS_VECTOR_CHAIN.UTL_TO_CHUNKS(
      data    => (SELECT conteudo FROM documentos_forenses WHERE id = 1),
      params  => JSON('{"by":"words","max":100,"overlap":10,"split":"sentence","language":"portuguese"}')
    )
  );

COMMIT;


--==============================================================================
-- 4. Procedure para chunking + embedding em batch
--==============================================================================

CREATE OR REPLACE PACKAGE BODY pipeline_embedding_pkg AS

  gc_nome_pacote CONSTANT VARCHAR2(30) := 'PIPELINE_EMBEDDING_PKG';

  -- Configurações default
  gc_chunk_max         CONSTANT PLS_INTEGER := 100;
  gc_chunk_overlap     CONSTANT PLS_INTEGER := 10;
  gc_modelo_default    CONSTANT VARCHAR2(30) := 'MODELO_MINILM_L12';

  PROCEDURE processar_documento (
    p_id_documento  IN NUMBER,
    p_modelo        IN VARCHAR2 DEFAULT NULL
  ) IS
    lc_nome_unidade CONSTANT VARCHAR2(60) := gc_nome_pacote || '.processar_documento';
    l_conteudo      CLOB;
    l_modelo        VARCHAR2(30) := NVL(p_modelo, gc_modelo_default);
    l_qtd_chunks    PLS_INTEGER;
  BEGIN
    -- Recupera documento
    SELECT conteudo INTO l_conteudo
      FROM documentos_forenses
     WHERE id = p_id_documento;

    -- Apaga chunks anteriores (reprocessamento idempotente)
    DELETE FROM chunks_documentos WHERE id_documento = p_id_documento;

    -- Insere novos chunks com embedding
    EXECUTE IMMEDIATE q'[
      INSERT INTO chunks_documentos (id_documento, num_chunk, texto_chunk, embedding)
      SELECT :p_id, chunk_offset, chunk_data,
             VECTOR_EMBEDDING(]' || l_modelo || q'[ USING chunk_data AS data)
        FROM TABLE(
          DBMS_VECTOR_CHAIN.UTL_TO_CHUNKS(
            data => :p_conteudo,
            params => JSON('{"by":"words","max":100,"overlap":10,"split":"sentence","language":"portuguese"}')
          )
        )
    ]' USING p_id_documento, l_conteudo;

    l_qtd_chunks := SQL%ROWCOUNT;

    COMMIT;

    DBMS_OUTPUT.put_line(
      lc_nome_unidade || ': documento ' || p_id_documento ||
      ' processado em ' || l_qtd_chunks || ' chunks'
    );

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      raise_application_error(-20101,
        'Documento não encontrado: ' || p_id_documento || ' em ' || lc_nome_unidade);
    WHEN OTHERS THEN
      ROLLBACK;
      raise_application_error(-20999,
        'Erro em ' || lc_nome_unidade || ': ' || SQLERRM);
  END processar_documento;


  -- Processa todos documentos modificados desde data X
  PROCEDURE processar_pendentes (
    p_data_corte IN DATE DEFAULT SYSDATE - 1
  ) IS
    lc_nome_unidade CONSTANT VARCHAR2(60) := gc_nome_pacote || '.processar_pendentes';
    l_total_processados PLS_INTEGER := 0;
  BEGIN
    FOR r IN (
      SELECT id FROM documentos_forenses
       WHERE data_criacao >= p_data_corte
          OR id NOT IN (SELECT DISTINCT id_documento FROM chunks_documentos)
    ) LOOP
      processar_documento(r.id);
      l_total_processados := l_total_processados + 1;
    END LOOP;

    DBMS_OUTPUT.put_line(
      lc_nome_unidade || ': ' || l_total_processados || ' documentos processados'
    );
  END processar_pendentes;

END pipeline_embedding_pkg;
/


--==============================================================================
-- 5. Search em chunks (RAG-friendly retrieval)
--==============================================================================

-- Top N chunks mais similares à pergunta, retornando documento original
WITH busca AS (
  SELECT VECTOR_EMBEDDING(modelo_minilm_l12 USING
           'qual a causa de morte no caso de trauma craniano' AS data
         ) AS query_emb
    FROM dual
)
SELECT d.id        AS id_documento,
       d.titulo,
       c.num_chunk,
       c.texto_chunk,
       VECTOR_DISTANCE(c.embedding, b.query_emb, COSINE) AS distancia
  FROM chunks_documentos c
  JOIN documentos_forenses d ON d.id = c.id_documento
 CROSS JOIN busca b
 ORDER BY distancia
 FETCH APPROX FIRST 5 ROWS ONLY;


--==============================================================================
-- 6. Pipeline com modelo externo (REST API)
--
-- Quando modelo é proprietário e roda fora do banco
-- (OpenAI, Azure OpenAI, Cohere, etc.).
-- DBMS_VECTOR_CHAIN.UTL_TO_EMBEDDING faz HTTP call para gerar.
--==============================================================================

-- Setup: credential para o serviço
BEGIN
  DBMS_VECTOR.CREATE_CREDENTIAL(
    credential_name  => 'CRED_OPENAI',
    params           => JSON('{
      "user_ocid"          : "...",
      "tenancy_ocid"       : "...",
      "private_key"        : "...",
      "fingerprint"        : "..."
    }')
  );
END;
/

-- Geração via API externa
SELECT VECTOR_EMBEDDING_TEXT
  FROM TABLE(
    DBMS_VECTOR_CHAIN.UTL_TO_EMBEDDING(
      data   => 'Texto a ser vetorizado',
      params => JSON('{
        "provider"        : "openai",
        "credential_name" : "CRED_OPENAI",
        "url"             : "https://api.openai.com/v1/embeddings",
        "model"           : "text-embedding-3-large"
      }')
    )
  );


--==============================================================================
-- 7. Anti-patterns
--==============================================================================

/*
ANTI-PATTERN 1: Embedding de documento inteiro de 50k chars
  - Modelo trunca em 512 tokens, perde 90% do conteúdo
  - Use chunking obrigatoriamente para documentos > 1000 caracteres

ANTI-PATTERN 2: Chunks sem overlap
  - Frases na borda perdem contexto
  - overlap = 10-20% do max é típico

ANTI-PATTERN 3: Reprocessar TODO o corpus quando 1 doc muda
  -- RUIM
  TRUNCATE TABLE chunks_documentos;
  -- depois reprocessa tudo

  -- BOM: incremental
  DELETE FROM chunks_documentos WHERE id_documento = :id_modificado;
  -- e re-processa só esse

ANTI-PATTERN 4: Não validar dimensão do modelo
  -- Tabela criada com VECTOR(384, FLOAT32) mas usar modelo de 768-dim falha
  SELECT VECTOR_EMBEDDING(modelo_768 USING 'teste' AS data) FROM dual;
  -- ORA-22849: vector dimensions mismatch

ANTI-PATTERN 5: Embedding de campos identificadores (CPF, código)
  -- Embedding semântico de '12345678900' não traz valor — use índice B-tree
  -- Use vector apenas em campos com semântica (texto, descrição)
*/
