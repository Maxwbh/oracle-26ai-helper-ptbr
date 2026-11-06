# Migração Oracle 19c → 26ai — Reference

Conceitos e considerações para upgrade. Revisado em nov/2026 contra a documentação Oracle AI Database 26ai (RU 23.26.4). Itens sem fonte confirmada estão marcados **A VERIFICAR**.

> Escopo nesta skill: visão de planejamento para quem vai usar Vector Search, JSON Duality e RAFT depois do upgrade. Checklist de código e sintaxe nova → `oracle-26ai-ptbr`; operação do upgrade (RMAN, Data Guard, PDB) → `oracle-dba-ptbr`; laboratório local 26ai Free → `oracle-lab-ptbr`. Suíte: https://github.com/Maxwbh/oracle-skills-ptbr

## Índice

- [Status do release (nov/2026)](#status-do-release-nov2026)
- [Caminho de upgrade](#caminho-de-upgrade)
- [Mudanças arquiteturais obrigatórias](#mudanças-arquiteturais-obrigatórias)
- [AutoUpgrade — ferramenta canônica](#autoupgrade--ferramenta-canônica)
- [Roteiro de migração — fases](#roteiro-de-migração--fases)
- [Riscos principais](#riscos-principais)
- [APEX após upgrade](#apex-após-upgrade)
- [Recomendação para ambientes sem cronograma definido](#recomendação-para-ambientes-sem-cronograma-definido)
- [Documentação e fontes](#documentação-e-fontes)

## Status do release (nov/2026)

| Item | Situação | Fonte |
|---|---|---|
| 26ai EE on-prem Linux x86-64 | GA em **27/01/2026**, RU 23.26.1 | Mike Dietrich, 27/01/2026 |
| RU atual | **23.26.4** (out/2026); anteriores 23.26.0 out/2025, 23.26.1 jan, 23.26.2 abr, 23.26.3 jul/2026 | AI Vector Search User's Guide 26ai (What's New por RU) |
| Outras plataformas | IBM AIX, zLinux, Windows previstos para 2027; SPARC Solaris e Linux ARM **não planejados** | Mike Dietrich, 01/10/2026 |
| Standard Edition 2 | **A VERIFICAR** — fontes de terceiros divergem (jul/2026 × out/2026) | — |
| 26ai Free | Disponível (Linux x86-64, ARM, Windows); 2 cores, 2 GB RAM, 12 GB de dados | Free Installation Guide 26ai — Licensing Restrictions |
| 19c | Premier Support até **31/12/2029**; Extended de 01/01/2030 a **31/12/2032** | Mike Dietrich, 20/11/2024 (confirme no MOS 742060.1) |

## Caminho de upgrade

- ✓ **Direto para 26ai:** a partir de **19c e 21c** (todas as releases) — Upgrade Guide 26ai, "Oracle Database Releases That Support Direct Upgrade".
- ✗ Anterior a 19c: passa por 19c/21c primeiro (ex.: `11.2.0.4 → 19c → 26ai`; `10.2 → 12.2 → 19c → 26ai`).
- **23ai → 26ai:** aplicação de RU (patch), não upgrade completo (oracle-base, "Upgrade Overview").

## Mudanças arquiteturais obrigatórias

### Multitenant compulsório

Non-CDB é desuportado (desde 21c, segundo oracle-base); não existe 26ai non-CDB. Todo 19c non-CDB vira PDB num CDB 26ai.

Implicações:
- AutoUpgrade converte para PDB durante o processo (ou Replay Upgrade ao plugar)
- Connection strings passam a apontar para o serviço da PDB
- `tnsnames.ora` dos clientes e pools de conexão (Java, .NET, ORDS) precisam ser revistos
- Limite de PDBs por CDB depende de edição/licença — **A VERIFICAR** no Licensing Information User Manual 26ai

### Vector Pool

Para índices HNSW, dimensione o Vector Pool:

```sql
-- 26ai — no CDB$ROOT: com pool em 0, o aumento só vale após restart
ALTER SYSTEM SET vector_memory_size = 1G SCOPE = SPFILE;
-- (reiniciar a instância na janela do upgrade)
-- no PDB: cota, dinâmica e limitada ao pool do CDB
ALTER SYSTEM SET vector_memory_size = 512M SCOPE = BOTH;
```

Default 0, range 0–70% da SGA, modificável no PDB. Inclua o tamanho do pool no SPFILE já na janela do upgrade para evitar um restart depois:
- **CDB com pool 0 no startup:** aumentar exige `SCOPE=SPFILE` + restart (sem restart → ORA-51950).
- **CDB com pool alocado no startup:** cresce dinamicamente; não reduz abaixo do valor inicial (ORA-51953).
- **PDB:** cota dinâmica (`SCOPE=BOTH`), limitada ao pool do CDB (ORA-51955).
- Medido no 26ai Free 23.26.3 (nov/2026). A doc lista o parâmetro como modificável por `ALTER SYSTEM`, mas não detalha essas restrições.

 Valor `1` com `sga_target > 0` ativa o auto-sizing (23.8+). Não há parâmetro para "ligar" Vector Search ou Duality Views.

## AutoUpgrade — ferramenta canônica

- Baixe sempre o mais recente (MOS 2485457.1) em vez de usar o do `ORACLE_HOME`. Mais recente em nov/2026: **26.6** (build 26.6.260925).
- Modos: `-mode analyze` → `fixups` → `deploy`.
- Capacidades: análise pré-upgrade, conversão non-CDB → PDB, vários bancos numa execução, retomada após falha, fallback por restore point garantido.
- A Oracle lista também **Replay Upgrade** (upgrade ao plugar) e Enterprise Manager (exige Lifecycle Management Pack).

## Roteiro de migração — fases

| Fase | Duração típica | O que fazer |
|---|---|---|
| 1. Preparação | semanas | Inventário (RAC, ADG, partitioning); 26ai em teste; AutoUpgrade ANALYZE num clone de produção; classificar issues; plano de fallback |
| 2. Certificação | semanas | Testar cada aplicação; APEX: páginas críticas; REST/SOAP; utPLSQL; comparar planos com 19c |
| 3. Treinamento | — | DBA em multitenant e Vector Pool; DEV nas features novas; comunicação da janela |
| 4. Não-prod | 1–2 semanas por ambiente | DEV, depois HOMO; medir tempos reais |
| 5. Produção | janela | Backup com restore validado; standby primeiro se houver ADG; DEPLOY monitorado; smoke tests; monitoração 24–72 h |
| 6. Pós-upgrade | semanas | AWR × baseline 19c; SQL Plan Management para regressões; adotar Vector/Duality aos poucos |

As durações são estimativas de planejamento, não números da Oracle.

## Riscos principais

| Risco | Mitigação |
|---|---|
| AutoUpgrade falha no meio | Fallback testado em homo (restore point garantido ou backup com restore validado) |
| Planos piores no 26ai | SQL Plan Management com baseline capturada no 19c; estatísticas completas pós-upgrade |
| Connection string quebra cliente | Comunicação prévia; alias em `tnsnames` durante a transição |
| PL/SQL com recursos desuportados | ANALYZE detecta; FIXUPS resolve parte; refatorar o resto |
| SGA insuficiente | RU 23.26.3 pode exigir SGA maior que releases anteriores (Mike Dietrich, 14/10/2026) |
| Time sem experiência em multitenant | Treinamento antes do upgrade |

## APEX após upgrade

- O APEX instalado no 19c sobe com o banco; a versão do APEX não muda por causa do upgrade.
- APEX 26.1 (GA mai/2026) e 26.2 (GA 06/10/2026) já existem. O 26.2 exige banco 19c RU 19.18+ ou 26ai (release notes 26.2).
- Se o AutoUpgrade trata o componente APEX automaticamente: **A VERIFICAR**.
- Decisão e detalhes de versão: `oracle-apex-ptbr`.

Validação pós-upgrade:

```sql
SELECT comp_id, version, status
  FROM dba_registry
 WHERE comp_id = 'APEX';
```

## Recomendação para ambientes sem cronograma definido

1. Suba o **26ai Free** em VM ou container (sem custo; ver `oracle-lab-ptbr`).
2. Explore Vector Search e JSON Duality em ambiente isolado (esta skill).
3. Com projeto concreto, comece pela Fase 1.
4. Com 19c em Premier Support até 2029, há margem — use-a para certificar, não para adiar.

## Documentação e fontes

- Upgrade Guide 26ai: https://docs.oracle.com/en/database/oracle/oracle-database/26/upgrd/
- Releases com upgrade direto: https://docs.oracle.com/en/database/oracle/oracle-database/26/upgrd/oracle-database-releases-that-support-direct-upgrade.html
- Conversão non-CDB: https://docs.oracle.com/en/database/oracle/oracle-database/26/upgrd/overview-converting-databases-during-upgrade.html
- oracle-base, Upgrade Overview 26ai: https://oracle-base.com/articles/26/oracle-26-upgrade-overview
- GA on-prem: https://mikedietrichde.com/2026/01/27/its-there-oracle-ai-database-26ai-is-available-for-download/
- Plataformas: https://mikedietrichde.com/2026/10/01/oracle-ai-database-26ai-isnt-planned-for-sparc-solaris-and-linux-arm/
- Suporte 19c: https://mikedietrichde.com/2024/11/20/important-update-to-oracle-database-19c-support-timelines/
- AutoUpgrade 26.6: https://mikedietrichde.com/2026/09/30/new-autoupgrade-version-26-6-is-available/
- SGA no 23.26.3: https://mikedietrichde.com/2026/10/14/oracle-23-26-3-may-require-a-larger-sga-than-previous-releases/
- MOS (login): 2485457.1 (AutoUpgrade), 742060.1 (release schedule)
