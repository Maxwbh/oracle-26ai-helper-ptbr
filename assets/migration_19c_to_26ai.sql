--==============================================================================
-- Template: Migração Oracle 19c → 26ai
--
-- Cobertura mínima conceitual: caminho de upgrade, CDB/PDB obrigatório,
-- ferramenta AutoUpgrade, init params alterados, certificação de aplicação.
--
-- Detalhes operacionais variam por ambiente — este template é referência,
-- não substituto de planejamento DBA dedicado.
--==============================================================================


--==============================================================================
-- 1. Cenário e premissas
--==============================================================================

/*
ORIGEM TÍPICA:
  - Oracle Database 19c Enterprise Edition
  - Provavelmente Linux x86-64 ou AIX/Windows
  - Pode ser non-CDB (legacy) ou já CDB
  - APEX 24.2 (atual) ou anterior

DESTINO:
  - Oracle AI Database 26ai (versão técnica 23.26.x)
  - Enterprise Edition (SE2 ainda sem data em abril/2026)
  - Linux x86-64 GA desde janeiro/2026; outras platafs em 2026
  - APEX 24.2 (continua mesmo em 26ai; APEX 26.1 ainda não saiu)

MUDANÇAS ARQUITETURAIS OBRIGATÓRIAS:
  ✗ Non-CDB DESCONTINUADO em 26ai
  ✓ Consolidação em CDB/PDB obrigatória durante migração
  ✓ MAX_PDB_PER_CDB padrão = 252 (era diferente em 19c)
*/


--==============================================================================
-- 2. Caminho de upgrade direto
--==============================================================================

/*
DIRETO 19c → 26ai (RECOMENDADO):
  - Suportado oficialmente
  - Sem passar por 21c ou 23ai
  - AutoUpgrade automatiza grande parte
  - Documentação: MOS Note 884522.1

NÃO SUPORTADO:
  - 11g → 26ai (precisa pular para 19c primeiro)
  - 12c → 26ai (idem, via 19c)
*/


--==============================================================================
-- 3. AutoUpgrade — ferramenta canônica
--==============================================================================

/*
AutoUpgrade é Java-based, vem incluso na instalação 26ai.

LOCALIZAÇÃO:
  $ORACLE_HOME/rdbms/admin/autoupgrade.jar
  Versão atual (abril/2026): 25.6+

CAPACIDADES:
  ✓ Pre-upgrade analysis (encontra problemas antes)
  ✓ Fix de issues comuns automatizado
  ✓ Upgrade do banco (ANALYZE → FIXUPS → UPGRADE → POSTUPGRADE)
  ✓ Conversão non-CDB → CDB durante o processo
  ✓ Multi-target (múltiplos databases em uma execução)
  ✓ Resumível em caso de falha
  ✓ Rollback (restore do backup pré-upgrade)

EXEMPLO DE CONFIGURAÇÃO (config file YAML/JSON):

  upg1.source_home=/u01/app/oracle/product/19/dbhome_1
  upg1.target_home=/u01/app/oracle/product/26/dbhome_1
  upg1.sid=appdb
  upg1.target_cdb=appcdb
  upg1.target_pdb_name=apppdb
  upg1.start_time=NOW
  upg1.upgrade_node=hostname.example.local
  upg1.run_utlrp=yes
  upg1.timezone_upg=yes
  upg1.target_version=26


COMANDOS:

  # 1. ANALYZE — identifica issues sem alterar nada
  $ java -jar autoupgrade.jar -config config.cfg -mode analyze

  # 2. FIXUPS — aplica correções pré-upgrade automatizáveis
  $ java -jar autoupgrade.jar -config config.cfg -mode fixups

  # 3. DEPLOY — executa upgrade completo
  $ java -jar autoupgrade.jar -config config.cfg -mode deploy

  # Status / monitoramento
  $ java -jar autoupgrade.jar -config config.cfg -lsj
  $ java -jar autoupgrade.jar -config config.cfg -status
*/


