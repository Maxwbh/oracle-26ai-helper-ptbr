# JSON Relational Duality — Reference

Conceitos e padrões para Oracle AI Database 23ai/26ai. Revisado em nov/2026 contra o JSON-Relational Duality Developer's Guide 26ai. Itens sem fonte confirmada estão marcados **A VERIFICAR**.

## Índice

- [O que é](#o-que-é)
- [Sintaxes: SQL e GraphQL](#sintaxes-sql-e-graphql)
- [Anotações e diretivas](#anotações-e-diretivas)
- [ETag — optimistic concurrency](#etag--optimistic-concurrency)
- [Regras de DML](#regras-de-dml)
- [GraphQL nativo no 26ai](#graphql-nativo-no-26ai)
- [Acesso via ORDS e MongoDB API](#acesso-via-ords-e-mongodb-api)
- [Novidades 26ai por Release Update](#novidades-26ai-por-release-update)
- [Quando usar](#quando-usar)
- [Tipos relacionados de JSON](#tipos-relacionados-de-json)
- [Erros comuns](#erros-comuns)
- [Documentação](#documentação)

## O que é

Duality view expõe dados relacionais como documentos JSON, sem duplicar dados. O armazenamento é relacional normalizado; o acesso é JSON ou SQL, à escolha do cliente. Por padrão a view é **somente leitura**: escrita só onde houver anotação.

Não confundir com:
- **Coluna JSON** em tabela: o JSON é o próprio armazenamento
- **JSON Collection Table**: coleção estilo MongoDB (documento puro)
- **JSON Collection View** (26ai): somente leitura sobre relacional

## Sintaxes: SQL e GraphQL

### SQL

```sql
-- 26ai (23ai+)
CREATE OR REPLACE JSON RELATIONAL DUALITY VIEW departamentos_dv AS
SELECT JSON {
         '_id'          : d.id_departamento,
         'nome'         : d.nome,
         'funcionarios' : [
           SELECT JSON {
                    'idFuncionario' : f.id_funcionario,
                    'nome'          : f.nome
                  }
             FROM funcionarios f WITH INSERT UPDATE DELETE
            WHERE f.id_departamento = d.id_departamento
         ]
       }
  FROM departamentos d WITH INSERT UPDATE DELETE;
```

### GraphQL (na DDL da view)

```sql
-- 26ai (23ai+)
CREATE OR REPLACE JSON RELATIONAL DUALITY VIEW departamentos_dv AS
departamentos @insert @update @delete {
  _id          : id_departamento,
  nome         : nome,
  funcionarios : funcionarios @insert @update @delete
                 @link (to : ["ID_DEPARTAMENTO"]) [{
    idFuncionario : id_funcionario,
    nome          : nome
  }]
};
```

- `@link(to: [...])` aponta a FK na tabela **aninhada** (um-para-muitos); `@link(from: [...])` aponta a FK na tabela **externa** (um-para-um).
- O `@link` só é obrigatório quando há mais de uma FK entre as duas tabelas ou FK para a própria tabela.
- Os exemplos da doc usam o nome da coluna em maiúsculas.

## Anotações e diretivas

| SQL | GraphQL | Efeito |
|---|---|---|
| `WITH INSERT` / `UPDATE` / `DELETE` | `@insert` / `@update` / `@delete` | Libera a operação na tabela |
| `WITH NOINSERT` / `NOUPDATE` / `NODELETE` | `@noinsert` / `@noupdate` / `@nodelete` | Bloqueia; vale também por coluna (`'x' : t.col WITH NOUPDATE`) |
| `WITH NOCHECK` | `@nocheck` | Campo (ou tabela) **fora** do cálculo do ETag |
| `WITH CHECK` | `@check` | Campo no cálculo do ETag (comportamento padrão) |

Anotação na coluna prevalece sobre a da tabela.

Diretivas GraphQL do 26ai: `@array`, `@cast`, `@[no]check`, `@[no]delete`, `@flex`, `@nest`/`@unnest`, `@generated`, `@hidden`, `@[no]insert`, `@link`, `@object`, `@onnull`, `@[no]update`.

## ETag — optimistic concurrency

Cada documento tem `_metadata.etag`, calculado sobre os campos que não estão marcados com `NOCHECK`. O `_metadata` também traz `asof` (SCN). Ambos são gerenciados pelo banco: no INSERT o `_metadata` é ignorado.

Fluxo:
1. **GET** do documento → ETag `X1`
2. Aplicação altera o documento
3. **UPDATE** do documento completo com `"_metadata": {"etag": "X1"}`
4. Se o ETag atual for outro → **ORA-42699** (via REST: HTTP 412)
5. Em caso de conflito: reler e tentar de novo

Vantagens sobre `SELECT FOR UPDATE`: funciona em arquiteturas sem estado (REST, MongoDB API) e não segura lock entre requisições.

## Regras de DML

1. Toda duality view tem campo `_id` no nível superior.
2. **Não há regra de ordem de campos.** A doc diz que objetos JSON têm ordem de campos indefinida. A regra "`_id` primeiro, `_metadata` segundo" da v1 foi removida.
3. Em **update parcial** (`JSON_TRANSFORM`) o ETag não é enviado, então não há controle otimista.
4. Filho de um-para-muitos **sem** `DELETE`: as linhas não são apagadas; a FK delas recebe NULL.
5. Duality view exige PK/FK declaradas.

## GraphQL nativo no 26ai

Além da DDL, o 26ai tem a função de tabela `GRAPHQL()` para consultar tabelas com sintaxe GraphQL; ela retorna uma coluna `DATA` do tipo JSON. Documentada a partir do RU **23.26.0**, junto com a API de introspecção de schema GraphQL.

```sql
-- 26ai 23.26.0+
SELECT JSON_SERIALIZE(data PRETTY)
  FROM GRAPHQL('query { departamentos { id: id_departamento nome } }');
```

Use `GRAPHQL()` para **leitura ad hoc** em formato JSON. Use a duality view quando precisar de leitura **e** escrita com ETag.

## Acesso via ORDS e MongoDB API

- **ORDS AutoREST** de duality views: ORDS **23.1+** (release notes do ORDS 23.1). Detalhes de endpoint → `oracle-ords-ptbr`.
- **Oracle Database API for MongoDB** sobre duality views: só no 26ai ou superior; fora do Autonomous roda dentro do ORDS. Versão mínima do ORDS: **A VERIFICAR**.
- Com **Deep Data Security** (23.26.2+) a autorização do usuário final vale também para documentos de duality views — ver `ecossistema-ia-26ai.md`.

## Novidades 26ai por Release Update

| RU | Novidade |
|---|---|
| 23.26.0 | Melhorias na sintaxe GraphQL da DDL; `GRAPHQL()`; introspecção de schema |
| 23.26.2 | Inline Write Augmentation; Validation Directives |
| 23.26.3 | Array Limits; Deletable Shared Tables; User-Defined Identifying Keys |
| 23.26.4 | Inferência incremental de schema no JSON-to-Duality Migrator |
| 26ai (RU não identificado) | Campos `@hidden` e `@generated`, flex columns, JSON Collection Views, JSON-to-Duality Migrator, Notification Directives |

## Quando usar

✓ Clientes mistos (SQL e documento/MongoDB)
✓ Migração de MongoDB para Oracle preservando a interface de documento
✓ API REST simples sem abrir mão da normalização

✗ Aplicação 100% SQL com schema estável (complexidade sem ganho)
✗ Documentos muito profundos ou com arrays enormes — meça antes; considere **Array Limits** (23.26.3+)
✗ Muitos UPDATEs concorrentes no mesmo documento (conflito de ETag) — use `NOCHECK` nos campos não críticos

## Tipos relacionados de JSON

| Tipo | Leitura | Escrita | Armazenamento |
|---|---|---|---|
| JSON Relational Duality View | ✓ | ✓ (com ETag) | Relacional normalizado |
| JSON Collection Table | ✓ | ✓ | JSON nativo |
| JSON Collection View (26ai) | ✓ | ✗ | Relacional |

## Erros comuns

| Erro | Significado (Error Help 26ai) |
|---|---|
| `ORA-42699` | ETag do documento no banco diferente do ETag enviado |
| `ORA-40940` | Campo não pode ser atualizado: falta anotação UPDATE ou há NOUPDATE |
| `ORA-42692` | Erro de DML numa tabela-base da duality view (veja o erro aninhado) |
| `ORA-42693` | Na criação: tabela dependente não pode ter anotação DELETE |
| `ORA-42605` | A mesma linha da tabela foi modificada mais de uma vez |
| `ORA-42624` | Coluna inválida no ORDER BY de duality view |

## Documentação

- JSON-Relational Duality Developer's Guide 26ai: https://docs.oracle.com/en/database/oracle/oracle-database/26/jsnvu/
- Diretivas GraphQL: https://docs.oracle.com/en/database/oracle/oracle-database/26/jsnvu/oracle-supported-graphql-directives-json-relational-duality-views.html
- Função GRAPHQL: https://docs.oracle.com/en/database/oracle/oracle-database/26/gphql/graphql-table-function.html
- MongoDB API e duality: https://docs.oracle.com/en/database/oracle/mongodb-api/mgapi/duality.html
- Error Help: https://docs.oracle.com/en/error-help/db/ora-42699/
- oracle-base: https://oracle-base.com/articles/23/json-relational-duality-views-23 e https://oracle-base.com/articles/23/graphql-23
