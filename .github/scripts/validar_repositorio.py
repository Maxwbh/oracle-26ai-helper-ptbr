#!/usr/bin/env python3
"""Validação estática do repositório oracle-26ai-helper-ptbr.

Não executa SQL (não há banco no CI). Verifica estrutura, frontmatter,
convenções dos templates e padrões proibidos (credenciais fixas, sintaxe
sabidamente inexistente, referências à skill antiga).

Uso: python3 .github/scripts/validar_repositorio.py [raiz]
Sai com código 1 se houver qualquer falha.
"""
import re
import sys
from pathlib import Path

RAIZ = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()

# Arquivos da raiz que entram no pacote .skill (e contam no suite_size)
ARQUIVOS_RAIZ_PACOTE = ["CHANGELOG.md", "LICENSE", "NOTICE"]
CHAVES_METADATA = ["version", "release_date", "repository", "suite_size",
                   "author", "contact", "organization", "site"]

# (regex, motivo) — padrões proibidos em templates .sql (fora de comentários)
PROIBIDOS_SQL = [
    (r"IDENTIFIED\s+BY\s+\"?(?!&)[A-Za-z0-9_#$]+", "senha fixa em CREATE/ALTER USER (use ACCEPT ... HIDE)"),
    (r"\"access_token\"\s*:\s*\"(?!&|<)[^\"]+\"", "token de API fixo"),
    (r"DBMS_VECTOR\.GENERATE\s*\(", "DBMS_VECTOR.GENERATE não existe (use UTL_TO_GENERATE_TEXT)"),
    (r"vector_compression", "parâmetro inexistente (use QUANTIZATION ...)"),
    (r"gv?\$sharding_units", "view inexistente (use V$SHARD_REPLICATION_UNIT)"),
]
# Padrões proibidos em qualquer arquivo do pacote, exceto CHANGELOG (histórico)
PROIBIDOS_TEXTO = [
    (r"oracle-sql-helper-ptbr", "skill antiga; aponte para a suíte oracle-skills-ptbr"),
]

falhas = []

# Armadilhas do SQL*Plus/SQLcl encontradas no teste de integração (26ai Free
# 23.26.3): todas fazem o comando ser descartado ou mal interpretado, às vezes
# SEM mensagem de erro.
INICIO_PLSQL = re.compile(
    r"^\s*(CREATE\s+(OR\s+REPLACE\s+)?(EDITIONABLE\s+|NONEDITIONABLE\s+)?"
    r"(PACKAGE|PROCEDURE|FUNCTION|TRIGGER|TYPE)\b|DECLARE\b|BEGIN\b)", re.I)
COMANDO_CLIENTE = re.compile(
    r"^(SET|SHOW|ACCEPT|UNDEFINE|DEFINE|VARIABLE|VAR|EXEC|EXECUTE|PROMPT|"
    r"SPOOL|WHENEVER|COLUMN|COL|SHUTDOWN|STARTUP)\b", re.I)


def armadilhas_sqlplus(texto):
    """Linha em branco dentro de comando SQL, linha iniciando com @ e ';'
    seguido de comentário na mesma linha (o SQL*Plus não encerra o comando)."""
    achados, em_bloco, inicio, plsql = [], False, None, False
    for n, bruta in enumerate(texto.splitlines(), 1):
        s = bruta.strip()
        if em_bloco:
            em_bloco = "*/" not in s
            continue
        if inicio is None:
            if not s or s.startswith("--") or s == "/":
                continue
            if s.startswith("/*"):
                em_bloco = "*/" not in s
                continue
            if s.startswith("@"):
                achados.append((n, "linha começa com @ (executada como script)"))
            if COMANDO_CLIENTE.match(s):
                continue
            inicio, plsql = n, bool(INICIO_PLSQL.match(s))
            if not plsql and re.search(r";\s*--", s):
                achados.append((n, "';' seguido de comentário não encerra o comando"))
                inicio = None
            elif not plsql and re.search(r";\s*$", s):
                inicio = None
            continue
        if plsql:
            if s == "/":
                inicio = None
            continue
        if not s:
            achados.append((n, f"linha em branco encerra o comando iniciado na linha {inicio}"))
            inicio = None
            continue
        if s.startswith("@"):
            achados.append((n, "linha começa com @ dentro do comando"))
        codigo = s.split("--", 1)[0].rstrip()
        if codigo.endswith(";") and re.search(r";\s*--", s):
            achados.append((n, "';' seguido de comentário não encerra o comando"))
            inicio = None
        elif codigo.endswith(";"):
            inicio = None
    return achados


def falha(msg):
    falhas.append(msg)
    print(f"[FAIL] {msg}")


def ok(msg):
    print(f"[OK]   {msg}")


def sem_comentarios_sql(texto):
    """Remove comentários -- e /* */ para checar só o código."""
    texto = re.sub(r"/\*.*?\*/", "", texto, flags=re.S)
    return "\n".join(l.split("--", 1)[0] for l in texto.splitlines())


# 1. Frontmatter -------------------------------------------------------------
skill = RAIZ / "SKILL.md"
conteudo = skill.read_text(encoding="utf-8")
m = re.match(r"^---\n(.*?)\n---\n", conteudo, re.S)
if not m:
    falha("SKILL.md sem frontmatter delimitado por ---")
    sys.exit(1)
