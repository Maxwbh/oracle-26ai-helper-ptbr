# AI Vector Search — Reference

Conceitos e padrões para Oracle AI Database 26ai. Revisado em nov/2026 contra a documentação 26ai (RU 23.26.4). Itens sem fonte confirmada estão marcados **A VERIFICAR**.

## Índice

- [VECTOR data type](#vector-data-type)
- [Métricas de distância](#métricas-de-distância)
- [Pacotes PL/SQL](#pacotes-plsql)
- [Índices: HNSW, IVF e híbrido](#índices-hnsw-ivf-e-híbrido)
- [Vector Pool (vector_memory_size)](#vector-pool-vector_memory_size)
- [Novidades por Release Update](#novidades-por-release-update)
- [Modelos de embedding](#modelos-de-embedding)
- [Padrão RAG canônico](#padrão-rag-canônico)
- [Edição Free](#edição-free)
- [Documentação oficial](#documentação-oficial)

## VECTOR data type

Tipo nativo desde 23ai:

```sql
-- 26ai
VECTOR(dimensoes, formato [, DENSE | SPARSE])
```

- **dimensoes**: número fixo ou `*`; máximo 65.535 (65.528 para BINARY; BINARY exige múltiplo de 8)
- **formato**: `INT8`, `FLOAT32`, `FLOAT64`, `BINARY`
- **SPARSE** (23.6+, `COMPATIBLE` ≥ 23.6.0): IVF não pode ser criado sobre SPARSE; HNSW sobre SPARSE desde 23.9

Storage aproximado por linha (dimensões × bytes do formato): FLOAT32 = 4 bytes/dim, FLOAT64 = 8, INT8 = 1, BINARY = 1 bit/dim.

## Métricas de distância

| Métrica | Observação (SQL Reference 26ai, `VECTOR_DISTANCE`) |
|---|---|
| `COSINE` | Default. Distância = 1 − cos(α) |
| `DOT` | Produto escalar negado |
| `EUCLIDEAN` / `EUCLIDEAN_SQUARED` (`L2_SQUARED`) | Distância euclidiana (ou ao quadrado) |
| `MANHATTAN` | Soma das diferenças absolutas |
| `HAMMING` | Default para vetores BINARY |
| `JACCARD` | Exige vetores BINARY |

Operadores abreviados: `<->` (euclidiana), `<=>` (cosseno), `<#>` (dot negado). Métrica customizada em JavaScript (MLE) desde 23.8.

**Padrão para texto:** COSINE.

## Pacotes PL/SQL

| Pacote | Uso |
|---|---|
| `DBMS_VECTOR` | `LOAD_ONNX_MODEL`, `LOAD_ONNX_MODEL_CLOUD`, `CREATE_INDEX`, `REBUILD_INDEX`, `UTL_TO_EMBEDDING(S)`, `UTL_TO_GENERATE_TEXT`, `CREATE_CREDENTIAL` |
| `DBMS_VECTOR_CHAIN` | Pipeline: `UTL_TO_TEXT`, `UTL_TO_CHUNKS`, `UTL_TO_EMBEDDING(S)`, `UTL_TO_GENERATE_TEXT`, `CREATE_PREFERENCE` |
| `DBMS_HYBRID_VECTOR` | `SEARCH(json)` — busca híbrida texto + vetor sobre hybrid vector index; retorna CLOB |
| `DBMS_AI_GRAPHRAG` | GraphRAG (23.26.4+) |

Não existe `DBMS_VECTOR.GENERATE`: geração de texto é `UTL_TO_GENERATE_TEXT`.

Provedores de embedding em `UTL_TO_EMBEDDING`: `cohere`, `googleai`, `huggingface`, `ocigenai`, `openai`, `vertexai`, `mistralai`, `ollama`, `privateai`, ou `database` (modelo ONNX no banco). Credencial OpenAI: `{"access_token": "..."}`; as chaves `user_ocid`/`tenancy_ocid`/`private_key`/`fingerprint` são só do `ocigenai`.

## Índices: HNSW, IVF e híbrido

| | HNSW | IVF |
|---|---|---|
| Organização | `INMEMORY NEIGHBOR GRAPH` (no Vector Pool) | `NEIGHBOR PARTITIONS` (em disco) |
| Parâmetros | `NEIGHBORS` (2–2048), `EFCONSTRUCTION` (1–65535) | `NEIGHBOR PARTITIONS`, `SAMPLES_PER_PARTITION`, `MIN_VECTORS_PER_PARTITION` |
| Quantização | `QUANTIZATION SCALAR COMPRESSION RATIO {2\|4\|8}` (23.26.1+); `PRODUCT` (23.26.4+) | Scalar quantized global IVF (23.26.4+) |
| ONLINE | `CREATE … ONLINE` desde 23.26.1 (não para HNSW local, distribuído ou com colunas incluídas) | `ALTER INDEX … REBUILD ONLINE` |
| Rebuild | `DBMS_VECTOR.REBUILD_INDEX` (ALTER INDEX não é suportado em HNSW) | `ALTER INDEX … REBUILD ONLINE [PARAMETERS (…)]` |
| Local (tabela particionada) | 23.26.2+; DML na tabela-base gera erro depois de criado | `LOCAL` |

- Defaults de `NEIGHBORS`/`EFCONSTRUCTION`: não documentados — **não** assuma valores.
- Target accuracy default: 90 em `DBMS_VECTOR.CREATE_INDEX`.
- IVF: partições "tipicamente √n" (texto informativo da doc, não default formal).
- Busca aproximada: `FETCH APPROX FIRST n ROWS ONLY [WITH TARGET ACCURACY n]`.

**Hybrid vector index** (23.6+), criado sobre a coluna de texto:

```sql
-- 26ai (23.6+)
CREATE HYBRID VECTOR INDEX idx_doc_hibrido
    ON documentos (conteudo)
    PARAMETERS ('MODEL modelo_onnx VECTOR_IDXTYPE HNSW');
```

`VECTOR_IDXTYPE` aceita IVF (default) ou HNSW. `MODEL` só aceita modelo ONNX no banco; a alternativa é `VECTORIZER` com preferência criada em `DBMS_VECTOR_CHAIN.CREATE_PREFERENCE`.

### Volume × índice

A doc não traz tabela de corte por volume. Regra prática: HNSW quando o índice cabe no Vector Pool; IVF quando não cabe ou a tabela é particionada.

Memória do HNSW, pela fórmula da doc ("Size the Vector Pool"): `1.3 × nº de vetores × dimensões × bytes do formato`. Exemplo: 1M vetores × 384 dim × 4 bytes (FLOAT32) × 1.3 ≈ 2 GB. Para estimar com os dados reais, use `DBMS_VECTOR.INDEX_VECTOR_MEMORY_ADVISOR`.

## Vector Pool (vector_memory_size)

- Default 0; range 0–70% da SGA; **dinâmico** (`ALTER SYSTEM … SCOPE=BOTH`) e modificável no PDB.
- No CDB: tamanho do pool. No PDB: cota máxima.
- `1` com `sga_target > 0`: auto-sizing (on-prem desde 23.8).
- HNSW mora no pool; IVF usa o pool só para acelerar a criação (sem espaço, centróides vão para a large pool).

## Novidades por Release Update

| RU | Destaques Vector |
|---|---|
| 23.6 | SPARSE, hybrid vector index + `DBMS_HYBRID_VECTOR`, JACCARD, IVF global/local, `INDEX_VECTOR_MEMORY_ADVISOR`, `UTL_TO_RERANK`, Ollama |
| 23.7 | Vetores em external tables, aritmética e SUM/AVG de vetores, included columns em IVF |
| 23.8 | Distância customizada em JavaScript, auto-sizing do pool on-prem, `SEARCHPIPELINE`, `GET_SQL` |
| 23.9 | Reorganização online de IVF, HNSW sobre SPARSE, `ALTER INDEX` em hybrid index |
| 23.26.1 | HNSW distribuído em RAC, criação ONLINE, HNSW scalar quantized, included columns em HNSW, auto-reorg IVF, modelos ONNX maiores |
| 23.26.2 | HNSW local, HNSW function-based, multi-vector com IVF, `VECTOR_ORIGIN`/`VECTOR_RANDOM` |
| 23.26.3 | Scalar quantization em HNSW distribuído |
| 23.26.4 | HNSW product quantized, multi-vector com HNSW, GraphRAG (`DBMS_AI_GRAPHRAG`), IVF scalar quantized |

Fonte: AI Vector Search User's Guide 26ai, páginas "What's New" por RU.

## Modelos de embedding

Sugestões para PT-BR (não são recomendação da Oracle; conferir licença e dimensão de cada modelo):

- Multilíngues: multilingual-e5, BGE-m3, paraphrase-multilingual-MiniLM
- Comerciais via provedor: Cohere Embed Multilingual, OpenAI text-embedding-3
- Para ONNX no banco, use o modelo pré-aumentado que a Oracle publica ou converta com OML4Py

## Padrão RAG canônico

1. **Ingestão:** `UTL_TO_TEXT` → `UTL_TO_CHUNKS` → `UTL_TO_EMBEDDINGS` → tabela com coluna VECTOR
2. **Recuperação:** embedding da pergunta → `VECTOR_DISTANCE` + `FETCH APPROX FIRST k`
3. **Prompt aumentado:** pergunta + chunks recuperados
4. **Geração:** `UTL_TO_GENERATE_TEXT`, citando os chunks

`UTL_TO_CHUNKS`: `by` = `characters`/`chars`, `words` (default) ou `vocabulary`; `max` default 100; `overlap` de 5% a 20% de `max`; `split` = `recursively` (default), `sentence` ou `custom`.

Tamanho de chunk, top-K, limiar de distância e temperature são ajustes empíricos do seu corpus: meça com um conjunto de perguntas de teste antes de fixar valores.

Segurança: com **Deep Data Security** (23.26.2+) a autorização por linha/coluna vale também para os chunks recuperados — ver `ecossistema-ia-26ai.md`.

## Edição Free

O 26ai Free roda com 2 cores, 2 GB de RAM e 12 GB de dados de usuário. O Licensing Information User Manual 26ai **não** tem linha explícita para AI Vector Search no Free (**A VERIFICAR** no FAQ do Free); Oracle Machine Learning não exige licença extra. O Vector Pool precisa caber nos 2 GB. Tabela por template em `assets/README.md`.

## Documentação oficial

- AI Vector Search User's Guide: https://docs.oracle.com/en/database/oracle/oracle-database/26/vecse/
- DBMS_VECTOR: https://docs.oracle.com/en/database/oracle/oracle-database/26/arpls/dbms_vector1.html
- DBMS_VECTOR_CHAIN: https://docs.oracle.com/en/database/oracle/oracle-database/26/arpls/dbms_vector_chain1.html
- DBMS_HYBRID_VECTOR: https://docs.oracle.com/en/database/oracle/oracle-database/26/arpls/dbms_hybrid_vector1.html
- CREATE HYBRID VECTOR INDEX: https://docs.oracle.com/en/database/oracle/oracle-database/26/ccref/create-hybrid-vector-index.html
- VECTOR_MEMORY_SIZE: https://docs.oracle.com/en/database/oracle/oracle-database/26/refrn/VECTOR_MEMORY_SIZE.html
- VECTOR_DISTANCE: https://docs.oracle.com/en/database/oracle/oracle-database/26/sqlrf/vector_distance.html