--==============================================================================
-- 4. Conversão non-CDB → CDB
--==============================================================================

/*
SE BANCO 19c É NON-CDB:

A conversão para CDB acontece automaticamente via AutoUpgrade. Por trás:

1. Não-CDB 19c torna-se PDB plugado em CDB 26ai
2. Dados, schemas, usuários, grants são preservados
3. Tablespaces e datafiles ficam associados ao novo PDB

IMPLICAÇÕES:
  - Connection strings podem mudar:
    19c: usuario@//host:1521/appdb
    26ai: usuario@//host:1521/apppdb (PDB name, não CDB)
  
  - tnsnames.ora dos clientes precisa atualizar
  - Aplicações com connection pool (Java, .NET): reconfigurar

CDB MULTITENANT:
  - 26ai permite até 252 PDBs por CDB (default)
  - Em ambientes corporativos: provavelmente 1 PDB por banco existente é suficiente
  - Para ambientes dev/homo/prod separados: múltiplos PDBs no mesmo CDB
*/


--==============================================================================
-- 5. Init params alterados / novos / desupportados
--==============================================================================

/*
DESUPPORTED EM 26ai (precisam ser removidos antes de upgrade):
  - Vários parâmetros legacy
  - AutoUpgrade detecta e sinaliza
  - Lista completa: docs.oracle.com → "Behavior Changes 26ai"

NOVOS PARAMS RELEVANTES:

  vector_memory_size
    Aloca Vector Memory Pool (essencial para HNSW indexes)
    Default: 0 (sem alocação — HNSW falha)
    Recomendação: 256M para exploração; produção depende de workload

  enable_ai_vector_search
    Habilita features Vector Search
    Default: TRUE em 26ai

  json_relational_duality
    Habilita JSON Duality Views
    Default: TRUE em 26ai

  result_cache_remote_expiration
    Comportamento alterado em RAC + RAFT
*/


--==============================================================================
-- 6. APEX após upgrade
--==============================================================================

/*
APEX em 26ai = continua sendo APEX 24.2 (não há APEX 26 ainda).

UPGRADE PATH:
  1. AutoUpgrade do BD para 26ai inclui APEX automaticamente
  2. Schema APEX_240200 (24.2) permanece o mesmo
  3. Apps existentes continuam funcionando sem modificação
  4. APEX 26.1 será release update separado quando GA (2026 fim/2027 início)

VALIDAÇÃO PÓS-UPGRADE:
  -- Schema APEX deve estar VALID
  SELECT comp_id, version, status
    FROM dba_registry
   WHERE comp_id = 'APEX';
   
  -- Aplicações ativas
  SELECT application_id, application_name, owner
    FROM apex_applications
   ORDER BY application_id;

CUIDADOS:
  - JOB SCHEDULER de APEX (apex_xxx_xxx) pode precisar reiniciar
  - Static files precisam re-deploy se URL pattern mudou
  - REST endpoints (ORDS) testar manualmente
*/


--==============================================================================
-- 7. Roteiro recomendado (de alto nível)
--==============================================================================

