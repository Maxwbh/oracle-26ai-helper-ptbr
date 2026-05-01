# Templates SQL — Oracle 26ai

Templates `.sql` para Oracle AI Database 26ai (versão técnica 23.26.x), Enterprise Edition.

**Esta skill é COMPLEMENTAR à `oracle-sql-helper-ptbr`** que cobre Oracle 19c. Padrões Trivadis 4.4 continuam valendo, mas estes templates focam em features pós-19c.

## Convenções

- Nomes em PT-BR (mesma da skill v5)
- Prefixos Trivadis em inglês (`g_`, `gc_`, `l_`, `lc_`, `p_`, `r_`, `t_`, `co_`, `e_`)
- Keywords Oracle e pacotes nativos em inglês (`VECTOR`, `JSON RELATIONAL DUALITY VIEW`, `DBMS_VECTOR`, etc.)
- Comentários em PT-BR

## Índice por área

### AI Vector Search (4 templates)

| Arquivo | Cobre |
|---|---|
| `ai_vector_search_basics.sql` | VECTOR data type, configuração `vector_memory_size`, carregar modelo ONNX (`DBMS_VECTOR.LOAD_ONNX_MODEL`), `VECTOR_EMBEDDING`, `VECTOR_DISTANCE`, similarity search exhaustive, métricas (COSINE/EUCLIDEAN/DOT) |
| `ai_vector_index_strategies.sql` | HNSW vs IVF, parâmetros (`neighbors`, `efconstruction`, `neighbor_partitions`), `CREATE VECTOR INDEX`, `FETCH APPROX FIRST`, hybrid vector index (texto + semântica), `DBMS_HYBRID_VECTOR.SEARCH` |
| `ai_vector_embedding_pipeline.sql` | Chunking (`DBMS_VECTOR_CHAIN.UTL_TO_CHUNKS`), pipeline batch para gerar embeddings, atualização incremental, integração com modelos externos (OpenAI, Cohere) via `UTL_TO_EMBEDDING` |
| `ai_vector_rag_pattern.sql` | RAG completo (Retrieval + Generation), `DBMS_VECTOR.GENERATE`, prompt engineering, auditoria de consultas, métricas de qualidade |

### JSON Relational Duality (3 templates)

| Arquivo | Cobre |
|---|---|
| `json_duality_view_basics.sql` | `CREATE JSON RELATIONAL DUALITY VIEW` (sintaxe SQL e GraphQL), tabelas-base normalizadas, hierarquias, anotações `@insert`/`@update`/`@delete`/`@nocheck`, `_id` e `_metadata` |
| `json_duality_dml.sql` | INSERT/UPDATE/DELETE em duality views, ordem `_id` ANTES de `_metadata`, partial updates, sub-arrays, propagação automática para tabelas-base |
| `json_duality_etag_concurrency.sql` | Optimistic locking via ETag, padrão GET → PUT, retry exponencial em ORA-42699, identificar hot rows, monitoring de collisions |

### RAFT Replication (3 templates — exploratório)

| Arquivo | Cobre |
|---|---|
| `raft_setup_overview.sql` | Conceitos (Replication Unit, Shard, GSM, Catalog), comandos GDSCTL, sharded vs duplicated tables, decisão "quando usar RAFT" |
| `raft_replication_units.sql` | Anatomia de RU (leader/followers/quorum), sintaxe sharded tables, comandos `add ru`, `switchover`, `failover`, distribuição de partitions |
| `raft_failover_recovery.sql` | Switchover planejado, failover automático, disaster failover, métricas de saúde, recovery após falha prolongada, PITR em GDD, anti-patterns |

### Migração 19c → 26ai (1 template)

| Arquivo | Cobre |
|---|---|
| `migration_19c_to_26ai.sql` | Caminho de upgrade direto, AutoUpgrade (ANALYZE/FIXUPS/DEPLOY), conversão non-CDB → PDB obrigatória, init params alterados, certificação de aplicações, riscos e mitigações |

## Como usar

1. **Confirme versão do banco antes:**
   ```sql
   SELECT banner_full FROM v$version;
   ```
   Esperado: `Oracle AI Database 26ai Enterprise Edition Release 23.26.x.x.x`

2. **Verifique edition:**
   - Enterprise Edition: todas features deste skill
   - Standard Edition 2: ainda sem data em abril/2026; muitas features não disponíveis

3. **Identifique a área** e clone o template correspondente

4. **Adapte preservando:**
   - Naming PT-BR
   - Prefixos Trivadis
   - Princípios canônicos (SQL > PL/SQL, NOCOPY, exception handlers com contexto)

5. **Para RAFT:** comece com `raft_setup_overview.sql` (conceitos), depois ambiente lab — não tente em produção sem treinamento dedicado

## Decisão rápida

| Cenário | Template |
|---|---|
| Quero similarity search em texto | `ai_vector_search_basics.sql` |
| Decidir HNSW ou IVF | `ai_vector_index_strategies.sql` |
| Documentos longos, preciso chunking | `ai_vector_embedding_pipeline.sql` |
| Construir chatbot/assistente factual | `ai_vector_rag_pattern.sql` |
| Aplicação MongoDB acessar dados Oracle | `json_duality_view_basics.sql` |
| INSERT/UPDATE em duality view | `json_duality_dml.sql` |
| ORA-42699 em alta concorrência | `json_duality_etag_concurrency.sql` |
| Entender RAFT antes de avaliar | `raft_setup_overview.sql` |
| Configurar replication units em lab | `raft_replication_units.sql` |
| Testar failover scenarios | `raft_failover_recovery.sql` |
| Planejar migração 19c → 26ai | `migration_19c_to_26ai.sql` |
