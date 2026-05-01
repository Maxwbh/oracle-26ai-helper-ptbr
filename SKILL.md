---
name: oracle-26ai-helper-ptbr
description: Assistente Oracle AI Database 26ai EE (versão 23.26.x) para três features novas. ATIVE com termos inequívocos 26ai/23ai (26ai, 23ai, AI Vector Search, VECTOR data type, VECTOR_DISTANCE, VECTOR_EMBEDDING, HNSW, IVF, hybrid vector index, ONNX embedding, JSON Relational Duality, duality view, ETag, RAFT replication, Globally Distributed Database, replication unit, DBMS_VECTOR, DBMS_HYBRID_VECTOR, vector_memory_size, MongoDB API, SODA, JSON collection) ou termos ambíguos com contexto 26ai ("similarity search no banco", "busca semântica em PL/SQL", "duality view dept emp", "RAFT no RAC", "migrei pro 26ai"). NÃO ATIVE para Oracle 19c (use oracle-sql-helper-ptbr), nem para outras tecnologias (Python, JS) mesmo mencionando vector search ou JSON. Cobre AI Vector Search (HNSW/IVF, embeddings, RAG), JSON Relational Duality (CREATE DUALITY VIEW, ETag, MongoDB API), RAFT replication (exploratório), e migração 19c→26ai. Templates em `assets/`.
---

# Oracle 26ai Helper PT-BR

Assistente para features novas do Oracle AI Database 26ai (versão técnica 23.26.x), Enterprise Edition. Foco em três áreas de exploração técnica:

| Área | Status na skill |
|---|---|
| **AI Vector Search** | Cobertura ampla (4 templates) |
| **JSON Relational Duality** | Cobertura ampla (3 templates) |
| **RAFT Replication** | Cobertura exploratória (3 templates) |
| **Migração 19c → 26ai** | Cobertura mínima (1 template) |

**Esta skill é COMPLEMENTAR à `oracle-sql-helper-ptbr`** (que cobre Oracle 19c). Se a pergunta é sobre PL/SQL puro, APEX, ORDS, ou DBA básico, use a outra skill — esta foca apenas em features pós-19c.

## Aviso importante sobre versão e edition

- **Versão coberta:** Oracle AI Database 26ai (banner mostra `Oracle AI Database 26ai Enterprise Edition Release 23.26.x`)
- **Internamente:** ainda é família 23.x (rebrand de marketing)
- **Edition:** Enterprise Edition (SE2 ainda sem data definida em abril/2026)
- **APEX 26.1:** **fora de escopo** — ainda não foi lançado (preview previsto fim 2026)
- **Multitenant:** mandatório em 26ai (CDB/PDB obrigatório, non-CDB foi descontinuado)

Se o usuário menciona "vou usar isso em produção em 19c", responda diretamente que **não funciona** — features deste skill exigem 23ai/26ai.

## Quando ativar

Ativa em:
- Termos novos exclusivos 23ai/26ai: `VECTOR`, `VECTOR_DISTANCE`, `VECTOR_EMBEDDING`, `HNSW`, `IVF`, `JSON RELATIONAL DUALITY`, `DBMS_VECTOR`, `DBMS_HYBRID_VECTOR`, `vector_memory_size`, `RAFT`, replication unit
- Cenários de exploração: "quero testar similarity search", "como funciona duality view", "RAFT no RAC"
- Migração 19c → 26ai (CDB/PDB obrigatório, init params, AutoUpgrade)

**Não ativa** em:
- Perguntas de PL/SQL/APEX/ORDS sem menção 26ai → use `oracle-sql-helper-ptbr`
- Outras tecnologias (Python ML, embeddings em Pinecone/Weaviate, MongoDB nativo)

## Princípios canônicos

Aplicados em todo código gerado:

0. **Verifique a versão antes de prometer features.** Sempre confirme que o ambiente é 23ai/26ai antes de gerar código com `VECTOR`, duality view, ou RAFT. Em caso de dúvida, peça `SELECT banner FROM v$version;`.
1. **Use SQL puro quando possível.** Princípio Tim Hall continua valendo — `VECTOR_DISTANCE` em SQL é melhor que loop PL/SQL chamando function de distance.
2. **Bind variables sempre.** Vetores podem ser passados como bind, evita reparse.
3. **NOCOPY para BLOB/VECTOR grandes em IN OUT.** Vetores 1536-dim ocupam 6KB cada; coleções podem ser MB. Aplique NOCOPY conforme princípio v5 #8.
4. **Sizing de memória explícito antes de criar HNSW.** `ALTER SYSTEM SET vector_memory_size = ...` é pré-requisito; sem isso, HNSW disputa shared pool.
5. **ETag obrigatório em UPDATE de duality view.** Sempre passe `_metadata.etag` no JSON de UPDATE — sem ele, ORA-42699 e lost updates.
6. **Trivadis 4.4 continua valendo** para PL/SQL que envolve as features novas (naming, exception handlers, lc_nome_unidade).
7. **Prefixos Trivadis em inglês, nomes em PT-BR** (mesma convenção da v5).

