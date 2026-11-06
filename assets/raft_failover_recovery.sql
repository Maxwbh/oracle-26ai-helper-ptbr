--==============================================================================
-- Template: Raft — Failover e Recuperação (EXPLORATÓRIO)
--
-- Cobre: switchover planejado de RU, failover automático por eleição Raft,
-- retorno do shard (failback), reparo de follower, monitoração e
-- troubleshooting.
--
-- Revisado: nov/2026 contra a documentação Oracle AI Database 26ai (RU 23.26.4)
-- Edição Free: Sim — o Licensing Guide 26ai permite Raft Replication no Free
--              com até 3 nós (2 CPUs, 2 GB RAM, 12 GB de dados por nó)
--
-- Material conceitual + comandos. Requer ambiente de laboratório.
-- Fontes: shard/raft-replication-concepts.html,
--         shard/raft-replication-operations.html,
--         gsctl/{switchover-ru, status-ru, copy-ru, sync-ru, start-ru}.html,
--         refrn/V-SHARD_REPLICATION_UNIT.html, nfcoa/ru23_26_4.html
--==============================================================================


--==============================================================================
-- 1. Tipos de troca de leader
--==============================================================================

/*
SWITCHOVER DE RU (planejado)
  - Manual: GDSCTL switchover ru -ru <id> -database <shard>
  - Muda qual réplica é o leader da RU; sem perda de dados
  - Uso: manutenção do shard, redistribuição de carga
  - -timeout: tempo de retenção das conexões entre o envio do evento FAN e o
    chunk ficar read-only/down

FAILOVER (não planejado, AUTOMÁTICO)
  - Followers sem dados/heartbeat do leader iniciam eleição Raft
    (heartbeat padrão 150 ms; timeout de eleição aleatório até 150 ms)
  - Com maioria (quorum) saudável, um novo leader é eleito
  - Commits já confirmados (consenso) não se perdem: zero data loss
  - Transação sem consenso não é confirmada à aplicação
  - Tempo documentado: < 3 s com latência < 10 ms entre zonas (detecção,
    eleição, reconexão da aplicação); sub-segundo possível no mesmo DC
  - Clientes (ex.: UCP) recebem notificação ONS e passam a rotear para o
    novo leader; configure retry/intervalo no driver JDBC

SEM QUORUM
  - Com RF = 3, perder 2 réplicas de uma RU impede eleição e commits dessa RU.
  - NÃO existe "failover ru -force" nem promoção forçada documentada.
  - Commits aguardam consenso até SHARD_TXN_ACK_TIMEOUT_SEC (padrão 90 s)
    e falham com ORA-05086.
  - Recuperação: restabelecer as réplicas; depois start ru / sync ru / copy ru
    conforme o caso (seção 5).
*/


--==============================================================================
-- 2. Switchover planejado — passo a passo
--==============================================================================

/*
PRÉ-CHECK:
  GDSCTL> status ru -ru 1
  -- confirme qual shard é Leader e que os followers estão com Status Ok
  GDSCTL> status ru -ru 1 -show_errors

EXECUÇÃO:
  GDSCTL> switchover ru -ru 1 -database <shard_destino>
  -- A VERIFICAR: o guia shard mostra "-shard"; a referência gsctl, "-database".

VALIDAÇÃO:
  GDSCTL> status ru -ru 1
  -- o shard destino deve aparecer como Leader; Term incrementado

DEPOIS DA MANUTENÇÃO:
  GDSCTL> switchover ru -rebalance
  -- redistribui leaders igualmente entre os shards

Melhor prática documentada: fazer switchover dos leaders de um shard ANTES
de qualquer manutenção nele.
*/


--==============================================================================
-- 3. Simulação de falha de leader (SOMENTE LABORATÓRIO)
--==============================================================================

/*
1. Identificar o leader da RU
   GDSCTL> status ru -ru 1 -leaders

2. Derrubar o shard leader (ex.: shutdown abort na instância do lab)

3. Observar a eleição em outro terminal
   GDSCTL> status ru -ru 1
   -- outro shard aparece como Leader, com Term maior
   -- no shard: V$SHARD_REPLICATION_UNIT (ROLE 3 = candidato durante eleição)

4. Validar acesso pela aplicação (via serviço do shard director)
   SQL> SELECT * FROM clientes WHERE id_cliente = 100;

5. Subir o shard derrubado
   - Ele tenta identificar o leader atual e volta como FOLLOWER,
     pedindo ao leader os logs a partir do seu índice atual.
   GDSCTL> status ru -ru 1

6. Reequilibrar leaders
   GDSCTL> switchover ru -rebalance
*/


--==============================================================================
-- 4. Monitoração da saúde Raft (SQL no shard)
--==============================================================================

-- 26ai: papel e índices por RU neste shard
SELECT ru_id,
       DECODE(role, 1, 'LEADER', 2, 'FOLLOWER', 3, 'CANDIDATO') AS papel,
       leader_id, term, commitidx, applylwmidx, ondiskidx,
       role_changed_time, flags
  FROM v$shard_replication_unit
 ORDER BY ru_id;

-- 26ai: RUs em eleição neste momento
SELECT ru_id, term, role_changed_time
  FROM v$shard_replication_unit
 WHERE role = 3;

-- 26ai: trocas de papel recentes (TERM sobe a cada novo leader)
SELECT ru_id, term, role, role_changed_time
  FROM v$shard_replication_unit
 WHERE role_changed_time > SYSTIMESTAMP - INTERVAL '1' HOUR
 ORDER BY role_changed_time DESC;

