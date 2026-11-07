--==============================================================================
-- Template: Migração Oracle 19c → 26ai
--
-- Cobertura mínima conceitual: caminho de upgrade, CDB/PDB obrigatório,
-- ferramenta AutoUpgrade, init params alterados, certificação de aplicação.
--
-- Detalhes operacionais variam por ambiente — este template é referência,
-- não substituto de planejamento DBA dedicado.
--
-- Revisado: nov/2026 contra a documentação Oracle AI Database 26ai (RU 23.26.4)
-- Tipo: Demonstrativo — roteiro de planejamento; comandos em comentários
-- RU mínimo: origem 19c ou 21c; destino 23.26.x (RU mais recente)
-- Edição Free: Parcial — serve como DESTINO de laboratório (26ai Free,
--   2 cores / 2 GB RAM / 12 GB de dados); upgrade de produção é EE.
-- Operação detalhada do upgrade (RMAN, Data Guard, PDB): oracle-dba-ptbr
-- Checklist de código e sintaxe nova: oracle-26ai-ptbr
-- Suíte: https://github.com/Maxwbh/oracle-skills-ptbr
--==============================================================================


--==============================================================================
-- 1. Cenário e premissas
--==============================================================================

/*
ORIGEM TÍPICA:
  - Oracle Database 19c Enterprise Edition
  - Provavelmente Linux x86-64 ou AIX/Windows
  - Pode ser non-CDB (legacy) ou já CDB
  - APEX 24.2, 26.1 ou anterior

DESTINO:
  - Oracle AI Database 26ai (versão técnica 23.26.x; RU atual 23.26.4, out/2026)
  - Enterprise Edition on-prem: Linux x86-64, GA em 27/01/2026 (23.26.1)
  - Outras plataformas: IBM AIX, zLinux e Windows previstos para 2027;
    SPARC Solaris e Linux ARM NÃO planejados (Mike Dietrich, 01/10/2026)
  - Standard Edition 2: A VERIFICAR (fontes de terceiros divergem)
  - APEX: 26.1 (GA mai/2026) e 26.2 (GA 06/10/2026) já existem; a escolha da
    versão do APEX é assunto da oracle-apex-ptbr

MUDANÇAS ARQUITETURAIS OBRIGATÓRIAS:
  ✗ Non-CDB desuportado (desde 21c, segundo oracle-base) — não existe 26ai non-CDB
  ✓ Todo non-CDB 19c vira PDB dentro de um CDB 26ai
*/


--==============================================================================
-- 2. Caminho de upgrade direto
--==============================================================================

/*
DIRETO 19c → 26ai (RECOMENDADO):
  - Suportado: upgrade direto a partir de 19c e 21c (todas as releases)
    (Upgrade Guide 26ai — "Oracle Database Releases That Support Direct Upgrade")
  - 23ai → 26ai é aplicação de RU (patch), não upgrade completo (oracle-base)
  - AutoUpgrade automatiza grande parte
  - Documentação: Upgrade Guide 26ai (link na seção 9)

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
  Use SEMPRE a versão mais recente do MOS 2485457.1 (substitua a do ORACLE_HOME).
  Versão mais recente em nov/2026: 26.6 (build 26.6.260925, 25/09/2026)

CAPACIDADES:
  ✓ Pre-upgrade analysis (encontra problemas antes)
  ✓ Fix de issues comuns automatizado
  ✓ Upgrade do banco (ANALYZE → FIXUPS → UPGRADE → POSTUPGRADE)
  ✓ Conversão non-CDB → CDB durante o processo
  ✓ Multi-target (múltiplos databases em uma execução)
  ✓ Resumível em caso de falha
  ✓ Fallback via restore point garantido (configurável; ver AutoUpgrade Guide)

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
  -- A VERIFICAR: valor aceito por target_version para 26ai (consultar o
  --              AutoUpgrade User's Guide antes de usar)
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
  - Limite de PDBs por CDB depende de edição/licença: A VERIFICAR no Licensing
    Information User Manual 26ai antes de planejar consolidação
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

NOVOS PARAMS RELEVANTES PARA AS FEATURES DESTA SKILL:

  vector_memory_size                                        -- 26ai
    Vector Pool (onde ficam os índices HNSW; acelera criação de IVF)
    Default: 0. Range: 0 a 70% da SGA.
    No CDB = tamanho do pool; no PDB = cota. Medido no 26ai Free 23.26.3:
    CDB com pool 0 no startup só aumenta com SCOPE=SPFILE + restart
    (ORA-51950) → defina já na janela do upgrade; com pool alocado, cresce
    sem restart e não reduz abaixo do inicial (ORA-51953); PDB dinâmico,
    limitado ao CDB (ORA-51955). Valor 1 com sga_target > 0 = auto-sizing (23.8+).
    Fonte: Reference 26ai, VECTOR_MEMORY_SIZE

  Não há parâmetro para "ligar" Vector Search ou Duality Views: as features
  vêm habilitadas no 26ai. (Os parâmetros enable_ai_vector_search e
  json_relational_duality citados na v1 foram removidos — não existem na doc.)
*/


--==============================================================================
-- 6. APEX após upgrade
--==============================================================================

/*
APEX existente no 19c sobe junto com o banco; a versão do APEX não muda só
porque o banco virou 26ai. Atualizar para APEX 26.1/26.2 é decisão separada
(APEX 26.2 exige banco 19c RU 19.18+ ou 26ai — release notes 26.2).
Detalhes de versão/compatibilidade: oracle-apex-ptbr e oracle-26ai-ptbr.

  -- A VERIFICAR: se o AutoUpgrade trata o componente APEX automaticamente
  --              (não encontrado no Upgrade Guide 26ai lido em nov/2026)

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
  Mitigação: plano de fallback testado em homo (restore point garantido ou
             backup com restore validado) antes do DEPLOY em produção

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

  - Releases com upgrade direto:
    https://docs.oracle.com/en/database/oracle/oracle-database/26/upgrd/oracle-database-releases-that-support-direct-upgrade.html

MOS NOTES (My Oracle Support, login required — títulos A VERIFICAR no MOS):
  - 2485457.1: Latest AutoUpgrade Build (citado por oracle-base)
  - 742060.1 / PNEWS1360: Release Schedule of Current Database Releases
  - 884522.1 e 1645862.1: citados na v1; conferir título/vigência no MOS

LIVELABS (hands-on grátis — títulos A VERIFICAR no catálogo LiveLabs):
  - "Upgrade to Oracle Database 26ai with AutoUpgrade"
  - "Migrate Non-CDB to PDB"

BLOG POSTS RECOMENDADOS:
  - mikedietrichde.com (Mike Dietrich — Upgrade Product Manager Oracle)
  - oracle-base.com (Tim Hall — referência geral)

EM AMBIENTES CORPORATIVOS:
  - Em ambientes sem data fixa para migração:
  - Exploração técnica em ambiente lab é início recomendado
  - 19c Premier Support até 31/12/2029; Extended Support de 01/01/2030 a
    31/12/2032 (Mike Dietrich, 20/11/2024 — confirmar no MOS 742060.1)
  - Há tempo para planejar com cuidado, mas não infinito
*/
