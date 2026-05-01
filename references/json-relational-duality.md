# JSON Relational Duality — Reference

Conceitos e padrões para Oracle AI Database 23ai/26ai.

## O que é

JSON Relational Duality é uma capacidade que **expõe dados relacionais como documentos JSON** sem duplicação. Storage = relacional normalizado; Access = JSON ou SQL, escolha do cliente.

Não confundir com:
- **Native JSON storage** (coluna JSON em tabela): JSON é o storage também
- **JSON Collection Tables**: tabela com 1 coluna JSON (document store puro)
- **JSON Collection Views**: read-only sobre relacional
- **Duality Views**: read-write, sincronização bidirecional automática

## Sintaxes

Duas sintaxes equivalentes:

### SQL (verbosa, familiar)
```sql
CREATE OR REPLACE JSON RELATIONAL DUALITY VIEW dept_dv AS
SELECT JSON {
  '_id'      : d.deptno,
  'nome'     : d.dname,
  'employees': [
    SELECT JSON {
      'idEmployee' : e.empno,
      'nome'       : e.ename
    }
      FROM emp e WITH INSERT UPDATE DELETE
     WHERE d.deptno = e.deptno
  ]
}
  FROM dept d WITH INSERT UPDATE DELETE;
```

### GraphQL (concisa, moderna)
```sql
CREATE OR REPLACE JSON RELATIONAL DUALITY VIEW dept_dv AS
dept @insert @update @delete {
  _id       : deptno,
  nome      : dname,
  employees : emp @insert @update @delete
                  @link (to: ["deptno"]) [{
    idEmployee : empno,
    nome       : ename
  }]
};
```

Ambas geram view idêntica. Use a que preferir; equipes vindas de NoSQL geralmente preferem GraphQL.

## Anotações de DML

| Anotação SQL | GraphQL | Significado |
|---|---|---|
| `WITH INSERT` | `@insert` | Permite criar via duality |
| `WITH UPDATE` | `@update` | Permite alterar via duality |
| `WITH DELETE` | `@delete` | Permite excluir via duality |
| `WITH NOINSERT` | `@noinsert` | Bloqueia INSERT |
| `WITH NOUPDATE` | `@noupdate` | Bloqueia UPDATE |
| `WITH NODELETE` | `@nodelete` | Bloqueia DELETE |
| `WITH NOCHECK` | `@nocheck` | Mudanças NÃO afetam ETag (otimização concorrência) |
| `WITH CHECK` | `@check` | Default — mudanças afetam ETag |

## ETag — optimistic concurrency

Cada documento tem `_metadata.etag` = hash do conteúdo das colunas que contribuem para ETag (excluindo `@nocheck`).

Fluxo:
1. **GET** documento → recebe ETag `X1`
2. Aplicação modifica
3. **PUT** com ETag `X1`
4. Banco verifica: ainda é `X1`? Se sim, aplica e gera novo ETag `X2`. Se não, **ORA-42699**.
5. Em mismatch, aplicação re-fetch e retry

Vantagens vs SELECT FOR UPDATE:
- Funciona em arquiteturas stateless (REST, MongoDB API)
- Sem lock holding entre requests
- Escala melhor

## Regras críticas de DML

1. **`_id` deve ser PRIMEIRO campo no JSON do UPDATE.** Se `_metadata` aparece antes, erro.
2. **`_metadata` deve ser segundo.** Padrão: `{"_id": ..., "_metadata": {...}, ...resto...}`
3. **ETag value é string plana, sem aspas escapadas internas.**
4. **Campo omitido em UPDATE preserva valor anterior.** Não precisa enviar JSON completo.
5. **Sub-array omitido em UPDATE com WITH DELETE → rows deletadas.** Cuidado.

## Acesso via MongoDB API

Duality views são automaticamente expostas via MongoDB API (com ORDS):

```javascript
// Cliente MongoDB conectando em duality view dept_dv
const dept = db.collection('DEPT_DV');

// findOne
const doc = await dept.findOne({_id: 10});

// updateOne com ETag implícito
await dept.replaceOne({_id: 10, _metadata: doc._metadata}, novoDoc);
```

ORDS em 24.1+ tem AutoREST que gera endpoints REST completos a partir de duality views.

## Quando usar

✓ Aplicação tem clientes mistos (alguns via SQL, outros via MongoDB driver)
✓ Migração de MongoDB para Oracle preservando interface document
✓ Simplificar API REST sem sacrificar normalização
✓ Acesso "objeto-relacional" sem ORM complexo

✗ Aplicação 100% SQL com schema estável (overhead desnecessário)
✗ Hierarquias muito profundas (3+ níveis)
✗ Sub-arrays gigantes (1000+ items por documento)
✗ Workload com taxa de UPDATE > 1000/s na mesma row (ETag collisions)

## Tipos relacionados de JSON

Em 23ai/26ai há 3 tipos de JSON Collections:

| Tipo | Read | Write | Storage | Use case |
|---|---|---|---|---|
| **JSON Relational Duality View** | ✓ | ✓ (com ETag) | Relacional normalizado | Híbrido |
| **JSON Collection Table** | ✓ | ✓ (raw JSON) | JSON nativo | Document store puro |
| **JSON Collection View** | ✓ | ✗ | Relacional | Read-only API |

Documentação:

- JSON Developer's Guide: https://docs.oracle.com/en/database/oracle/oracle-database/26/adjsn/
- JSON-Relational Duality Developer's Guide: https://docs.oracle.com/en/database/oracle/oracle-database/26/jsnvu/
- Oracle Database API for MongoDB: https://docs.oracle.com/en/database/oracle/mongodb-api/

## Erros comuns

| Erro | Causa |
|---|---|
| `ORA-42692` | Tentou DML mas anotação é NOINSERT/NOUPDATE/NODELETE |
| `ORA-42699` | ETag mismatch — concorrência |
| `ORA-42624` | Field `_id` ausente ou inválido |
| `ORA-42693` | DELETE de sub-row em sub-array NODELETE |
| `ORA-40769` | View já existe; use CREATE OR REPLACE |
