# Templates SQL — Oracle AI Database 26ai

Templates `.sql` para Oracle AI Database 26ai (versão técnica 23.26.x). Revisados em nov/2026 contra a documentação 26ai, RU 23.26.4.

Esta skill aprofunda Vector Search, JSON Duality, RAFT e migração. Para o restante, use a suíte [oracle-skills-ptbr](https://github.com/Maxwbh/oracle-skills-ptbr): PL/SQL 19c → `oracle-plsql-ptbr`; sintaxe nova genérica 26ai → `oracle-26ai-ptbr`; APEX → `oracle-apex-ptbr`; ORDS → `oracle-ords-ptbr`; laboratório local → `oracle-lab-ptbr`.

## Convenções

- Naming Trivadis 4.4: prefixos em inglês (`g_`, `gc_`, `l_`, `lc_`, `p_`, `r_`, `t_`, `c_`, `co_`, `e_`), nomes em PT-BR
- Keywords Oracle e pacotes nativos em inglês (`VECTOR`, `JSON RELATIONAL DUALITY VIEW`, `DBMS_VECTOR` …)
- Comentários em PT-BR
- Código exclusivo do 26ai marcado com `-- 26ai`, com a versão mínima quando a feature chegou num RU específico (ex.: `-- 26ai 23.26.1+`)
- Pontos sem confirmação na documentação marcados `-- A VERIFICAR`
- Cada cabeçalho traz as linhas "Revisado", "Tipo", "RU mínimo" e "Edição Free"
- Nenhuma senha, token ou chave fica no script: credenciais são pedidas em tempo de execução (`ACCEPT … HIDE` no SQLcl/SQL*Plus)
- APIs reutilizáveis (packages e procedures) **não fazem COMMIT nem ROLLBACK**: a transação pertence ao chamador. Exceções documentadas: rotinas de lote/manutenção (`processar_pendentes_lote`, `expurgar_log_rag`) e logs em transação autônoma

## Tipo de cada template

| Tipo | Significado | Templates |
|---|---|---|
| **Executável** | Cria os próprios objetos de exemplo e roda num 26ai limpo, na ordem indicada | `json_duality_view_basics.sql` → `json_duality_dml.sql` → `json_duality_etag_concurrency.sql` |
| **Dependente de configuração** | Roda depois de preparar algo fora do script (arquivo ONNX no servidor, Vector Pool, ACL, credencial de provedor) | `ai_vector_search_basics.sql` → `ai_vector_index_strategies.sql` → `ai_vector_embedding_pipeline.sql` → `ai_vector_rag_pattern.sql` |
| **Demonstrativo** | Roteiro comentado; exige infraestrutura que um script não cria (topologia RAFT com GSM e 3+ shards, banco 19c de origem) | `raft_*.sql`, `migration_19c_to_26ai.sql` |

Nenhum template foi executado em banco no CI: a validação automática (`.github/workflows/validar.yml`) é estática. Antes de usar em produção, rode-os num 26ai de teste.

## Índice por área

### AI Vector Search (4 templates)

| Arquivo | Cobre |
|---|---|
| `ai_vector_search_basics.sql` | Vector Pool (`vector_memory_size` dinâmico), `DBMS_VECTOR.LOAD_ONNX_MODEL`, tipo `VECTOR` (incl. BINARY/SPARSE), `VECTOR_EMBEDDING`, `VECTOR_DISTANCE`, métricas, busca exata |
| `ai_vector_index_strategies.sql` | HNSW × IVF, `NEIGHBOR PARTITIONS`, `CREATE … ONLINE` (23.26.1+), quantização SCALAR (23.26.1+) e PRODUCT (23.26.4+), `DBMS_VECTOR.REBUILD_INDEX`, `INDEX_VECTOR_MEMORY_ADVISOR`, hybrid vector index e `DBMS_HYBRID_VECTOR.SEARCH` |
| `ai_vector_embedding_pipeline.sql` | `UTL_TO_CHUNKS`/`VECTOR_CHUNKS`, embeddings em lote, atualização incremental, provedor externo (ACL, credencial `access_token`, `UTL_TO_EMBEDDING(S)`) |
| `ai_vector_rag_pattern.sql` | RAG completo: recuperação + `UTL_TO_GENERATE_TEXT` (ocigenai `/actions/chat`), auditoria de consultas |

### JSON Relational Duality (3 templates)

| Arquivo | Cobre |
|---|---|
| `json_duality_view_basics.sql` | `CREATE JSON RELATIONAL DUALITY VIEW` em SQL e GraphQL, anotações e diretivas, `GRAPHQL()` (23.26.0+), views `USER_JSON_DUALITY_VIEW*`, AutoREST (ORDS 23.1+) |
| `json_duality_dml.sql` | INSERT/UPDATE/DELETE de documentos, update parcial com `JSON_TRANSFORM` (sem ETag), sub-arrays, códigos ORA corretos |
| `json_duality_etag_concurrency.sql` | Cálculo do ETag, `NOCHECK`, GET → PUT, retry em ORA-42699, log de conflitos, `SYS_ROW_ETAG` |

### RAFT Replication (3 templates — exploratório)

| Arquivo | Cobre |
|---|---|
| `raft_setup_overview.sql` | Conceitos, licença, `create shardcatalog -repl native`, deploy, sharded/duplicated tables, `V$SHARD_REPLICATION_UNIT` |
| `raft_replication_units.sql` | Anatomia de RU (RF 3), `status ru`, `switchover ru`, `move ru`, `copy ru`, `relocate chunk`, `set ru parameter` |
| `raft_failover_recovery.sql` | Failover automático (eleição Raft), switchover e rebalance, monitoração, recuperação de réplicas |

### Migração 19c → 26ai (1 template)

| Arquivo | Cobre |
|---|---|
| `migration_19c_to_26ai.sql` | Upgrade direto a partir de 19c/21c, AutoUpgrade (versão do MOS; 26.6 em nov/2026), non-CDB → PDB, `vector_memory_size`, APEX após upgrade, roteiro, riscos |

## Funciona no 26ai Free?

O **Oracle AI Database 26ai Free** tem limite de 2 cores, 2 GB de RAM e 12 GB de dados de usuário. Fonte: Free Installation Guide 26ai, Licensing Restrictions.

| Template | Free? | Observação |
|---|---|---|
| `ai_vector_search_basics.sql` | Parcial | VECTOR, ONNX e busca exata rodam. O modelo ONNX e o Vector Pool precisam caber nos 2 GB. A doc de licença não lista Vector Search no Free (**A VERIFICAR**) |
| `ai_vector_index_strategies.sql` | Parcial | HNSW limitado pelo pool dentro dos 2 GB; recursos de RAC não se aplicam; blocos 23.26.x dependem do RU da imagem Free |
| `ai_vector_embedding_pipeline.sql` | Parcial | O caminho com ONNX no banco roda; provedor externo exige rede, ACL e credencial |
| `ai_vector_rag_pattern.sql` | Parcial | A recuperação roda; a geração exige LLM externo (ou Ollama local), rede e credencial |
| `json_duality_view_basics.sql` | A verificar | A doc de licença não tem linha explícita de duality views para o Free |
| `json_duality_dml.sql` | A verificar | Idem |
| `json_duality_etag_concurrency.sql` | A verificar | Idem |
| `raft_setup_overview.sql` | Sim | Licença 26ai: Raft no Free com até 3 nós, cada um dentro dos limites do Free |
| `raft_replication_units.sql` | Sim | Idem (3 nós Free) |
| `raft_failover_recovery.sql` | Sim | Idem; dá para simular a queda do leader em laboratório |
| `migration_19c_to_26ai.sql` | Parcial | O Free serve como destino de laboratório; o upgrade de produção é EE |

Montar o ambiente Free local (VM, container, rede): `oracle-lab-ptbr`.

## Como usar

1. **Confirme versão e RU do banco:**
   ```sql
   SELECT banner_full FROM v$version;
   SELECT version_full FROM v$instance;   -- RU, ex.: 23.26.4.0.0
   ```
2. **Confirme a edição:** EE, Free (tabela acima) ou SE2 (*a verificar*).
3. **Escolha o template** pela tabela abaixo e adapte preservando naming PT-BR, prefixos Trivadis e as marcações `-- 26ai`.
4. **RAFT:** comece por `raft_setup_overview.sql` e um laboratório com 3 nós Free; não vá direto para produção.

## Decisão rápida

| Cenário | Template |
|---|---|
| Similarity search em texto | `ai_vector_search_basics.sql` |
| HNSW ou IVF, quantização, hybrid index | `ai_vector_index_strategies.sql` |
| Documentos longos, chunking, provedor externo | `ai_vector_embedding_pipeline.sql` |
| Chatbot/assistente factual (RAG) | `ai_vector_rag_pattern.sql` |
| API de documento sobre tabelas relacionais | `json_duality_view_basics.sql` |
| INSERT/UPDATE/DELETE em duality view | `json_duality_dml.sql` |
| ORA-42699 em alta concorrência | `json_duality_etag_concurrency.sql` |
| Entender RAFT antes de avaliar | `raft_setup_overview.sql` |
| Replication units em laboratório | `raft_replication_units.sql` |
| Cenários de failover | `raft_failover_recovery.sql` |
| Planejar migração 19c → 26ai | `migration_19c_to_26ai.sql` |
