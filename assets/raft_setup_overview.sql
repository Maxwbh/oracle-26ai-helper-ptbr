--==============================================================================
-- Template: RAFT Replication — Visão Geral (EXPLORATÓRIO)
--
-- IMPORTANTE: este template cobre conceitos e comandos. RAFT em produção
-- requer infraestrutura específica (múltiplos shards, múltiplos sites)
-- e é tipicamente implementado com consultoria Oracle.
--
-- Este conteúdo é para EXPLORAÇÃO TÉCNICA — entender o modelo,
-- testar em ambiente lab, planejar arquitetura.
--
-- Pré-requisitos:
--   - Oracle AI Database 26ai Enterprise Edition
--   - Opção Globally Distributed Database (licenciada separadamente)
--   - Mínimo 3 shards (database instances) para majority quorum
--==============================================================================


--==============================================================================
-- 1. Conceitos fundamentais
--==============================================================================

/*
RAFT é algoritmo de consenso distribuído. Em Oracle 23ai/26ai, RAFT é usado
para replicação multi-master entre shards de uma Globally Distributed Database.

Componentes-chave:
  
  REPLICATION UNIT (RU)
    Unidade lógica de replicação. Cada RU contém:
    - 1 leader (aceita writes)
    - N followers (replicam writes)
    - Quorum = majority (ex: 3 replicas → quorum = 2)
  
  SHARD
    Database instance que hospeda 1+ RUs.
    Distribuição: hash, range, ou list.
  
  SHARD CATALOG
    Database especial que armazena metadata da topologia.
    Não armazena dados de aplicação — só catálogo.
  
  GSM (Global Service Manager)
    Software intermediário que roteia conexões para o shard correto.
    Cliente conecta no GSM, GSM redireciona para shard apropriado.

Vantagens RAFT vs Active Data Guard tradicional:
  ✓ Multi-master ativo-ativo (todos shards aceitam writes)
  ✓ Failover automático em <3 segundos
  ✓ Zero data loss garantido pelo quorum
  ✓ Suporta partições de rede sem split-brain

Desvantagens / complexidades:
  ✗ Latência de write maior (espera quorum)
  ✗ Configuração complexa (GSM, shards, RUs)
  ✗ Requer planejamento de sharding key (afeta performance)
  ✗ Custo de licenciamento elevado
*/


--==============================================================================
-- 2. Setup inicial — visão de alto nível (executado em múltiplos lugares)
--==============================================================================

/*
PASSO 1: Provisionar 3+ databases (shards) e 1 catalog
  - Pode ser em VMs separadas, OCI instances, ou containers
  - Cada um precisa de tnsnames consistente

PASSO 2: Instalar GSM (Global Service Manager) em cada site
  - Software adicional, vem com Oracle DB
  - Configura como serviço: gdsctl

PASSO 3: Conectar shards ao catalog
  - GDSCTL: ferramenta CLI para administrar topologia
  - Comandos: ADD SHARDGROUP, ADD SHARD, ADD REGION

PASSO 4: Definir sharding key e distribution
  - HASH (consistent hashing) ou RANGE ou LIST
  - Tabelas marcadas com SHARDED criam estrutura distribuída

PASSO 5: Habilitar RAFT
  - ALTER SYSTEM SET DG_BROKER_START=TRUE;
  - Configurar Replication Units com PROPERTY raft_enabled=true
*/


--==============================================================================
-- 3. GDSCTL — comandos básicos de administração
--==============================================================================

/*
Conectar ao GSM:
  $ gdsctl connect gsmadmin/<senha>@gsm1

Status da topologia:
  GDSCTL> status gsm
  GDSCTL> config shard
  GDSCTL> config region

Criar shard catalog:
  $ gdsctl create shardcatalog \
      -database catalogdb \
      -region us-east \
      -agent_password <pwd> \
      -sharding system

Adicionar shard group:
  GDSCTL> add shardgroup -shardgroup sg_brasil -region brasil

Adicionar shard ao group:
  GDSCTL> add shard -connect db1.example.local:1521/shard1 \
                    -shardgroup sg_brasil \
                    -pwd <pwd>

Validar topologia:
  GDSCTL> validate
*/


