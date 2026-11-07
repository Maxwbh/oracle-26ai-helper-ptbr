# oracle-26ai-helper-ptbr

Skill em português brasileiro para [Claude](https://claude.ai) com **aprofundamento em Oracle AI Database 26ai**: AI Vector Search, JSON Relational Duality (com GraphQL), RAFT replication e migração 19c → 26ai.

Versão atual: **1.1.1** (novembro/2026) — revisada contra a documentação Oracle AI Database 26ai (RU 23.26.4) e testada no 26ai Free 23.26.3.

## Onde esta skill se encaixa

Ela complementa a suíte **[oracle-skills-ptbr](https://github.com/Maxwbh/oracle-skills-ptbr)**:

| Precisa de | Skill |
|---|---|
| Vector Search, Duality, RAFT, migração 19c → 26ai em profundidade | **esta skill** |
| PL/SQL 19c (packages, procedures, LOBs, EBR) | `oracle-plsql-ptbr` |
| Sintaxe nova genérica do 26ai (BOOLEAN, Domains, QUALIFY, SQL Firewall…) | `oracle-26ai-ptbr` |
| APEX (inclusive 26.1 / 26.2) | `oracle-apex-ptbr` |
| Endpoints REST, AutoREST de duality views | `oracle-ords-ptbr` |
| Operação do upgrade (RMAN, Data Guard, PDB) | `oracle-dba-ptbr` |
| Montar um 26ai Free local para testar | `oracle-lab-ptbr` |

## Aviso sobre versão e edição (nov/2026)

- **26ai on-prem:** Enterprise Edition para Linux x86-64, GA em **27/01/2026** (RU 23.26.1). RU atual: **23.26.4** (out/2026). IBM AIX, zLinux e Windows estão previstos para 2027.
- **26ai Free:** 2 cores, 2 GB RAM e 12 GB de dados. A tabela "funciona no Free?" por template está em [`assets/README.md`](assets/README.md).
- **Standard Edition 2:** disponibilidade e escopo das features *a verificar*.
- **Multitenant:** 26ai só existe como CDB/PDB.
- **APEX:** 26.1 (mai/2026) e 26.2 (06/10/2026) já foram lançados, mas APEX fica na `oracle-apex-ptbr`.

Em **Oracle 19c** as features desta skill não existem. Use a suíte.

## Áreas cobertas

| Área | Reference | Templates |
|---|---|---|
| **AI Vector Search** | `references/ai-vector-search.md` | 4 (basics, index strategies, embedding pipeline, RAG) |
| **JSON Relational Duality** | `references/json-relational-duality.md` | 3 (basics, DML, ETag) |
| **RAFT Replication** | `references/raft-globally-distributed.md` | 3 (overview, replication units, failover) — exploratório |
| **Migração 19c → 26ai** | `references/migration-19c-26ai.md` | 1 (AutoUpgrade, CDB/PDB, roteiro) |
| **Ecossistema de IA** | `references/ecossistema-ia-26ai.md` | — (Private Agent Factory, Agent Engine, Deep NL2SQL × NL2IR, Deep Data Security, GraphQL) |

## Princípios canônicos

0. **Confirme versão e RU antes de prometer features.** Várias chegaram num RU específico.
1. **SQL puro antes de PL/SQL.**
2. **Bind variables sempre**, inclusive para vetores.
3. **NOCOPY em parâmetros IN OUT grandes.**
4. **Vector Pool dimensionado antes do HNSW.** No CDB, ligar o pool (de 0) exige restart; depois cresce sem restart.
5. **ETag no UPDATE de documento completo em duality view**; trate ORA-42699.
6. **Não invente sintaxe.**
7. **Naming Trivadis 4.4:** prefixos em inglês, nomes em PT-BR.
8. **Código 26ai marcado** com `-- 26ai` e versão mínima (ex.: `-- 26ai 23.26.1+`).

## Instalação

### Claude.ai (Pro/Team/Enterprise)

1. Baixe `oracle-26ai-helper-ptbr.skill` da [aba Releases](https://github.com/Maxwbh/oracle-26ai-helper-ptbr/releases).
2. Em Claude.ai, vá em **Settings → Capabilities → Skills**.
3. Faça upload do arquivo `.skill`.

O pacote `.skill` contém `SKILL.md`, `references/`, `assets/`, `CHANGELOG.md`, `LICENSE` e `NOTICE`. README e CONTRIBUTING ficam só no repositório.

## Estrutura do repositório

```
oracle-26ai-helper-ptbr/
├── SKILL.md                              # Frontmatter + princípios + fluxo
├── CHANGELOG.md · LICENSE · NOTICE       # (entram no pacote)
├── README.md · CONTRIBUTING.md           # (só no repositório)
├── references/
│   ├── ai-vector-search.md
│   ├── json-relational-duality.md
│   ├── raft-globally-distributed.md
│   ├── migration-19c-26ai.md
│   └── ecossistema-ia-26ai.md
└── assets/
    ├── README.md                         # Índice + tabela "funciona no Free?"
    ├── ai_vector_search_basics.sql
    ├── ai_vector_index_strategies.sql
    ├── ai_vector_embedding_pipeline.sql
    ├── ai_vector_rag_pattern.sql
    ├── json_duality_view_basics.sql
    ├── json_duality_dml.sql
    ├── json_duality_etag_concurrency.sql
    ├── raft_setup_overview.sql
    ├── raft_replication_units.sql
    ├── raft_failover_recovery.sql
    └── migration_19c_to_26ai.sql
```

## Estatísticas

- 11 templates SQL e 5 references
- `suite_size`: 20 arquivos de apoio (5 references, 12 assets, CHANGELOG, LICENSE, NOTICE)

## Decisão rápida — qual template usar?

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

## Limitações

- Só 23ai/26ai; não se aplica a 19c.
- RAFT é exploratório; produção exige planejamento e licença (EE: RAC por shard).
- O ecossistema de IA (Agent Factory, Agent Engine, Deep Data Security) é descritivo: versões mínimas e licenças em parte estão *a verificar*.
- Português brasileiro.

## Histórico de versões

| Versão | Mudanças principais |
|---|---|
| **1.1.1** (nov/2026) | Teste de integração no 26ai Free 23.26.3: correções de SQL*Plus, Vector Pool, privilégios e exemplos executáveis; validador e script de teste local. |
| **1.1.0** (nov/2026) | Revisão contra a doc 26ai RU 23.26.4; correção de sintaxe inventada em Vector, Duality e RAFT; tabela Free; ecossistema de IA; integração com a suíte oracle-skills-ptbr. Detalhes em `CHANGELOG.md`. |
| **v1** (abr/2026) | Versão inicial |

## Ambiente de teste

`ambiente-teste/` sobe 26ai Free + ORDS + APEX em Docker, com snapshot dourado e PDB descartável: a suíte de templates roda num banco limpo em ~30 s. Veja `ambiente-teste/README.md`.

## Contribuindo

Veja [CONTRIBUTING.md](CONTRIBUTING.md). Issues e PRs são bem-vindos, principalmente sobre mudanças de sintaxe entre RUs do 26ai.

## Licença

Apache License 2.0 — veja [LICENSE](LICENSE) e [NOTICE](NOTICE).

Construída sobre:
- [Trivadis Coding Guidelines 4.4](https://trivadis.github.io/plsql-and-sql-coding-guidelines/v4.4/)
- Documentação oficial Oracle AI Database 26ai (docs.oracle.com)
- [Oracle-Base](https://oracle-base.com/) (Tim Hall) e [mikedietrichde.com](https://mikedietrichde.com/) (Mike Dietrich)

## Autor

**Maxwell da Silva Oliveira** — Senior Oracle Developer

- Empresa: M&S do Brasil LTDA — https://msbrasil.inf.br
- Sete Lagoas, Minas Gerais, Brasil
- E-mail: [maxwbh@gmail.com](mailto:maxwbh@gmail.com)
- GitHub: [@maxwbh](https://github.com/maxwbh)
