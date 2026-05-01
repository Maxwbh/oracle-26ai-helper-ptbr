--==============================================================================
-- Template: ETag Concurrency Control em Duality Views
--
-- Cobre: padrão optimistic locking via ETag, retry strategies,
--        monitoring de ETag collisions em alta concorrência.
--
-- Por que importa:
--   Duality views são acessadas via REST/MongoDB API — operações stateless.
--   Locks tradicionais não funcionam (sessão fecha entre GET e PUT).
--   ETag = hash do conteúdo, garante "ninguém mudou entre meu GET e PUT".
--==============================================================================


--==============================================================================
-- 1. Como ETag é calculado
--==============================================================================

/*
ETag é hash do CONTEÚDO da row (e sub-rows incluídas via @link).

Modificação em qualquer campo NÃO marcado @nocheck altera ETag.
Modificação em campo @nocheck NÃO altera ETag.

Casos de uso:
  - Campo "audit_timestamp" deve atualizar sem afetar ETag → @nocheck
  - Campo "versão" do documento deve afetar ETag → default (sem @nocheck)
  - Sub-array de "histórico" não-essencial → @nocheck no sub-array
*/

-- View com @nocheck seletivo
CREATE OR REPLACE JSON RELATIONAL DUALITY VIEW departamentos_etag_dv AS
SELECT JSON {
  '_id'         : d.id_departamento,
  'nome'        : d.nome,
  'localizacao' : d.localizacao,
  
  -- Campo de auditoria: muda sem afetar ETag (não bloqueia outros UPDATEs)
  'ultimaConsulta': d.ultima_consulta WITH NOCHECK,
  
  -- Sub-array core: contribui para ETag normalmente
  'funcionarios': [
    SELECT JSON {
      'idFuncionario': f.id_funcionario,
      'nome'         : f.nome,
      'cargo'        : f.cargo
    }
      FROM funcionarios f WITH INSERT UPDATE DELETE
     WHERE d.id_departamento = f.id_departamento
  ]
}
  FROM departamentos d WITH INSERT UPDATE DELETE;


--==============================================================================
-- 2. Padrão GET → PUT via SQL (simulando o fluxo REST)
--==============================================================================

-- Etapa 1: GET — capture conteúdo + ETag
DECLARE
  l_dados      CLOB;
  l_etag       VARCHAR2(100);
BEGIN
  SELECT data INTO l_dados
    FROM departamentos_etag_dv
   WHERE data."_id" = 1;
  
  -- Extrai ETag do _metadata
  SELECT JSON_VALUE(l_dados, '$._metadata.etag')
    INTO l_etag
    FROM dual;
  
  DBMS_OUTPUT.put_line('ETag capturado: ' || l_etag);
  -- ... aplicação faz alterações no documento ...
  
  -- Etapa 2: PUT — envia documento modificado COM o ETag original
  -- Se outro processo modificou entre GET e PUT, ORA-42699 é lançado
END;
/


--==============================================================================
-- 3. Procedure robusta com retry exponencial
--==============================================================================

