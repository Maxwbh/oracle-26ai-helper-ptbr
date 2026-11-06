# RAFT Globally Distributed Database — Reference

Conceitos para Oracle AI Database 26ai. Revisado em nov/2026 contra o Globally Distributed Database Guide e a GDSCTL Reference 26ai. **Material exploratório**: RAFT em produção exige planejamento dedicado.

## Índice

- [Conceito-chave](#conceito-chave)
- [Componentes](#componentes)
- [Replication Unit (RU)](#replication-unit-ru)
- [Habilitar RAFT](#habilitar-raft)
- [Sharded vs Duplicated tables](#sharded-vs-duplicated-tables)
- [GDSCTL — comandos de RU](#gdsctl--comandos-de-ru)
- [Monitoração](#monitoração)
- [Licenciamento e edição Free](#licenciamento-e-edição-free)
- [Quando usar](#quando-usar)
- [Novidades 26ai](#novidades-26ai)
- [Roadmap exploratório](#roadmap-exploratório)
- [Documentação](#documentação)

## Conceito-chave

**Globally Distributed Database (GDD)** é a arquitetura de sharding nativa da Oracle. **Raft replication** é a replicação nativa por consenso entre shards, alternativa ao Data Guard dentro do GDD.

Não confundir com:
- **RAC:** várias instâncias sobre um storage compartilhado; alta disponibilidade local
- **Active Data Guard:** primary + standbys; DR e escala de leitura
- **GoldenGate:** replicação heterogênea com consistência eventual

## Componentes

```
Shard Catalog (banco de metadados)
        │
GSM — Global Service Manager (roteamento)
        │
 ┌──────┼──────┐
Shard1 Shard2 Shard3   ← mínimo de 3 shards para Raft
Cada shard hospeda réplicas de várias RUs; cada RU tem 1 leader + followers.
```

## Replication Unit (RU)

- Conjunto de chunks replicados juntos; cada RU tem um **leader** e **followers**.
- **Replication factor fixo em 3**, definido para o banco distribuído inteiro.
- Heartbeat padrão de **150 ms**, com timeouts de eleição aleatórios; failover em menos de 3 s quando a latência de rede é baixa.
- Commit por consenso: `SHARD_TXN_ACK_TIMEOUT_SEC` padrão de 90 s (estouro gera ORA-05086).
- As RUs **nascem no `DEPLOY`**. Não existe comando `add ru`. A quantidade é definida antes do deploy.
- Failover é **automático** (eleição Raft). Não existe `failover ru`. Depois que o nó volta, rebalanceie com `switchover ru -rebalance`.

## Habilitar RAFT

```bash
# 26ai — -repl NATIVE liga o Raft; o default é DG e não pode ser alterado depois
gdsctl create shardcatalog -database cat_host:1521/catpdb \
       -user mysdbadmin/<senha> -repl native -sharding system \
       -region regiao1,regiao2
```

A quantidade de RUs se define na criação (`-repunits n`) ou, antes do deploy, com `modify shardspace -shardspace <nome> -repunit n`. A grafia `-repunits` × `-repunit` diverge entre os guias; confira na GDSCTL Reference. O valor não muda depois do deploy.

## Sharded vs Duplicated tables

| Tipo | Distribuição | Uso |
|---|---|---|
| `SHARDED TABLE` | Particionada pela sharding key | Tabelas grandes, transacionais |
| `DUPLICATED TABLE` | Cópia em todos os shards | Dados de referência pequenos |

```sql
-- 26ai (23ai+) — rodar no shard catalog
CREATE SHARDED TABLE clientes (
  id_cliente NUMBER        NOT NULL,
  cpf        VARCHAR2(11)  NOT NULL,
  nome       VARCHAR2(100),
  CONSTRAINT pk_clientes PRIMARY KEY (id_cliente)
)
PARTITION BY CONSISTENT HASH (id_cliente)
PARTITIONS AUTO
TABLESPACE SET tbs_clientes;

CREATE DUPLICATED TABLE estados (
  uf   VARCHAR2(2)   NOT NULL,
  nome VARCHAR2(100),
  CONSTRAINT pk_estados PRIMARY KEY (uf)
);
```

Métodos de sharding: system-managed (`CONSISTENT HASH`, padrão), user-defined e composite.

## GDSCTL — comandos de RU

| Comando | Uso |
|---|---|
| `status ru [-ru n] [-leaders] [-show_chunks] [-show_errors]` | Estado das RUs, leaders e lag |
| `switchover ru -ru n -database <shard>` | Troca planejada de leader |
| `switchover ru -rebalance` | Redistribui leaders depois de falha ou manutenção |
| `move ru -ru n -source <shard> -target <shard>` | Move réplica follower |
| `copy ru -ru n -source <a> -target <b> [-replace <c>]` | Recria réplica a partir de outra |
| `relocate chunk -chunk <lista> -sourceru n [-targetru n]` | Move chunks entre RUs (`MOVE CHUNK` não é suportado com Raft) |
| `remove ru -ru n` | Remove RU vazia |
| `start ru` / `stop ru` / `sync ru -ru n` | Operação de réplica |
| `set ru parameter NOME=valor` | Parâmetros de RU |
| `config sdb` | Mostra "Replication Type Native" |

Comandos **inexistentes** citados na v1: `add ru`, `failover ru`, `config ru`, `add replica`, `remove replica`, `set ru priority`.

## Monitoração

- `V$SHARD_REPLICATION_UNIT`: RU_ID, LEADER_ID, ROLE (1 = leader, 2 = follower, 3 = candidate), TERM, COMMITIDX
- `SHARD_RAFT_PARAMETERS` (26ai)
- `V$SHARD_ACK_SENDER`, `V$SHARD_ACK_RECEIVER`, `V$SHARD_APPLY_*`, `V$SHARD_LCR_*`, `V$SHARD_NETWORK_SENDER`, `V$SHARD_TRANSACTION`
- Parâmetro `SHARD_ENABLE_RAFT_FOLLOWER_READ` (leitura em followers)

`GV$SHARDING_UNITS` **não existe** (citado na v1).

## Licenciamento e edição Free

Licensing Information User Manual 26ai, linha "Oracle Globally Distributed Database Raft Replication":

| Edição | Raft |
|---|---|
| **Free** | Permitido, até **3 nós**; cada nó dentro dos limites do Free (2 CPUs, 2 GB RAM, 12 GB de dados) |
| SE2 | Não |
| EE / EE-ES | Sim, sem limite de shards, mas **cada shard precisa de licença Oracle RAC** |

Sem Raft (GDD com Data Guard básico, sem ADG, GoldenGate ou RAC), o uso fica limitado a 3 shards primários.

## Quando usar

✓ Várias regiões geográficas ou exigência de soberania de dados
✓ Escala de escrita além do que um RAC entrega
✓ RPO zero com failover automático entre shards

✗ Um só datacenter: RAC + Data Guard é mais simples
✗ Schema com muitos JOINs entre shards
✗ Equipe sem experiência em sistemas distribuídos

## Novidades 26ai

| RU | Novidade |
|---|---|
| 23.26.0 | Mover chunks entre shardspaces |
| 23.26.4 | Replicação assíncrona entre regiões para GDD com Raft; Witness Replica |

Sintaxe das novidades do 23.26.4: consulte o guia antes de gerar código (**A VERIFICAR**).

## Roadmap exploratório

1. **Entender:** guia oficial + oracle-base.
2. **Lab:** 3 nós 26ai Free (limite da licença Free) + GSM; criar catálogo com `-repl native`, fazer deploy, `status ru`, derrubar o leader e observar a eleição. Ambiente local → `oracle-lab-ptbr`.
3. **POC:** carga sintética; medir latência de escrita com rede real entre regiões.
4. **Produção:** só com treinamento e planejamento de licença (RAC por shard).

## Documentação

- Globally Distributed Database Guide 26ai: https://docs.oracle.com/en/database/oracle/oracle-database/26/shard/
- Enabling Raft Replication: https://docs.oracle.com/en/database/oracle/oracle-database/26/shard/enabling-raft-replication.html
- Raft Replication Concepts: https://docs.oracle.com/en/database/oracle/oracle-database/26/shard/raft-replication-concepts.html
- GDSCTL Reference: https://docs.oracle.com/en/database/oracle/oracle-database/26/gsctl/
- V$SHARD_REPLICATION_UNIT: https://docs.oracle.com/en/database/oracle/oracle-database/26/refrn/V-SHARD_REPLICATION_UNIT.html
- Licenciamento: https://docs.oracle.com/en/database/oracle/oracle-database/26/dblic/Licensing-Information.html