-- 26ai: RU com erros ativos (bit 0x00010000 = ERRORS em FLAGS)
SELECT ru_id, flags
  FROM v$shard_replication_unit
 WHERE BITAND(flags, TO_NUMBER('10000', 'XXXXX')) <> 0;

-- 26ai: follower atrasado no apply (consenso x low watermark de apply)
SELECT ru_id, commitidx - applylwmidx AS indices_pendentes_apply
  FROM v$shard_replication_unit
 WHERE role = 2
 ORDER BY indices_pendentes_apply DESC;

-- Pelo GDSCTL (visão de todos os shards):
--   status ru -sort -show_errors [-all]
--   status ru -show_offline        (shards fora do ar que têm a RU)
--   status ru -show_stats


--==============================================================================
-- 5. Recuperação de shard após falha prolongada
--==============================================================================

/*
CENÁRIO: um shard ficou fora do ar por muito tempo.

OPÇÃO A: Retorno automático (failback)
  Ao voltar, o shard se junta como follower e pede ao leader os Raft logs
  a partir do seu índice. Funciona enquanto o leader ainda tiver os logs.

OPÇÃO B: Repopular o follower a partir de outro follower (COPY RU)
  Se o leader não tiver mais logs suficientes:
    GDSCTL> copy ru -ru <id> -source <follower_bom> -target <shard_recuperado>
  (nem origem nem destino podem ser o leader; exige tablespace set)

OPÇÃO C: Ressincronizar todos os membros da RU (SYNC RU)
    GDSCTL> sync ru -ru <id> [-database <shard_referencia>]
  Apaga Raft logs e zera log index/term. Sem -database, escolhe a réplica
  que foi o último leader ou, na falta dela, a de maior apply index.
  Acompanhar com: GDSCTL> config task
  "Warning: GSM timeout expired" não significa que a operação parou.

OPÇÃO D: RU parada por erro (ex.: processo de log producer parou)
    GDSCTL> start ru -ru <id> [-database <shard>]
  Reinicia a RU sem reiniciar o banco.

OPÇÃO E: Substituir o shard definitivamente
  1. switchover ru / move ru para tirar as réplicas dele
  2. adicionar novo shard (add shard + deploy) ou copy ru -replace
  O RF continua 3 — não há como "reduzir réplicas".
*/


--==============================================================================
-- 6. Recuperação point-in-time (PITR) em banco distribuído
--==============================================================================

/*
PITR em banco distribuído é bem mais complexo que em banco único:
  - Backup e restore são por banco (catálogo e cada shard).
  - Restaurar shards para pontos diferentes gera inconsistência entre RUs.
  -- A VERIFICAR: procedimento oficial de PITR coordenado com Raft
     (shard/backup-and-recovery.html não foi revisado nesta passagem).
  Não use comandos genéricos de RMAN como receita sem ler esse capítulo.
  Operação de RMAN: skill oracle-dba-ptbr da suíte
  https://github.com/Maxwbh/oracle-skills-ptbr
*/


--==============================================================================
-- 7. Anti-patterns operacionais
--==============================================================================

/*
ANTI-PATTERN 1: Procurar comandos que não existem
  - failover ru, config ru, add/remove replica, set ru priority: não existem.
  - Failover é automático; ajuste fino é por set ru parameter.

ANTI-PATTERN 2: Réplicas no mesmo rack/zona
  - Use add shard ... -rack <id>: o catálogo impede réplicas da mesma RU no
    mesmo rack (erro se não for possível).

ANTI-PATTERN 3: Rede lenta entre shards
  - O commit espera consenso; latência alta entre zonas aumenta o tempo de
    commit e o tempo de failover (< 3 s documentado para < 10 ms).

ANTI-PATTERN 4: Não monitorar follower atrasado
  - Compare COMMITIDX x APPLYLWMIDX; ajuste SHARD_FLOW_CONTROL se preciso.

ANTI-PATTERN 5: Manutenção sem switchover prévio
  - Faça switchover dos leaders antes; rebalanceie depois.

ANTI-PATTERN 6: Achar que Raft protege o catálogo
  - Não protege: configure Data Guard no shard catalog.
*/


--==============================================================================
-- 8. Novidades 23.26.4 relacionadas a DR (somente descrição)
--==============================================================================

/*
-- 26ai 23.26.4+ : Asynchronous Cross-Region Replication — cluster Raft
--                 somente leitura, réplica do cluster primário, para DR
--                 entre regiões e leitura próxima ao usuário.
-- 26ai 23.26.4+ : Witness Replica — membro que mantém só Raft logs e vota
--                 no quorum (sem cópia completa dos dados).
-- A VERIFICAR: comandos GDSCTL e procedimentos de failover desses recursos.
*/


--==============================================================================
-- 9. Roteiro de exploração
--==============================================================================

/*
NÍVEL 1 (conceito):
  - shard/raft-replication-concepts.html e raft-replication-operations.html

NÍVEL 2 (laboratório):
  - 3 instâncias 26ai Free (o Free permite Raft com até 3 nós)
  - create shardcatalog -repl native, add gsm, add shard (x3), deploy
  - status ru, switchover ru, simular queda de um shard, switchover ru -rebalance
  - Ambiente local: skill oracle-lab-ptbr da suíte
    https://github.com/Maxwbh/oracle-skills-ptbr

NÍVEL 3 (POC):
  - Tabela sharded real, carga sintética, medir latência de commit e tempo
    de failover entre zonas

NÍVEL 4 (produção):
  - EE com licença RAC por shard; Data Guard no catálogo; runbook de DR
    testado
*/
