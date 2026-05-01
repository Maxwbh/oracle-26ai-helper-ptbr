--==============================================================================
-- Template: DML em JSON Relational Duality Views
--
-- Cobre: INSERT/UPDATE/DELETE em duality views, regras de mapeamento,
--        ordem dos campos no JSON, propagação para tabelas-base.
--
-- Pré-requisito: duality view criada (ver json_duality_view_basics.sql).
--==============================================================================


--==============================================================================
-- 1. INSERT — adiciona registros nas tabelas-base via JSON
--==============================================================================

-- Insert simples — só departamento (sem funcionários)
INSERT INTO departamentos_dv VALUES ('
{
  "nome"        : "Genética Forense",
  "localizacao" : "Bloco D"
}');

-- Insert com array — departamento + funcionários (cria FK automaticamente)
INSERT INTO departamentos_dv VALUES ('
{
  "nome"        : "DNA Forense",
  "localizacao" : "Bloco D",
  "funcionarios": [
    {"nome": "Lucas Pereira", "cargo": "Geneticista", "salario": 14000},
    {"nome": "Carla Mendes", "cargo": "Auxiliar", "salario": 4800}
  ]
}');

-- Insert SEM _id (será gerado via IDENTITY ou sequence da tabela-base)
-- Insert COM _id (deve estar disponível, senão ORA-42624)

COMMIT;


--==============================================================================
-- 2. UPDATE — regra fundamental: _id ANTES de _metadata
--
-- O Oracle exige ordem específica no JSON do UPDATE:
--   1. _id (identifica registro)
--   2. _metadata (contém ETag)
--   3. Resto dos campos
--==============================================================================

-- 1. Primeiro fazer SELECT para obter ETag atual
SELECT data
  FROM departamentos_dv
 WHERE data."_id" = 1;

-- Suponha retorno:
-- {"_id":1, "_metadata":{"etag":"E546E2220E8F9620...","asof":"..."},
--  "nome":"Necropsia", "localizacao":"Bloco A", "funcionarios":[...]}


-- 2. UPDATE com ETag explícito
UPDATE departamentos_dv d
   SET d.data = '{
     "_id"        : 1,
     "_metadata"  : {"etag": "E546E2220E8F9620"},
     "nome"       : "Necropsia Especializada",
     "localizacao": "Bloco A - Térreo",
     "funcionarios": [
       {"idFuncionario": 1, "nome": "João Silva", "cargo": "Médico Legista Sênior", "salario": 16500},
       {"idFuncionario": 2, "nome": "Ana Costa", "cargo": "Auxiliar Sênior", "salario": 5500}
     ]
   }'
 WHERE d.data."_id" = 1;

COMMIT;


-- Se ETag não bate (alguém mais modificou entre SELECT e UPDATE):
--   ORA-42699: Cannot update view with etag mismatch.
-- Solução: re-fetch com novo ETag e retry (próximo template tem padrão completo)


--==============================================================================
-- 3. UPDATE parcial — alterar apenas alguns campos
--
-- Você pode mandar JSON parcial; campos omitidos preservam valor anterior.
-- IMPORTANTE: _id e _metadata sempre obrigatórios.
--==============================================================================

UPDATE departamentos_dv d
   SET d.data = '{
     "_id"      : 2,
     "_metadata": {"etag": "..."},
     "nome"     : "Toxicologia Avançada"
   }'
 WHERE d.data."_id" = 2;

-- Resultado: apenas "nome" alterado; "localizacao" e "funcionarios" preservados


--==============================================================================
-- 4. UPDATE em sub-array — adicionar/remover funcionário
--==============================================================================

-- Adicionar novo funcionário ao departamento
UPDATE departamentos_dv d
   SET d.data = '{
     "_id"      : 1,
     "_metadata": {"etag": "..."},
     "funcionarios": [
       {"idFuncionario": 1, "nome": "João Silva", "cargo": "Médico Legista", "salario": 16500},
       {"idFuncionario": 2, "nome": "Ana Costa", "cargo": "Auxiliar", "salario": 5500},
       {"nome": "Roberto Andrade", "cargo": "Estagiário", "salario": 2500}  -- novo (sem idFuncionario)
     ]
   }'
 WHERE d.data."_id" = 1;

-- Remover funcionário (basta omitir do array)
UPDATE departamentos_dv d
   SET d.data = '{
     "_id"      : 1,
     "_metadata": {"etag": "..."},
     "funcionarios": [
       {"idFuncionario": 1, "nome": "João Silva", "cargo": "Médico Legista", "salario": 16500}
       -- omitidos: 2, 3 (serão DELETE-ados via FK ON DELETE)
     ]
   }'
 WHERE d.data."_id" = 1;


-- Comportamento depende das anotações:
--   WITH DELETE: funcionários omitidos são deletados
--   WITH NODELETE: funcionários omitidos não podem sumir; ORA-42693


