# oracle-26ai-helper-ptbr

Skill em português brasileiro para [Claude](https://claude.ai) focada em **Oracle AI Database 26ai** — features novas que não existem em 19c: AI Vector Search, JSON Relational Duality, e RAFT replication.

Versão atual: **v1** (abril 2026)

## Aviso importante sobre versão

Esta skill cobre **Oracle AI Database 26ai (versão técnica 23.26.x), Enterprise Edition**, GA on-prem desde **27/janeiro/2026**.

- Versão técnica interna: ainda família 23.x (rebrand de marketing)
- Edition: Enterprise Edition (Standard Edition 2 ainda sem data definida em abril/2026)
- **APEX 26.1**: fora de escopo — ainda não foi lançado (preview previsto fim 2026)
- **Multitenant**: mandatório em 26ai (CDB/PDB obrigatório, non-CDB foi descontinuado)

Se você está em **Oracle 19c**, esta skill **não se aplica** — use a skill complementar [oracle-sql-helper-ptbr](https://github.com/maxwbh/oracle-sql-helper-ptbr).

## Áreas cobertas

| Área | Reference | Templates |
|---|---|---|
| **AI Vector Search** | `references/ai-vector-search.md` | 4 templates (basics, index strategies, embedding pipeline, RAG pattern) |
| **JSON Relational Duality** | `references/json-relational-duality.md` | 3 templates (basics, DML, ETag concurrency) |
| **RAFT Replication** | `references/raft-globally-distributed.md` | 3 templates (overview, replication units, failover/recovery) — exploratório |
| **Migração 19c → 26ai** | `references/migration-19c-26ai.md` | 1 template (CDB/PDB obrigatório, AutoUpgrade, init params, certificação) |

## Princípios canônicos

A skill aplica 8 princípios em todo código gerado:

0. **Verifique a versão antes de prometer features.** Sempre confirme que o ambiente é 23ai/26ai antes de gerar código com `VECTOR`, duality view, ou RAFT
1. **Use SQL puro quando possível** — `VECTOR_DISTANCE` em SQL é melhor que loop PL/SQL
2. **Bind variables sempre**, vetores podem ser passados como bind para evitar reparse
3. **NOCOPY para BLOB/VECTOR grandes em IN OUT** — vetores 1536-dim ocupam 6KB cada, coleções podem ser MB
4. **Sizing de memória explícito antes de criar HNSW** — `vector_memory_size` é pré-requisito
5. **ETag obrigatório em UPDATE de duality view** — sem ele, ORA-42699 e lost updates
6. **Trivadis 4.4 continua valendo** para PL/SQL que envolve features novas (naming, exception handlers)
7. **Prefixos Trivadis em inglês, nomes em PT-BR** (mesma convenção da skill 19c)

## Convenção de nomes

Mesma convenção da skill `oracle-sql-helper-ptbr` (Trivadis 4.4 + adaptação PT-BR).

### Glossário — keywords novas em inglês obrigatoriamente

Adições específicas 26ai:

| Categoria | Exemplos |
|---|---|
| **Keywords novas SQL/PL/SQL** | `VECTOR`, `VECTOR_DISTANCE`, `VECTOR_EMBEDDING`, `JSON RELATIONAL DUALITY VIEW`, `WITH INSERT UPDATE DELETE`, `WITH NOCHECK`, `FETCH APPROX FIRST` |
| **Pacotes 26ai** | `DBMS_VECTOR`, `DBMS_HYBRID_VECTOR`, `DBMS_VECTOR_CHAIN`, `DBMS_SODA` |
| **Anotações duality** | `@insert`, `@update`, `@delete`, `@link`, `@nocheck`, `@check` |
| **Tipos de índice** | `HNSW`, `IVF`, `INMEMORY NEIGHBOR GRAPH`, `NEIGHBOR PARTITIONS` |
| **Métricas distance** | `COSINE`, `EUCLIDEAN`, `DOT`, `MANHATTAN`, `HAMMING` |

## Instalação

### Para uso pessoal no Claude.ai (Pro/Team/Enterprise)

1. Baixe o arquivo `.skill` da [aba Releases](https://github.com/maxwbh/oracle-26ai-helper-ptbr/releases) (procurar `oracle-26ai-helper-ptbr-v1.skill`)
2. Em Claude.ai, vá em **Settings → Capabilities → Skills**
3. Faça upload do arquivo `.skill`
4. A skill ativa automaticamente quando você menciona termos 26ai inequívocos (`VECTOR`, `duality view`, `HNSW`, `RAFT`, etc.)

### Para uso via API

A skill pode ser usada como referência para construir prompts de sistema customizados em integrações via API.

## Estrutura do repositório

```
oracle-26ai-helper-ptbr/
├── SKILL.md                              # Frontmatter + princípios + glossário
├── assets/                               # Templates SQL prontos para clonar
│   ├── README.md                         # Índice dos templates
│   │
│   ├── # AI Vector Search
│   ├── ai_vector_search_basics.sql       # VECTOR data type, embedding model, similarity search
│   ├── ai_vector_index_strategies.sql    # HNSW vs IVF, hybrid vector index
│   ├── ai_vector_embedding_pipeline.sql  # Chunking, batch embedding, modelos externos
│   ├── ai_vector_rag_pattern.sql         # RAG completo: retrieval + generation
│   │
│   ├── # JSON Duality
│   ├── json_duality_view_basics.sql      # CREATE DUALITY VIEW (SQL e GraphQL)
│   ├── json_duality_dml.sql              # INSERT/UPDATE/DELETE em duality views
│   ├── json_duality_etag_concurrency.sql # ETag concurrency control, retry exponencial
│   │
│   ├── # RAFT (exploratório)
│   ├── raft_setup_overview.sql           # Conceitos GDD, GSM, comandos GDSCTL
│   ├── raft_replication_units.sql        # RU anatomia, sharded tables, switchover
│   ├── raft_failover_recovery.sql        # Failover scenarios, PITR em GDD
│   │
│   └── migration_19c_to_26ai.sql         # AutoUpgrade, CDB/PDB, init params
│
└── references/                           # Documentos de referência
    ├── ai-vector-search.md
    ├── json-relational-duality.md
    ├── raft-globally-distributed.md
    └── migration-19c-26ai.md
```

## Estatísticas

- **11 templates SQL** prontos para uso
- **4 references** com conceitos e padrões
- **8 princípios canônicos**
- ~85 KB total descompactado

## Decisão rápida — qual template usar?

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

## Skill complementar

Para Oracle 19c (PL/SQL, APEX 24.2, ORDS, DBA, performance, EBR), use a skill paralela: [oracle-sql-helper-ptbr](https://github.com/maxwbh/oracle-sql-helper-ptbr).

As duas skills foram desenhadas com gatilhos não-sobrepostos:
- Termos 23ai/26ai-only (`VECTOR`, `duality view`, `HNSW`, `RAFT`) → ativa esta skill
- Termos Oracle 19c (PL/SQL, APEX, ORDS, EBR, etc.) → ativa a skill complementar

## Filosofia

- **PT-BR como idioma principal** — comentários, nomes de domínio, status
- **Trivadis 4.4 como base** — naming convention preserved da skill 19c
- **Templates executáveis em `assets/`** — não snippets em markdown, mas SQL real que roda em Oracle 23ai+/26ai
- **Anti-patterns documentados antes×depois** — código errado e corrigido lado a lado
- **MVP focado** — apenas 3 features (Vector Search + JSON Duality + RAFT) cobertas em profundidade

## Limitações

- **Foco em 23ai/26ai** — não funciona em Oracle 19c ou anteriores
- **Enterprise Edition apenas** — algumas features (Globally Distributed Database para RAFT) exigem opções licenciadas adicionais
- **APEX 26.1** — fora de escopo até GA (previsto fim 2026/início 2027)
- **RAFT é cobertura exploratória** — produção exige planejamento dedicado e tipicamente consultoria Oracle
- **Português brasileiro** — não é português europeu

## Histórico de versões

| Versão | Mudanças principais |
|---|---|
| **v1** (abr/2026) | Versão inicial. MVP focado em AI Vector Search + JSON Relational Duality + RAFT replication + migração 19c → 26ai |

## Contribuindo

Issues e PRs bem-vindos. Se identificar:
- Mudanças de sintaxe entre release updates do 26ai
- Anti-patterns não cobertos
- Erros nos templates
- Sugestões de naming PT-BR para keywords novas

abra issue descrevendo o caso de uso real.

## Licença

Apache License 2.0 — veja [LICENSE](LICENSE).

Esta skill é construída sobre:
- [Trivadis Coding Guidelines 4.4](https://trivadis.github.io/plsql-and-sql-coding-guidelines/v4.4/) — naming e estrutura PL/SQL
- Documentação oficial Oracle AI Database 26ai
- [Oracle-Base](https://oracle-base.com/) (Tim Hall) — princípios práticos e blog posts sobre 26ai

## Autor

**Maxwell da Silva Oliveira** — Senior Oracle Developer

- Empresa: M&S do Brasil
- Sete Lagoas, Minas Gerais, Brasil
- E-mail: [maxwbh@gmail.com](mailto:maxwbh@gmail.com)
- GitHub: [@maxwbh](https://github.com/maxwbh)
