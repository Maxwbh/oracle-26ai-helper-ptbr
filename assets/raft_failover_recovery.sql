--==============================================================================
-- Template: RAFT Failover & Recovery Scenarios (EXPLORATÓRIO)
--
-- Cobre: cenários de failover automático, recovery após falha,
-- point-in-time recovery, e troubleshooting comum.
--
-- Material conceitual + comandos. Requer ambiente lab para testar.
--==============================================================================


--==============================================================================
-- 1. Tipos de failover
--==============================================================================

/*
SWITCHOVER (planejado, sem perda)
  - Iniciado manualmente
  - Leader transfere papel para um follower específico
  - Zero data loss garantido
  - Tempo: ~1-3 segundos
  - Uso: manutenção, balanceamento de carga, atualização de patch

FAILOVER (não-planejado, automático)
  - Disparado por RAFT quando leader fica inacessível
  - Eleição automática entre followers via heartbeat
  - Quorum elege novo leader
  - Dados confirmados pelo quorum: zero data loss
  - Dados em flight (não atingiram quorum): perdidos
  - Tempo: ~3-10 segundos típico
  - Uso: indisponibilidade súbita, falha de hardware

DISASTER FAILOVER (manual, último recurso)
  - Múltiplos shards offline simultaneamente
  - Sem quorum disponível para eleição automática
  - Admin força promoção de um shard sobrevivente
  - Pode haver perda de dados (split-brain potencial)
  - Comando: failover ru <ru> -force
  - Uso: catástrofe regional, falha de múltiplos sites
*/


--==============================================================================
-- 2. Switchover planejado — passo a passo
--==============================================================================

/*
PRÉ-CHECK:
  $ gdsctl connect gsmadmin/<senha>@gsm1
  
  GDSCTL> config ru ru_principal
    Leader: shard1.example.local
    Followers: shard2 (lag: 5ms), shard3 (lag: 8ms)
    Status: HEALTHY
  
  -- Verificar que followers estão SYNCED
  -- Ideal: lag < 100ms

EXECUÇÃO:
  GDSCTL> switchover ru ru_principal -newleader shard2
  
  -- GSM:
  -- 1. Promove shard2 a candidato
  -- 2. shard2 solicita votos dos demais
  -- 3. Recebe quorum, vira leader
  -- 4. shard1 vira follower automaticamente
  -- 5. Conexões existentes são reroteadas

VALIDAÇÃO:
  GDSCTL> config ru ru_principal
    Leader: shard2.example.local  -- NOVO
    Followers: shard1 (lag: 2ms), shard3 (lag: 5ms)
    Status: HEALTHY

POST:
  - Aplicação cliente reconecta automaticamente via TAF (Transparent Application Failover)
  - Algumas transações em andamento podem precisar retry (típico em REST/ORDS)
  - Monitorar lag no novo leader: gv$ru_metrics
*/


--==============================================================================
-- 3. Simulação de falha de leader em ambiente de teste
--==============================================================================

/*
TESTE LAB (NÃO FAZER EM PRODUÇÃO):

# 1. Identifique leader
GDSCTL> config ru ru_test
   Leader: shard1

# 2. Simule falha: derrube o shard
$ ssh shard1.lab.local
$ srvctl stop database -d shard1 -o abort

# 3. Observe eleição (em outro terminal)
GDSCTL> config ru ru_test
   Status: ELECTING_LEADER  -- intermediário, ~3-5 segundos
   ...
   Leader: shard2  -- ou shard3, depende de quem tinha menor lag

# 4. Verifique disponibilidade
$ sqlplus app_user/<pwd>@gsm_alias
SQL> SELECT * FROM clientes WHERE id_cliente = 100;
-- Deve retornar dados, agora servidos pelo novo leader

# 5. Recupere shard caído
$ srvctl start database -d shard1
GDSCTL> config ru ru_test
   Leader: shard2
   Followers: shard1 (status: CATCHING_UP, lag: 5min)
            shard3 (status: SYNCED, lag: 0ms)

# 6. shard1 sincroniza via RAFT log replay
# Tempo depende de quantas transações ocorreram durante downtime
*/


--==============================================================================
-- 4. Métricas para monitorar saúde RAFT
--==============================================================================

-- Lag por replica (alarmar se > 1000ms sustentado)
SELECT ru_name, replica_shard, status,
       current_lag_ms, max_lag_ms_24h
  FROM gv$ru_replicas
 ORDER BY current_lag_ms DESC;


-- Eleições recentes (alarmar se > 1 por hora indica instabilidade)
SELECT ru_name, COUNT(*) AS eleicoes_24h
  FROM dba_ru_events
 WHERE event_type IN ('FAILOVER', 'ELECTION')
   AND event_time > SYSDATE - 1
 GROUP BY ru_name
HAVING COUNT(*) > 0
 ORDER BY eleicoes_24h DESC;


-- Follower out-of-sync (precisa investigação)
SELECT * FROM gv$ru_replicas
 WHERE status NOT IN ('SYNCED', 'LEADER');


-- Quorum em risco (fewer than majority alive)
SELECT ru_name, total_replicas, alive_replicas,
       quorum_required,
       CASE WHEN alive_replicas < quorum_required
            THEN 'CRÍTICO: SEM QUORUM'
            WHEN alive_replicas = quorum_required
            THEN 'ALERTA: 1 falha = sem quorum'
            ELSE 'OK'
       END AS situacao
  FROM gv$ru_status;