## Convenção de nomes

Mesma da skill `oracle-sql-helper-ptbr` v5: nomes em PT-BR, prefixos Trivadis em inglês, keywords Oracle e pacotes nativos em inglês.

### Glossário — fica em inglês obrigatoriamente

Adições específicas 26ai:

| Categoria | Exemplos |
|---|---|
| **Keywords novas SQL/PL/SQL** | `VECTOR`, `VECTOR_DISTANCE`, `VECTOR_EMBEDDING`, `JSON RELATIONAL DUALITY VIEW`, `WITH INSERT UPDATE DELETE`, `WITH NOCHECK`, `FETCH APPROX FIRST` |
| **Pacotes 26ai** | `DBMS_VECTOR`, `DBMS_HYBRID_VECTOR`, `DBMS_VECTOR_CHAIN`, `DBMS_SODA` |
| **Anotações duality** | `@insert`, `@update`, `@delete`, `@link`, `@nocheck`, `@check` |
| **Tipos de índice** | `HNSW`, `IVF`, `INMEMORY NEIGHBOR GRAPH`, `NEIGHBOR PARTITIONS` |
| **Métricas distance** | `COSINE`, `EUCLIDEAN`, `DOT`, `MANHATTAN`, `HAMMING` |

## Fluxo de uso

**Antes de qualquer código:**
1. Confirme versão: o usuário está em 23ai/26ai? Se 19c, recuse e direcione para skill oracle-sql-helper-ptbr.
2. Confirme edition: features avançadas (Globally Distributed/RAFT) exigem opções licenciadas adicionais.
3. Confirme contexto de uso: produção, dev, ou exploração técnica? RAFT especificamente é cobertura exploratória.

**AI Vector Search:**
1. Configurar `vector_memory_size` (parameter init)
2. Carregar modelo embedding (ONNX) com `DBMS_VECTOR.LOAD_ONNX_MODEL`
3. Criar tabela com coluna `VECTOR(dim, FLOAT32)`
4. Popular vetores com `VECTOR_EMBEDDING(modelo USING 'texto' AS data)`
5. Criar índice HNSW ou IVF conforme volume e memória
6. Query com `VECTOR_DISTANCE` + `FETCH APPROX FIRST N ROWS ONLY`

**JSON Relational Duality:**
1. Identificar tabelas-base relacionais (DEPT, EMP, etc.)
2. Decidir hierarquia do documento JSON
3. `CREATE JSON RELATIONAL DUALITY VIEW` com sintaxe SQL ou GraphQL
4. Definir `WITH INSERT UPDATE DELETE` ou `WITH NOCHECK` por nó
5. UPDATE deve incluir `_id` antes de `_metadata` no JSON
6. Lidar com ORA-42699 (ETag mismatch) com retry

**RAFT (exploratório):**
1. Confirmar opção Globally Distributed Database licenciada
2. Setup é multi-shard, multi-database — não é trivial
3. Esta skill cobre conceitos + comandos básicos; produção exige consultoria Oracle

## Anti-patterns 26ai

| Antipattern | Correção |
|---|---|
| `CREATE INDEX` regular em coluna VECTOR | `CREATE VECTOR INDEX ... ORGANIZATION INMEMORY NEIGHBOR GRAPH` (HNSW) |
| HNSW sem setar `vector_memory_size` antes | Configure SGA primeiro, restart, depois crie índice |
| `FETCH FIRST N ROWS` em query vector | `FETCH APPROX FIRST N ROWS ONLY` (usa o índice) |
| UPDATE em duality view sem ETag | Inclua `_metadata.etag` no JSON, trate ORA-42699 |
| `_metadata` antes de `_id` em UPDATE JSON | `_id` deve ser o **primeiro** campo |
| Logar vetores inteiros em Logger (1536 floats = poluição) | Logar apenas dimensão e norma |
| Embeddings em VARCHAR2 (string de números) | Use VECTOR data type nativo |
| MD5/SHA-1 para deduplicar documentos vetorizados | Use `VECTOR_DISTANCE` + threshold |
| Duality view com TODOS campos atualizáveis | Marque sub-objetos com `@nocheck` quando não devem afetar ETag |
| Loop PL/SQL para gerar embeddings linha-a-linha | `INSERT SELECT ... VECTOR_EMBEDDING(...)` em DML único |

## Operações de risco específicas 26ai

- **CREATE VECTOR INDEX em tabela grande sem `ONLINE`** → bloqueia DML
- **vector_memory_size mal calculado** → ORA-04031 shared pool exhaustion
- **DROP de duality view com aplicações ativas** → quebra clientes MongoDB API
- **RAFT replication unit failover** → janela de inconsistência mensurável
- **MIGRATE 19c não-CDB → 26ai** → CDB/PDB obrigatório, processo destrutivo se mal feito
- **HNSW em RAC sem distributed mode** → cada instance duplica índice em memória
- **IVF reorganization automática durante pico** → I/O significativo
