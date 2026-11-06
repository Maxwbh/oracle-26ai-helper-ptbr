--==============================================================================
-- Template: AI Vector Search — Fundamentos
--
-- Cobre: VECTOR data type, carregar modelo ONNX, gerar embeddings,
--        similarity search (exata, sem índice), métricas de distância.
--
-- Pré-requisito: Oracle AI Database 26ai (banner mostra "AI Database").
--                Em 19c não funciona — VECTOR e VECTOR_EMBEDDING não existem.
--
-- Revisado: nov/2026 contra a documentação Oracle AI Database 26ai (RU 23.26.4)
-- Testado: 26ai Free 23.26.3 (nov/2026), SQL*Plus — sem erros (ONNX all_MiniLM_L12_v2 oficial)
-- Tipo: Dependente de configuração — exige o arquivo ONNX no servidor (DIRECTORY) e Vector Pool para HNSW
-- RU mínimo: 23.26.0 (qualquer 26ai); blocos de RU específico marcados no código
-- Edição Free: Parcial — VECTOR, ONNX e busca exata cabem no Free, mas o guia
--              de licenciamento não cita Vector Search explicitamente para o
--              Free (OML/ONNX sem custo extra) e o limite de 2 GB de RAM
--              restringe o tamanho do modelo e do vector pool.
--
-- Ver também (suíte https://github.com/Maxwbh/oracle-skills-ptbr):
--   oracle-lab-ptbr   → montar o 26ai Free local para testar este template
--   oracle-plsql-ptbr → PL/SQL 19c (o que NÃO é específico de 26ai)
--
-- Verificação inicial obrigatória:
--   SELECT banner_full FROM v$version;
--   -- Espera: "Oracle AI Database 26ai ... Release 23.26.x.x.x"
--==============================================================================


--==============================================================================
-- 1. Setup: Vector Pool (como SYS) — só é necessário para índices vetoriais
--
-- Busca exata (seção 6) NÃO usa o vector pool. Ele é exigido para criar
-- índices HNSW (o grafo fica inteiro no pool) e acelera criação/DML de IVF
-- (centróides em cache; se faltar espaço, vão para o large pool).
--
-- Comportamento medido no 26ai Free 23.26.3 (nov/2026):
--   - CDB com pool 0 no startup: aumentar exige SCOPE=SPFILE + restart
--     (sem restart → ORA-51950 "cannot be increased")
--   - CDB com pool alocado no startup: CRESCE dinamicamente; não reduz abaixo
--     do valor inicial (ORA-51953); um resize de cada vez (ORA-51957)
--   - PDB: cota dinâmica (SCOPE=BOTH), limitada ao pool do CDB (ORA-51955)
--==============================================================================

-- 26ai
-- Regra de sizing para HNSW (fórmula da doc Oracle):
--   bytes ≈ 1,3 × num_vetores × dimensoes × bytes_por_dimensao (FLOAT32 = 4)
-- Exemplo: 1536-dim, 10M linhas → ~80 GB
-- Exemplo: 384-dim, 100k linhas  → ~200 MB
-- Para uma estimativa calculada pelo próprio banco, use
-- DBMS_VECTOR.INDEX_VECTOR_MEMORY_ADVISOR (ver ai_vector_index_strategies.sql).

-- Confirmar que pode ser alterado no PDB
SELECT name, ispdb_modifiable
  FROM v$system_parameter
 WHERE name = 'vector_memory_size';

-- Passo 1 — no CDB$ROOT (só se o pool estiver em 0): grava no SPFILE e
-- reinicia a instância. Em produção, planeje a janela.
--   ALTER SESSION SET CONTAINER = CDB$ROOT;
--   ALTER SYSTEM SET vector_memory_size = 512M SCOPE = SPFILE;
--   SHUTDOWN IMMEDIATE
--   STARTUP
--   ALTER PLUGGABLE DATABASE ALL OPEN;

-- Passo 2 — conectado no PDB: cota do PDB (dinâmica, ≤ pool do CDB)
ALTER SYSTEM SET vector_memory_size = 256M SCOPE = BOTH;

-- 26ai (23ai 23.8+): alternativa de pool auto-gerenciado —
-- VECTOR_MEMORY_SIZE = 1 no CDB com SGA_TARGET > 0 na inicialização faz o pool
-- crescer sob demanda na criação de HNSW (máx. 70% do SGA_TARGET do PDB).
-- Nesse modo o crescimento não é persistido no SPFILE.

-- Confirmar
SELECT name, value
  FROM v$parameter
 WHERE name = 'vector_memory_size';

-- 26ai — monitorar o pool (ALLOC_BYTES fica 0 até existir um índice HNSW)
SELECT con_id, pool,
       alloc_bytes / 1024 / 1024 AS alloc_mb,
       used_bytes  / 1024 / 1024 AS used_mb
  FROM v$vector_memory_pool
 ORDER BY con_id, pool;


--==============================================================================
-- 2. Setup do schema de exploração (executar uma vez, como SYS no PDB)
--==============================================================================

-- Tablespace dedicado. "DATAFILE SIZE" sem caminho exige OMF
-- (DB_CREATE_FILE_DEST definido); sem OMF → ORA-02236. No container do 26ai
-- Free o OMF vem vazio: informe o caminho do arquivo.
--   SELECT value FROM v$parameter WHERE name = 'db_create_file_dest';
-- Com OMF:
--   CREATE BIGFILE TABLESPACE tbs_vector DATAFILE SIZE 256M AUTOEXTEND ON MAXSIZE 2G;
-- Sem OMF (caminho do container 26ai Free; ajuste ao seu ambiente):
CREATE BIGFILE TABLESPACE tbs_vector
  DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/tbs_vector01.dbf'
  SIZE 256M AUTOEXTEND ON MAXSIZE 2G;

-- Senha: NUNCA fica no script. Informe em tempo de execução (SQLcl/SQL*Plus)
-- ou use o cofre de senhas do ambiente. Não reaproveite este usuário fora do
-- laboratório.
ACCEPT senha_usuario_vetor CHAR PROMPT 'Senha para USUARIO_VETOR: ' HIDE

CREATE USER usuario_vetor IDENTIFIED BY "&senha_usuario_vetor"
  DEFAULT TABLESPACE tbs_vector
  TEMPORARY TABLESPACE TEMP
  QUOTA 2G ON tbs_vector;

UNDEFINE senha_usuario_vetor

-- Privilégios MÍNIMOS para este template (tabelas, índices no próprio schema,
-- packages/procedures e o modelo ONNX)
-- exigido para LOAD_ONNX_MODEL
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW,
      CREATE SEQUENCE, CREATE PROCEDURE TO usuario_vetor;
GRANT CREATE MINING MODEL TO usuario_vetor;
-- Alternativa só para laboratório pessoal: DB_DEVELOPER_ROLE (23ai+) concede
-- bem mais do que este template precisa — evite em ambientes compartilhados.

-- Diretório (no servidor do banco) de onde o modelo ONNX será lido.
-- LOAD_ONNX_MODEL só LÊ o arquivo: conceda READ, não WRITE.
CREATE OR REPLACE DIRECTORY dir_modelos AS '/home/oracle/embedding_models';
GRANT READ ON DIRECTORY dir_modelos TO usuario_vetor;


--==============================================================================
-- 3. Carregar modelo ONNX no banco
--
-- Opções para obter o arquivo .onnx:
--   a) Modelo pré-construído all-MiniLM-L12-v2 que a Oracle disponibiliza
--      (all-MiniLM-L12-v2_augmented.zip → all_MiniLM_L12_v2.onnx) — o link
--      está em "SQL Quick Start Using a Vector Embedding Model Uploaded into
--      the Database", AI Vector Search User's Guide 26ai.
--   b) Converter um modelo Hugging Face com OML4Py — ver "Convert Pretrained
--      Models to ONNX Model: End-to-End Instructions" no mesmo guia.
--==============================================================================

