#!/usr/bin/env bash
# Prepara o ambiente de teste: gera .env com senhas aleatórias (se não existir)
# e baixa/descompacta o APEX (se ./apex não existir).
# Uso: ./preparar.sh [versao_apex]   ex.: ./preparar.sh 26.2   (padrão: latest)
set -euo pipefail
cd "$(dirname "$0")"

senha() { python3 -c "import secrets,string;a=string.ascii_letters+string.digits;print('Aa1'+''.join(secrets.choice(a) for _ in range(17)))"; }
# Política de senha do APEX exige pontuação; '#' e '_' são seguros em SQL e shell
senha_apex() { echo "$(senha)#_"; }

if [ ! -f .env ]; then
  umask 077
  {
    echo "ORACLE_PWD=$(senha)"
    echo "APEX_PWD=$(senha)"
    echo "APEX_ADMIN_PWD=$(senha_apex)"
    echo "ORDS_PWD=$(senha)"
    echo "DB_TAG=latest"
    echo "ORDS_TAG=26.3.1"
  } > .env
  echo ".env criado (senhas aleatórias; não versionado)"
fi
# .env de versão anterior sem ORDS_PWD
grep -q '^ORDS_PWD=' .env || echo "ORDS_PWD=$(senha)" >> .env
# .env de versão anterior com APEX_ADMIN_PWD sem pontuação
if ! grep -q '^APEX_ADMIN_PWD=.*[#_]' .env; then
  sed -i '/^APEX_ADMIN_PWD=/d' .env && echo "APEX_ADMIN_PWD=$(senha_apex)" >> .env
fi

mkdir -p modelos
if [ ! -d apex/core ]; then
  versao="${1:-latest}"
  if [ "$versao" = latest ]; then arq=apex-latest.zip; else arq="apex_${versao}.zip"; fi
  echo "Baixando $arq ..."
  curl -fSL --retry 3 -o "/tmp/$arq" "https://download.oracle.com/otn_software/apex/$arq"
  unzip -q -o "/tmp/$arq" -d . && rm -f "/tmp/$arq"
  echo "APEX descompactado em ./apex ($(grep -o 'APEX_[0-9]\{6\}' apex/core/scripts/set_appun.sql | head -1))"
fi
