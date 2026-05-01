--==============================================================================
-- Template: Estratégias de Índice Vetorial — HNSW vs IVF
--
-- Decide qual índice usar para similarity search, como configurar parâmetros,
-- e quando reorganizar.
--
-- Pré-requisito: tabela com VECTOR já populada (ver ai_vector_search_basics.sql).
--==============================================================================


--==============================================================================
-- 1. Decisão rápida — HNSW ou IVF?
--==============================================================================

/*
HNSW (Hierarchical Navigable Small World) — In-Memory Neighbor Graph
  ✓ MAIS RÁPIDO em queries (graph navigation)
  ✓ Alta acurácia
  ✓ Em 26ai suporta DML transacionalmente consistente
  ✗ Inteiramente em MEMÓRIA — limitado por vector_memory_size
  ✗ Em RAC: duplica em cada instance (custo de memória) ou usa distributed mode
  
  USE quando: dataset cabe em memória (< vector_memory_size disponível)
              queries de baixa latência são prioridade

IVF (Inverted File Flat) — Neighbor Partition
  ✓ Armazenado em DISCO (escala para datasets enormes)
  ✓ Pode ser locally partitioned em tabelas particionadas
  ✓ Reorganização automática em 26ai
  ✗ MAIS LENTO que HNSW (mas ainda muito mais rápido que exhaustive)
  ✗ Acurácia depende de número de partitions vs centroids
  
  USE quando: dataset > vector_memory_size disponível
              tabela já é particionada (alinhamento natural)
              custo de memória é maior que custo de latência

REGRA PRÁTICA: comece com IVF, migre para HNSW se latência for crítica
                e dataset couber em memória.
*/


--==============================================================================
-- 2. HNSW Index — sintaxe e parâmetros
--==============================================================================

-- Criação básica
CREATE VECTOR INDEX idx_doc_forense_hnsw
ON documentos_forenses (embedding)
ORGANIZATION INMEMORY NEIGHBOR GRAPH
DISTANCE COSINE
WITH TARGET ACCURACY 95
PARAMETERS (
  type             HNSW,
  neighbors        16,    -- nós conectados por nó no grafo
  efconstruction   100    -- candidatos avaliados durante construção
);

-- Parâmetros explicados:
--   neighbors (default 32): mais = recall melhor, build mais lento, memória maior
--   efconstruction (default 200): mais = grafo melhor, build mais lento
--   target accuracy (default 95): % recall esperado; query troca acurácia por velocidade
--
-- Ajustes para casos de alta precisão exigida (forense, jurídico, médico):
CREATE VECTOR INDEX idx_doc_forense_hnsw_alto
ON documentos_forenses (embedding)
ORGANIZATION INMEMORY NEIGHBOR GRAPH
DISTANCE COSINE
WITH TARGET ACCURACY 99       -- exige recall maior
PARAMETERS (
  type             HNSW,
  neighbors        32,         -- grafo mais denso
  efconstruction   200         -- construção mais cuidadosa
);


-- Verificar índice criado
SELECT index_name, index_type, status,
       parameters
  FROM user_indexes
 WHERE table_name = 'DOCUMENTOS_FORENSES'
   AND index_type = 'VECTOR';

-- Detalhes específicos vector
SELECT * FROM user_vector_indexes;


--==============================================================================
-- 3. IVF Index — sintaxe e parâmetros
--==============================================================================

-- Criação básica (storage-based, sem requisito de vector_memory_size)
CREATE VECTOR INDEX idx_doc_forense_ivf
ON documentos_forenses (embedding)
ORGANIZATION NEIGHBOR PARTITIONS
DISTANCE COSINE
WITH TARGET ACCURACY 90
PARAMETERS (
  type                IVF,
  neighbor_partitions 100   -- partitions/centroids; default = sqrt(num_linhas)
);