CREATE OR REPLACE PACKAGE BODY duality_concurrency_pkg AS

  gc_nome_pacote CONSTANT VARCHAR2(30) := 'DUALITY_CONCURRENCY_PKG';

  -- Default: 5 tentativas, backoff exponencial até 1.6s
  gc_max_tentativas    CONSTANT PLS_INTEGER := 5;
  gc_backoff_inicial   CONSTANT NUMBER := 0.1;  -- segundos
  gc_backoff_fator     CONSTANT NUMBER := 2;    -- dobra a cada falha


  PROCEDURE update_com_retry (
    p_view_name        IN VARCHAR2,
    p_id_doc           IN NUMBER,
    p_funcao_modificar IN VARCHAR2,  -- nome de função que recebe JSON e retorna JSON
    p_resultado        OUT VARCHAR2
  ) IS
    lc_nome_unidade CONSTANT VARCHAR2(60) := gc_nome_pacote || '.update_com_retry';
    
    l_doc_atual       CLOB;
    l_doc_modificado  CLOB;
    l_etag            VARCHAR2(100);
    l_tentativa       PLS_INTEGER := 0;
    l_backoff         NUMBER := gc_backoff_inicial;
    l_sucesso         BOOLEAN := FALSE;
    l_sql             VARCHAR2(4000);
    
    e_etag_mismatch   EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_etag_mismatch, -42699);
  BEGIN
    -- Validação básica
    IF p_view_name IS NULL OR p_id_doc IS NULL OR p_funcao_modificar IS NULL THEN
      raise_application_error(-20102,
        'Parâmetros obrigatórios em ' || lc_nome_unidade
      );
    END IF;

    -- Sanitiza nome da view e função (proteção SQL injection)
    DECLARE
      l_view_seguro VARCHAR2(128);
      l_fn_segura   VARCHAR2(128);
    BEGIN
      l_view_seguro := DBMS_ASSERT.simple_sql_name(p_view_name);
      l_fn_segura   := DBMS_ASSERT.simple_sql_name(p_funcao_modificar);
    EXCEPTION
      WHEN OTHERS THEN
        raise_application_error(-20103,
          'Nome inválido em ' || lc_nome_unidade
        );
    END;

    WHILE l_tentativa < gc_max_tentativas AND NOT l_sucesso LOOP
      l_tentativa := l_tentativa + 1;
      
      BEGIN
        -- GET: re-fetch documento atual com ETag fresh
        l_sql := 'SELECT data FROM ' || p_view_name ||
                 ' WHERE data."_id" = :id_doc';
        EXECUTE IMMEDIATE l_sql INTO l_doc_atual USING p_id_doc;
        
        -- Aplica função de modificação fornecida pelo caller
        l_sql := 'SELECT ' || p_funcao_modificar || '(:doc) FROM dual';
        EXECUTE IMMEDIATE l_sql INTO l_doc_modificado USING l_doc_atual;
        
        -- PUT: tenta atualizar com ETag implícito no l_doc_modificado
        l_sql := 'UPDATE ' || p_view_name ||
                 ' SET data = :doc WHERE data."_id" = :id_doc';
        EXECUTE IMMEDIATE l_sql USING l_doc_modificado, p_id_doc;
        
        l_sucesso := TRUE;
        p_resultado := l_doc_modificado;
        COMMIT;
        
      EXCEPTION
        WHEN e_etag_mismatch THEN
          ROLLBACK;
          IF l_tentativa < gc_max_tentativas THEN
            DBMS_LOCK.sleep(l_backoff);
            l_backoff := l_backoff * gc_backoff_fator;  -- exponential backoff
          ELSE
            raise_application_error(-20100,
              'Concorrência excessiva em ' || lc_nome_unidade ||
              ' após ' || gc_max_tentativas || ' tentativas'
            );
          END IF;
      END;
    END LOOP;
  END update_com_retry;


  -- Estatísticas: monitorar ETag collisions
  PROCEDURE relatorio_etag_collisions (
    p_horas IN PLS_INTEGER DEFAULT 24
  ) IS
    l_total_commits   NUMBER;
    l_total_rollbacks NUMBER;
    l_taxa_collision  NUMBER;
  BEGIN
    -- Métricas approximadas via v$sysstat
    SELECT MAX(CASE WHEN name = 'user commits' THEN value END),
           MAX(CASE WHEN name = 'user rollbacks' THEN value END)
      INTO l_total_commits, l_total_rollbacks
      FROM v$sysstat
     WHERE name IN ('user commits', 'user rollbacks');
    
    IF NVL(l_total_commits, 0) > 0 THEN
      l_taxa_collision := ROUND(l_total_rollbacks / l_total_commits * 100, 2);
    ELSE
      l_taxa_collision := 0;
    END IF;
    
    DBMS_OUTPUT.put_line('=== Análise de ETag Collisions ===');
    DBMS_OUTPUT.put_line('Total commits:   ' || l_total_commits);
    DBMS_OUTPUT.put_line('Total rollbacks: ' || l_total_rollbacks);
    DBMS_OUTPUT.put_line('Taxa rollback:   ' || l_taxa_collision || '%');
    
    IF l_taxa_collision > 5 THEN
      DBMS_OUTPUT.put_line('ALERTA: taxa alta sugere hot rows ou retry loops em duality views');
    END IF;
  END relatorio_etag_collisions;