--==============================================================================
-- 5. Recovery após falha prolongada de um shard
--==============================================================================

/*
CENÁRIO: shard3 ficou offline por 2 dias.
RAFT logs no leader podem não cobrir todo o período (truncamento normal).

OPÇÕES DE RECOVERY:

OPÇÃO A: Reseed automático via RAFT snapshot
  Funciona se: leader ainda tem snapshot recente cobrindo o período
  Comando: nenhum, é automático ao reiniciar shard3
  
  $ srvctl start database -d shard3
  -- shard3 detecta lag, solicita snapshot do leader
  -- leader envia snapshot completo + log delta
  -- shard3 vira SYNCED após sincronização (pode demorar horas para datasets grandes)


OPÇÃO B: Reconstrução manual do shard
  Funciona se: log do leader já truncou ou shard3 está corrompido
  Passos:
  1. remove replica ru_xxx -shard shard3
  2. Backup completo do leader (RMAN)
  3. Restore no shard3
  4. add replica ru_xxx -shard shard3
  5. RAFT inicializa com snapshot RMAN, aplica deltas posteriores


OPÇÃO C: Desativar shard permanentemente
  Se shard3 não voltará:
  1. remove replica ru_xxx -shard shard3
  2. Considere reduzir replication_factor temporariamente
  3. Adicione novo shard em substituição
*/


--==============================================================================
-- 6. Point-in-time recovery (PITR) em ambiente RAFT
--==============================================================================

/*
PITR em GDD com RAFT é mais complexo que single-database:

  - RMAN backup deve ser COORDENADO entre shards
    (snapshot consistente = todos shards no mesmo SCN global)
  
  - Restore exige reverter TODOS os shards para mesmo SCN
    
  - GSM/catalog também precisa ser restaurado
  
  - Após restore, RAFT precisa reinicializar replication

COMANDOS (visão geral):
  
  1. No catalog:
     RESTORE DATABASE UNTIL SCN <scn_global>;
     RECOVER DATABASE UNTIL SCN <scn_global>;
  
  2. Em cada shard:
     RESTORE DATABASE UNTIL SCN <scn_global>;
     RECOVER DATABASE UNTIL SCN <scn_global>;
  
  3. Reinicializar topologia GSM:
     gdsctl> sync database
     gdsctl> validate

OBS: PITR raramente é primeira escolha em GDD.
     Flashback (mais granular) ou replicação reversa são mais comuns.
*/


--==============================================================================
-- 7. Anti-patterns RAFT operacional
--==============================================================================

/*
ANTI-PATTERN 1: Replication factor 2
  - Quorum de 2 = AMBOS precisam estar online para writes
  - 1 falha = downtime
  - Sempre use 3+ replicas

ANTI-PATTERN 2: Replicas em mesmo rack/zona
  - Falha de rack derruba múltiplas replicas simultaneamente
  - Distribua em zonas/regiões diferentes

ANTI-PATTERN 3: Network insuficiente entre shards
  - RAFT exige round-trip baixo entre replicas
  - Latência > 100ms entre regions afeta performance significativamente
  - Use regions próximas ou aceite latência de write maior

ANTI-PATTERN 4: Sem monitoring de lag
  - Lag crescente em follower indica problema (CPU, disco, network)
  - Sem alerta, descobre só quando follower fica out-of-sync
  - Configure alarme em current_lag_ms > 5000

ANTI-PATTERN 5: Switchover frequente sem necessidade
  - Cada switchover gera reconexões e potencial retry de transações
  - Faça switchover apenas para manutenção real, não testes diários

ANTI-PATTERN 6: Ignorar logs RAFT em troubleshooting
  - Logs em $ORACLE_BASE/diag/raft/...
  - Erros de eleição, lag, quorum aparecem aqui
  - Inclua nos runbooks de troubleshooting
*/


--==============================================================================
-- 8. Recomendações de exploração
--==============================================================================

/*
NÍVEL 1 (entender o conceito):
  - Ler "Oracle Globally Distributed Database Concepts" (manual oficial)
  - Assistir "RAFT Replication Deep Dive" (Oracle Tech Network video)
  - Tempo: 2-4 horas

NÍVEL 2 (ambiente de teste):
  - Subir 3 containers Docker com Oracle 23ai Free
  - Configurar shard catalog + GSM
  - Criar 1 RU com 3 replicas
  - Simular failover
  - Tempo: 1-2 dias

NÍVEL 3 (POC realista):
  - Pequeno projeto com tabela sharded real
  - Workload sintético (Swingbench)
  - Medir latência write com diferentes replication_factor
  - Validar comportamento em failover
  - Tempo: 1 semana

NÍVEL 4 (produção):
  - Treinamento Oracle dedicado
  - Consultoria Oracle ACS para arquitetura
  - DR runbook validado
  - Tempo: meses (não tentativa pessoal)

Sem requisito multi-master claro: nível 1-2 é suficiente
para informar decisões arquiteturais futuras. Nível 3+ se houver
projeto concreto de distribuição geográfica.
*/
