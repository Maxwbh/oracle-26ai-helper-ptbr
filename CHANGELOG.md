# Changelog

Todas as mudanças notáveis neste projeto serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e este projeto adere a [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [1.1.1] — 2026-11-06

Teste de integração dos templates no **Oracle AI Database 26ai Free 23.26.3** (imagem oficial `container-registry.oracle.com/database/free:latest`, SQL*Plus).

### Adicionado
- Linha `-- Testado:` no cabeçalho dos 7 templates executados, com o resultado
- `.github/scripts/teste_integracao_local.sh`: sobe o 26ai Free em container, roda os templates de Duality e (com o arquivo ONNX) os de Vector, e resume os erros
- Validador (`validar_repositorio.py`) passa a barrar as armadilhas de SQL*Plus/SQLcl: `;` seguido de comentário, linha em branco dentro de comando SQL e linha iniciando com `@`
- Tabela de dados de origem `laudos_origem` em `ai_vector_search_basics.sql` (o INSERT em lote referenciava tabela inexistente)

### Alterado
- Tabela "funciona no Free?" com resultados medidos (Vector e Duality funcionam no Free 23.26.3; quantização PRODUCT não, por ser 23.26.4+)
- `ai_vector_index_strategies.sql` executável em sequência: `DROP INDEX IF EXISTS` entre as alternativas (uma coluna aceita um índice vetorial — ORA-01408); IVF LOCAL comentado (exige tabela particionada); exemplo de `REBUILD_INDEX` sobre o HNSW quantizado
- Notas de privilégio: `DBMS_VECTOR_ADMIN` só para `PDB_DBA`; consultas V$ exigem `SELECT_CATALOG_ROLE`

### Corrigido
- **`;` seguido de comentário** fazia o SQL*Plus descartar o comando sem erro: o `GRANT CREATE MINING MODEL` não era executado e o `LOAD_ONNX_MODEL` falhava com ORA-01031 (também em `LOCAL;`, `FETCH APPROX …;` e numa duality view)
- **Linha em branco dentro de `CREATE … DUALITY VIEW`** encerrava o comando (view não criada; erros em cascata no template de ETag)
- **Linha iniciando com `@link`** na DDL GraphQL era executada como script pelo SQL*Plus (SP2-0310)
- **`vector_memory_size`:** a 1.1.0 dizia "dinâmico, não exige restart". Medido: no CDB com pool 0 no startup, o aumento exige `SCOPE=SPFILE` + restart (ORA-51950); com pool alocado, cresce sem restart e não reduz abaixo do inicial (ORA-51953); no PDB a cota é dinâmica e limitada ao CDB (ORA-51955)
- `CREATE TABLESPACE … DATAFILE SIZE` sem caminho exige OMF (ORA-02236 no container Free): o template passa a informar o caminho e explica a alternativa com OMF
- Exemplos de UPDATE/DELETE em duality view usavam texto `<etag lido>` (geravam ORA-42699): agora leem o ETag real numa variável de ligação
- Exemplo de DELETE com ETag apontava para documento já excluído

## [1.1.0] — 2026-11-06

Revisão completa contra a documentação Oracle AI Database 26ai (RU 23.26.4, out/2026), oracle-base.com e mikedietrichde.com. Itens sem fonte confirmada ficaram marcados "A VERIFICAR".

### Adicionado
- `metadata` no frontmatter no padrão da suíte (`version`, `release_date`, `repository`, `suite_size`, `author`, `contact`, `organization`, `site`)
- `references/ecossistema-ia-26ai.md`: Private Agent Factory 26.10 (Deep NL2SQL, Business Knowledge Graph, Knowledge Workbench, SDK Python, REST, A2A, observabilidade), Oracle AI Database Agent Engine, Deep NL2SQL × Select AI × NL2IR do APEX, Deep Data Security (23.26.2+) e impacto em RAG, AI Agents e duality views
- GraphQL nativo: função `GRAPHQL()` (23.26.0+) na reference de duality e nos templates
- Edição Free: tabela "funciona no Free?" por template em `assets/README.md` e linha "Edição Free" no cabeçalho de cada template
- Tabelas de novidades por Release Update (23.6 → 23.26.4) em Vector, Duality e RAFT
- `## Índice` nas references com mais de 100 linhas
- Marcação `-- 26ai` com versão mínima de RU (ex.: `-- 26ai 23.26.1+`) no código
- Cabeçalho de cada template com "Tipo" (executável / dependente de configuração / demonstrativo) e "RU mínimo"
- Validação automática no GitHub Actions (`.github/workflows/validar.yml` + `.github/scripts/validar_repositorio.py`): frontmatter, `suite_size`, references citadas e com índice, cabeçalhos dos templates, credenciais fixas, sintaxe sabidamente inexistente e referências à skill antiga; monta o pacote `.skill` e confere a estrutura
- Allowlist `cfg_retentativa_etag` e contrato de idempotência no retry de ETag (`p_max_tentativas => 1` devolve o conflito ao chamador)
- Auditoria do RAG em transação autônoma, com hash SHA-256 da pergunta, texto integral opt-in (`p_registrar_texto`), situação OK/ERRO e expurgo por retenção (`expurgar_log_rag`)

### Alterado
- `description` reescrita com ATIVE / Frases / NÃO ATIVE e ponteiros para a suíte
- Integração com a suíte [oracle-skills-ptbr](https://github.com/Maxwbh/oracle-skills-ptbr): 19c/PL/SQL → `oracle-plsql-ptbr`; APEX → `oracle-apex-ptbr`; sintaxe nova genérica 26ai → `oracle-26ai-ptbr`; operação do upgrade → `oracle-dba-ptbr`; laboratório local (26ai Free) → `oracle-lab-ptbr`
- Aviso de versão: GA on-prem 27/01/2026 (23.26.1) confirmado; RU atual 23.26.4; plataformas previstas (AIX/zLinux/Windows 2027); SE2 "a verificar"
- APEX 26.1/26.2 deixam de ser "não lançados"; APEX fica fora do escopo por pertencer à `oracle-apex-ptbr`
- Migração 19c → 26ai mantida no helper e atualizada: upgrade direto a partir de 19c e 21c, AutoUpgrade 26.6, roteiro e riscos
- SKILL.md passa a citar todas as references (antes ficavam órfãs)
- `LICENSE` e `NOTICE` passam a fazer parte do pacote `.skill`; `NOTICE` cita as fontes usadas

### Removido
- Toda referência à `oracle-sql-helper-ptbr` (dividida na suíte oracle-skills-ptbr)
- Parâmetros inexistentes `enable_ai_vector_search`, `json_relational_duality` e a nota sobre `result_cache_remote_expiration`
- Regra inventada "`_id` primeiro / `_metadata` segundo" no UPDATE de duality view
- Comandos GDSCTL inexistentes (`add ru`, `failover ru`, `config ru`, `add/remove replica`) e a view `gv$sharding_units`

### Corrigido
- `vector_memory_size`: no CDB com pool 0 o aumento exige `SCOPE=SPFILE` + restart (ORA-51950); com pool alocado, cresce sem restart e não reduz abaixo do inicial (ORA-51953); no PDB a cota é dinâmica e limitada ao CDB (ORA-51955) — medido no 26ai Free 23.26.3
- Quantização HNSW: `QUANTIZATION SCALAR COMPRESSION RATIO` (23.26.1+) e `PRODUCT` (23.26.4+) no lugar de `vector_compression` inventado
- IVF: parâmetro `NEIGHBOR PARTITIONS`; `ALTER INDEX … REBUILD ONLINE` só para IVF, HNSW via `DBMS_VECTOR.REBUILD_INDEX`; `CREATE VECTOR INDEX … ONLINE` desde 23.26.1
- Hybrid vector index (`MODEL … VECTOR_IDXTYPE …`) e `DBMS_HYBRID_VECTOR.SEARCH` (argumento JSON único)
- `UTL_TO_CHUNKS` (`by` = characters/words/vocabulary), credencial OpenAI (`access_token`), `UTL_TO_GENERATE_TEXT` no lugar de `DBMS_VECTOR.GENERATE` (inexistente)
- Significado dos erros ORA-42692, ORA-42693, ORA-42624 e ORA-40769; inclusão de ORA-40940 e ORA-42605
- Erro de dimensão de vetor: ORA-51803 (INSERT) e ORA-51808 (`VECTOR_DISTANCE`) no lugar de ORA-22849
- `UTL_TO_CHUNKS` retorna `VECTOR_ARRAY_T` de JSON (leitura via `JSON_VALUE`); `UTL_TO_EMBEDDING` é escalar
- Brechas de SQL injection nos pacotes de pipeline e de retry de ETag (nomes validados com `DBMS_ASSERT` e usados de fato)
- Packages sem SPEC; prefixo `co_` usado em cursor (Trivadis: `c_`)
- Senha fixa no `CREATE USER` e chaves de API no script → `ACCEPT … HIDE` + `UNDEFINE`; `DB_DEVELOPER_ROLE` → privilégios mínimos; `DIRECTORY` só com READ
- `COMMIT`/`ROLLBACK` dentro de APIs reutilizáveis: `processar_documento` usa `SAVEPOINT` e não confirma; o lote passa a ser `processar_pendentes_lote`; `consultar_rag` não confirma nem desfaz a transação do chamador
- LOB temporário de `gerar_resposta_llm` liberado também em caso de erro
- Nome do modelo em `processar_documento` validado contra `USER_MINING_MODELS` (além de `DBMS_ASSERT`)
- Views inexistentes `user_vector_indexes` e `v$sgastat 'vector pool'` → `V$VECTOR_INDEX` e `V$VECTOR_MEMORY_POOL`
- ORDS AutoREST de duality views: 23.1+ (antes 24.1+)
- RAFT: habilitado por `create shardcatalog -repl native` (default DG); RF fixo 3; heartbeat 150 ms; failover automático; `switchover ru -ru <id> -database <db>`; views `V$SHARD_REPLICATION_UNIT` e `SHARD_RAFT_PARAMETERS`; licença (Free até 3 nós; EE com RAC por shard)
- `CREATE SHARDED TABLE` com PRIMARY KEY declarada duas vezes
- 19c: Premier Support até 31/12/2029 e Extended até 31/12/2032 (antes 30/04/2024 e 30/04/2027)
- Copyright do `LICENSE` citava `oracle-sql-helper-ptbr`

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
