--==============================================================================
-- Template: JSON Relational Duality — Fundamentos
--
-- Cobre: CREATE JSON RELATIONAL DUALITY VIEW (sintaxe SQL e GraphQL),
--        consulta via SQL, JSON, e MongoDB API.
--
-- Pré-requisito: Oracle 23ai+ ou 26ai. Em 19c não funciona.
--
-- Conceito-chave: dados ficam em tabelas relacionais normalizadas mas são
-- ACESSADOS como documentos JSON. O melhor dos dois mundos: integridade
-- relacional + flexibilidade JSON.
--==============================================================================


--==============================================================================
-- 1. Tabelas-base (relacionais, normalizadas)
--==============================================================================

CREATE TABLE departamentos (
  id_departamento  NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nome             VARCHAR2(100) NOT NULL,
  localizacao      VARCHAR2(100)
);

CREATE TABLE funcionarios (
  id_funcionario   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nome             VARCHAR2(100) NOT NULL,
  cargo            VARCHAR2(50),
  salario          NUMBER(10,2),
  id_departamento  NUMBER NOT NULL,
  CONSTRAINT fk_func_dept FOREIGN KEY (id_departamento)
    REFERENCES departamentos(id_departamento)
);

INSERT INTO departamentos (nome, localizacao) VALUES ('Necropsia',  'Bloco A');
INSERT INTO departamentos (nome, localizacao) VALUES ('Toxicologia', 'Bloco B');

INSERT INTO funcionarios (nome, cargo, salario, id_departamento)
  VALUES ('João Silva', 'Médico Legista', 15000, 1);
INSERT INTO funcionarios (nome, cargo, salario, id_departamento)
  VALUES ('Ana Costa', 'Auxiliar', 5000, 1);
INSERT INTO funcionarios (nome, cargo, salario, id_departamento)
  VALUES ('Pedro Lima', 'Toxicologista', 12000, 2);

COMMIT;


--==============================================================================
-- 2. Duality view — sintaxe SQL
--
-- View hierárquica: departamento → array de funcionários
--==============================================================================

CREATE OR REPLACE JSON RELATIONAL DUALITY VIEW departamentos_dv AS
SELECT JSON {
  '_id'        : d.id_departamento,
  'nome'       : d.nome,
  'localizacao': d.localizacao,
  'funcionarios' : [
    SELECT JSON {
      'idFuncionario' : f.id_funcionario,
      'nome'          : f.nome,
      'cargo'         : f.cargo,
      'salario'       : f.salario
    }
      FROM funcionarios f WITH INSERT UPDATE DELETE
     WHERE d.id_departamento = f.id_departamento
  ]
}
  FROM departamentos d WITH INSERT UPDATE DELETE;


--==============================================================================
-- 3. Duality view — sintaxe GraphQL (alternativa, mesma semântica)
--==============================================================================

CREATE OR REPLACE JSON RELATIONAL DUALITY VIEW departamentos_dv_gql AS
departamentos @insert @update @delete {
  _id          : id_departamento,
  nome         : nome,
  localizacao  : localizacao,
  funcionarios : funcionarios @insert @update @delete
                              @link (to: ["id_departamento"]) [{
    idFuncionario : id_funcionario,
    nome          : nome,
    cargo         : cargo,
    salario       : salario
  }]
};


--==============================================================================
-- 4. Consulta — SQL retorna JSON
--==============================================================================

-- Toda a hierarquia
SELECT data FROM departamentos_dv;

-- Campos específicos via dot notation
SELECT data."_id", data.nome, data.localizacao
  FROM departamentos_dv;

-- Consulta com filtro em campo aninhado
SELECT data
  FROM departamentos_dv
 WHERE data.localizacao = 'Bloco A';

-- Query no array de funcionários (todos com salário > 10000)
SELECT d.data.nome AS departamento,
       f.nome AS funcionario, f.salario
  FROM departamentos_dv d,
       JSON_TABLE(d.data.funcionarios, '$[*]'
         COLUMNS (
           nome    VARCHAR2(100) PATH '$.nome',
           salario NUMBER PATH '$.salario'
         )) f
 WHERE f.salario > 10000;


--==============================================================================
-- 5. INSERT — adicionar departamento com funcionários (atomic)
--==============================================================================