--==============================================================================
-- 5. DELETE — remove o departamento (e funcionários, via cascade FK)
--==============================================================================

-- DELETE direto, sem ETag check (potencialmente perigoso em concorrência)
DELETE FROM departamentos_dv d WHERE d.data."_id" = 5;

-- DELETE com ETag check (recomendado em concorrência)
-- (ETag em DELETE não é nativo do SQL; precisa lógica em PL/SQL ou MongoDB API)


--==============================================================================
-- 6. Procedure padrão — UPDATE com retry em ETag mismatch
--==============================================================================

CREATE OR REPLACE PROCEDURE atualizar_departamento_safe (
  p_id_departamento  IN NUMBER,
  p_novo_nome        IN VARCHAR2,
  p_max_tentativas   IN PLS_INTEGER DEFAULT 3
) IS
  lc_nome_unidade CONSTANT VARCHAR2(60) := 'ATUALIZAR_DEPARTAMENTO_SAFE';
  
  l_dados_atuais   CLOB;
  l_etag_atual     VARCHAR2(100);
  l_dados_novos    VARCHAR2(4000);
  l_tentativa      PLS_INTEGER := 0;
  l_sucesso        BOOLEAN := FALSE;
  
  e_etag_mismatch  EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_etag_mismatch, -42699);
BEGIN
  WHILE l_tentativa < p_max_tentativas AND NOT l_sucesso LOOP
    l_tentativa := l_tentativa + 1;
    
    BEGIN
      -- Re-fetch com ETag atual
      SELECT JSON_VALUE(data, '$._metadata.etag')
        INTO l_etag_atual
        FROM departamentos_dv
       WHERE data."_id" = p_id_departamento;
      
      -- Construir novo documento (mantém demais campos via partial update)
      l_dados_novos := '{
        "_id"      : ' || p_id_departamento || ',
        "_metadata": {"etag": "' || l_etag_atual || '"},
        "nome"     : "' || p_novo_nome || '"
      }';
      
      UPDATE departamentos_dv d
         SET d.data = l_dados_novos
       WHERE d.data."_id" = p_id_departamento;
      
      l_sucesso := TRUE;
      COMMIT;
      
      DBMS_OUTPUT.put_line(
        lc_nome_unidade || ': sucesso na tentativa ' || l_tentativa
      );
      
    EXCEPTION
      WHEN e_etag_mismatch THEN
        ROLLBACK;
        IF l_tentativa < p_max_tentativas THEN
          DBMS_OUTPUT.put_line(
            lc_nome_unidade || ': ETag mismatch tentativa ' || l_tentativa ||
            ', tentando novamente'
          );
          DBMS_LOCK.sleep(0.1);  -- backoff curto
        ELSE
          raise_application_error(-20100,
            'Concorrência em ' || lc_nome_unidade || 
            ': ' || p_max_tentativas || ' tentativas falharam por ETag mismatch'
          );
        END IF;
    END;
  END LOOP;
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    raise_application_error(-20101,
      'Departamento não encontrado: ' || p_id_departamento ||
      ' em ' || lc_nome_unidade
    );
  WHEN OTHERS THEN
    ROLLBACK;
    raise_application_error(-20999,
      'Erro em ' || lc_nome_unidade || ': ' || SQLERRM
    );
END atualizar_departamento_safe;
/


--==============================================================================
-- 7. Anti-patterns
--==============================================================================

/*
ANTI-PATTERN 1: _metadata antes de _id no UPDATE
  -- ERRO:
  UPDATE departamentos_dv SET data = '{
    "_metadata": {...},      -- ERRADO: deve vir DEPOIS de _id
    "_id": 1,
    ...
  }';
  -- ORA-XXXXX: invalid JSON metadata order

ANTI-PATTERN 2: UPDATE sem ETag em ambiente concorrente
  -- ERRO: lost update — duas sessões alteram simultaneamente
  UPDATE departamentos_dv SET data = '{...sem _metadata...}' WHERE ...
  -- Isso permite sobrescrita silenciosa
  
  -- BOM: SEMPRE incluir _metadata.etag e tratar ORA-42699

ANTI-PATTERN 3: Reusar ETag antigo após modificações
  - ETag muda a cada UPDATE bem-sucedido
  - Sempre re-SELECT antes de re-UPDATE

ANTI-PATTERN 4: DELETE em loop sem batch
  -- RUIM: 1000 sessões, 1000 commits
  FOR r IN (...) LOOP
    DELETE FROM departamentos_dv WHERE data."_id" = r.id;
    COMMIT;
  END LOOP;
  
  -- BOM: chunked
  DELETE FROM departamentos_dv WHERE data."_id" IN (...);
  COMMIT;

ANTI-PATTERN 5: Retry infinito em ETag mismatch
  - 3-5 tentativas é razoável
  - Acima disso, pode ser hot row e a aplicação precisa repensar
*/
