---
name: oracle-26ai-helper-ptbr
description: "Aprofundamento em Oracle AI Database 26ai (23.26.x) — AI Vector Search, JSON Relational Duality, RAFT replication e migração 19c→26ai, com templates SQL/PL/SQL em PT-BR. ATIVE em VECTOR, VECTOR_DISTANCE, VECTOR_EMBEDDING, HNSW, IVF, vector_memory_size, ONNX, DBMS_VECTOR, DBMS_VECTOR_CHAIN, DBMS_HYBRID_VECTOR, hybrid vector index, RAG, UTL_TO_CHUNKS, quantização, duality view, ETag, ORA-42699, @nocheck, @link, GRAPHQL(), MongoDB API, Globally Distributed Database, RAFT, replication unit, GDSCTL, AutoUpgrade para 26ai, Deep Data Security, Private Agent Factory, Deep NL2SQL. Frases — 'busca semântica no banco', 'RAG em PL/SQL', 'HNSW ou IVF?', 'duality view dept emp', 'ORA-42699 em produção', 'RAFT funciona no Free?', 'planejar migração 19c pro 26ai'. NÃO ATIVE em Oracle 19c, PL/SQL ou SQL sem essas features (oracle-plsql-ptbr), sintaxe nova genérica do 26ai (oracle-26ai-ptbr), APEX (oracle-apex-ptbr), instalar banco local (oracle-lab-ptbr), nem vector DB ou JSON fora do Oracle (Pinecone, MongoDB nativo)."
metadata:
  version: 1.1.0
  release_date: 2026-11-06
  repository: https://github.com/Maxwbh/oracle-26ai-helper-ptbr
  suite_size: 20
  author: Maxwell da Silva Oliveira
  contact: maxwbh@gmail.com
  organization: M&S do Brasil LTDA
  site: https://msbrasil.inf.br
---

# Oracle 26ai Helper PT-BR