--==============================================================================
-- 4. Sharded tables — sintaxe SQL
--==============================================================================

-- Conectar ao shard catalog (não ao shard direto)
-- Tabelas DUPLICATED replicam para todos shards (small reference data)
CREATE SHARDED TABLE clientes (
  id_cliente   NUMBER PRIMARY KEY,
  cpf          VARCHAR2(11) NOT NULL,
  nome         VARCHAR2(100),
  estado       VARCHAR2(2),
  CONSTRAINT pk_clientes PRIMARY KEY (id_cliente)
)
PARTITION BY CONSISTENT HASH (id_cliente)
PARTITIONS AUTO
TABLESPACE SET tbs_clientes;

-- Tabela duplicated (replica para todos shards)
CREATE DUPLICATED TABLE estados (
  uf      VARCHAR2(2) PRIMARY KEY,
  nome    VARCHAR2(100)
);


--==============================================================================
-- 5. RAFT Replication Units (RU) — habilitação
--==============================================================================

/*
Em 26ai, RAFT é a opção default para replication units.

Configurações típicas:
  - replication_factor: 3 (1 leader + 2 followers; quorum = 2)
  - max_lag: tempo máximo de defasagem permitido
  - priority: ordem de candidatura para leadership

Comandos GDSCTL:
  GDSCTL> add ru -name ru_brasil_central \
                 -replicas 3 \
                 -shardgroup sg_brasil

  GDSCTL> config ru ru_brasil_central
  -- mostra leader atual, followers, lag
  
  GDSCTL> switchover ru ru_brasil_central -newleader shard2
  -- move leadership manualmente
*/


--==============================================================================
-- 6. Verificar status do RAFT em PL/SQL
--==============================================================================

-- Identificar shard atual
SELECT SYS_CONTEXT('USERENV', 'CON_NAME') AS pdb,
       SYS_CONTEXT('USERENV', 'INSTANCE_NAME') AS instance,
       SYS_CONTEXT('USERENV', 'DB_UNIQUE_NAME') AS db_unique;

-- Replication units visíveis (em catalog)
SELECT * FROM gv$sharding_units;

-- Status replicação (lag, leader, followers)
SELECT * FROM gv$raft_status;

-- Métricas em tempo real
SELECT * FROM gv$raft_metrics;


--==============================================================================
-- 7. Decisão de arquitetura — quando usar RAFT
--==============================================================================

/*
USE RAFT QUANDO:
  ✓ Múltiplas regiões geograficamente distribuídas
  ✓ Requer zero data loss em failover
  ✓ Workload write-heavy (ADG read-only não basta)
  ✓ Compliance exige redundância regional ativa

NÃO USE RAFT QUANDO:
  ✗ Single datacenter (RAC + ADG é mais simples)
  ✗ Workload pequeno (overhead de coordenação não compensa)
  ✗ Equipe pequena sem expertise em distributed systems
  ✗ Latência de write é crítica (quorum adiciona ~5-50ms)

ALTERNATIVAS:
  - Active Data Guard (single primary, multiple read replicas)
  - GoldenGate (heterogeneous replication, eventual consistency)
  - RAC (single site, shared storage, instant failover)
  - Sharding sem RAFT (manual replication ou ADG por shard)

Em ambientes single-DC ou com 1-2 sites, RAC + ADG entre datacenters geralmente atende;
RAFT é overkill se não há requisito de write multi-master.
*/


--==============================================================================
-- 8. Recursos para aprofundamento (exploração técnica)
--==============================================================================

/*
Documentação oficial:
  - Oracle Globally Distributed Database Guide:
    https://docs.oracle.com/en/database/oracle/oracle-database/26/shard/

  - RAFT Replication chapter:
    https://docs.oracle.com/en/database/oracle/oracle-database/26/shard/raft-replication.html

LiveLabs (hands-on):
  - "Setting up Oracle Globally Distributed Database"
  - "RAFT Replication Quickstart"

Ambiente de exploração:
  - Oracle AI Database Free Developer Release (single instance, mas suporta
    sintaxe sharded para testes)
  - VirtualBox appliances Oracle Sharding (multi-instance lab)
  - OCI Free Tier não suporta GDD (sharding) gratuitamente
*/
