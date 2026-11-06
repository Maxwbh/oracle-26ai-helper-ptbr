--==============================================================================
-- Template: Raft Replication Units — Detalhes (EXPLORATÓRIO)
--
-- Cobre: anatomia da Replication Unit (RU), comandos GDSCTL reais para RUs,
-- distribuição de chunks, parâmetros por RU e monitoração em SQL.
--
-- Revisado: nov/2026 contra a documentação Oracle AI Database 26ai (RU 23.26.4)
-- Edição Free: Sim — o Licensing Guide 26ai permite Raft Replication no Free
--              com até 3 nós (2 CPUs, 2 GB RAM, 12 GB de dados por nó)
--
-- Referência conceitual. Os comandos exigem um banco distribuído com
-- Raft habilitado (create shardcatalog ... -repl native) e já com DEPLOY.
--
-- Fontes: shard/raft-replication-concepts.html,
--         shard/raft-replication-operations.html,
--         gsctl/{status-ru, switchover-ru, move-ru, copy-ru, relocate-chunk,
--                remove-ru, start-ru, stop-ru, sync-ru}.html,
--         refrn/V-SHARD_REPLICATION_UNIT.html, refrn/SHARD_RAFT_PARAMETERS.html
--==============================================================================


--==============================================================================
-- 1. Replication Unit (RU) — anatomia
--==============================================================================

/*
RU = conjunto de chunks com a mesma topologia de replicação (um chunk set).
Cada RU forma um Raft group:

  - 1 LEADER: recebe a DML desse subconjunto de dados
  - FOLLOWERS: recebem o Raft log do leader
  - RF (replication factor) = 3 no Oracle Globally Distributed AI Database
    (limite atual, igual para todas as RUs) → precisa de maioria (2 de 3)
    para escrever; tolera 1 réplica indisponível.

Exemplo com RF = 3:
  +----------+   +----------+   +----------+
  | LEADER   |-->| FOLLOWER |   | FOLLOWER |
  | (shard1) |-->| (shard2) |   | (shard3) |
  +----------+   +----------+   +----------+
  O commit é confirmado no leader quando metade dos followers grava o
  registro de commit no Raft log (consenso → zero data loss). A aplicação
  das mudanças nos followers é assíncrona.

Cada shard é leader de algumas RUs e follower de outras (padrão: leader de
2 e follower de 4), mantendo todos os shards ativos.

Failover: sem heartbeat do leader (padrão 150 ms + timeout aleatório de até
150 ms), os followers elegem novo leader. Tempo documentado: < 3 s com
latência < 10 ms entre zonas, incluindo reconexão da aplicação (clientes
notificados via ONS/FAN).
*/


--==============================================================================
-- 2. Comandos GDSCTL para RUs (somente os documentados)
--==============================================================================

/*
NÃO EXISTEM: add ru, config ru, failover ru, add replica, remove replica,
set ru priority, opções -replicas / -newleader / -priority / -max_lag /
-read_local. As RUs são criadas no DEPLOY (quantidade padrão decidida no
primeiro DEPLOY, ou definida antes dele com -repunits — ver
raft_setup_overview.sql).

$ gdsctl
GDSCTL> connect <admin>@<catalogo>        -- ou rodar no home do shard director

# Situação das RUs (também: "status replication" ou só "ru")
GDSCTL> status ru
GDSCTL> status ru -ru 1
GDSCTL> status ru -leaders
GDSCTL> status ru -sort -show_chunks
GDSCTL> status ru -database <shard> -show_errors
  -- Saída: Database, RU#, Role (Leader/Follower), Term, Log Index, Status
  --        e, conforme a versão/opções, Apply/LWM/On-disk index.

# Trocar o leader de uma RU (manutenção planejada)
GDSCTL> switchover ru -ru 1 -database <shard_destino>
  -- A VERIFICAR: o guia shard mostra "-shard"; a referência gsctl, "-database".

# Redistribuir leaders igualmente entre shards
GDSCTL> switchover ru -rebalance

# Mover uma réplica FOLLOWER para outro shard
#   (origem não pode ser o leader; destino não pode já ter réplica da RU)
GDSCTL> move ru -ru 1 -source <shard_a> -target <shard_b>

# Instanciar/reparar um follower copiando de outro follower
#   (nem origem nem destino podem ser o leader; exige ao menos 1 tablespace set)
GDSCTL> copy ru -ru 1 -source <shard_a> -target <shard_b>
GDSCTL> copy ru -ru 1 -source <shard_a> -target <shard_c> -replace <shard_b>

# Mover chunks entre RUs (leaders e followers das duas RUs colocalizados)
#   MOVE CHUNK não é suportado com Raft — use RELOCATE CHUNK
GDSCTL> relocate chunk -chunk 3,4 -sourceru 1 -targetru 2
#   sem -targetru: cria uma RU nova e vazia como destino

# Dividir um chunk dentro da RU
GDSCTL> split chunk -chunk 3

# Remover RU (precisa estar vazia)
GDSCTL> remove ru -ru 4

# Parar/retomar uma RU (todas as réplicas ou só a de um shard)
GDSCTL> stop ru  -ru 1 -database <shard>
GDSCTL> start ru -ru 1 -database <shard>

# Ressincronizar os membros da RU (apaga Raft logs, zera log index/term;
#   acompanhar com "config task")
GDSCTL> sync ru -ru 1 -database <shard>
*/