Skill de **aprofundamento** em Oracle AI Database 26ai (versão técnica 23.26.x). Complementa a suíte [oracle-skills-ptbr](https://github.com/Maxwbh/oracle-skills-ptbr): a suíte cobre o dia a dia 19c e a sintaxe nova do 26ai; esta skill desce ao detalhe de quatro áreas.

| Área | Reference | Templates em `assets/` |
|---|---|---|
| **AI Vector Search** | `references/ai-vector-search.md` | 4 |
| **JSON Relational Duality** (+ GraphQL) | `references/json-relational-duality.md` | 3 |
| **RAFT Replication** (exploratório) | `references/raft-globally-distributed.md` | 3 |
| **Migração 19c → 26ai** | `references/migration-19c-26ai.md` | 1 |
| **Ecossistema de IA** (Agent Factory, Deep Data Security) | `references/ecossistema-ia-26ai.md` | — (sem código) |

Leia a reference da área antes de gerar código. Escolha o template pela tabela "Decisão rápida" em `assets/README.md`, que também mostra o que roda no 26ai Free.

## Versão, edição e RU (nov/2026)

- **26ai on-prem:** EE para Linux x86-64, GA em 27/01/2026 (RU 23.26.1). RU atual: **23.26.4** (out/2026). AIX, zLinux e Windows previstos para 2027.
- **Free:** "Oracle AI Database 26ai Free" — 2 cores, 2 GB RAM, 12 GB de dados. Bom para laboratório; o RAFT é permitido com até 3 nós. Montar o ambiente → `oracle-lab-ptbr`.
- **SE2:** disponibilidade e escopo das features **a verificar**. Não prometa Vector/Duality em SE2 sem confirmação.
- **Multitenant:** 26ai só existe como CDB/PDB.
- **APEX:** 26.1 e 26.2 já existem, mas APEX não é escopo desta skill → `oracle-apex-ptbr`.

Muita coisa chegou num RU específico (HNSW ONLINE e quantização em 23.26.1, Deep Data Security em 23.26.2, product quantization em 23.26.4). Por isso **confirme o RU** antes de usar essas features: `SELECT version_full FROM v$instance;`.

## Princípios canônicos

0. **Confirme versão e RU antes de prometer features.** Em 19c nada disto funciona; responda isso diretamente e aponte a skill da suíte.
1. **SQL puro antes de PL/SQL.** `VECTOR_DISTANCE` e `INSERT … SELECT VECTOR_EMBEDDING(…)` em vez de loop linha a linha.
2. **Bind variables sempre**, inclusive para vetores.
3. **NOCOPY em parâmetros IN OUT grandes** (VECTOR, CLOB, coleções).
4. **Vector Pool dimensionado antes do HNSW.** `vector_memory_size` é dinâmico (`SCOPE=BOTH`), mas sem pool não há HNSW. Use `DBMS_VECTOR.INDEX_VECTOR_MEMORY_ADVISOR` em vez de chute.
5. **ETag no UPDATE de documento completo em duality view.** Envie `_metadata.etag` e trate ORA-42699 com retry. Não existe regra de ordem de campos.
6. **Não invente sintaxe.** Pacotes de IA mudam por RU; se não estiver na reference, consulte a doc 26ai ou diga que não sabe.
7. **Naming Trivadis 4.4:** prefixos em inglês (`g_`, `gc_`, `l_`, `lc_`, `p_`, `r_`, `t_`, `co_`, `e_`), nomes em PT-BR, keywords e pacotes Oracle em inglês. Revisão de padrão → `oracle-trivadis-ptbr`.
8. **Marque o código 26ai:** comentário `-- 26ai` e versão mínima quando a feature for de um RU específico (ex.: `-- 26ai 23.26.1+`).

## Glossário — fica em inglês

| Categoria | Exemplos |
|---|---|
| Keywords SQL | `VECTOR`, `VECTOR_DISTANCE`, `VECTOR_EMBEDDING`, `FETCH APPROX FIRST`, `WITH TARGET ACCURACY`, `JSON RELATIONAL DUALITY VIEW`, `WITH INSERT UPDATE DELETE`, `WITH NOCHECK`, `GRAPHQL()` |
| Pacotes | `DBMS_VECTOR`, `DBMS_VECTOR_CHAIN`, `DBMS_HYBRID_VECTOR`, `DBMS_AI_GRAPHRAG`, `DBMS_AI_AGENT`, `DBMS_SODA` |
| Diretivas duality | `@insert`, `@update`, `@delete`, `@link`, `@nocheck`, `@check`, `@hidden`, `@generated`, `@flex` |
| Índices | `HNSW`, `IVF`, `INMEMORY NEIGHBOR GRAPH`, `NEIGHBOR PARTITIONS`, `QUANTIZATION SCALAR` / `PRODUCT` |
| Métricas | `COSINE`, `DOT`, `EUCLIDEAN`, `EUCLIDEAN_SQUARED`, `MANHATTAN`, `HAMMING`, `JACCARD` |
| RAFT | `-repl native`, `switchover ru`, `status ru`, `relocate chunk`, `V$SHARD_REPLICATION_UNIT` |

## Fluxo de uso

**Antes de qualquer código:** confirme a versão, o RU e a edição (EE, Free); diga se o ambiente é produção, desenvolvimento ou laboratório.

**AI Vector Search:** dimensionar `vector_memory_size` → `DBMS_VECTOR.LOAD_ONNX_MODEL` (ou provedor externo com credencial) → coluna `VECTOR(dim, FLOAT32)` → `INSERT … SELECT VECTOR_EMBEDDING(…)` → índice HNSW ou IVF → consulta com `VECTOR_DISTANCE` + `FETCH APPROX FIRST n ROWS ONLY`.

**JSON Duality:** confirmar PK/FK → desenhar a hierarquia do documento → `CREATE JSON RELATIONAL DUALITY VIEW` (SQL ou GraphQL) → anotações por tabela ou coluna → ETag e retry em ORA-42699 → expor via ORDS (`oracle-ords-ptbr`).

**RAFT (exploratório):** licença (Free: 3 nós; EE: RAC por shard) → `create shardcatalog -repl native` → deploy → `status ru`. Failover é automático; não existe `add ru` nem `failover ru`.

**Migração 19c → 26ai:** upgrade direto a partir de 19c e 21c; AutoUpgrade (versão mais recente do MOS); non-CDB vira PDB. Checklist de código → `oracle-26ai-ptbr`; operação do upgrade → `oracle-dba-ptbr`.

**Ecossistema de IA:** só explicação e comparação (Agent Factory, Agent Engine, Deep NL2SQL × NL2IR, Deep Data Security). Não gere código sem confirmar versão e licença.

## Anti-patterns 26ai

| Antipattern | Correção |
|---|---|
| `CREATE INDEX` comum em coluna VECTOR | `CREATE VECTOR INDEX … ORGANIZATION INMEMORY NEIGHBOR GRAPH` (HNSW) ou `NEIGHBOR PARTITIONS` (IVF) |
| HNSW sem Vector Pool | `ALTER SYSTEM SET vector_memory_size = … SCOPE=BOTH` (dinâmico) |
| `ALTER INDEX … REBUILD` em HNSW | `DBMS_VECTOR.REBUILD_INDEX` (ALTER INDEX só em IVF) |
| `DBMS_VECTOR.GENERATE` | Não existe; use `UTL_TO_GENERATE_TEXT` |
| Credencial OpenAI com chaves OCI | OpenAI usa `{"access_token": …}`; chaves OCI são do `ocigenai` |
| UPDATE de documento sem ETag | Envie `_metadata.etag`; trate ORA-42699 |
| Todos os campos no ETag | `WITH NOCHECK` / `@nocheck` nos campos não críticos |
| Embeddings em VARCHAR2 | Tipo `VECTOR` nativo |
| Loop PL/SQL gerando embedding linha a linha | `INSERT … SELECT VECTOR_EMBEDDING(…)` ou `UTL_TO_EMBEDDINGS` |
| `add ru` / `failover ru` no GDSCTL | Comandos inexistentes; as RUs nascem no deploy e o failover é automático |

## Operações de risco

- **CREATE VECTOR INDEX sem ONLINE** (antes de 23.26.1, ou nos casos sem suporte) → bloqueia DML
- **HNSW local (23.26.2+)** → DML na tabela-base gera erro depois de criado o índice
- **Vector Pool subdimensionado** → falha ao criar ou carregar HNSW
- **DROP de duality view com clientes ativos** → quebra REST e MongoDB API
- **Deep Data Security ligado sem teste** → RAG e agentes passam a ver menos dados (é o objetivo, mas valide o recall)
- **Catálogo RAFT criado sem `-repl native`** → não dá para mudar depois
- **Migração non-CDB → PDB** → connection strings mudam; teste o fallback antes