fm = m.group(1)

nome = re.search(r"^name:\s*(\S+)", fm, re.M)
if nome and re.fullmatch(r"[a-z0-9-]{1,64}", nome.group(1)):
    ok(f"name '{nome.group(1)}'")
else:
    falha("name ausente ou fora de kebab-case (≤64)")

desc = re.search(r'^description:\s*"(.*)"\s*$', fm, re.M)
if not desc:
    falha("description ausente (esperada entre aspas duplas)")
else:
    d = desc.group(1)
    if len(d) > 1024:
        falha(f"description com {len(d)} caracteres (> 1024)")
    elif "<" in d or ">" in d:
        falha("description contém < ou >")
    elif not all(k in d for k in ("ATIVE", "NÃO ATIVE")):
        falha("description sem gatilhos ATIVE / NÃO ATIVE")
    else:
        ok(f"description com {len(d)} caracteres e gatilhos")

for chave in CHAVES_METADATA:
    if not re.search(rf"^\s+{chave}:\s*\S", fm, re.M):
        falha(f"metadata.{chave} ausente")
versao = re.search(r"^\s+version:\s*(\S+)", fm, re.M)
if versao and not re.fullmatch(r"\d+\.\d+\.\d+", versao.group(1)):
    falha(f"metadata.version '{versao.group(1)}' não é SemVer")

# 2. suite_size ----------------------------------------------------------------
recursos = [p for pasta in ("references", "assets", "agents", "scripts")
            if (RAIZ / pasta).is_dir()
            for p in (RAIZ / pasta).rglob("*") if p.is_file()]
recursos += [RAIZ / a for a in ARQUIVOS_RAIZ_PACOTE if (RAIZ / a).is_file()]
declarado = re.search(r"^\s+suite_size:\s*(\d+)", fm, re.M)
if declarado and int(declarado.group(1)) == len(recursos):
    ok(f"suite_size = {len(recursos)}")
else:
    falha(f"suite_size declarado {declarado.group(1) if declarado else '?'} "
          f"≠ contagem real {len(recursos)}")

# 3. CHANGELOG registra a versão ---------------------------------------------
if versao and f"[{versao.group(1)}]" in (RAIZ / "CHANGELOG.md").read_text(encoding="utf-8"):
    ok(f"CHANGELOG registra {versao.group(1)}")
else:
    falha("CHANGELOG sem entrada para a versão do frontmatter")

# 4. References citadas no SKILL.md e com índice ------------------------------
for ref in sorted((RAIZ / "references").glob("*.md")):
    rel = f"references/{ref.name}"
    if rel not in conteudo:
        falha(f"{rel} não é citado no SKILL.md")
    linhas = ref.read_text(encoding="utf-8").count("\n")
    if linhas > 100 and "## Índice" not in ref.read_text(encoding="utf-8"):
        falha(f"{rel} tem {linhas} linhas e não tem '## Índice'")
for citado in set(re.findall(r"(?:references|assets)/[\w.-]+\.(?:md|sql)", conteudo)):
    if not (RAIZ / citado).is_file():
        falha(f"SKILL.md cita {citado}, que não existe")

# 5. Templates SQL --------------------------------------------------------------
indice_assets = (RAIZ / "assets" / "README.md").read_text(encoding="utf-8")
for sql in sorted((RAIZ / "assets").glob("*.sql")):
    texto = sql.read_text(encoding="utf-8")
    cabecalho = texto[:3000]
    for linha in ("-- Revisado:", "-- Tipo:", "-- RU mínimo:", "-- Edição Free:"):
        if linha not in cabecalho:
            falha(f"{sql.name}: cabeçalho sem '{linha}'")
    if "-- 26ai" not in texto:
        falha(f"{sql.name}: nenhum bloco marcado com '-- 26ai'")
    if sql.name not in indice_assets:
        falha(f"{sql.name}: ausente do assets/README.md")
    codigo = sem_comentarios_sql(texto)
    for padrao, motivo in PROIBIDOS_SQL:
        if re.search(padrao, codigo, re.I):
            falha(f"{sql.name}: {motivo}")
    for linha, motivo in armadilhas_sqlplus(texto):
        falha(f"{sql.name}:{linha}: SQL*Plus — {motivo}")
    # Naming Trivadis: cursor explícito não usa prefixo co_ (é de constante)
    if re.search(r"\bCURSOR\s+co_", codigo, re.I):
        falha(f"{sql.name}: cursor com prefixo co_ (use c_)")

# 6. Padrões proibidos em texto ------------------------------------------------
pacote = [skill] + [p for p in recursos if p.name != "CHANGELOG.md"]
for arq in pacote:
    texto = arq.read_text(encoding="utf-8", errors="ignore")
    for padrao, motivo in PROIBIDOS_TEXTO:
        if re.search(padrao, texto):
            falha(f"{arq.relative_to(RAIZ)}: {motivo}")

print()
if falhas:
    print(f"{len(falhas)} falha(s).")
    sys.exit(1)
print("Validação estática concluída sem falhas.")