-- 26ai — como usuario_vetor
-- Modelos convertidos pelo OML4Py (como o pré-construído) já trazem a
-- convenção de entrada/saída e dispensam o parâmetro metadata.
BEGIN
  DBMS_VECTOR.LOAD_ONNX_MODEL(
    directory   => 'DIR_MODELOS',
    file_name   => 'all_MiniLM_L12_v2.onnx',
    model_name  => 'modelo_minilm_l12'
  );
END;
/

-- Verificar carregamento (ALGORITHM = ONNX, MINING_FUNCTION = EMBEDDING)
SELECT model_name, algorithm, mining_function
  FROM user_mining_models
 WHERE model_name = 'MODELO_MINILM_L12';


--==============================================================================
-- 4. Tabela com coluna VECTOR
--
-- Sintaxe: VECTOR(dimensoes, formato [, DENSE | SPARSE])
--   - dimensoes: número fixo (1 a 65535) ou * (flexível)
--   - formato:   INT8, FLOAT32, FLOAT64, BINARY (BINARY: dimensão múltipla de 8)
--   - SPARSE (23ai 23.6+, COMPATIBLE >= 23.6.0): só valores não-zero gravados;
--     índice IVF não suporta SPARSE (HNSW suporta a partir de 23.9)
--
-- all-MiniLM-L12-v2 produz vetores de 384 dimensões em FLOAT32.
--==============================================================================

-- 26ai
CREATE TABLE documentos_forenses (
  id              NUMBER PRIMARY KEY,
  titulo          VARCHAR2(200),
  conteudo        CLOB,
  categoria       VARCHAR2(50),
  data_criacao    DATE DEFAULT SYSDATE,
  embedding       VECTOR(384, FLOAT32)
);


