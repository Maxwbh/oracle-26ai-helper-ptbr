--==============================================================================
-- Template: RAFT Replication Units — Detalhes (EXPLORATÓRIO)
--
-- Cobre: criação, configuração, e operações com Replication Units (RUs)
-- num cluster RAFT.
--
-- Este é template de referência conceitual. Comandos requerem ambiente
-- multi-shard configurado.
--==============================================================================


--==============================================================================
-- 1. Replication Unit (RU) — anatomia
--==============================================================================

/*
Cada RU é composta por:

  - 1 LEADER (replica primária, aceita writes)
  - N FOLLOWERS (replicas secundárias, aceitam reads se configurado)
  - QUORUM = floor(N/2) + 1 (writes só commitam com quorum confirmado)

Exemplo com replication_factor = 3:
  +----------+   +----------+   +----------+
  | LEADER   |--→| FOLLOWER |   | FOLLOWER |
  | (shard1) |   | (shard2) |   | (shard3) |
  +----------+   +----------+   +----------+
       ↓             ↓               ↓
  Write recebido    Replica         Replica
  COMMIT só após    confirma        confirma
  2 confirmações
  (quorum)

Failover:
  Se LEADER falha, FOLLOWERS elegem novo leader (algoritmo RAFT).
  Eleição leva tipicamente 2-5 segundos.
  Cliente reconecta automaticamente via GSM.
*/


--==============================================================================
-- 2. Comandos GDSCTL para RUs
--==============================================================================

/*
$ gdsctl connect gsmadmin/<senha>@gsm1

# Criar RU com 3 replicas
GDSCTL> add ru -name ru_principal \
               -replicas 3 \
               -shardgroup sg_brasil

# Listar todas as RUs
GDSCTL> config ru
   RU Name              Status   Replicas   Shardgroup
   ru_principal   ONLINE   3          sg_brasil

# Detalhes de uma RU específica
GDSCTL> config ru ru_principal
   Leader: shard1.example.local
   Followers:
     - shard2.example.local (lag: 0ms, status: SYNCED)
     - shard3.example.local (lag: 12ms, status: SYNCED)

# Forçar troca de leader (manutenção planejada)
GDSCTL> switchover ru ru_principal -newleader shard2

# Adicionar mais um follower
GDSCTL> add replica ru_principal -shard shard4

# Remover follower (reduzir replicas)
GDSCTL> remove replica ru_principal -shard shard3

# Failover forçado (em emergência, leader inacessível)
GDSCTL> failover ru ru_principal -newleader shard2 -force
*/


--==============================================================================
-- 3. Distribuição de tabelas por RU
--==============================================================================

-- Sharded tables são automaticamente distribuídas entre RUs por hash da chave
-- Tabelas duplicated replicam para TODAS as RUs (overhead de write em todas)

-- Sharded: cada partition fica em uma RU diferente
CREATE SHARDED TABLE laudos (
  id_laudo      NUMBER,
  numero_laudo  VARCHAR2(20),
  data_emissao  DATE,
  conteudo      CLOB,
  id_perito     NUMBER,
  CONSTRAINT pk_laudos PRIMARY KEY (id_laudo)
)
PARTITION BY CONSISTENT HASH (id_laudo)
PARTITIONS AUTO
TABLESPACE SET tbs_laudos;

-- Resultado: 256 partitions distribuídas entre N RUs
-- Cada partition é uma "chunk" replicada via RAFT


-- Duplicated: tabelas pequenas de referência, replicam para todos
CREATE DUPLICATED TABLE tipos_laudo (
  codigo  VARCHAR2(10) PRIMARY KEY,
  nome    VARCHAR2(100),
  ativo   CHAR(1) DEFAULT 'S'
);

INSERT INTO tipos_laudo VALUES ('NECRO', 'Necropsia', 'S');
INSERT INTO tipos_laudo VALUES ('TOXIC', 'Toxicológico', 'S');
INSERT INTO tipos_laudo VALUES ('GENET', 'Genético', 'S');
COMMIT;
-- Estes 3 inserts são propagados para TODOS os shards


--==============================================================================
-- 4. Identificar onde uma row está armazenada
--==============================================================================

