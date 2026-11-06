#!/usr/bin/env bash
# Pós-instalação (uma vez, depois que o APEX responder em /ords/apex):
#  - troca a senha do ADMIN do workspace INTERNAL (a imagem do ORDS instala o
#    APEX em modo silencioso com senhas internas fixas) pela do .env
#  - cria o DIRECTORY dir_modelos (modelos ONNX montados em ./modelos)
# A senha vai pela entrada padrão do sqlplus, não pela linha de comando.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a

docker exec -i ora26ai-db bash -c 'sqlplus -s / as sysdba' <<SQL
whenever sqlerror exit failure
set feedback off serveroutput on
alter session set container = FREEPDB1;
column esquema new_value esquema_apex noprint
select schema as esquema from dba_registry where comp_id = 'APEX';
alter session set current_schema = &esquema_apex;
begin
  wwv_flow_instance_admin.create_or_update_admin_user(
    p_username => 'ADMIN',
    p_email    => 'admin@localhost',
    p_password => '${APEX_ADMIN_PWD}');
  commit;
end;
/
alter session set current_schema = SYS;
create or replace directory dir_modelos as '/home/oracle/embedding_models';
select 'APEX ' || version || ' (' || status || ')' as apex from dba_registry where comp_id = 'APEX';
exit
SQL
echo "ADMIN do INTERNAL com a senha APEX_ADMIN_PWD do .env"