--==============================================================================
-- 3. Distribuição de tabelas por RU
--==============================================================================

-- Sharded table: partições (chunks) distribuídas entre as RUs pela chave
ALTER SESSION ENABLE SHARD DDL;

CREATE TABLESPACE SET tbs_laudos;

CREATE SHARDED TABLE laudos (
  id_laudo      NUMBER NOT NULL,
  numero_laudo  VARCHAR2(20),
  data_emissao  DATE,
  conteudo      CLOB,
  id_perito     NUMBER,
  CONSTRAINT pk_laudos PRIMARY KEY (id_laudo)
)
TABLESPACE SET tbs_laudos
PARTITION BY CONSISTENT HASH (id_laudo) PARTITIONS AUTO;

-- O número de chunks depende da configuração (create shardcatalog -chunks;
-- sem isso, definido no primeiro DEPLOY). Cada chunk pertence a uma RU.
-- Ver a distribuição: GDSCTL> status ru -show_chunks


-- Tabela duplicada: dados de referência pequenos, copiados em todos os shards
CREATE DUPLICATED TABLE tipos_laudo (
  codigo  VARCHAR2(10) PRIMARY KEY,
  nome    VARCHAR2(100),
  ativo   CHAR(1) DEFAULT 'S'
);

INSERT INTO tipos_laudo VALUES ('NECRO', 'Necropsia', 'S');
INSERT INTO tipos_laudo VALUES ('TOXIC', 'Toxicológico', 'S');
INSERT INTO tipos_laudo VALUES ('GENET', 'Genético', 'S');
COMMIT;
-- A VERIFICAR: mecanismo de propagação de tabelas duplicadas quando a
-- replicação é Raft (não detalhado nas páginas de Raft lidas).


--==============================================================================
-- 4. Parâmetros por RU (set ru parameter)
--==============================================================================

/*
Sintaxe:
  GDSCTL> set ru parameter <PARAMETRO>=<valor> [-shard <shard>] [-ru <id>]
  (sem -ru: todas as RUs; sem -shard: todos os shards)

Parâmetros documentados:
  SHARD_TXN_ACK_TIMEOUT_SEC
    Tempo máximo que uma transação espera o consenso do commit antes de
    ORA-05086. Padrão 90 s; mínimo 1 s.
      GDSCTL> set ru parameter SHARD_TXN_ACK_TIMEOUT_SEC=10

  SHARD_FLOW_CONTROL = TILL_TIMEOUT (padrão) | AT_DISTANCE | AT_LOGLIMIT
    Controle de fluxo para follower atrasado.
  SHARD_FLOW_CONTROL_NS_DISTANCE_PCT     (padrão 10; usado por AT_DISTANCE)
  SHARD_FLOW_CONTROL_TIMEOUT_MULTIPLIER  (padrão 10 x heartbeat; TILL_TIMEOUT)

Parâmetro de inicialização (não é "set ru parameter"):
  SHARD_ENABLE_RAFT_FOLLOWER_READ = TRUE | FALSE (padrão FALSE)
    Habilita leitura nas réplicas follower do shard; modificável por
    ALTER SYSTEM / ALTER SESSION, também no PDB.
*/

