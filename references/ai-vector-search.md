# AI Vector Search — Reference

Conceitos e padrões para Oracle AI Database 26ai.

## VECTOR data type

Tipo nativo, introduzido em 23ai. Sintaxe:
```
VECTOR(dimensoes, formato)
```

- **dimensoes**: número fixo (384, 768, 1024, 1536, 3072) ou `*` (qualquer)
- **formato**: `FLOAT32` (default), `FLOAT64`, `INT8`, `BINARY`

Storage:
- FLOAT32: 4 bytes/dim → 384-dim = 1.5 KB/row
- FLOAT64: 8 bytes/dim → 384-dim = 3 KB/row
- INT8: 1 byte/dim → 384-dim = 384 bytes/row (com perda)
- BINARY: 1 bit/dim → 384-dim = 48 bytes/row (binário, hashing-like)

Recomendação: FLOAT32 default, FLOAT64 só se precisão extrema, INT8 com scalar quantization para memória.

## Métricas de distância

| Métrica | Caso de uso | Range |
|---|---|---|
| `COSINE` | Texto, embeddings normalizados | [0, 2] (0 = idêntico) |
| `EUCLIDEAN` | Coordenadas espaciais, vetores brutos | [0, ∞) |
| `DOT` | Quando vetores não-normalizados, importância de magnitude | (-∞, ∞) |
| `MANHATTAN` | Discretas, grids | [0, ∞) |
| `HAMMING` | BINARY vectors, hashing | [0, dim] |

**Padrão para texto:** COSINE. Embeddings de modelos de linguagem (BERT, Sentence Transformers) são normalmente normalizados, então COSINE é equivalente a 1 - DOT mas mais intuitivo.

## Pacotes PL/SQL

| Pacote | Uso |
|---|---|
| `DBMS_VECTOR` | Operações high-level: load model, generate embeddings, generate text via LLM |
| `DBMS_VECTOR_CHAIN` | Pipeline: chunking, embedding, generation com REST APIs externas |
| `DBMS_HYBRID_VECTOR` | Search híbrida texto + vector com API simplificada |
| `DBMS_DATA_MINING` | Modelos de ML clássicos (continua funcionando em 26ai) |

## Modelos de embedding recomendados

Para PT-BR forense ou jurídico:

1. **multilingual-e5-large** (1024-dim, 96 idiomas incluindo PT)
2. **BGE-m3** (1024-dim, multilíngue, performance forte em PT-BR)
3. **Cohere Embed Multilingual v3** (1024-dim, comercial)
4. **OpenAI text-embedding-3-large** (3072-dim, comercial)

Modelos pequenos (para teste/lab):
- **all-MiniLM-L12-v2** (384-dim, inglês principalmente)
- **paraphrase-multilingual-MiniLM-L12-v2** (384-dim, multilíngue)

## Quando usar índice vs exhaustive

| Volume | Recomendação |
|---|---|
| < 1.000 | Sem índice (exhaustive < 100ms) |
| 1k - 10k | HNSW (memória trivial) |
| 10k - 1M | HNSW se cabe em memória, IVF caso contrário |
| 1M - 100M | IVF, considerar partitioning |
| > 100M | IVF locally partitioned + tabela particionada |

## Sizing Vector Memory Pool

Fórmula:
```
bytes ≈ dimensoes × 4 (FLOAT32) × num_linhas × 1.3 (overhead grafo HNSW)
```

Exemplos:
- 1536-dim, 1M linhas → 8 GB
- 1536-dim, 10M linhas → 80 GB
- 384-dim, 1M linhas → 2 GB
- 384-dim, 100k linhas → 200 MB

Configurar via:
```sql
ALTER SYSTEM SET vector_memory_size = 8G SCOPE = SPFILE;
-- restart obrigatório
```

## Padrão RAG canônico

1. **Ingestion**: chunk documentos → gerar embeddings → armazenar
2. **Retrieval**: pergunta → embedding da pergunta → similarity search → top-K chunks
3. **Augmented Prompt**: pergunta + chunks como contexto → prompt para LLM
4. **Generation**: LLM responde citando chunks

Decisões críticas:
- Tamanho de chunk: 100-500 palavras típico, com 10-20% overlap
- Top-K: 3-7 chunks (mais que isso confunde LLM)
- Threshold de distância: 0.3-0.5 para COSINE
- Temperature do LLM: 0.0-0.3 para RAG factual

## Documentação oficial

- Vector Search User's Guide: https://docs.oracle.com/en/database/oracle/oracle-database/26/vecse/
- DBMS_VECTOR Reference: https://docs.oracle.com/en/database/oracle/oracle-database/26/arpls/dbms_vector.html
- LiveLabs: "Oracle AI Vector Search"