-- Parâmetros explicados:
--   neighbor_partitions: número de centroids que dividem o espaço vetorial
--     - default: sqrt(num_linhas) — ex: 1M linhas → 1000 partitions
--     - mais partitions = busca mais rápida, mas menos vetores por partition
--     - menos partitions = busca lenta, mas vetores mais agrupados
--
--   target accuracy: 90 é típico para IVF (vs 95 default HNSW)


-- IVF localmente particionado (em tabela particionada)
CREATE VECTOR INDEX idx_doc_forense_ivf_local
ON documentos_forenses_part (embedding)
ORGANIZATION NEIGHBOR PARTITIONS
DISTANCE COSINE
WITH TARGET ACCURACY 90
PARAMETERS (type IVF, neighbor_partitions 100)
LOCAL;  -- alinha com partitioning da tabela; partition pruning + index pruning


--==============================================================================
-- 4. Query usando o índice
--
-- IMPORTANTE: para o índice ser usado, a query DEVE:
--   1. Usar a MESMA métrica de distance do índice (COSINE aqui)
--   2. Usar FETCH APPROX FIRST (não FETCH FIRST regular)
--   3. ORDER BY a função VECTOR_DISTANCE
--==============================================================================

-- Query que USA o índice
SELECT id, titulo, categoria,
       VECTOR_DISTANCE(
         embedding,
         VECTOR_EMBEDDING(modelo_minilm_l12 USING 'arma de fogo' AS data),
         COSINE                    -- mesma métrica do índice
       ) AS distancia
  FROM documentos_forenses
 ORDER BY distancia
 FETCH APPROX FIRST 10 ROWS ONLY;  -- APPROX para usar índice


-- Verificar se índice foi usado
EXPLAIN PLAN FOR
SELECT id, titulo,
       VECTOR_DISTANCE(embedding,
         VECTOR_EMBEDDING(modelo_minilm_l12 USING 'arma de fogo' AS data),
         COSINE) AS distancia
  FROM documentos_forenses
 ORDER BY distancia
 FETCH APPROX FIRST 10 ROWS ONLY;

SELECT * FROM TABLE(DBMS_XPLAN.display);

-- Espera plano com:
--   VECTOR INDEX HNSW SCAN (ou VECTOR INDEX IVF SCAN)
--   Em vez de TABLE FULL SCAN com VECTOR_DISTANCE em cada linha


-- Override de target accuracy na query (sem rebuild do índice)
SELECT id, titulo,
       VECTOR_DISTANCE(embedding,
         VECTOR_EMBEDDING(modelo_minilm_l12 USING 'arma de fogo' AS data),
         COSINE) AS distancia
  FROM documentos_forenses
 ORDER BY distancia
 FETCH APPROX FIRST 10 ROWS ONLY
   WITH TARGET ACCURACY 99;  -- query mais cuidadosa que default do índice


--==============================================================================
-- 5. Manutenção de índices vetoriais
--==============================================================================

-- HNSW: rebuild (online em 26ai)
ALTER INDEX idx_doc_forense_hnsw REBUILD ONLINE;

-- IVF: reorganização (após muitas DMLs, distribuição pode degradar)
ALTER INDEX idx_doc_forense_ivf REBUILD ONLINE;

-- Em 26ai, IVF tem reorganização automática:
--   "IVF vector indexes can be automatically reorganized after the database
--    system has determined that a rebuild is necessary"


-- Compactação HNSW com scalar quantization (26ai)
-- Reduz memória ~50% com perda mínima de acurácia
CREATE VECTOR INDEX idx_doc_forense_hnsw_compact
ON documentos_forenses (embedding)
ORGANIZATION INMEMORY NEIGHBOR GRAPH
DISTANCE COSINE
WITH TARGET ACCURACY 95
PARAMETERS (
  type                HNSW,
  neighbors           32,
  efconstruction      200,
  vector_compression  scalar_quantization_8bit  -- INT8 em vez de FLOAT32
);