END duality_concurrency_pkg;
/


--==============================================================================
-- 4. Identificar hot rows (rows muito disputadas)
--==============================================================================

-- Sessions ativas em UPDATE/DELETE de duality views
SELECT s.sid, s.serial#, s.username, s.event,
       SUBSTR(q.sql_text, 1, 100) AS sql_preview
  FROM v$session s
  JOIN v$sql q ON s.sql_id = q.sql_id
 WHERE s.status = 'ACTIVE'
   AND q.sql_text LIKE '%DUALITY%'
   AND q.sql_text LIKE '%UPDATE%'
 ORDER BY s.sid;


-- Identificar transactions que estão fazendo retry loops
-- (alta atividade de redo + rollback indica padrão problemático)
SELECT s.sid, s.username,
       t.used_ublk * 8192 AS undo_bytes,
       t.used_urec AS undo_records
  FROM v$transaction t
  JOIN v$session s ON s.taddr = t.addr
 WHERE s.status = 'ACTIVE'
 ORDER BY t.used_ublk DESC
 FETCH FIRST 10 ROWS ONLY;


--==============================================================================
-- 5. Estratégias para minimizar ETag collisions
--==============================================================================

/*
ESTRATÉGIA 1: @nocheck em campos não-críticos
  - Campo "ultima_consulta" muda 1000x/dia mas não é "core"
  - Marque com WITH NOCHECK para não disparar collision em UPDATEs paralelos

ESTRATÉGIA 2: Granularidade fina nas duality views
  - View que cobre dept + 100 funcionários = todo UPDATE invalida ETag
  - Uma view só para dept e outra só para funcionarios = collisions reduzem

ESTRATÉGIA 3: Idempotência na lógica de UPDATE
  - Se UPDATE seta valor X, segundo UPDATE também setando X é OK
  - Procedure deve poder ser chamada múltiplas vezes sem efeito colateral

ESTRATÉGIA 4: Backoff exponencial no retry
  - Inicial: 100ms, dobra a cada falha
  - 5 tentativas = 100ms + 200 + 400 + 800 + 1600 = ~3s total
  - Acima disso, repensar arquitetura (hot row)

ESTRATÉGIA 5: Queue assíncrona para hot rows
  - Em vez de N sessões competindo, enfileirar updates
  - DBMS_AQ ou tabela de comandos consumida sequencialmente

ESTRATÉGIA 6: Em produção, usar APIs MongoDB ou ORDS REST
  - Aplicação cliente lida com ETag mais naturalmente em REST
  - PL/SQL direto é mais propenso a erros de ordering JSON
*/


--==============================================================================
-- 6. Anti-patterns ETag
--==============================================================================

/*
ANTI-PATTERN 1: Ignorar ORA-42699
  EXCEPTION WHEN e_etag_mismatch THEN NULL;  -- ERRADO: silently lost update
  
  -- BOM: ou retry ou propagar erro

ANTI-PATTERN 2: Hardcode ETag no código
  -- ERRADO: ETag muda a cada UPDATE
  l_etag := 'E546E2220E8F9620';  -- vai falhar na 2a chamada
  
  -- BOM: re-fetch sempre antes de UPDATE

ANTI-PATTERN 3: Wrap o UPDATE inteiro num try/catch sem retry
  - Se ORA-42699 acontece, perder o trabalho não é solução
  - Use retry com backoff

ANTI-PATTERN 4: Não monitorar taxa de collisions em produção
  - Sem visibilidade, hot rows passam despercebidos
  - Configure alerta se taxa > 5%

ANTI-PATTERN 5: ETag em sistema single-user
  - Se app é single-user (1 sessão por vez), ETag traz overhead sem benefício
  - Considere @nocheck globalmente, ou view sem ETag enforcement
*/
