#!/usr/bin/env bash
# Roda os templates da skill num PDB DESCARTÁVEL clonado do PDB_DOURADO.
# Cada execução parte de um banco limpo (clone ~10 s, descarte ~3 s).
#
# Pré-requisitos: ambiente no ar (docker compose up -d ou ./restaurar.sh),
# ./pdb.sh dourado já executado uma vez, ./modelos/all_MiniLM_L12_v2.onnx
# (opcional, para os templates de Vector).
#
# Uso: ./testar.sh [--manter]     --manter: não descarta o PDB no fim
set -euo pipefail
cd "$(dirname "$0")"
ASSETS="$(cd .. && pwd)/assets"
PDB="PDB_T$(date +%H%M%S)"
SAIDA="$(mktemp -d)"
MANTER="${1:-}"
senha() { python3 -c "import secrets,string;a=string.ascii_letters+string.digits;print('Aa1'+''.join(secrets.choice(a) for _ in range(17)))"; }
S_TESTE="$(senha)"; S_VETOR="$(senha)"

sysdba() { docker exec -i ora26ai-db bash -c 'sqlplus -s / as sysdba'; }
copiar() { docker cp "$1" "ora26ai-db:/tmp/$(basename "$1")" >/dev/null
           docker exec -u 0 ora26ai-db chmod 644 "/tmp/$(basename "$1")"; }
rodar() {  # rodar <usuario> <senha> <arquivo_no_container> <log>
  docker exec -i -e NLS_LANG=AMERICAN_AMERICA.AL32UTF8 ora26ai-db \
    bash -c "sqlplus -s $1/\"$2\"@//localhost:1521/$PDB" > "$4" 2>&1 <<SQL
whenever sqlerror continue
set define off serveroutput on lines 200 pages 200
@$3
exit
SQL
}
inesperados() { grep -E '^(ORA|PLS|SP2)-' "$1" | grep -vE "$2" | grep -vc 'ORA-0651[0-9]\|ORA-06550' || true; }

descartar() { [ "$MANTER" = --manter ] || ./pdb.sh descartar "$PDB" >/dev/null 2>&1 || true; }
trap descartar EXIT

inicio=$(date +%s)
./pdb.sh novo "$PDB" | tail -1
falhou=0

echo ">> JSON Duality"
sysdba >/dev/null <<SQL
alter session set container = $PDB;
create user usr_teste identified by "$S_TESTE" default tablespace users quota unlimited on users;
grant create session, create table, create view, create sequence, create procedure to usr_teste;
SQL
for f in json_duality_view_basics json_duality_dml json_duality_etag_concurrency; do
  copiar "$ASSETS/$f.sql"
  rodar usr_teste "$S_TESTE" "/tmp/$f.sql" "$SAIDA/$f.log"
  n=$(inesperados "$SAIDA/$f.log" 'V_\$')     # V$ sem SELECT_CATALOG_ROLE: esperado
  echo "   $f: $n erro(s) inesperado(s)"; [ "$n" -eq 0 ] || falhou=1
done

if [ -f modelos/all_MiniLM_L12_v2.onnx ]; then
  echo ">> AI Vector Search"
  F="$ASSETS/ai_vector_search_basics.sql"
  L=$(( $(grep -n '^-- 3. Carregar modelo' "$F" | cut -d: -f1) - 2 ))
  # Teste automatizado: ACCEPT ... HIDE não lê de stdin → DEFINE; datafile no
  # diretório do PDB descartável
  sed -n "1,${L}p" "$F" \
    | sed "s/^ACCEPT senha_usuario_vetor.*/DEFINE senha_usuario_vetor = \"$S_VETOR\"/" \
    | sed "s#/FREEPDB1/tbs_vector01.dbf#/$PDB/tbs_vector01.dbf#" > "$SAIDA/basics_A.sql"
  sed -n "$((L + 1)),\$p" "$F" > "$SAIDA/basics_B.sql"
  copiar "$SAIDA/basics_A.sql"; copiar "$SAIDA/basics_B.sql"
  docker exec -i ora26ai-db bash -c 'sqlplus -s / as sysdba' > "$SAIDA/basics_A.log" 2>&1 <<SQL
alter session set container = $PDB;
@/tmp/basics_A.sql
exit
SQL
  echo "   provisionamento: $(inesperados "$SAIDA/basics_A.log" 'ORA-51955|ORA-02097|ORA-00955') erro(s) inesperado(s)"
  rodar usuario_vetor "$S_VETOR" /tmp/basics_B.sql "$SAIDA/basics_B.log"
  n=$(inesperados "$SAIDA/basics_B.log" '^$'); echo "   ai_vector_search_basics: $n erro(s) inesperado(s)"
  [ "$n" -eq 0 ] || falhou=1
  # Esperados: seções de DBA (V$, DBMS_VECTOR_ADMIN, ACL), credencial externa
  # ausente e quantização PRODUCT (23.26.4+)
  esperados='V_\$|DBMS_VECTOR_ADMIN|DBMS_NETWORK_ACL_ADMIN|ORA-51930|ORA-01031|ORA-27486|ORA-20000|ORA-20001|ORA-20002|ORA-20999'
  for f in ai_vector_index_strategies ai_vector_embedding_pipeline ai_vector_rag_pattern; do
    sed -E 's/^ACCEPT ([a-z_]+) .*/DEFINE \1 = "valor_ficticio_teste"/' "$ASSETS/$f.sql" > "$SAIDA/$f.sql"
    copiar "$SAIDA/$f.sql"
    rodar usuario_vetor "$S_VETOR" "/tmp/$f.sql" "$SAIDA/$f.log"
    n=$(inesperados "$SAIDA/$f.log" "$esperados")
    echo "   $f: $n erro(s) inesperado(s)"; [ "$n" -eq 0 ] || falhou=1
  done
fi

echo ">> $PDB $( [ "$MANTER" = --manter ] && echo mantido || echo descartado ); logs em $SAIDA"
echo ">> Tempo total: $(( $(date +%s) - inicio ))s — $( [ $falhou -eq 0 ] && echo OK || echo FALHOU )"
exit $falhou