--==============================================================================
-- 5. Popular embeddings — DML único (princípio Tim Hall)
--==============================================================================

-- 26ai — inserir documento com embedding gerado em SQL puro
INSERT INTO documentos_forenses (id, titulo, conteudo, categoria, embedding)
VALUES (
  1,
  'Laudo necropsia caso 2024-001',
  'Vítima do sexo masculino, 45 anos, óbito por trauma craniano contuso...',
  'NECROPSIA',
  VECTOR_EMBEDDING(modelo_minilm_l12 USING
    'Vítima do sexo masculino, 45 anos, óbito por trauma craniano contuso' AS data)
);

-- Tabela de origem do exemplo (em produção, a tabela do sistema legado)
CREATE TABLE laudos_origem (
  id_origem         NUMBER        NOT NULL,
  titulo_origem     VARCHAR2(200) NOT NULL,
  conteudo_origem   CLOB          NOT NULL,
  categoria_origem  VARCHAR2(50),
  data_criacao      DATE          DEFAULT SYSDATE NOT NULL,
  CONSTRAINT pk_laudos_origem PRIMARY KEY (id_origem)
);

INSERT INTO laudos_origem (id_origem, titulo_origem, conteudo_origem, categoria_origem)
VALUES (101, 'Laudo 101', 'Lesão corporal por instrumento contundente em membro superior.', 'LESAO');
INSERT INTO laudos_origem (id_origem, titulo_origem, conteudo_origem, categoria_origem)
VALUES (102, 'Laudo 102', 'Óbito por intoxicação exógena; presença de opioides no sangue.', 'TOXICOLOGIA');
INSERT INTO laudos_origem (id_origem, titulo_origem, conteudo_origem, categoria_origem)
VALUES (103, 'Laudo 103', 'Ferimento por projétil de arma de fogo com orifício de entrada no tórax.', 'OBITO');

-- 26ai — bulk: gerar embeddings para múltiplas linhas (SQL puro)
-- Para textos longos, fatie antes (ver ai_vector_embedding_pipeline.sql):
-- o modelo só "enxerga" até o seu limite de tokens.
INSERT INTO documentos_forenses (id, titulo, conteudo, categoria, embedding)
SELECT id_origem,
       titulo_origem,
       conteudo_origem,
       categoria_origem,
       VECTOR_EMBEDDING(modelo_minilm_l12 USING conteudo_origem AS data)
  FROM laudos_origem
 WHERE data_criacao > SYSDATE - 30;

COMMIT;


--==============================================================================
-- 6. Similarity search EXATA (sem índice)
--
-- Calcula a distância contra TODAS as linhas. OK para datasets pequenos ou
-- exploração. Para volume maior, use índice (ai_vector_index_strategies.sql).
--==============================================================================

-- Métricas: COSINE (default), DOT, EUCLIDEAN, EUCLIDEAN_SQUARED (= L2_SQUARED),
--           MANHATTAN, HAMMING, JACCARD (só vetores BINARY)
-- Atalhos: COSINE_DISTANCE, L1_DISTANCE, L2_DISTANCE, INNER_PRODUCT,
--          HAMMING_DISTANCE, JACCARD_DISTANCE; operadores <=> (cosine),
--          <-> (euclidiana), <#> (dot negativo).
-- Mais comum em texto: COSINE (independe da magnitude).

-- 26ai — top 5 mais similares a uma busca textual
SELECT id, titulo, categoria,
       VECTOR_DISTANCE(
         embedding,
         VECTOR_EMBEDDING(modelo_minilm_l12 USING 'morte por arma de fogo' AS data),
         COSINE
       ) AS distancia
  FROM documentos_forenses
 ORDER BY distancia
 FETCH FIRST 5 ROWS ONLY;


-- 26ai — query com variáveis PL/SQL (viram bind variables)
DECLARE
  l_busca         VARCHAR2(500) := 'morte por arma de fogo';
  l_limite        PLS_INTEGER   := 5;
  CURSOR c_resultados IS
    SELECT id, titulo, categoria,
           VECTOR_DISTANCE(
             embedding,
             VECTOR_EMBEDDING(modelo_minilm_l12 USING l_busca AS data),
             COSINE
           ) AS distancia
      FROM documentos_forenses
     ORDER BY distancia
     FETCH FIRST l_limite ROWS ONLY;
BEGIN
  FOR r_resultado IN c_resultados LOOP
    DBMS_OUTPUT.put_line(
      r_resultado.id || ' | ' || r_resultado.titulo ||
      ' | dist=' || ROUND(r_resultado.distancia, 4)
    );
  END LOOP;
END;
/


--==============================================================================
-- 7. Comparar dois embeddings diretamente
--==============================================================================

