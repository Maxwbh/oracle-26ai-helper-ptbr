--==============================================================================
-- Template: Estratégias de Índice Vetorial — HNSW vs IVF (+ Hybrid Vector Index)
--
-- Decide qual índice usar para similarity search, como configurar parâmetros,
-- e quando reorganizar.
--
-- Pré-requisito: tabela com VECTOR já populada (ver ai_vector_search_basics.sql).
--
-- Revisado: nov/2026 contra a documentação Oracle AI Database 26ai (RU 23.26.4)
-- Testado: 26ai Free 23.26.3 (nov/2026), SQL*Plus — OK; PRODUCT falha como esperado (23.26.4+); DBMS_VECTOR_ADMIN e V$ exigem DBA/SELECT_CATALOG_ROLE
-- Tipo: Dependente de configuração — exige o modelo ONNX e as tabelas de ai_vector_search_basics.sql
-- RU mínimo: 23.26.0; ONLINE/quantização SCALAR 23.26.1+; HNSW local 23.26.2+; PRODUCT 23.26.4+
-- Edição Free: Parcial — HNSW depende do vector pool dentro do limite de 2 GB
--              de RAM; recursos de RAC (distributed HNSW) não se aplicam; os
--              blocos marcados 23.26.x exigem que a imagem Free esteja nesse RU
--              (A VERIFICAR); licenciamento de Vector Search no Free não está
--              listado explicitamente no guia de licenças.
--==============================================================================


--==============================================================================
-- 1. Decisão rápida — HNSW ou IVF?
--==============================================================================

/*
HNSW (Hierarchical Navigable Small World) — In-Memory Neighbor Graph
  + Geralmente a menor latência de consulta (navegação em grafo)
  + Alta acurácia
  + DML transacionalmente consistente (journals privado/compartilhado, 23.6+)
  - Grafo inteiro em MEMÓRIA — limitado pelo vector pool (vector_memory_size)
  - Em RAC: por padrão é duplicado em cada instância; a partir de 23.26.1
    pode ser DISTRIBUÍDO entre as instâncias (DISTRIBUTE ...)
  - Parallel DML em tabela com HNSW é convertido para DML serial

  USE quando: o índice cabe no vector pool disponível
              latência baixa é prioridade

IVF (Inverted File Flat) — Neighbor Partitions
  + Armazenado em DISCO (escala para datasets enormes)
  + Pode ser LOCAL em tabelas particionadas
  + Rebuild online (23.9+) e reorganização automática (23.26.1+)
  - Em geral mais lento que HNSW (mas muito mais rápido que busca exata)
  - Acurácia depende do número de partições sondadas
  - Não suporta vetores SPARSE

  USE quando: o índice não cabe no vector pool
              a tabela já é particionada (alinhamento natural com LOCAL)
              custo de memória pesa mais que latência

REGRA PRÁTICA (heurística, não da Oracle): comece com IVF; migre para HNSW se a
latência for crítica e o índice couber em memória (estime na seção 6).
*/


--==============================================================================
-- 2. HNSW Index — sintaxe e parâmetros
--
-- Sintaxe (doc 26ai, ordem das cláusulas):
--   CREATE VECTOR INDEX nome ON tabela (coluna_vetor)
--   [GLOBAL] ORGANIZATION INMEMORY [NEIGHBOR] GRAPH
--   [WITH] [DISTANCE metrica]
--   [WITH TARGET ACCURACY pct]
--   [QUANTIZATION SCALAR COMPRESSION RATIO {2|4|8}]
--   [PARAMETERS (TYPE HNSW, NEIGHBORS n, EFCONSTRUCTION n [, RESCORE FACTOR n] ...)]
--   [DUPLICATE ALL | DISTRIBUTE [AUTO | BY ROWID RANGE | BY PARTITION | BY SUBPARTITION]]
--   [PARALLEL n] [ONLINE]
--==============================================================================

-- 26ai — criação básica
CREATE VECTOR INDEX idx_doc_forense_hnsw
ON documentos_forenses (embedding)
ORGANIZATION INMEMORY NEIGHBOR GRAPH
DISTANCE COSINE
WITH TARGET ACCURACY 95
PARAMETERS (
  TYPE             HNSW,
  NEIGHBORS        16,    -- máx. de vizinhos por vetor em cada camada (2..2048)
  EFCONSTRUCTION   100    -- candidatos avaliados por passo na inserção (1..65535)
);

