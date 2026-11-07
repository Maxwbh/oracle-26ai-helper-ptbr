# Ambiente de teste — Oracle AI Database 26ai Free + ORDS + APEX

Ambiente Docker para testar os templates da skill (e o seu código Oracle/APEX) num banco **26ai Free** com **ORDS** e **APEX**. A pasta não faz parte do pacote `.skill`.

Os tempos abaixo foram medidos em nov/2026: imagem `database/free:latest` (RU 23.26.3), `database/ords:26.3.1`, APEX 26.2, máquina com 4 vCPU e 15 GB de RAM.

| Situação | Tempo até o APEX responder |
|---|---|
| Primeira subida (instala ORDS e APEX no banco) | ~21 min |
| Restaurar o **snapshot dourado** (`./restaurar.sh`) | **139 s** |
| Parar e subir de novo (`docker compose stop` / `start`) | **55 s** |
| **Suíte de testes num PDB descartável** (`./testar.sh`) | **30 s** no total (clone 7–9 s, descarte 2–3 s) |

## Peças

| Arquivo | Função |
|---|---|
| `compose.yaml` | Banco 26ai Free + imagem oficial do ORDS, que instala/atualiza o APEX montado em `./apex` e serve as imagens em `/i/` |
| `preparar.sh` | Gera `.env` com senhas aleatórias e baixa o APEX (`./preparar.sh 26.2` fixa a versão) |
| `db-startup/01_vector_pool.sh` | A cada subida: se o Vector Pool estiver em 0, grava 384M no SPFILE e reinicia a instância (no CDB, aumentar a partir de 0 exige restart — ORA-51950) |
| `pos-instalacao.sh` | Uma vez: troca a senha do ADMIN do INTERNAL (a imagem instala o APEX com senhas internas fixas) e cria o `DIRECTORY dir_modelos` |
| `pdb.sh` | `dourado` cria o PDB_DOURADO (READ ONLY) a partir do FREEPDB1; `novo`/`descartar` clonam e removem PDBs de teste |
| `congelar.sh` / `restaurar.sh` | Snapshot dourado dos volumes (banco + ORDS) em `./snapshot` e restauração sem reinstalar nada |
| `testar.sh` | Clona um PDB do dourado, roda os templates de Duality e Vector, resume os erros e descarta o PDB |

`.env`, `apex/`, `modelos/` e `snapshot/` ficam fora do Git.

## Primeira vez

```bash
./preparar.sh
```

```bash
docker compose up -d
```

Aguarde o APEX responder em `http://127.0.0.1:8080/ords/apex` (~21 min na primeira vez; acompanhe com `docker logs -f ora26ai-ords`). Depois:

```bash
./pos-instalacao.sh
```

```bash
./pdb.sh dourado
```

Opcional, para os templates de Vector: coloque `all_MiniLM_L12_v2.onnx` (pacote `all_MiniLM_L12_v2_augmented.zip` publicado pela Oracle, link no "SQL Quick Start Using a Vector Embedding Model" do AI Vector Search User's Guide) em `./modelos/`.

Por fim, congele o resultado:

```bash
./congelar.sh --gzip
```

## Dia a dia

Rodar a suíte num banco limpo:

```bash
./testar.sh
```

Voltar ao estado dourado (APEX instalado, sem nada dos testes):

```bash
./restaurar.sh
```

Login no APEX: workspace `INTERNAL`, usuário `ADMIN`, senha `APEX_ADMIN_PWD` do `.env`. Para o seu próprio código, use `./pdb.sh novo MEU_PDB`: o clone já traz o APEX no dicionário. Conexão em `localhost:1521/MEU_PDB`.

## O que acelera e por quê

1. **Instalar uma vez.** A instalação do APEX (~21 min) é o maior custo. Com os volumes preservados, o ORDS só confere a versão a cada subida.
2. **Snapshot dourado.** Os volumes (7,5 GB) viram 1,3 GB com `--gzip` e restauram em ~2 min em qualquer máquina, sem baixar nem instalar o APEX. Sem `--gzip`, a cópia fica do tamanho do volume; use só se houver disco sobrando.
3. **PDB descartável.** Em vez de recriar schema ou banco, cada teste clona o PDB_DOURADO (hot clone, ~8 s) e o descarta no fim. Testes não deixam lixo e podem rodar em PDBs paralelos.
4. **Vector Pool no startup.** O restart que o pool exige acontece só na primeira subida, pelo script em `db-startup/`.

## Limitações

- **Free:** 2 cores, 2 GB de RAM e 12 GB de dados de usuário. Banco, APEX e PDBs clonados dividem esse limite.
- **Disco:** o volume do banco ocupa ~7,5 GB com o PDB dourado; o snapshot com `--gzip`, mais 1,3 GB.
- O ORDS serve o **FREEPDB1**. Os PDBs clonados servem para SQL/PL/SQL, Vector e Duality; para testar telas APEX num clone, seria preciso configurar outro pool no ORDS (não incluído).
- `ACCEPT … HIDE` não lê de entrada não interativa: o `testar.sh` troca por `DEFINE` só na cópia de teste.
- A imagem `database/free:latest` muda com o tempo. Para reprodutibilidade, fixe `DB_TAG` no `.env`.
