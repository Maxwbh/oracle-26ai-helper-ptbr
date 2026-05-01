# Migração Oracle 19c → 26ai — Reference

Conceitos e considerações para upgrade.

## Status do release (abril 2026)

- **Oracle AI Database 26ai EE Linux x86-64**: GA desde 27/janeiro/2026 (versão técnica 23.26.1)
- **Outras plataformas (Windows, AIX)**: previstas ao longo de 2026
- **Standard Edition 2 (SE2)**: ainda sem data definida
- **Oracle 19c**: Premier Support encerrou 30/04/2024; Extended Support até 30/04/2027; ESS até 30/04/2030

Há tempo para planejar com cuidado, mas não infinito.

## Caminho de upgrade

✓ **Direto 19c → 26ai**: suportado oficialmente, sem etapa intermediária
✗ 11g → 26ai: precisa upgrade para 19c primeiro
✗ 12c → 26ai: idem, via 19c

Para clientes que já estão em 23ai cloud/Engineered: aplicar Release Update 23.26.1 (não é upgrade, é patch).

## Mudanças arquiteturais obrigatórias

### Multitenant compulsório

Non-CDB foi **descontinuado** em 26ai. Toda instalação 26ai é CDB com 1+ PDBs.

Implicações para 19c non-CDB:
- AutoUpgrade converte automaticamente para PDB durante o processo
- Connection strings mudam: agora apontam para PDB, não para SID
- tnsnames.ora dos clientes precisa atualização
- Aplicações com connection pool (Java, .NET, ORDS): reconfigurar

Em 26ai:
- Default `MAX_PDB_PER_CDB`: 252
- Recomendação: 1 PDB por banco existente (preserva isolamento)
- Múltiplos ambientes (dev/homo/prod) num único CDB: opcional, traz consolidação mas exige cuidado com resource management

### Vector Memory Pool

Para usar HNSW vector indexes:
```sql
ALTER SYSTEM SET vector_memory_size = 8G SCOPE = SPFILE;
-- restart obrigatório
```

Sem isso, HNSW disputa shared pool e falha. Não habilita por default.

## AutoUpgrade — ferramenta canônica

Java-based, incluído em `$ORACLE_HOME/rdbms/admin/autoupgrade.jar`. Versão atual recomendada: 25.6+.

Modos:
1. **ANALYZE**: identifica issues sem alterar nada
2. **FIXUPS**: aplica correções pré-upgrade automatizáveis
3. **DEPLOY**: executa upgrade completo

Capacidades:
- Pre-upgrade analysis exaustivo
- Conversão non-CDB → PDB
- Multi-target (vários databases numa execução)
- Resumível e com rollback

## Roteiro de migração — fases

### Fase 1: Preparação (semanas)
- Inventário completo de bancos e suas características (RAC, ADG, partitioning, custom features)
- Provisionar 26ai em ambiente de teste
- AutoUpgrade ANALYZE em clone do prod
- Classificar issues: auto-fixable, manual, bloqueador
- Documentar plano de rollback

### Fase 2: Certificação de aplicações (semanas)
- Identificar todas as aplicações dependentes
- Para cada app: testar funcionamento em 26ai
- APEX apps: testar pages críticas em produção
- Integrações REST/SOAP: testar endpoints
- PL/SQL crítico: rodar test suite (utPLSQL)
- Performance: comparar plans com 19c

### Fase 3: Treinamento e comunicação
- DBA: treinar em multitenant, vector pool, novas features
- DEV: avisar sobre features novas (não obrigatórias inicialmente)
- Stakeholders: janela de manutenção, comunicação de mudança

### Fase 4: Upgrade em ambientes não-prod
- DEV primeiro
- HOMO depois (com data real ou anonimizada)
- 1-2 semanas de validação em cada
- Documentar tempos reais e issues

### Fase 5: Upgrade prod
- Backup completo verificado (restore validado, não apenas RMAN status)
- Janela de manutenção comunicada com antecedência
- Standby (ADG) atualizado primeiro se aplicável
- AutoUpgrade DEPLOY com monitoramento ativo
- Smoke tests imediatamente pós-upgrade
- Monitoring intensivo nas primeiras 24-72h

### Fase 6: Pós-upgrade (semanas)
- Coletar AWR, comparar com baseline 19c
- SQL Plan Management para fixar plans regressivos
- Habilitar features 26ai gradualmente (vector search, duality)
- Documentar lessons learned

## Riscos principais

| Risco | Probabilidade | Mitigação |
|---|---|---|
| AutoUpgrade falha no meio | Baixa | Rollback automático testado em homo |
| Plans piores em 26ai | Média | SQL Plan Management; baseline em 19c |
| Connection string quebra cliente | Alta | Manter alias tnsnames durante transição |
| PL/SQL com features deprecated | Média | ANALYZE detecta; FIXUPS resolve grande parte |
| Performance regression específica | Média | Testes de performance em homo; manter 19c rollback |
| Time DBA inexperiente em multitenant | Alta | Treinamento ANTES do upgrade |

## APEX após upgrade

APEX em 26ai = **APEX 24.2.11** (não há APEX 26 ainda).

- AutoUpgrade do BD para 26ai inclui APEX automaticamente
- Schema APEX_240200 permanece o mesmo
- Apps existentes continuam funcionando sem modificação
- APEX 26.1 será release update separado quando GA (previsto fim 2026/início 2027)

Validação pós-upgrade:
```sql
SELECT comp_id, version, status
  FROM dba_registry
 WHERE comp_id = 'APEX';
```

## Recomendação para ambientes sem cronograma definido

Conforme conversa: sem data definida para migração. Recomendação:

1. Provisionar 26ai Free Developer Release em VM/container (sem custo)
2. Explorar Vector Search e JSON Duality em ambiente isolado (esta skill cobre)
3. Quando houver projeto concreto, planejar Fase 1 acima
4. Considerar contratação Oracle ACS para primeiro upgrade prod (reduz risco)

19c Extended Support até abril/2027 dá margem confortável.

## Documentação

- Upgrade Guide 26ai: https://docs.oracle.com/en/database/oracle/oracle-database/26/upgrd/
- AutoUpgrade User's Guide: dentro do upgrade guide acima
- MOS Notes: 884522.1 (NLS), 1645862.1 (AutoUpgrade Best Practices), 2485457.1 (latest build), 742060.1 (release schedule)
- Blog Mike Dietrich (Upgrade Product Manager): https://mikedietrichde.com
- LiveLabs: "Upgrade to Oracle Database 26ai with AutoUpgrade"