-- Uma coluna aceita UM índice vetorial (ORA-01408): remova antes de testar a próxima alternativa.
DROP INDEX IF EXISTS idx_doc_forense_hnsw;

-- Parâmetros explicados:
--   NEIGHBORS (sinônimo: M): mais = recall melhor, build mais lento, mais memória
--   EFCONSTRUCTION: mais = grafo de melhor qualidade, build mais lento
--   Defaults de NEIGHBORS/EFCONSTRUCTION: não documentados — informe sempre.
--   TARGET ACCURACY: % de acurácia alvo (> 0 e <= 100). O default no
--     DBMS_VECTOR.CREATE_INDEX é 90; o default da DDL não é declarado na doc.
--   DISTANCE: COSINE é o default.
--
-- 26ai — ajustes para casos de alta precisão exigida (forense, jurídico, médico):
CREATE VECTOR INDEX idx_doc_forense_hnsw_alto
ON documentos_forenses (embedding)
ORGANIZATION INMEMORY NEIGHBOR GRAPH
DISTANCE COSINE
WITH TARGET ACCURACY 99       -- exige acurácia maior
PARAMETERS (
  TYPE             HNSW,
  NEIGHBORS        32,         -- grafo mais denso
  EFCONSTRUCTION   200         -- construção mais cuidadosa
);

-- Uma coluna aceita UM índice vetorial (ORA-01408): remova antes de testar a próxima alternativa.
DROP INDEX IF EXISTS idx_doc_forense_hnsw_alto;
-- (Na prática você terá UM índice vetorial por coluna; os exemplos acima são
--  alternativas — drope um antes de testar o outro.)


-- 26ai 23.26.1+ — criação ONLINE (tabela continua aceitando DML durante o build)
-- Não suportado: HNSW local, HNSW distribuído, índice com included columns.
CREATE VECTOR INDEX idx_doc_forense_hnsw_online
ON documentos_forenses (embedding)
ORGANIZATION INMEMORY NEIGHBOR GRAPH
DISTANCE COSINE
WITH TARGET ACCURACY 95
PARAMETERS (TYPE HNSW, NEIGHBORS 32, EFCONSTRUCTION 200)
ONLINE;

-- Uma coluna aceita UM índice vetorial (ORA-01408): remova antes de testar a próxima alternativa.
DROP INDEX IF EXISTS idx_doc_forense_hnsw_online;


-- Verificar índices criados (dicionário padrão)
SELECT index_name, index_type, status
  FROM user_indexes
 WHERE table_name = 'DOCUMENTOS_FORENSES';

-- 26ai — detalhes específicos de índice vetorial (fixed view): exige
-- SELECT_CATALOG_ROLE ou consulta como DBA (sem isso → ORA-00942)
SELECT owner, index_name, index_organization, distance_type,
       index_dimensions, index_dim_type, num_vectors,
       allocated_bytes / 1024 / 1024 AS alocado_mb,   -- 0 para IVF
       used_bytes      / 1024 / 1024 AS usado_mb
  FROM v$vector_index
 WHERE owner = USER;


--==============================================================================
-- 3. IVF Index — sintaxe e parâmetros
--
-- Sintaxe (doc 26ai):
--   CREATE VECTOR INDEX nome ON tabela (coluna_vetor)
--   [GLOBAL] ORGANIZATION [NEIGHBOR] PARTITIONS
--   [WITH] [DISTANCE metrica]
--   [WITH TARGET ACCURACY pct]
--   [QUANTIZATION SCALAR COMPRESSION RATIO {2|4|8}]      -- 23.26.4+
--   [PARAMETERS (TYPE IVF, NEIGHBOR PARTITIONS n | SAMPLES_PER_PARTITION n |
--                MIN_VECTORS_PER_PARTITION n | NEIGHBOR PARTITION GROUPING {ON|OFF}
--                [, RESCORE FACTOR n])]
--   [PARALLEL n] [LOCAL]
-- Atenção: é "NEIGHBOR PARTITIONS" com ESPAÇO (não neighbor_partitions).
--==============================================================================

-- 26ai — criação básica (armazenado em disco)
CREATE VECTOR INDEX idx_doc_forense_ivf
ON documentos_forenses (embedding)
ORGANIZATION NEIGHBOR PARTITIONS
DISTANCE COSINE
WITH TARGET ACCURACY 90
PARAMETERS (
  TYPE                IVF,
  NEIGHBOR PARTITIONS 100   -- nº alvo de partições/centróides (1..10.000.000)
);

