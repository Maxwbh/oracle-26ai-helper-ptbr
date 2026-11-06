--==============================================================================
-- Template: Raft Replication — Visão Geral (EXPLORATÓRIO)
--
-- Revisado: nov/2026 contra a documentação Oracle AI Database 26ai (RU 23.26.4)
-- Tipo: Demonstrativo — comandos GDSCTL em comentários; exige catálogo, GSM e 3+ shards
-- RU mínimo: 23.26.0; replicação assíncrona entre regiões 23.26.4+
-- Edição Free: Sim — o Licensing Guide 26ai permite Raft Replication no Free
--              com até 3 nós, cada um dentro dos limites do Free
--              (2 CPUs, 2 GB RAM, 12 GB de dados de usuário)
--
-- IMPORTANTE: este template cobre conceitos e comandos. Raft em produção
-- requer infraestrutura distribuída (vários shards/sites) e planejamento.
-- Conteúdo para EXPLORAÇÃO TÉCNICA — entender o modelo, testar em lab,
-- planejar arquitetura.
--
-- Pré-requisitos:
--   - Oracle Globally Distributed AI Database (antes "Oracle Sharding")
--   - Distribuição system-managed (Raft só é suportado nesse método)
--   - No mínimo 3 shards
--   - Licença (Licensing Guide 26ai):
--       Free : Sim, até 3 nós (limites do Free em cada nó)
--       SE2  : Não
--       EE   : Sim, sem limite de shards, mas CADA shard precisa de licença
--              Oracle RAC
--
-- Fontes (docs.oracle.com/en/database/oracle/oracle-database/26/):
--   shard/raft-replication.html, shard/raft-replication-concepts.html,
--   shard/enabling-raft-replication.html, shard/raft-replication-operations.html,
--   gsctl/create-shardcatalog.html, dblic (Licensing Guide), nfcoa/ru23_26_4.html
--==============================================================================


--==============================================================================
-- 1. Conceitos fundamentais
--==============================================================================

/*
Raft é um protocolo de consenso. No Oracle Globally Distributed AI Database,
a Raft replication é replicação LÓGICA com commit por consenso, integrada ao
banco (sem Data Guard nem GoldenGate para os shards).

  REPLICATION UNIT (RU)
    Conjunto de chunks com a mesma topologia de replicação. Cada RU tem
    réplicas em shards diferentes: 1 leader + followers = um "Raft group".
    Toda DML de um subconjunto de dados executa no leader e é replicada.

  REPLICATION FACTOR (RF)
    Número de participantes do Raft group. No Oracle Globally Distributed AI
    Database o RF está limitado a 3 (tolera a falha de 1 réplica) e vale para
    o banco inteiro.

  SHARD
    Banco que hospeda réplicas de várias RUs — leader de algumas, follower
    de outras. Por padrão cada shard é leader de 2 RUs e follower de 4.

  SHARD CATALOG
    Banco com os metadados da topologia. Raft NÃO dá alta disponibilidade ao
    catálogo: use Data Guard separado nele.

  SHARD DIRECTOR (GSM)
    Roteia conexões para o shard correto.

Comportamento (raft-replication-concepts):
  - Active/active: cada shard processa leituras e escritas do seu subconjunto.
  - Commit no leader quando metade dos followers confirma o registro de
    commit no Raft log → zero data loss; a aplicação da DML nos followers é
    assíncrona.
  - Heartbeat padrão de 150 ms, com timeout de eleição aleatório (até 150 ms).
  - Failover automático em menos de 3 s com latência < 10 ms entre zonas
    (sub-segundo possível com todos os shards no mesmo data center).
  - Transação que não obtém consenso no prazo: ORA-05086
    (SHARD_TXN_ACK_TIMEOUT_SEC, padrão 90 s, mínimo 1 s).

Custos/complexidade:
  - Latência de commit inclui a ida e volta até o quorum.
  - Topologia distribuída (catálogo, shard directors, shards).
  - Escolha da sharding key afeta desempenho.
  - EE: licença RAC por shard.
*/


--==============================================================================
-- 2. Setup — visão de alto nível (GDSCTL)
--==============================================================================

