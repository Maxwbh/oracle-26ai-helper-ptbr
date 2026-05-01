--==============================================================================
-- Template: AI Vector Search — Fundamentos
--
-- Cobre: VECTOR data type, carregar modelo ONNX, gerar embeddings,
--        similarity search (exhaustive), métricas de distance.
--
-- Pré-requisito: Oracle 23ai+ ou 26ai (banner mostra "AI Database").
--                Em 19c não funciona — features novas exclusivas.
--
-- Verificação inicial obrigatória:
--   SELECT banner_full FROM v$version;
--   -- Espera: "Oracle AI Database 26ai Enterprise Edition Release 23.26.x.x.x"
--==============================================================================


--==============================================================================
-- 1. Setup: alocar Vector Memory Pool (uma vez, como SYS)
--
-- Sem isso, HNSW disputa shared pool e causa ORA-04031.
--==============================================================================

-- Sizing rule:
--   bytes ≈ dimensoes × 4 (FLOAT32) × num_linhas × 1.3 (overhead grafo)
-- Exemplo: 1536-dim, 10M linhas → 80 GB
-- Exemplo: 384-dim, 100k linhas → 200 MB
ALTER SYSTEM SET vector_memory_size = 512M SCOPE = SPFILE;

-- Restart obrigatório
SHUTDOWN IMMEDIATE;
STARTUP;

-- Confirmar
SELECT name, value
  FROM v$parameter
 WHERE name = 'vector_memory_size';


--==============================================================================
-- 2. Setup do schema de exploração (executar uma vez)
--==============================================================================

-- Como SYS no PDB de desenvolvimento
CREATE BIGFILE TABLESPACE tbs_vector DATAFILE SIZE 256M AUTOEXTEND ON MAXSIZE 2G;

CREATE USER usuario_vetor IDENTIFIED BY "Oracle_4U_dev"
  DEFAULT TABLESPACE tbs_vector
  TEMPORARY TABLESPACE TEMP
  QUOTA UNLIMITED ON tbs_vector;

GRANT CREATE SESSION, CREATE TABLE, CREATE PROCEDURE TO usuario_vetor;
GRANT CREATE MINING MODEL TO usuario_vetor;
GRANT DB_DEVELOPER_ROLE TO usuario_vetor;  -- role nova em 23ai

-- Diretório para carregar modelo ONNX
CREATE OR REPLACE DIRECTORY dir_modelos AS '/home/oracle/embedding_models';
GRANT READ, WRITE ON DIRECTORY dir_modelos TO usuario_vetor;


