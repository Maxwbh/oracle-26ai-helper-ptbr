# RAFT Globally Distributed Database — Reference

Conceitos para Oracle AI Database 26ai. **Material exploratório** — RAFT em produção exige planejamento dedicado e tipicamente consultoria Oracle.

## Conceito-chave

**Globally Distributed Database (GDD)** é a arquitetura de sharding nativa Oracle. **RAFT** é o protocolo de consenso distribuído usado para replicação multi-master entre shards.

Não confundir com:
- **Oracle RAC**: cluster de instances compartilhando 1 storage; alta disponibilidade local
- **Active Data Guard (ADG)**: 1 primary + N standbys read-only; DR e read scaling
- **GoldenGate**: replicação heterogênea, eventual consistency
- **GDD com RAFT**: múltiplas databases distribuídas, todas aceitando writes, consenso para consistência

## Componentes

```
           ┌──────────────────┐
           │  Shard Catalog   │ ← metadata da topologia
           │  (separate DB)   │
           └────────┬─────────┘
                    │
           ┌────────┴─────────┐
           │       GSM        │ ← Global Service Manager (router)
           │   (mid-tier)     │
           └────────┬─────────┘
                    │
       ┌────────────┼────────────┐
       │            │            │
   ┌───▼───┐    ┌───▼───┐    ┌───▼───┐
   │Shard 1│    │Shard 2│    │Shard 3│
   │ (DB)  │    │ (DB)  │    │ (DB)  │
   └───────┘    └───────┘    └───────┘
   
   Cada Shard hospeda 1+ Replication Units (RUs)
   Cada RU tem 1 leader + N followers, replicação via RAFT
```

## Replication Unit (RU)

Unidade lógica de replicação. Default em 26ai: 3 replicas (1 leader + 2 followers, quorum=2).

Eleição:
- Heartbeat entre replicas (default: 1s)
- Se leader não responde por timeout (default: 5s), followers iniciam eleição
- Eleição: candidate solicita votos, ganha se majority concorda
- Tempo típico de eleição: 3-5 segundos

Garantias:
- **Zero data loss** para writes que receberam ACK (quorum atingido)
- **No split-brain** — apenas lado com quorum aceita writes
- **Linearizability** — leituras vêem dados na ordem global de commit

## Sharded vs Duplicated tables

| Tipo | Distribuição | Use case |
|---|---|---|
| `SHARDED TABLE` | Particionada por shard key | Tabelas grandes, dados de transação |
| `DUPLICATED TABLE` | Replicada para todos shards | Reference data pequena (countries, status codes) |

Sharded:
```sql
CREATE SHARDED TABLE clientes (...)
PARTITION BY CONSISTENT HASH (id_cliente)
PARTITIONS AUTO
TABLESPACE SET tbs_clientes;
```

Duplicated:
```sql
CREATE DUPLICATED TABLE estados (
  uf VARCHAR2(2) PRIMARY KEY,
  nome VARCHAR2(100)
);
```

## Sharding methods

| Método | Distribuição | Comentário |
|---|---|---|
| `CONSISTENT HASH` | Hash da chave | Recomendado default; rebalance gradual |
| `RANGE` | Faixas de valor | Útil para temporais (mês/trimestre por shard) |
| `LIST` | Valores enumerados | Geográfico (estado/região por shard) |
| `COMPOSITE` | Combinação | Avançado, raro |

## Quando usar GDD com RAFT

✓ **Múltiplas regiões geográficas** (US-East + US-West + EU)
✓ **Data sovereignty** (dados de cliente BR só em shards BR)
✓ **Write scalability** além do que RAC fornece
✓ **Active-active multi-master** com consistency strong
✓ **Zero RPO** com automatic failover

✗ **Single datacenter**: RAC + ADG é mais simples e suficiente
✗ **Workload pequeno** (<TB): overhead não compensa
✗ **Schema complexo com muitos JOINs cross-shard**: latência mata performance
✗ **Equipe sem expertise distribuída**: curva de aprendizado íngreme

## Comparação com alternativas

| Necessidade | RAC | ADG | GoldenGate | GDD+RAFT |
|---|---|---|---|---|
| HA local | ✓✓✓ | ✓ | ✗ | ✓ |
| DR remoto | ✗ | ✓✓✓ | ✓✓ | ✓✓✓ |
| Multi-master writes | ✗ | ✗ | ✓ (com conflito) | ✓✓✓ |
| Zero data loss | ✓ (mesmo storage) | ✓ (sync mode) | ✗ | ✓✓✓ |
| Read scaling | ✗ | ✓✓ | ✓ | ✓✓ |
| Geo-distribution | ✗ | ✓ | ✓✓ | ✓✓✓ |
| Setup complexity | Médio | Baixo | Alto | Muito alto |
| Custo licença | Médio | Médio | Alto | Muito alto |

## GDSCTL — comandos essenciais

```bash
# Conectar
$ gdsctl connect gsmadmin/<senha>@gsm1

# Status da topologia
GDSCTL> status gsm
GDSCTL> config shard
GDSCTL> config region
GDSCTL> config ru

# Eventos recentes
GDSCTL> show events

# Switchover planejado
GDSCTL> switchover ru ru_name -newleader shard2

# Adicionar shard
GDSCTL> add shard -connect db.host:1521/sid -shardgroup sg_brasil

# Validar
GDSCTL> validate
```

## Roadmap exploratório

Sem requisito multi-master claro, RAFT é overkill na maioria dos cenários. Sugestão de roadmap exploratório:

1. **Nível 1 (entender)**: ler documentação oficial, Oracle-Base, blog Mike Dietrich. ~4h.
2. **Nível 2 (lab pessoal)**: 3 containers Docker com 23ai Free, configurar GSM + 1 RU. Simular failover. ~2 dias.
3. **Nível 3 (POC)**: workload sintético, medir latência write com diferentes replication_factor. ~1 semana.
4. **Nível 4 (produção)**: só com treinamento Oracle dedicado e consultoria.

Sem projeto concreto de distribuição geográfica, nível 1-2 é suficiente para informar decisões futuras.

## Documentação

- Globally Distributed Database User's Guide: https://docs.oracle.com/en/database/oracle/oracle-database/26/shard/
- RAFT Replication chapter: capítulo dedicado dentro do guide acima
- LiveLabs: "Oracle Sharding" e "RAFT Replication Quickstart"
- MOS Notes: "RAFT Replication Best Practices" (atualizada por release update)