-- Uma coluna aceita UM índice vetorial (ORA-01408): remova antes de testar a próxima alternativa.
DROP INDEX IF EXISTS idx_doc_forense_ivf;

-- Parâmetros explicados:
--   NEIGHBOR PARTITIONS: número alvo de centróides que dividem o espaço vetorial
--     - sem o parâmetro, o banco escolhe; referência informal comum: ~sqrt(n)
--       (ex.: 1M linhas → ~1000 partições) — não é regra documentada
--     - mais partições = menos vetores por partição sondada
--   SAMPLES_PER_PARTITION: amostra usada no clustering (build mais rápido)
--   MIN_VECTORS_PER_PARTITION: descarta partições muito pequenas
--   NEIGHBOR PARTITION GROUPING ON: agrupamento extra no storage (só IVF global,
--     só na criação; para desligar, drop + create)
--
--   O vector pool NÃO é obrigatório para IVF; se existir, guarda os centróides
--   e acelera build/DML (sem espaço: large pool; sem espaço lá: sem cache).


-- 26ai — IVF local (em tabela particionada)
-- Pré-requisito: tabela PARTICIONADA documentos_forenses_part com coluna
-- VECTOR (não criada neste template). Uma partição de índice por partição.
-- CREATE VECTOR INDEX idx_doc_forense_ivf_local
-- ON documentos_forenses_part (embedding)
-- ORGANIZATION NEIGHBOR PARTITIONS
-- DISTANCE COSINE
-- WITH TARGET ACCURACY 90
-- PARAMETERS (TYPE IVF, NEIGHBOR PARTITIONS 100)
-- LOCAL;


-- 26ai 23.26.1+ — IVF ONLINE (não suportado para IVF LOCAL nem com included columns)
CREATE VECTOR INDEX idx_doc_forense_ivf_online
ON documentos_forenses (embedding)
ORGANIZATION NEIGHBOR PARTITIONS
DISTANCE COSINE
WITH TARGET ACCURACY 90
PARAMETERS (TYPE IVF, NEIGHBOR PARTITIONS 100)
ONLINE;


--==============================================================================
-- 4. Query usando o índice
--
-- IMPORTANTE: para o índice ser usado, a query DEVE:
--   1. Usar a MESMA métrica do índice (ou omitir a métrica)
--   2. Usar FETCH APPROX FIRST (on-premises; sem APPROX a busca é exata)
--   3. Fazer ORDER BY pela VECTOR_DISTANCE (sem envolvê-la em ROUND etc.)
-- Mesmo assim, uma busca aproximada pode devolver MENOS que K linhas.
--==============================================================================

-- 26ai — query que USA o índice
-- APPROX para usar índice
SELECT id, titulo, categoria,
       VECTOR_DISTANCE(
         embedding,
         VECTOR_EMBEDDING(modelo_minilm_l12 USING 'arma de fogo' AS data),
         COSINE                    -- mesma métrica do índice
       ) AS distancia
  FROM documentos_forenses
 ORDER BY distancia
 FETCH APPROX FIRST 10 ROWS ONLY;


-- 26ai — verificar se o índice foi usado
EXPLAIN PLAN FOR
SELECT id, titulo,
       VECTOR_DISTANCE(embedding,
         VECTOR_EMBEDDING(modelo_minilm_l12 USING 'arma de fogo' AS data),
         COSINE) AS distancia
  FROM documentos_forenses
 ORDER BY distancia
 FETCH APPROX FIRST 10 ROWS ONLY;

SELECT * FROM TABLE(DBMS_XPLAN.display);

