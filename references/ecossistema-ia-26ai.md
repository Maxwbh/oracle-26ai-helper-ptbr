# Ecossistema de IA do Oracle AI Database 26ai — Reference

Visão curta das peças de IA que usam o 26ai como base de dados. Revisado em nov/2026. **Não gere código destas ferramentas sem antes confirmar a versão do banco e a licença com o usuário**: várias são recentes e mudam a cada release.

Nesta sessão, blogs.oracle.com e oracle.com recusaram acesso (HTTP 403). Os fatos abaixo vêm de docs.oracle.com. O que depende dos blogs está marcado **A VERIFICAR**.

## Índice

- [Mapa rápido](#mapa-rápido)
- [Private Agent Factory 26.10](#private-agent-factory-2610)
- [Oracle AI Database Agent Engine](#oracle-ai-database-agent-engine)
- [Deep NL2SQL × Select AI × NL2IR do APEX](#deep-nl2sql--select-ai--nl2ir-do-apex)
- [Deep Data Security](#deep-data-security)
- [GraphQL nativo](#graphql-nativo)
- [Fontes](#fontes)

## Mapa rápido

| Peça | O que é | Banco mínimo | Licença |
|---|---|---|---|
| Private Agent Factory 26.10 | Plataforma no-code para construir e publicar agentes | 26ai (self-managed ou Autonomous); RU mínimo não informado | "No-cost add-on" do 26ai (FAQ) |
| Agent Engine | Runtime de agentes **dentro** do banco (`DBMS_AI_AGENT`) | **A VERIFICAR**; guia rotulado "Release 23.26.3.2" | **A VERIFICAR** |
| Deep NL2SQL | Agente pré-construído do Agent Factory que gera **e executa** SQL | Fonte de dados 19c+ (o Agent Factory roda em 26ai) | Como o Agent Factory |
| Select AI | NL2SQL / RAG / agentes via `DBMS_CLOUD_AI` | 23.26.1 (on-prem) | **A VERIFICAR** |
| NL2IR (APEX 26.1) | Pergunta em linguagem natural vira configuração de Interactive Report | APEX 26.1 + serviço de IA generativa | Conforme o APEX |
| Deep Data Security | Autorização por linha/coluna/célula com identidade do usuário final | **23.26.2**; token OCI IAM e integração APEX em **23.26.3** | Não consta no Licensing Information User Manual — **A VERIFICAR** |
| `GRAPHQL()` | Consulta GraphQL em SQL, retorno JSON | **23.26.0** | Incluído no banco (sem menção específica de licença) |

## Private Agent Factory 26.10

Recursos documentados no "What's New" 26.10:

- **Deep NL2SQL** com **Business Knowledge Graph** opcional para contexto de negócio
- **Knowledge Workbench**: criar, avaliar e publicar Business Knowledge Graphs
- **Memory Workbench**: respostas de esclarecimento salvas como memória
- **SDK Python** (usuário/senha ou SSO) e **APIs REST**
- **A2A** (Agent2Agent 1.0 e 0.3, JSON-RPC sobre HTTP(S))
- **Observabilidade**: dashboards de métricas, sessões, traces e spans

Implantação: containers Podman em Oracle Linux 8/9, Ubuntu 24.04, RHEL ou macOS; modos Production e Quickstart. O modo Production exige um Oracle AI Database 26ai com `max_string_size=EXTENDED`. A página de instalação pelo OCI Marketplace não foi lida — **A VERIFICAR**. Data do anúncio: **A VERIFICAR** (blog bloqueado); a doc 26.10 é de nov/2026.

O agente pode rodar dentro do banco ("DB Agent Engine"): o Agent Factory compila o workflow para Open Agent Spec e executa numa PDB que tenha `DBMS_AI_AGENT`.

## Oracle AI Database Agent Engine

- Executa agentes e workflows Agent Spec 26.1.0 dentro do banco, coordenando chamadas a LLM, ferramentas PL/SQL, transações e segurança.
- Pré-requisitos documentados: pacotes `DBMS_AI_AGENT` e `DBMS_VECTOR_CHAIN`, privilégio `CREATE CREDENTIAL` e ACL de rede.
- `DBMS_AI_AGENT` (Agent Engine) ≠ `DBMS_CLOUD_AI_AGENT` (Select AI Agent): são pacotes diferentes.
- Versão mínima, plataformas e licença: **A VERIFICAR**.

## Deep NL2SQL × Select AI × NL2IR do APEX

| | Deep NL2SQL | Select AI | NL2IR (APEX 26.1) |
|---|---|---|---|
| Onde roda | Agent Factory | Pacote `DBMS_CLOUD_AI` no banco | Interactive Report do APEX |
| Executa SQL gerado? | **Sim** (executor somente leitura) | **A VERIFICAR** (ações do `DBMS_CLOUD_AI`) | **Não**: produz filtros, quebras e gráficos do IR |
| Contexto de negócio | Business Knowledge Graph, esclarecimentos, memória | Perfil de IA (`DBMS_CLOUD_AI`) | Configurações e nomes de colunas do relatório |
| Dados enviados ao LLM | **A VERIFICAR** | **A VERIFICAR** | A doc diz que dados da aplicação nunca vão ao serviço de IA |

Sobre o NL2IR: a doc diz que ele traduz o pedido para recursos existentes do Interactive Report e que "produces report settings". A afirmação "não executa SQL gerado" é dedução dessa descrição; não há frase literal da Oracle.

Comparação detalhada entre Deep NL2SQL e Select AI: nenhuma página da Oracle compara os dois — **A VERIFICAR**. Para APEX → `oracle-apex-ptbr`.

## Deep Data Security

- Autorização imposta pelo banco em nível de linha, coluna e célula ("Deep Sec").
- Integra com IAM externo (**Microsoft Entra ID**, **OCI IAM**; o guia também cobre Keycloak). A identidade do usuário final e da aplicação viaja em tokens OAuth 2.0.
- **RU 23.26.2:** a feature (views como `USER_DATA_GRANTS`). **RU 23.26.3:** autenticação por token OCI IAM e MFA para usuários locais; a integração com o APEX exige 23.26.3+. **RU 23.26.4:** filtros de data grants, SQL macros, Keycloak/OAUTH2.

Impacto nas áreas desta skill:

| Área | Impacto |
|---|---|
| **RAG** | A doc cita embeddings para RAG entre os formatos cobertos: a busca vetorial passa a devolver só os chunks que o usuário final pode ver. Teste o recall com usuários de perfis diferentes. |
| **AI Agents** | SQL gerado por IA é autorizado pelo usuário que iniciou a tarefa, não por uma conta compartilhada com privilégio amplo. |
| **Duality views via ORDS** | A doc cita JSON por duality views entre os formatos cobertos. Como o ORDS repassa a identidade: **A VERIFICAR** (o guia de Deep Sec não menciona ORDS). |

## GraphQL nativo

A função de tabela `GRAPHQL()` (23.26.0+) consulta tabelas com sintaxe GraphQL e devolve JSON. Exemplo e diferença para a DDL de duality view em `json-relational-duality.md`, seção "GraphQL nativo no 26ai".

## Fontes

- Agent Factory 26.10: https://docs.oracle.com/en/database/oracle/agent-factory/26.10/paias/whats-new.html , .../faq.html , .../prerequisites.html , .../a2a-agents.html , .../deep-nl2sql-agents.html , .../in-db-executor.html
- Anúncio (blog, não lido — HTTP 403): https://blogs.oracle.com/database/announcing-private-agent-factory-26-10-featuring-deep-nl2sql
- Agent Engine: https://docs.oracle.com/en/database/oracle/oracle-database/26/odbae/oracle-ai-database-agent-engine.html
- NL2IR: https://docs.oracle.com/en/database/oracle/apex/26.1/htmrn/new-features.html e https://docs.oracle.com/en/database/oracle/apex/26.1/apxdc/exploring-data-natural-language.html
- Deep Data Security: https://docs.oracle.com/en/database/oracle/oracle-database/26/ddscg/why-choose-oracle-deep-data-security.html , https://docs.oracle.com/en/database/oracle/oracle-database/26/nfcoa/ru23_26_2.html , https://docs.oracle.com/en/database/oracle/apex/26.2/htmdb/configuring-deep-data-security-with-apex.html
- GraphQL: https://docs.oracle.com/en/database/oracle/oracle-database/26/gphql/graphql-table-function.html
- Select AI: https://docs.oracle.com/en/database/oracle/oracle-database/26/saicm/index.html
