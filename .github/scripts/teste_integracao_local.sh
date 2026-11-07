#!/usr/bin/env bash
# Teste de integração LOCAL dos templates contra um Oracle AI Database 26ai Free
# em container (não roda no CI: a imagem tem ~14 GB).
#
# Pré-requisitos:
#   - Docker (daemon ativo)
#   - Imagem: docker pull container-registry.oracle.com/database/free:latest
#   - Opcional (templates de Vector): arquivo all_MiniLM_L12_v2.onnx, do pacote
#     all_MiniLM_L12_v2_augmented.zip publicado pela Oracle (link no "SQL Quick
#     Start Using a Vector Embedding Model" do AI Vector Search User's Guide)
#
# Uso:
#   .github/scripts/teste_integracao_local.sh [caminho/all_MiniLM_L12_v2.onnx]
#
# Senhas são geradas aleatoriamente a cada execução e não ficam em disco.
# O que o script NÃO cobre: LLM/provedor externo (exige credencial), RAFT
# (exige GSM e 3 bancos) e migração (exige banco 19c de origem).
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
ONNX="${1:-}"
CONTAINER="ora26free_teste_$$"
SAIDA="$(mktemp -d)"
gerar_senha() { python3 -c "import secrets,string;a=string.ascii_letters+string.digits;print('Aa1'+''.join(secrets.choice(a) for _ in range(17)))"; }
SENHA_SYS="$(gerar_senha)"; SENHA_TESTE="$(gerar_senha)"; SENHA_VETOR="$(gerar_senha)"

limpar() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap limpar EXIT

sysdba() { docker exec -i "$CONTAINER" bash -c 'sqlplus -s / as sysdba'; }
como() {  # como <usuario> <senha> <script_no_container> <log>
  docker exec -i -e NLS_LANG=AMERICAN_AMERICA.AL32UTF8 "$CONTAINER" \
    bash -c "sqlplus -s $1/\"$2\"@//localhost:1521/FREEPDB1" > "$4" 2>&1 <<SQL
set echo on feedback on serveroutput on lines 200 pages 200
whenever sqlerror continue
@$3
exit
SQL
}
copiar() { docker cp "$1" "$CONTAINER:/tmp/$(basename "$1")" >/dev/null
           docker exec -u 0 "$CONTAINER" chmod 644 "/tmp/$(basename "$1")"; }
erros() { grep -cE '^(ORA|PLS|SP2)-' "$1" || true; }

echo ">> Subindo 26ai Free ($CONTAINER)"
docker run -d --name "$CONTAINER" -e ORACLE_PWD="$SENHA_SYS" \
  container-registry.oracle.com/database/free:latest >/dev/null
for _ in $(seq 1 90); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")" = healthy ] && break
  sleep 10
done
printf 'select version_full from v$instance;\n' | sysdba | grep -E '^[0-9]'

echo ">> JSON Duality (Executável)"
sysdba >/dev/null <<SQL
alter session set container=FREEPDB1;
create user usr_teste identified by "$SENHA_TESTE" default tablespace users quota unlimited on users;
grant create session, create table, create view, create sequence, create procedure to usr_teste;
SQL
falhou=0
for f in json_duality_view_basics json_duality_dml json_duality_etag_concurrency; do
  copiar "$RAIZ/assets/$f.sql"
  como usr_teste "$SENHA_TESTE" "/tmp/$f.sql" "$SAIDA/$f.log"
  # V$ sem SELECT_CATALOG_ROLE é esperado (ORA-00942 em V_\$...)
  n=$(grep -E '^(ORA|PLS|SP2)-' "$SAIDA/$f.log" | grep -vc 'V_\$' || true)
  echo "   $f: $n erro(s) inesperado(s)"; [ "$n" -eq 0 ] || falhou=1
done

if [ -n "$ONNX" ]; then
  echo ">> AI Vector Search (Dependente de configuração)"
  docker exec "$CONTAINER" mkdir -p /home/oracle/embedding_models
  docker cp "$ONNX" "$CONTAINER:/home/oracle/embedding_models/all_MiniLM_L12_v2.onnx" >/dev/null
  docker exec -u 0 "$CONTAINER" chown -R oracle /home/oracle/embedding_models
  # Vector Pool: com pool 0 no startup, o CDB exige SPFILE + restart
  sysdba >/dev/null <<SQL
alter system set vector_memory_size = 384M scope = spfile;
shutdown immediate
startup
alter pluggable database all open;
SQL
  F="$RAIZ/assets/ai_vector_search_basics.sql"
  L=$(( $(grep -n '^-- 3. Carregar modelo' "$F" | cut -d: -f1) - 2 ))
  # ACCEPT ... HIDE não lê de stdin sem terminal: substitui por DEFINE no teste
  sed -n "1,${L}p" "$F" | sed "s/^ACCEPT senha_usuario_vetor.*/DEFINE senha_usuario_vetor = \"$SENHA_VETOR\"/" > "$SAIDA/basics_A.sql"
  sed -n "$((L + 1)),\$p" "$F" > "$SAIDA/basics_B.sql"
  copiar "$SAIDA/basics_A.sql"; copiar "$SAIDA/basics_B.sql"
  docker exec -i "$CONTAINER" bash -c 'sqlplus -s / as sysdba' > "$SAIDA/basics_A.log" 2>&1 <<SQL
alter session set container=FREEPDB1;
@/tmp/basics_A.sql
exit
SQL
  echo "   provisionamento: $(erros "$SAIDA/basics_A.log") erro(s)"
  como usuario_vetor "$SENHA_VETOR" /tmp/basics_B.sql "$SAIDA/basics_B.log"
  echo "   ai_vector_search_basics: $(erros "$SAIDA/basics_B.log") erro(s)"
  [ "$(erros "$SAIDA/basics_B.log")" -eq 0 ] || falhou=1
  for f in ai_vector_index_strategies ai_vector_embedding_pipeline; do
    sed -E 's/^ACCEPT ([a-z_]+) .*/DEFINE \1 = "valor_ficticio_teste"/' "$RAIZ/assets/$f.sql" > "$SAIDA/$f.sql"
    copiar "$SAIDA/$f.sql"
    como usuario_vetor "$SENHA_VETOR" "/tmp/$f.sql" "$SAIDA/$f.log"
    echo "   $f: erros por código (esperados: seções de DBA/credencial/23.26.4+):"
    grep -E '^(ORA|PLS|SP2)-' "$SAIDA/$f.log" | grep -v 'ORA-0651\|ORA-06550' | sort | uniq -c | sed 's/^/      /'
  done
fi

echo ">> Logs em $SAIDA"
exit "$falhou"