--==============================================================================
-- 3. Carregar modelo ONNX no banco
--
-- Pré-requisito: baixar modelo all-MiniLM-L12-v2 (ou similar) de
--   https://huggingface.co/sentence-transformers/all-MiniLM-L12-v2
-- e converter para ONNX (Oracle fornece versão pré-convertida em
--   https://blogs.oracle.com/database/post/embedding-model-onnx-import).
--==============================================================================

-- Como usuario_vetor:
BEGIN
  DBMS_VECTOR.LOAD_ONNX_MODEL(
    directory   => 'DIR_MODELOS',
    file_name   => 'all_MiniLM_L12_v2.onnx',
    model_name  => 'modelo_minilm_l12'
  );
END;
/

-- Verificar carregamento
SELECT model_name, algorithm, mining_function
  FROM user_mining_models
 WHERE model_name = 'MODELO_MINILM_L12';


--==============================================================================
-- 4. Tabela com coluna VECTOR
--
-- Sintaxe: VECTOR(dimensoes, FORMATO)
--   - dimensoes: número fixo (384, 768, 1536) ou * (qualquer)
--   - formato: FLOAT32, FLOAT64, INT8, BINARY
--
-- all-MiniLM-L12-v2 produz vetores de 384 dimensões em FLOAT32.
--==============================================================================

CREATE TABLE documentos_forenses (
  id              NUMBER PRIMARY KEY,
  titulo          VARCHAR2(200),
  conteudo        CLOB,
  categoria       VARCHAR2(50),
  data_criacao    DATE DEFAULT SYSDATE,
  embedding       VECTOR(384, FLOAT32)
);


--==============================================================================
-- 5. Popular embeddings — DML único (princípio Tim Hall)
--==============================================================================

-- Inserir documentos com embedding gerado em SQL puro
INSERT INTO documentos_forenses (id, titulo, conteudo, categoria, embedding)
VALUES (
  1,
  'Laudo necropsia caso 2024-001',
  'Vítima do sexo masculino, 45 anos, óbito por trauma craniano contuso...',
  'NECROPSIA',
  VECTOR_EMBEDDING(modelo_minilm_l12 USING
    'Vítima do sexo masculino, 45 anos, óbito por trauma craniano contuso' AS data)
);

-- Bulk: gerar embeddings para múltiplas linhas (SQL puro)
INSERT INTO documentos_forenses (id, titulo, conteudo, categoria, embedding)
SELECT id_origem,
       titulo_origem,
       conteudo_origem,
       categoria_origem,
       VECTOR_EMBEDDING(modelo_minilm_l12 USING conteudo_origem AS data)
  FROM laudos_origem
 WHERE data_criacao > SYSDATE - 30;

COMMIT;


--==============================================================================
-- 6. Similarity search EXHAUSTIVE (sem índice)
--
-- Calcula distance contra TODAS as linhas. OK para datasets pequenos
-- (<10k linhas) ou exploração. Para produção, use índice (próximos templates).
--==============================================================================

-- Métricas disponíveis: COSINE, EUCLIDEAN, DOT, MANHATTAN, HAMMING
-- Mais comum em texto: COSINE (independe de magnitude)

-- Top 5 mais similares a uma busca textual
SELECT id, titulo, categoria,
       VECTOR_DISTANCE(
         embedding,
         VECTOR_EMBEDDING(modelo_minilm_l12 USING 'morte por arma de fogo' AS data),
         COSINE
       ) AS distancia
  FROM documentos_forenses
 ORDER BY distancia
 FETCH FIRST 5 ROWS ONLY;


-- Query parametrizada com bind variable (recomendado em produção)
DECLARE
  l_busca         VARCHAR2(500) := 'morte por arma de fogo';
  l_limite        PLS_INTEGER := 5;
  CURSOR co_resultados IS
    SELECT id, titulo, categoria,
           VECTOR_DISTANCE(
             embedding,
             VECTOR_EMBEDDING(modelo_minilm_l12 USING l_busca AS data),
             COSINE
           ) AS distancia
      FROM documentos_forenses
     ORDER BY distancia
     FETCH FIRST l_limite ROWS ONLY;
BEGIN
  FOR r IN co_resultados LOOP
    DBMS_OUTPUT.put_line(
      r.id || ' | ' || r.titulo || ' | dist=' || ROUND(r.distancia, 4)
    );
  END LOOP;
END;
/


--==============================================================================
-- 7. Comparar dois embeddings diretamente
--==============================================================================

DECLARE
  l_emb_a VECTOR;
  l_emb_b VECTOR;
  l_dist  NUMBER;
BEGIN
  l_emb_a := VECTOR_EMBEDDING(modelo_minilm_l12 USING 'óbito por arma de fogo' AS data);
  l_emb_b := VECTOR_EMBEDDING(modelo_minilm_l12 USING 'morte por disparo' AS data);

  l_dist := VECTOR_DISTANCE(l_emb_a, l_emb_b, COSINE);
  DBMS_OUTPUT.put_line('Distance COSINE: ' || ROUND(l_dist, 4));
  -- Espera valor baixo (próximo de 0) — frases semanticamente próximas

  l_emb_b := VECTOR_EMBEDDING(modelo_minilm_l12 USING 'receita de bolo de chocolate' AS data);
  l_dist := VECTOR_DISTANCE(l_emb_a, l_emb_b, COSINE);
  DBMS_OUTPUT.put_line('Distance COSINE (descorrelacionado): ' || ROUND(l_dist, 4));
  -- Espera valor alto — frases não relacionadas
END;
/


--==============================================================================
-- 8. Inspeção da coluna VECTOR
--==============================================================================

-- Tamanho em bytes (dimensoes × 4 para FLOAT32)
SELECT id,
       LENGTH(VECTOR_SERIALIZE(embedding)) AS tamanho_serializado,
       VECTOR_DIMENSION_COUNT(embedding) AS dimensoes,
       VECTOR_NORM(embedding) AS norma
  FROM documentos_forenses
 WHERE id <= 3;


--==============================================================================
-- 9. Anti-patterns
--==============================================================================

/*
ANTI-PATTERN 1: Armazenar embeddings em VARCHAR2/CLOB como string
  -- RUIM: '[0.1, 0.2, 0.3, ...]' ocupa 5x mais espaço, não tem índice
  embedding_text CLOB

  -- BOM:
  embedding VECTOR(384, FLOAT32)

ANTI-PATTERN 2: Loop PL/SQL gerando embeddings linha-a-linha
  -- RUIM
  FOR r IN (SELECT id, conteudo FROM origem) LOOP
    UPDATE destino SET embedding = VECTOR_EMBEDDING(...) WHERE id = r.id;
  END LOOP;

  -- BOM: INSERT SELECT em DML único
  INSERT INTO destino SELECT id, ..., VECTOR_EMBEDDING(...) FROM origem;

ANTI-PATTERN 3: FETCH FIRST sem APPROX em query indexada
  -- RUIM (com índice HNSW criado): não usa o índice
  ORDER BY VECTOR_DISTANCE(...) FETCH FIRST 10 ROWS ONLY

  -- BOM: explicita aproximação para usar o índice
  ORDER BY VECTOR_DISTANCE(...) FETCH APPROX FIRST 10 ROWS ONLY

ANTI-PATTERN 4: Misturar métricas de distance entre índice e query
  -- Índice criado com COSINE; query usa EUCLIDEAN → ignora índice
  -- Sempre use a MESMA métrica do índice na query

ANTI-PATTERN 5: Logar vetor inteiro em Logger
  logger.append_param(l_params, 'embedding', l_vetor); -- 384 floats poluição

  -- BOM: log dimensão e norma
  logger.append_param(l_params, 'dim', VECTOR_DIMENSION_COUNT(l_vetor));
  logger.append_param(l_params, 'norma', VECTOR_NORM(l_vetor));

ANTI-PATTERN 6: Modelo ONNX errado para o caso de uso
  -- all-MiniLM-L12-v2: 384-dim, ótimo para texto curto, multilíngue parcial
  -- text-embedding-3-large (OpenAI): 3072-dim, alta qualidade, custo
  -- E5-large-v2: 1024-dim, multilíngue, open
  -- BGE-large: 1024-dim, performance forte em pt-br
  -- Para PT-BR forense, BGE-m3 ou multilingual-e5 são opções superiores
*/
