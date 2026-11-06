#!/usr/bin/env bash
# Restaura o snapshot dourado: descarta os volumes atuais e sobe o ambiente já
# com APEX instalado, sem reinstalar nada.
# Uso: ./restaurar.sh
set -euo pipefail
cd "$(dirname "$0")"
PROJETO=ora26ai-teste
IMG=container-registry.oracle.com/database/free:latest
[ -f snapshot/env ] || { echo "Sem snapshot: rode ./congelar.sh antes"; exit 1; }

inicio=$(date +%s)
cp snapshot/env .env && chmod 600 .env
docker compose down -v
docker compose create            # recria volumes vazios (com rótulos do compose)
for v in oradata ords_config; do
  if [ -f "snapshot/${v}.tar.gz" ]; then arq="${v}.tar.gz"; opt=-xzf; else arq="${v}.tar"; opt=-xf; fi
  docker run --rm --user 0 -v "${PROJETO}_${v}:/v" -v "$PWD/snapshot:/s:ro" \
    --entrypoint bash "$IMG" -c "tar -C /v ${opt} /s/${arq}"
done
docker compose up -d
# O APEX redireciona com cookie de sessão: sem cookie jar o curl entra em loop
cj=$(mktemp); trap 'rm -f "$cj"' EXIT
until [ "$(curl -s -c "$cj" -b "$cj" -o /dev/null -w '%{http_code}' -L http://127.0.0.1:${ORDS_PORTA:-8080}/ords/apex)" = 200 ]; do
  sleep 3
  [ $(( $(date +%s) - inicio )) -gt 900 ] && { echo "APEX não respondeu em 15 min"; exit 1; }
done
echo "Ambiente restaurado e APEX respondendo em $(( $(date +%s) - inicio ))s"