-- 26ai — VECTOR_EMBEDDING é função SQL; em PL/SQL use SELECT ... INTO
DECLARE
  l_emb_a VECTOR;
  l_emb_b VECTOR;
  l_dist  NUMBER;
BEGIN
  SELECT VECTOR_EMBEDDING(modelo_minilm_l12 USING 'óbito por arma de fogo' AS data),
         VECTOR_EMBEDDING(modelo_minilm_l12 USING 'morte por disparo' AS data)
    INTO l_emb_a, l_emb_b
    FROM dual;

  l_dist := VECTOR_DISTANCE(l_emb_a, l_emb_b, COSINE);
  DBMS_OUTPUT.put_line('Distância COSINE: ' || ROUND(l_dist, 4));
  -- Espera valor baixo (próximo de 0) — frases semanticamente próximas

  SELECT VECTOR_EMBEDDING(modelo_minilm_l12 USING 'receita de bolo de chocolate' AS data)
    INTO l_emb_b
    FROM dual;

  l_dist := VECTOR_DISTANCE(l_emb_a, l_emb_b, COSINE);
  DBMS_OUTPUT.put_line('Distância COSINE (não relacionado): ' || ROUND(l_dist, 4));
  -- Espera valor maior — frases não relacionadas
END;
/


--==============================================================================
-- 8. Inspeção da coluna VECTOR
--==============================================================================

-- 26ai — armazenamento ≈ dimensoes × bytes do formato (FLOAT32 = 4 bytes)
-- Obs.: VECTOR_SERIALIZE devolve a forma TEXTUAL ('[0.1,...]'); o tamanho dela
-- não é o tamanho em disco e, para 384 floats, pode passar de 4000 bytes
-- (use RETURNING CLOB se precisar serializar).
SELECT id,
       VECTOR_DIMENSION_COUNT(embedding)  AS dimensoes,
       VECTOR_DIMENSION_FORMAT(embedding) AS formato,
       VECTOR_NORM(embedding)             AS norma
  FROM documentos_forenses
 WHERE id <= 3;


--==============================================================================
-- 9. Anti-patterns
--==============================================================================

/*
ANTI-PATTERN 1: Armazenar embeddings em VARCHAR2/CLOB como string
  -- RUIM: '[0.1, 0.2, 0.3, ...]' ocupa mais espaço, exige conversão e
  --       não aceita índice vetorial
  embedding_text CLOB

  -- BOM:
  embedding VECTOR(384, FLOAT32)

ANTI-PATTERN 2: Loop PL/SQL gerando embeddings linha-a-linha
  -- RUIM
  FOR r IN (SELECT id, conteudo FROM origem) LOOP
    UPDATE destino SET embedding = VECTOR_EMBEDDING(...) WHERE id = r.id;
  END LOOP;

  -- BOM: INSERT SELECT em DML único
  INSERT INTO destino SELECT id, ..., VECTOR_EMBEDDING(...) FROM origem;

ANTI-PATTERN 3: FETCH FIRST sem APPROX em query que deveria usar índice
  -- RUIM (on-premises, com índice criado): faz busca EXATA
  ORDER BY VECTOR_DISTANCE(...) FETCH FIRST 10 ROWS ONLY

  -- BOM: explicita aproximação para usar o índice
  ORDER BY VECTOR_DISTANCE(...) FETCH APPROX FIRST 10 ROWS ONLY
  -- (Só no Autonomous Serverless o APPROX é tentado mesmo se omitido.)

ANTI-PATTERN 4: Métrica da query diferente da métrica do índice
  -- Índice criado com COSINE; query usa EUCLIDEAN → índice não é usado
  -- Use a MESMA métrica, ou omita a métrica na query (VECTOR_DISTANCE herda
  -- a métrica do índice da coluna quando há um único índice vetorial).

ANTI-PATTERN 5: Logar vetor inteiro em Logger
  logger.append_param(l_params, 'embedding', l_vetor); -- 384 floats de ruído

  -- BOM: log dimensão e norma
  logger.append_param(l_params, 'dim', VECTOR_DIMENSION_COUNT(l_vetor));
  logger.append_param(l_params, 'norma', VECTOR_NORM(l_vetor));

ANTI-PATTERN 6: Modelo de embedding escolhido sem avaliar o caso de uso
  -- all-MiniLM-L12-v2 (384-dim): leve, bom ponto de partida, foco em inglês
  -- Para PT-BR, avalie modelos multilíngues (ex.: famílias E5 multilíngue,
  -- BGE-M3) convertidos para ONNX, ou um provedor externo.
  -- Dimensões e limites de tokens: confira no model card de cada modelo
  -- antes de definir VECTOR(n, ...) — não estão na doc Oracle.
  -- Meça a qualidade com um conjunto de perguntas reais antes de decidir.
*/