--==============================================================================
-- 6. Sizing de memória — quando usar HNSW
--==============================================================================

-- Estimar memória necessária ANTES de criar HNSW
DECLARE
  l_qtd_linhas    NUMBER;
  l_dimensoes     NUMBER := 384;  -- conhecido do modelo
  l_overhead      NUMBER := 1.3;   -- fator overhead grafo
  l_bytes_total   NUMBER;
  l_mb_total      NUMBER;
BEGIN
  SELECT COUNT(*) INTO l_qtd_linhas FROM documentos_forenses;
  
  -- bytes = qtd × dim × 4 (FLOAT32) × overhead
  l_bytes_total := l_qtd_linhas * l_dimensoes * 4 * l_overhead;
  l_mb_total := ROUND(l_bytes_total / 1024 / 1024, 0);
  
  DBMS_OUTPUT.put_line('Linhas: ' || l_qtd_linhas);
  DBMS_OUTPUT.put_line('Memória estimada para HNSW: ' || l_mb_total || ' MB');
  DBMS_OUTPUT.put_line('Vector_memory_size atual: ' || (
    SELECT value FROM v$parameter WHERE name = 'vector_memory_size'
  ));
END;
/


-- Verificar uso atual do Vector Memory Pool
SELECT pool, name, bytes/1024/1024 AS mb, sql_id
  FROM v$sgastat
 WHERE pool = 'vector pool'
 ORDER BY bytes DESC;


--==============================================================================
-- 7. Decisão: quando criar índice?
--==============================================================================

/*
< 1.000 linhas:    sem índice (exhaustive já é instantâneo)
1.000 - 10.000:    HNSW (memória trivial, baixa latência)
10.000 - 1M:       HNSW se cabe em memória, senão IVF
1M - 100M:         IVF (HNSW exige RAM proibitiva)
> 100M:            IVF + locally partitioned (tabela particionada)
                   ou HNSW distributed em RAC com múltiplas instances

Regra adicional:
  Se tabela tem MUITAS DMLs (>10% do volume diariamente):
    - Em 26ai, HNSW suporta DML transacionalmente
    - Em versões anteriores, HNSW exigia rebuild — usava IVF nesse caso
*/


--==============================================================================
-- 8. Hybrid Vector Index (combina texto + semântica) — 26ai
--==============================================================================

-- Combina full-text search (Oracle Text) com vector similarity num único índice
CREATE HYBRID VECTOR INDEX idx_doc_forense_hibrido
ON documentos_forenses (conteudo)
PARAMETERS ('
  VECTOR_EMBEDDING_MODEL  modelo_minilm_l12
  VECTOR_DISTANCE         COSINE
  VECTOR_INDEX_TYPE       IVF
');

-- Query híbrida: combina termos textuais + similaridade semântica
SELECT id, titulo
  FROM documentos_forenses
 WHERE CONTAINS(conteudo, 'trauma OR contusão', 1) > 0
   AND VECTOR_DISTANCE(
         embedding,
         VECTOR_EMBEDDING(modelo_minilm_l12 USING 'lesão por agressão' AS data),
         COSINE
       ) < 0.3
 ORDER BY SCORE(1) + (1 - VECTOR_DISTANCE(
         embedding,
         VECTOR_EMBEDDING(modelo_minilm_l12 USING 'lesão por agressão' AS data),
         COSINE)) DESC
 FETCH APPROX FIRST 10 ROWS ONLY;


-- API DBMS_HYBRID_VECTOR (mais fácil em 26ai)
SELECT id, titulo, score
  FROM TABLE(
    DBMS_HYBRID_VECTOR.SEARCH(
      query_text     => 'trauma craniano contuso',
      table_name     => 'DOCUMENTOS_FORENSES',
      vector_column  => 'EMBEDDING',
      text_column    => 'CONTEUDO',
      max_results    => 10
    )
  );