/*
FASE 1: PREPARAÇÃO (semanas)
  ✓ Inventário: bancos, versões, características (RAC, ADG, partitioning)
  ✓ Provisionar 26ai em ambiente de teste
  ✓ Rodar AutoUpgrade ANALYZE no clone do prod
  ✓ Listar issues, classificar (auto-fixable, manual, bloqueador)
  ✓ Plano de rollback documentado

FASE 2: CERTIFICAÇÃO DE APLICAÇÕES (semanas)
  ✓ Identificar todas as aplicações dependentes
  ✓ Para cada app: testar funcionamento em 26ai
  ✓ APEX apps: testar pages críticas
  ✓ Integrações REST/SOAP: testar endpoints
  ✓ PL/SQL crítico: rodar test suite (utPLSQL?)
  ✓ Performance: comparar plans com 19c

FASE 3: TREINAMENTO E COMUNICAÇÃO
  ✓ Equipe DBA: treinar em multitenant, vector pool, novas features
  ✓ Equipe DEV: avisar sobre features novas disponíveis (mas não obrigatórias)
  ✓ Stakeholders: janela de manutenção, comunicação de mudança

FASE 4: UPGRADE EM AMBIENTES NÃO-PROD
  ✓ DEV primeiro
  ✓ Depois HOMO (com data real ou anonimizada)
  ✓ Validar 1-2 semanas em cada
  ✓ Documentar tempos reais e issues encontrados

FASE 5: UPGRADE PROD
  ✓ Backup completo verificado (não apenas RMAN — restore validado)
  ✓ Janela de manutenção comunicada
  ✓ Standby (ADG) atualizado primeiro se aplicável
  ✓ AutoUpgrade DEPLOY com monitoramento ativo
  ✓ Smoke tests imediatamente pós-upgrade
  ✓ Monitoring intensivo primeiras 24-72h

FASE 6: PÓS-UPGRADE (semanas)
  ✓ Coletar AWR, comparar com baseline 19c
  ✓ Identificar plans alterados, aplicar SQL plan management se necessário
  ✓ Habilitar features 26ai gradualmente (vector search, duality)
  ✓ Documentar lessons learned
*/


--==============================================================================
-- 8. Riscos e mitigações
--==============================================================================

/*
RISCO: AutoUpgrade falha no meio
  Mitigação: AutoUpgrade tem rollback automático, mas TESTAR antes em homo

RISCO: Plans de execução piores em 26ai
  Mitigação: SQL Plan Management — capturar baseline em 19c, aplicar em 26ai
             Statistics gathering completo pós-upgrade

RISCO: Aplicação cliente quebra (connection string)
  Mitigação: Comunicação prévia, manter alias via tnsnames durante transição

RISCO: Custom PL/SQL com features deprecated
  Mitigação: ANALYZE detecta, FIXUPS resolve grande parte automaticamente
             Refactor manual do que sobrar

RISCO: Performance regression em workload específico
  Mitigação: Testes de performance em homo com workload realista
             Manter 19c como rollback até validação completa

RISCO: Time de DBA inexperiente em multitenant
  Mitigação: Treinamento ANTES do upgrade, não durante
             Considerar consultoria Oracle para primeiro upgrade
*/


--==============================================================================
-- 9. Recursos
--==============================================================================

/*
DOCUMENTAÇÃO OFICIAL:
  - Upgrade Guide 26ai:
    https://docs.oracle.com/en/database/oracle/oracle-database/26/upgrd/
  
  - AutoUpgrade User's Guide:
    https://docs.oracle.com/en/database/oracle/oracle-database/26/upgrd/using-autoupgrade-oracle-database-upgrades.html

MOS NOTES (My Oracle Support, login required):
  - 884522.1: NLS Considerations During Upgrade
  - 1645862.1: AutoUpgrade Tool — Best Practices
  - 2485457.1: Latest AutoUpgrade Build
  - 742060.1: Release Schedule of Current Database Releases

LIVELABS (hands-on grátis):
  - "Upgrade to Oracle Database 26ai with AutoUpgrade"
  - "Migrate Non-CDB to PDB"

BLOG POSTS RECOMENDADOS:
  - mikedietrichde.com (Mike Dietrich — Upgrade Product Manager Oracle)
  - oracle-base.com (Tim Hall — referência geral)

EM AMBIENTES CORPORATIVOS:
  - Em ambientes sem data fixa para migração:
  - Exploração técnica em ambiente lab é início recomendado
  - 19c suporte premier até 30/04/2024 (já encerrado)
  - 19c Extended Support até 30/04/2027
  - Há tempo para planejar com cuidado, mas não infinito
*/