-- HNSW: espere a operação VECTOR INDEX HNSW SCAN no plano.
-- IVF: o plano acessa as partições de centróides do índice (formato do plano
--      detalhado em "Optimizer Plans for IVF Vector Indexes", AI Vector Search
--      User's Guide). Sem índice: TABLE ACCESS FULL + SORT pela distância.


-- 26ai — override de target accuracy na query (sem rebuild do índice)
SELECT id, titulo,
       VECTOR_DISTANCE(embedding,
         VECTOR_EMBEDDING(modelo_minilm_l12 USING 'arma de fogo' AS data),
         COSINE) AS distancia
  FROM documentos_forenses
 ORDER BY distancia
 FETCH APPROX FIRST 10 ROWS ONLY
   WITH TARGET ACCURACY 99;

-- 26ai — controle fino por parâmetro interno em vez de percentual
--   HNSW: ... FETCH APPROX FIRST 10 ROWS ONLY WITH TARGET ACCURACY PARAMETERS (EFSEARCH 500);
--   IVF:  ... FETCH APPROX FIRST 10 ROWS ONLY WITH TARGET ACCURACY PARAMETERS (NEIGHBOR PARTITION PROBES 10);


--==============================================================================
-- 5. Manutenção de índices vetoriais
--==============================================================================

-- 26ai (23ai 23.9+) — IVF: rebuild/reorganização online (após muitas DMLs a
-- distribuição dos centróides degrada)
ALTER INDEX idx_doc_forense_ivf_online REBUILD ONLINE;

-- 26ai 23.26.1+ — IVF: rebuild online trocando parâmetros (sem drop/create)
-- A VERIFICAR: a doc lista NEIGHBOR PARTITIONS, SAMPLES_PER_PARTITION e
-- MIN_VECTORS_PER_PARTITION juntos no PARAMETERS do REBUILD; não deixa claro se
-- cada um pode ser informado isoladamente — teste antes de usar em GMUD.
ALTER INDEX idx_doc_forense_ivf_online REBUILD
  PARAMETERS (NEIGHBOR PARTITIONS 200)
  ONLINE;

-- 26ai 23.26.1+ — IVF: reorganização AUTOMÁTICA por job em background
-- (DBMS_VECTOR_ADMIN; default habilitado; dispara quando o DML passa de 20%
--  das linhas, em tabelas com >= 100.000 linhas; não vale com included columns)
-- Rodar como DBA: EXECUTE em DBMS_VECTOR_ADMIN é concedido ao PDB_DBA
-- (usuário de aplicação recebe PLS-00201 — verificado no 26ai Free 23.26.3).
BEGIN
  DBMS_VECTOR_ADMIN.SET_PARAMETER(
    parameter => DBMS_VECTOR_ADMIN.VECTOR_INDEX_OPTIMIZATION_BACKGROUND_INTERVAL,
    value     => 1800   -- segundos entre varreduras
  );
END;
/




-- Uma coluna aceita UM índice vetorial (ORA-01408): remova antes de testar a próxima alternativa.
DROP INDEX IF EXISTS idx_doc_forense_ivf_online;

-- 26ai 23.26.1+ — HNSW com SCALAR QUANTIZATION (reduz memória do grafo)
-- Combinações válidas (formato da coluna → tipo guardado no índice):
--   FLOAT32: RATIO 2 → FLOAT16 | RATIO 4 → INT8 | RATIO 8 → não suportado
--   FLOAT64: RATIO 2 → FLOAT32 | RATIO 4 → FLOAT16 | RATIO 8 → INT8
-- RESCORE FACTOR (1..100, default 1) recalcula as distâncias dos candidatos
-- com os vetores originais; só tem efeito em índice quantizado.
CREATE VECTOR INDEX idx_doc_forense_hnsw_sq
ON documentos_forenses (embedding)
ORGANIZATION INMEMORY NEIGHBOR GRAPH
DISTANCE COSINE
WITH TARGET ACCURACY 95
QUANTIZATION SCALAR COMPRESSION RATIO 4     -- FLOAT32 → INT8
PARAMETERS (
  TYPE             HNSW,
  NEIGHBORS        32,
  EFCONSTRUCTION   200,
  RESCORE FACTOR   2,
  ALGORITHM        UNIFORM_QUANTIZATION
);

-- 26ai — HNSW: ALTER INDEX ... REBUILD ONLINE NÃO é o caminho; use
-- DBMS_VECTOR.REBUILD_INDEX. Parâmetros NULL (omitidos) mantêm o valor atual
-- do índice. idx_rebuild_mode: 'FULL' | 'INCREMENTAL' (só HNSW).
-- 26ai 23.26.1+: idx_online_build => TRUE para reconstruir online.
BEGIN
  DBMS_VECTOR.REBUILD_INDEX(
    idx_name         => 'IDX_DOC_FORENSE_HNSW_SQ',
    table_name       => 'DOCUMENTOS_FORENSES',
    idx_vector_col   => 'EMBEDDING',
    idx_rebuild_mode => 'FULL'
  );
END;
/

-- Uma coluna aceita UM índice vetorial (ORA-01408): remova antes de testar a próxima alternativa.
DROP INDEX IF EXISTS idx_doc_forense_hnsw_sq;

-- 26ai 23.26.4+ — HNSW com PRODUCT QUANTIZATION (compressão maior, 2..128)
-- Só FLOAT32/FLOAT64; métricas EUCLIDEAN, EUCLIDEAN_SQUARED e COSINE.
-- A razão C precisa ser compatível: B (bytes/dimensão, 4 p/ FLOAT32) divide C
-- e C/B divide o nº de dimensões. Para 384 dims FLOAT32: 16 → 16/4 = 4 divide 384.
CREATE VECTOR INDEX idx_doc_forense_hnsw_pq
ON documentos_forenses (embedding)
ORGANIZATION INMEMORY NEIGHBOR GRAPH
WITH TARGET ACCURACY 90
DISTANCE COSINE
QUANTIZATION PRODUCT
COMPRESSION RATIO 16
PARAMETERS (
  TYPE            HNSW,
  NEIGHBORS       32,
  EFCONSTRUCTION  200,
  RESCORE FACTOR  4
);
-- Status do codebook (NOT_CREATED/CREATED) aparece em V$VECTOR_INDEX.

-- 26ai 23.26.4+ — scalar quantization também em IVF GLOBAL
-- (FLOAT32 só aceita RATIO 4 → INT8; FLOAT64 aceita 2 ou 8)
-- CREATE VECTOR INDEX ... ORGANIZATION NEIGHBOR PARTITIONS DISTANCE COSINE
--   WITH TARGET ACCURACY 95 QUANTIZATION SCALAR COMPRESSION RATIO 4
--   PARAMETERS (TYPE IVF, NEIGHBOR PARTITIONS 100, RESCORE FACTOR 2);


--==============================================================================
-- 6. Sizing de memória — quando usar HNSW
--==============================================================================

-- 26ai — estimativa pela fórmula da doc ANTES de criar HNSW
--   bytes ≈ 1,3 × qtd_vetores × dimensoes × bytes_por_dimensao
DECLARE
  lc_dimensoes        CONSTANT PLS_INTEGER := 384;  -- conhecido do modelo
  lc_bytes_dimensao   CONSTANT PLS_INTEGER := 4;    -- FLOAT32
  lc_fator_overhead   CONSTANT NUMBER      := 1.3;  -- fator da doc Oracle
  l_qtd_linhas        NUMBER;
  l_mb_total          NUMBER;
  l_vector_memory     VARCHAR2(100);
BEGIN
  SELECT COUNT(*) INTO l_qtd_linhas FROM documentos_forenses;

  SELECT value
    INTO l_vector_memory
    FROM v$parameter
   WHERE name = 'vector_memory_size';

  l_mb_total := ROUND(
    lc_fator_overhead * l_qtd_linhas * lc_dimensoes * lc_bytes_dimensao
      / 1024 / 1024, 0);

  DBMS_OUTPUT.put_line('Linhas: ' || l_qtd_linhas);
  DBMS_OUTPUT.put_line('Memória estimada para HNSW: ' || l_mb_total || ' MB');
  DBMS_OUTPUT.put_line('vector_memory_size atual: ' || l_vector_memory);
END;
/

-- 26ai — estimativa calculada pelo banco (lê a tabela/coluna; default 90%)
DECLARE
  l_resposta CLOB;
BEGIN
  DBMS_VECTOR.INDEX_VECTOR_MEMORY_ADVISOR(
    USER,
    'DOCUMENTOS_FORENSES',
    'EMBEDDING',
    'HNSW',
    response_json => l_resposta
  );
  -- O resultado também é impresso via DBMS_OUTPUT
END;
/


-- 26ai — uso atual do Vector Memory Pool (exige SELECT_CATALOG_ROLE ou DBA)
SELECT con_id, pool,
       alloc_bytes / 1024 / 1024 AS alloc_mb,
       used_bytes  / 1024 / 1024 AS used_mb
  FROM v$vector_memory_pool
 ORDER BY con_id, pool;


--==============================================================================
-- 7. Decisão: quando criar índice? (heurística do autor, não da Oracle)
--==============================================================================

/*
< 1.000 linhas:    sem índice (busca exata já é rápida)
1.000 - 10.000:    HNSW (memória pequena, baixa latência)
10.000 - 1M:       HNSW se couber no vector pool, senão IVF
1M - 100M:         IVF, ou HNSW com quantização (scalar 23.26.1+,
                   product 23.26.4+) se a memória for o gargalo
> 100M:            IVF LOCAL (tabela particionada), HNSW LOCAL (23.26.2+)
                   ou HNSW distribuído em RAC (23.26.1+)

Regra adicional:
  Tabela com MUITA DML:
    - HNSW mantém consistência transacional (23.6+), com snapshots
      incrementais do grafo (23.9+)
    - IVF degrada com o tempo → rebuild online (23.9+) ou reorganização
      automática (23.26.1+)
  Sempre valide com um conjunto de queries reais (DBMS_VECTOR.INDEX_ACCURACY_QUERY).
*/


--==============================================================================
-- 8. Hybrid Vector Index (texto + semântica num único índice) — 26ai (23ai 23.6+)
--
-- O índice é criado sobre a COLUNA DE TEXTO (VARCHAR2, CLOB ou BLOB). O próprio
-- índice faz chunking + embedding + índice vetorial; NÃO precisa de coluna
-- VECTOR separada na tabela. Requer Oracle Text (é um SEARCH INDEX).
--==============================================================================

-- 26ai — forma mínima: MODEL (ONNX carregado no banco) + tipo do índice vetorial
-- VECTOR_IDXTYPE: IVF (default) ou HNSW. MEMORY e PARALLEL são recomendados
-- (memória total de PGA = MEMORY × PARALLEL).
CREATE HYBRID VECTOR INDEX idx_doc_forense_hibrido
ON documentos_forenses (conteudo)
PARAMETERS ('MODEL modelo_minilm_l12 VECTOR_IDXTYPE IVF MEMORY 256M')
PARALLEL 2;

-- 26ai — alternativa: preferência VECTORIZER (controle de chunking/modelo/índice)
-- Não combine VECTORIZER com MODEL/VECTOR_IDXTYPE no mesmo PARAMETERS.
BEGIN
  DBMS_VECTOR_CHAIN.CREATE_PREFERENCE(
    'pref_vetorizador_laudos',
    DBMS_VECTOR_CHAIN.VECTORIZER,
    JSON('{
      "vector_idxtype" : "hnsw",
      "model"          : "modelo_minilm_l12",
      "by"             : "words",
      "max"            : 100,
      "overlap"        : 10,
      "split"          : "recursively"
    }')
  );
END;
/
-- CREATE HYBRID VECTOR INDEX idx_doc_forense_hibrido
-- ON documentos_forenses (conteudo)
-- PARAMETERS ('VECTORIZER pref_vetorizador_laudos');

-- Linhas que falharam na indexação ficam em CTX_USER_INDEX_ERRORS.


-- 26ai — consulta híbrida: DBMS_HYBRID_VECTOR.SEARCH recebe UM JSON e devolve
-- CLOB (JSON). Mínimo: hybrid_index_name + search_text (o mesmo texto vira
-- CONTAINS na parte textual e embedding na parte vetorial).
-- return.values default: rowid, score, vector_score, text_score, vector_rank,
-- text_rank, chunk_text, chunk_id. topN default = 20.
SELECT d.id, d.titulo, jt.score, jt.trecho
  FROM JSON_TABLE(
         DBMS_HYBRID_VECTOR.SEARCH(
           JSON('{
             "hybrid_index_name" : "idx_doc_forense_hibrido",
             "search_text"       : "trauma craniano contuso",
             "return"            : { "topN" : 10 }
           }')
         ),
         '$[*]' COLUMNS (
           linha   VARCHAR2(30)   PATH '$.rowid',
           score   NUMBER         PATH '$.score',
           trecho  VARCHAR2(4000) PATH '$.chunk_text'
         )
       ) jt
  JOIN documentos_forenses d
    ON d.rowid = CHARTOROWID(jt.linha)
 ORDER BY jt.score DESC;

-- 26ai — termos textuais e semânticos SEPARADOS (não misture com o
-- search_text de topo na mesma chamada)
SELECT DBMS_HYBRID_VECTOR.SEARCH(
         JSON('{
           "hybrid_index_name" : "idx_doc_forense_hibrido",
           "search_scorer"     : "RSF",
           "vector" : { "search_text" : "lesão por agressão",
                        "search_mode" : "CHUNK" },
           "text"   : { "contains"    : "trauma OR contusão" },
           "return" : { "topN" : 10 }
         }')
       ) AS resultado_json
  FROM dual;

-- Rebuild do hybrid index:
--   ALTER INDEX idx_doc_forense_hibrido REBUILD;                       -- tudo
--   ALTER INDEX idx_doc_forense_hibrido REBUILD
--     PARAMETERS ('UPDATE VECTOR INDEX');                              -- só a parte vetorial
--   (UPDATE VECTOR INDEX não é suportado para HVI local nem com HNSW)
