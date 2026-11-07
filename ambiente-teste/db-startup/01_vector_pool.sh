#!/bin/bash
# Executado a CADA subida pela imagem do 26ai Free (/opt/oracle/scripts/startup).
# A imagem já traz o banco pré-criado, então scripts de "setup" não rodam.
# Vector Pool: com pool 0 no startup, o aumento no CDB só vale após restart
# (ORA-51950, medido no 23.26.3). Só age se o pool ainda estiver em 0.
atual=$(sqlplus -s / as sysdba <<'SQL' | tr -d '[:space:]'
set heading off feedback off pagesize 0
select value from v$parameter where name = 'vector_memory_size';
SQL
)
if [ "$atual" = "0" ]; then
  echo "Vector Pool em 0: gravando 384M no SPFILE e reiniciando a instância"
  sqlplus -s / as sysdba <<'SQL'
alter system set vector_memory_size = 384M scope = spfile;
shutdown immediate
startup
alter pluggable database all open;
alter pluggable database all save state;
alter session set container = FREEPDB1;
alter system set vector_memory_size = 256M scope = both;
SQL
else
  echo "Vector Pool já alocado: $atual bytes"
fi
