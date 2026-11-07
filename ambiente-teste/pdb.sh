#!/usr/bin/env bash
# PDBs descartáveis para teste, clonados de um PDB "dourado".
#
#   ./pdb.sh dourado          cria PDB_DOURADO a partir do FREEPDB1 (hot clone)
#                             e o deixa READ ONLY (base estável para clones)
#   ./pdb.sh novo [NOME]      clona PDB_DOURADO em NOME (padrão PDB_TESTE) e abre
#   ./pdb.sh descartar [NOME] fecha e remove NOME com os datafiles
#   ./pdb.sh listar           mostra os PDBs e o estado
#
# Conexão ao clone: localhost:1521/<NOME> (serviço com o nome do PDB).
# O APEX/ORDS continuam servindo o FREEPDB1; o clone serve para SQL/PL/SQL,
# Vector e Duality com o mesmo conteúdo do dourado (APEX incluso no dicionário).
set -euo pipefail
cd "$(dirname "$0")"
BASE=/opt/oracle/oradata/FREE
acao="${1:-listar}"; nome="$(echo "${2:-PDB_TESTE}" | tr '[:lower:]' '[:upper:]')"
[[ "$nome" =~ ^[A-Z][A-Z0-9_]{0,29}$ ]] || { echo "Nome de PDB inválido: $nome"; exit 1; }

sysdba() { docker exec -i ora26ai-db bash -c 'sqlplus -s / as sysdba'; }
inicio=$(date +%s)

case "$acao" in
  dourado)
    sysdba <<SQL
whenever sqlerror exit failure
create pluggable database PDB_DOURADO from FREEPDB1
  file_name_convert = ('${BASE}/FREEPDB1/', '${BASE}/PDB_DOURADO/');
-- PDB recém-criado precisa abrir uma vez em READ WRITE (senão ORA-65085)
alter pluggable database PDB_DOURADO open;
alter pluggable database PDB_DOURADO close immediate;
alter pluggable database PDB_DOURADO open read only;
alter pluggable database PDB_DOURADO save state;
exit
SQL
    ;;
  novo)
    sysdba <<SQL
whenever sqlerror exit failure
create pluggable database ${nome} from PDB_DOURADO
  file_name_convert = ('${BASE}/PDB_DOURADO/', '${BASE}/${nome}/');
alter pluggable database ${nome} open;
exit
SQL
    ;;
  descartar)
    sysdba <<SQL
whenever sqlerror exit failure
alter pluggable database ${nome} close immediate;
drop pluggable database ${nome} including datafiles;
exit
SQL
    ;;
  listar)
    printf 'set lines 120\ncol name format a20\nselect name, open_mode from v$pdbs order by con_id;\n' | sysdba
    exit 0
    ;;
  *) echo "Uso: $0 dourado | novo [NOME] | descartar [NOME] | listar"; exit 1 ;;
esac
echo "$acao $( [ "$acao" = dourado ] && echo PDB_DOURADO || echo "$nome"): $(( $(date +%s) - inicio ))s"