-- 26ai
ALTER SESSION SET shard_enable_raft_follower_read = TRUE;


--==============================================================================
-- 5. Monitoração em SQL (no shard)
--==============================================================================

-- 26ai: papel deste shard em cada RU
--   ROLE: 1 = leader, 2 = follower, 3 = candidato
--   COMMITIDX: LCRs com índice <= COMMITIDX têm consenso
--   APPLYLWMIDX: low watermark de apply no follower
SELECT ru_id,
       DECODE(role, 1, 'LEADER', 2, 'FOLLOWER', 3, 'CANDIDATO') AS papel,
       leader_id, term, commitidx, applylwmidx, ondiskidx,
       role_changed_time
  FROM v$shard_replication_unit
 ORDER BY ru_id;

-- 26ai: distância entre consenso e apply (indício de follower atrasado)
SELECT ru_id, commitidx - applylwmidx AS indices_pendentes_apply
  FROM v$shard_replication_unit
 WHERE role = 2
 ORDER BY indices_pendentes_apply DESC;

-- 26ai 23.26.1+: tipo de réplica (0 = completa, 1 = witness)
SELECT ru_id, replica_type
  FROM v$shard_replication_unit;

-- 26ai: parâmetros definidos por RU
SELECT ora_shard_id, ru_id, name, value
  FROM shard_raft_parameters;

-- Demais V$ de Raft: V$SHARD_ACK_SENDER, V$SHARD_ACK_RECEIVER,
-- V$SHARD_APPLY_*, V$SHARD_LCR_*, V$SHARD_NETWORK_SENDER,
-- V$SHARD_MESSAGE_TRACKING, V$SHARD_TRANSACTION (colunas no Reference).
-- A VERIFICAR: não há view documentada de histórico de eleições/switchovers;
-- use ROLE_CHANGED_TIME e TERM (TERM incrementa a cada novo leader).


--==============================================================================
-- 6. Cenários de operação
--==============================================================================

/*
CENÁRIO 1: Manutenção planejada de um shard
  1. status ru -database <shard>       → RUs em que ele é leader
  2. switchover ru -ru <id> -database <outro_shard>  (para cada RU leader)
  3. stop ru -ru <id> -database <shard> se precisar suspender a replicação
  4. manutenção
  5. start ru ...; depois switchover ru -rebalance

CENÁRIO 2: Adicionar shards
  1. add shard -connect ... ; deploy
  2. Rebalanceamento automático: para cada shard novo, 2 RUs novas com
     leader nele; chunks movidos de outras RUs. Acompanhar com config task.
  3. deploy -no_rebalance para mover RUs/chunks manualmente.

CENÁRIO 3: Remover shard
  1. switchover ru (leaders para outros shards)
  2. move ru (followers para shards sem réplica daquela RU)
  3. status ru -database <shard> deve vir vazio
  4. remove shard / remove cdb / remove invitednode
  5. opcional: relocate chunk + remove ru das RUs excedentes

CENÁRIO 4: Falha de leader → ver raft_failover_recovery.sql
  Eleição automática; não existe comando de failover manual de RU.

CENÁRIO 5: Partição de rede
  Só o lado com maioria do Raft group elege leader e confirma commits;
  no lado minoritário commits não obtêm consenso (ORA-05086 após
  SHARD_TXN_ACK_TIMEOUT_SEC).
*/


--==============================================================================
-- 7. Limitações e considerações
--==============================================================================

/*
- Raft só com distribuição system-managed.
- RF fixo em 3.
- Número de RUs não muda após o DEPLOY (só por relocate chunk/remove ru,
  e por rebalanceamento ao adicionar shards).
- MOVE CHUNK não é suportado: use RELOCATE CHUNK.
- copy ru / relocate chunk / split chunk exigem ao menos 1 tablespace set.
- Raft não protege o shard catalog (use Data Guard nele).
- Réplicas da mesma RU não devem ficar no mesmo rack: add shard ... -rack.
- Backup é por banco (RMAN em cada shard e no catálogo) — skill
  oracle-dba-ptbr da suíte https://github.com/Maxwbh/oracle-skills-ptbr

PARA EXPLORAÇÃO:
  - 3 instâncias 26ai Free bastam (limite do Free para Raft: 3 nós).
  - Ambiente local: skill oracle-lab-ptbr da mesma suíte.
*/