/*
PASSO 1: Provisionar o catálogo e 3+ bancos para os shards.

PASSO 2: Criar o shard catalog COM Raft. É o -repl native que habilita Raft;
         o padrão é -repl DG (Data Guard) e NÃO pode ser alterado depois.
         -sharding system é o padrão (Raft exige system-managed).

  GDSCTL> create shardcatalog -database <catalogo_connect_string>
            -user <admin>/<senha> -repl native -sharding system
            -region regiao1,regiao2 -agent_password <senha_agente>

  Número de RUs (opcional; por padrão é decidido no primeiro DEPLOY):
  GDSCTL> create shardcatalog ... -repunits <n>
  ou, antes do DEPLOY:
  GDSCTL> modify shardspace -shardspace shardspaceora -repunits <n>
  -- A VERIFICAR: grafia da opção. A referência GDSCTL (gsctl) usa
     -repunits; o guia Globally Distributed (shard) usa -repunit.
  O número de RUs não pode ser alterado depois do DEPLOY.

PASSO 3: Shard director(s)
  GDSCTL> add gsm -gsm <nome_gsm> -catalog <catalogo_connect_string>
            -region regiao1
  GDSCTL> start gsm -gsm <nome_gsm>

PASSO 4: Adicionar os shards (rack distinto evita réplicas no mesmo rack)
  GDSCTL> add shard -connect <shard1_connect_string> -rack rack1
  GDSCTL> add shard -connect <shard2_connect_string> -rack rack2
  GDSCTL> add shard -connect <shard3_connect_string> -rack rack3
  (com -autovncr OFF, registre os hosts com add invitednode)

PASSO 5: Deploy — é aqui que as RUs são criadas e distribuídas
  GDSCTL> deploy
  (deploy -no_rebalance desliga o rebalanceamento automático em deploys
   incrementais)

PASSO 6: Conferir
  GDSCTL> config sdb      -- "Replication Type" deve mostrar Native
  GDSCTL> status ru       -- RUs, leaders e followers
*/


--==============================================================================
-- 3. Tabelas distribuídas — SQL (no shard catalog)
--==============================================================================

-- Conectado ao shard catalog como usuário do schema de aplicação, com
-- ALTER SESSION ENABLE SHARD DDL (conforme shard/schema-creation-examples).
ALTER SESSION ENABLE SHARD DDL;

-- Tablespace set para as sharded tables
CREATE TABLESPACE SET tbs_clientes;

-- Sharded table (PK declarada uma única vez)
CREATE SHARDED TABLE clientes (
  id_cliente   NUMBER        NOT NULL,
  cpf          VARCHAR2(11)  NOT NULL,
  nome         VARCHAR2(100),
  estado       VARCHAR2(2),
  CONSTRAINT pk_clientes PRIMARY KEY (id_cliente)
)
TABLESPACE SET tbs_clientes
PARTITION BY CONSISTENT HASH (id_cliente) PARTITIONS AUTO;

-- Tabela duplicada (dados de referência pequenos, copiados em todos os shards)
CREATE DUPLICATED TABLE estados (
  uf      VARCHAR2(2) PRIMARY KEY,
  nome    VARCHAR2(100)
);


--==============================================================================
-- 4. Replication Units — o que existe e o que NÃO existe
--==============================================================================

/*
NÃO EXISTEM em GDSCTL: add ru, config ru, failover ru, add replica,
remove replica, set ru priority, nem opções -replicas/-newleader.
As RUs nascem no DEPLOY; o RF é fixo em 3; o failover é automático
(eleição Raft).

Comandos reais (gsctl):
  status ru [-ru <id>] [-leaders] [-database <shard>] [-show_chunks]
            [-show_errors] [-show_stats] [-sort]
  switchover ru -ru <id> -database <shard>    -- troca o leader da RU
  switchover ru -rebalance                    -- redistribui leaders
    (a referência gsctl usa -database; o guia shard mostra -shard no exemplo)
  move ru -ru <id> -source <shard> -target <shard>   -- move follower
  copy ru -ru <id> [-source <shard>] -target <shard> [-replace <shard>]
  relocate chunk -chunk <lista|all> -sourceru <id> [-targetru <id>]
  remove ru -ru <id>                          -- só RU vazia
  start ru -ru <id> [-database <shard>]
  stop ru  -ru <id> [-database <shard>]
  sync ru  -ru <id> [-database <shard>]
  set ru parameter <PARAM>=<valor> [-shard <shard>] [-ru <id>]

Detalhes: raft_replication_units.sql e raft_failover_recovery.sql.
*/


