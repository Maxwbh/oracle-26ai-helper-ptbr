# Changelog

Todas as mudanças notáveis neste projeto serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e este projeto adere a [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [v1] — 2026-04-30

### Versão inicial

Skill MVP focada em três features novas do Oracle AI Database 26ai (versão técnica 23.26.x), Enterprise Edition.

### Adicionado

#### AI Vector Search (4 templates)
- `assets/ai_vector_search_basics.sql`: VECTOR data type, configuração `vector_memory_size`, carregar modelo ONNX (`DBMS_VECTOR.LOAD_ONNX_MODEL`), `VECTOR_EMBEDDING`, `VECTOR_DISTANCE`, similarity search exhaustive, métricas (COSINE/EUCLIDEAN/DOT)
- `assets/ai_vector_index_strategies.sql`: HNSW vs IVF, parâmetros (`neighbors`, `efconstruction`, `neighbor_partitions`), `CREATE VECTOR INDEX`, `FETCH APPROX FIRST`, hybrid vector index (texto + semântica)
- `assets/ai_vector_embedding_pipeline.sql`: chunking via `DBMS_VECTOR_CHAIN.UTL_TO_CHUNKS`, pipeline batch para gerar embeddings, atualização incremental, integração com modelos externos (OpenAI, Cohere) via `UTL_TO_EMBEDDING`
- `assets/ai_vector_rag_pattern.sql`: RAG completo (Retrieval + Generation), `DBMS_VECTOR.GENERATE`, prompt engineering, auditoria de consultas

#### JSON Relational Duality (3 templates)
- `assets/json_duality_view_basics.sql`: `CREATE JSON RELATIONAL DUALITY VIEW` (sintaxe SQL e GraphQL), tabelas-base normalizadas, hierarquias, anotações `@insert`/`@update`/`@delete`/`@nocheck`, `_id` e `_metadata`
- `assets/json_duality_dml.sql`: INSERT/UPDATE/DELETE em duality views, ordem `_id` ANTES de `_metadata`, partial updates, sub-arrays, propagação automática para tabelas-base
- `assets/json_duality_etag_concurrency.sql`: optimistic locking via ETag, padrão GET → PUT, retry exponencial em ORA-42699, identificar hot rows, monitoring de collisions

#### RAFT Replication (3 templates exploratórios)
- `assets/raft_setup_overview.sql`: conceitos (Replication Unit, Shard, GSM, Catalog), comandos GDSCTL, sharded vs duplicated tables
- `assets/raft_replication_units.sql`: anatomia de RU (leader/followers/quorum), sintaxe sharded tables, comandos `add ru`, `switchover`, `failover`, distribuição de partitions
- `assets/raft_failover_recovery.sql`: switchover planejado, failover automático, disaster failover, métricas de saúde, recovery após falha prolongada, PITR em GDD

#### Migração 19c → 26ai (1 template)
- `assets/migration_19c_to_26ai.sql`: caminho de upgrade direto, AutoUpgrade (ANALYZE/FIXUPS/DEPLOY), conversão non-CDB → PDB obrigatória, init params alterados, certificação de aplicações, riscos e mitigações

#### References (4 documentos)
- `references/ai-vector-search.md`: VECTOR data type, métricas, pacotes DBMS_VECTOR/DBMS_VECTOR_CHAIN/DBMS_HYBRID_VECTOR, modelos recomendados PT-BR (multilingual-e5, BGE-m3), decisão índice vs exhaustive, sizing fórmula, padrão RAG canônico
- `references/json-relational-duality.md`: conceitos GraphQL syntax, ETag mechanics, MongoDB API integration, JSON Collections vs Duality Views
- `references/raft-globally-distributed.md`: conceitos sharding, GSM, RAFT consensus, comparação com ADG/RAC
- `references/migration-19c-26ai.md`: AutoUpgrade detalhado, multitenant compulsório, lifecycle 19c support dates

### Princípios canônicos

8 princípios aplicados em todo código gerado:

0. Verifique a versão antes de prometer features
1. Use SQL puro quando possível
2. Bind variables sempre
3. NOCOPY para BLOB/VECTOR grandes em IN OUT
4. Sizing de memória explícito antes de criar HNSW
5. ETag obrigatório em UPDATE de duality view
6. Trivadis 4.4 continua valendo para PL/SQL que envolve as features novas
7. Prefixos Trivadis em inglês, nomes em PT-BR

### Decisões de escopo

- **MVP focado**: apenas as 3 features priorizadas + migration mínimo. Outras features 26ai (Select AI, SQL Firewall, True Cache, Property Graph, DBMS_CLOUD nativo) ficam fora desta primeira versão
- **RAFT exploratório**: cobre conceitos e comandos básicos para uso em ambiente lab; não cobre operação produtiva (que exige consultoria Oracle)
- **APEX 26.1**: fora de escopo (não foi lançado em abril/2026)
- **Naming**: keywords novas (`VECTOR`, `EMBEDDING`, `DUALITY VIEW`, `RAFT`) ficam em inglês; nomes de domínio e comentários em PT-BR
- **Coexistência**: skill paralela à `oracle-sql-helper-ptbr` (que cobre 19c). Gatilhos não-sobrepostos