INSERT INTO departamentos_dv VALUES ('
{
  "nome"          : "Antropologia Forense",
  "localizacao"   : "Bloco C",
  "funcionarios"  : [
    {
      "nome"    : "Maria Souza",
      "cargo"   : "Antropóloga",
      "salario" : 13000
    },
    {
      "nome"    : "Carlos Dias",
      "cargo"   : "Auxiliar",
      "salario" : 4500
    }
  ]
}');

COMMIT;

-- O INSERT acima:
--   - Cria 1 row em DEPARTAMENTOS
--   - Cria 2 rows em FUNCIONARIOS (com FK correto)
--   - Tudo numa única operação atomic


--==============================================================================
-- 6. SELECT após INSERT — observar metadata
--==============================================================================

SELECT data
  FROM departamentos_dv
 WHERE data.nome = 'Antropologia Forense';

/* Retorno típico (formato JSON):
{
  "_id": 3,
  "_metadata": {
    "etag": "B3F8A2D1C4E5F6G7H8I9J0K1L2M3N4O5",
    "asof": "0000000000FA42C8"
  },
  "nome": "Antropologia Forense",
  "localizacao": "Bloco C",
  "funcionarios": [
    {
      "idFuncionario": 4,
      "_metadata": {"etag": "..."},
      "nome": "Maria Souza",
      ...
    },
    ...
  ]
}
*/

-- _metadata.etag = hash do conteúdo, usado para optimistic locking (próximo template)
-- _metadata.asof = SCN, identifica versão


--==============================================================================
-- 7. Gerenciamento de duality views — dictionary views
--==============================================================================

-- Listar duality views do schema
SELECT table_name AS view_name, comments
  FROM user_tab_comments
 WHERE table_name IN (
   SELECT collection_name FROM user_json_collections
    WHERE collection_type = 'DUALITY VIEW'
 );

-- Detalhes da estrutura de uma duality view
SELECT * FROM user_json_dv_objects WHERE name = 'DEPARTAMENTOS_DV';

-- Detalhes dos campos
SELECT * FROM user_json_dv_columns WHERE owner = USER AND name = 'DEPARTAMENTOS_DV';


--==============================================================================
-- 8. Anotações — controle granular de DML
--==============================================================================

/*
Anotações disponíveis:

  WITH INSERT UPDATE DELETE  -- DML completo (default em raiz)
  WITH NOINSERT NOUPDATE NODELETE  -- read-only

  WITH NOINSERT  -- não permite criar via duality
  WITH NOUPDATE  -- não permite alterar
  WITH NODELETE  -- não permite excluir
  WITH NOCHECK   -- mudanças nesta sub-árvore NÃO afetam ETag do pai
                 -- (útil quando colunas mudam frequentemente mas não são "core")
*/

-- Exemplo: departamento permite tudo, funcionários só leitura via duality
-- (mudanças em funcionários devem ser feitas direto na tabela)
CREATE OR REPLACE JSON RELATIONAL DUALITY VIEW dept_readonly_func_dv AS
SELECT JSON {
  '_id'         : d.id_departamento,
  'nome'        : d.nome,
  'funcionarios': [
    SELECT JSON {
      'nome'    : f.nome,
      'cargo'   : f.cargo
    }
      FROM funcionarios f WITH NOINSERT NOUPDATE NODELETE  -- read-only
     WHERE d.id_departamento = f.id_departamento
  ]
}
  FROM departamentos d WITH INSERT UPDATE DELETE;


--==============================================================================
-- 9. Anti-patterns
--==============================================================================

/*
ANTI-PATTERN 1: Duality view sem _id
  - _id é obrigatório, mapeia para PK da root table
  - Sem _id, view não pode ser usada via MongoDB API

ANTI-PATTERN 2: Esquecer WITH INSERT UPDATE DELETE
  - Sem isso, view é read-only por default
  - Aplicação tenta INSERT e recebe ORA-42692

ANTI-PATTERN 3: Hierarquia muito profunda
  - 3+ níveis aninhados em duality view fica difícil de manter
  - Considere dividir em múltiplas views ou usar JSON Collection table

ANTI-PATTERN 4: Tentar fazer DML em coluna calculada
  - Campo derivado (ex: salario_anual = salario * 12) não é atualizável
  - Marque com @nocheck ou exclua da view

ANTI-PATTERN 5: Não considerar performance de query agregada
  - SELECT data FROM duality_view WHERE data.array.contains(...)
  - JSON_TABLE pode ser caro em volumes grandes
  - Considere índices funcionais sobre JSON paths
*/