--==============================================================================
-- 5. Verificar Raft em SQL (no shard)
--==============================================================================

-- Identificar o shard/PDB da sessão
SELECT SYS_CONTEXT('USERENV', 'CON_NAME')       AS pdb,
       SYS_CONTEXT('USERENV', 'INSTANCE_NAME')  AS instancia,
       SYS_CONTEXT('USERENV', 'DB_UNIQUE_NAME') AS db_unique;

-- 26ai: uma linha por RU presente neste shard
--   ROLE: 1 = leader, 2 = follower, 3 = candidato em eleição
SELECT ru_id, shard_id, leader_id,
       DECODE(role, 1, 'LEADER', 2, 'FOLLOWER', 3, 'CANDIDATO') AS papel,
       term, commitidx, applylwmidx, ondiskidx, role_changed_time
  FROM v$shard_replication_unit
 ORDER BY ru_id;

-- 26ai: parâmetros Raft definidos por RU (set ru parameter)
SELECT ora_shard_id, ru_id, name, value
  FROM shard_raft_parameters
 ORDER BY ru_id, name;

-- Outras V$ de Raft (colunas no Oracle AI Database Reference):
--   V$SHARD_ACK_SENDER, V$SHARD_ACK_RECEIVER, V$SHARD_APPLY_COORDINATOR,
--   V$SHARD_APPLY_LCR_READER, V$SHARD_APPLY_READER, V$SHARD_APPLY_SERVER,
--   V$SHARD_LCR_LOGS, V$SHARD_LCR_PERSISTER, V$SHARD_LCR_PRODUCER,
--   V$SHARD_NETWORK_SENDER, V$SHARD_MESSAGE_TRACKING, V$SHARD_TRANSACTION


--==============================================================================
-- 6. Novidades por RU (somente descrição; sintaxe não incluída)
--==============================================================================

/*
-- 26ai 23.26.4+ : Asynchronous Cross-Region Replication para bancos
--                 distribuídos com Raft — clusters Raft somente leitura,
--                 réplicas do cluster primário, para DR e leitura próxima ao
--                 usuário.
-- 26ai 23.26.4+ : Witness Replica — réplica leve que mantém só os Raft logs
--                 (sem cópia completa dos dados) e participa do quorum;
--                 economia de até 33% de armazenamento.
--                 (V$SHARD_REPLICATION_UNIT.REPLICA_TYPE: 0 = completa,
--                  1 = witness; coluna disponível desde 23.26.1)
-- A VERIFICAR: comandos/opções GDSCTL desses dois recursos (não confirmados).
*/


--==============================================================================
-- 7. Decisão de arquitetura — quando usar Raft
--==============================================================================

/*
USE QUANDO:
  - Dados distribuídos (escala horizontal, várias zonas/regiões)
  - Failover automático rápido com zero perda de dados confirmados
  - Escrita ativa em todos os shards (cada um líder de parte dos dados)

NÃO USE QUANDO:
  - Um único banco atende (RAC + Data Guard é mais simples)
  - Carga pequena (coordenação não compensa)
  - Equipe sem experiência em sistemas distribuídos
  - Latência de commit é crítica e as zonas são distantes

ALTERNATIVAS:
  - Active Data Guard (um primário, standbys de leitura)
  - GoldenGate (replicação heterogênea)
  - RAC (um site, storage compartilhado)
  - Globally Distributed Database com Data Guard (-repl DG)
*/


--==============================================================================
-- 8. Referências
--==============================================================================

/*
Documentação oficial:
  https://docs.oracle.com/en/database/oracle/oracle-database/26/shard/raft-replication.html
  https://docs.oracle.com/en/database/oracle/oracle-database/26/gsctl/

Laboratório: o Free permite Raft com até 3 nós (limites do Free por nó).
  Montar o ambiente local 26ai Free: skill oracle-lab-ptbr da suíte
  https://github.com/Maxwbh/oracle-skills-ptbr
  Operação de banco (Data Guard no catálogo, RMAN): skill oracle-dba-ptbr.
*/