-- Em catalog connection, ver qual chunk/RU contém um id específico
SELECT id_laudo, sys_context('USERENV', 'DB_UNIQUE_NAME') AS shard
  FROM laudos
 WHERE id_laudo = 12345;

-- Estatísticas de distribuição
SELECT chunk_number, num_rows, shard
  FROM gv$shard_chunks
 WHERE table_name = 'LAUDOS';


--==============================================================================
-- 5. Configurações importantes da RU
--==============================================================================

/*
Parâmetros configuráveis em add ru / modify ru:

  -replicas N
    Número de replicas (incluindo leader). Mínimo 3 para quorum válido.
    
  -region <region>
    Região associada à RU. Afeta routing por proximidade.
    
  -priority <list>
    Ordem de preferência para leadership.
    Útil quando shards têm capacidades diferentes.
    
  -max_lag <segundos>
    Lag máximo aceitável antes de RU ficar OUT_OF_SYNC.
    
  -read_local <true/false>
    Se TRUE, queries SELECT podem usar followers (read scaling).
    Se FALSE, todas queries vão para leader (consistência forte).
*/


--==============================================================================
-- 6. Monitoring em SQL
--==============================================================================

-- Status agregado de todas RUs
SELECT ru_name, leader_shard, num_followers,
       num_synced, num_out_of_sync,
       max_lag_ms
  FROM gv$ru_status
 ORDER BY max_lag_ms DESC;

-- Histórico de switchovers/failovers
SELECT ru_name, event_type, old_leader, new_leader,
       event_time, duration_ms
  FROM dba_ru_events
 WHERE event_time > SYSDATE - 7
 ORDER BY event_time DESC;

-- Métricas de write throughput por RU
SELECT ru_name, 
       writes_per_sec, reads_per_sec,
       avg_commit_latency_ms,
       p99_commit_latency_ms
  FROM gv$ru_metrics;


--==============================================================================
-- 7. Cenários de operação
--==============================================================================

/*
CENÁRIO 1: Manutenção planejada do leader
  1. Identificar RU afetada: config ru
  2. Switchover para outro shard: switchover ru <name> -newleader <shard>
  3. Verificar nova topologia: config ru
  4. Aplicar manutenção no shard agora-follower
  5. Re-adicionar como follower quando voltar

CENÁRIO 2: Adicionar capacidade (mais shards)
  1. Provisionar novo shard
  2. add shard -connect ... -shardgroup ...
  3. Sharded tables automaticamente rebalanceiam
     (chunks são movidos via RAFT log, sem downtime)

CENÁRIO 3: Falha de leader
  1. Followers detectam ausência (heartbeat timeout)
  2. Eleição automática (algoritmo RAFT)
  3. Quorum dos followers vivos elege novo leader
  4. Cliente recebe ORA-XXXXX, reconecta via GSM
  5. Aplicação deve ter retry logic (típico em REST/ORDS)

CENÁRIO 4: Split-brain (partição de rede)
  - RAFT garante: APENAS o lado com quorum aceita writes
  - Lado minoritário fica read-only
  - Quando partição se resolve, lado minoritário sincroniza com maioria
*/


--==============================================================================
-- 8. Limitações e considerações
--==============================================================================

/*
LIMITAÇÕES:
  - Nem todos os tipos de objeto são "sharded-friendly":
    * Sequences distribuídas: usar GENERATED ALWAYS AS IDENTITY consciente de shard
    * Triggers cross-shard: complicado, geralmente evitar
    * PL/SQL com cross-shard JOIN: fica lento (network)
    
  - Backup é por shard:
    * RMAN backup individual de cada shard
    * Recovery point depends de log shipping/RAFT logs
    
  - Schema changes:
    * DDL é propagado via shard catalog
    * Tempo de propagação aumenta com número de shards

EM PRODUÇÃO:
  - RAFT em 23.26.x ainda tem refinamentos por release update
  - Recomenda-se MOS notes atualizadas: "RAFT Replication Best Practices"
  - Testes de failover devem ser parte do plano de DR

PARA EXPLORAÇÃO TÉCNICA:
  - Comece com 3 instâncias em VirtualBox ou Docker
  - Use "Oracle Sharding Lab" do LiveLabs
  - Não tente em produção sem treinamento dedicado
*/
