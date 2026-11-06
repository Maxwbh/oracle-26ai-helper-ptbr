#!/usr/bin/env bash
# Snapshot dourado: copia os volumes do banco e do ORDS (com APEX instalado,
# Vector Pool ligado e o que mais tiver sido preparado) para ./snapshot.
# Backup a frio: para os containers durante a cópia e religa no fim.
# Uso: ./congelar.sh [--gzip]
set -euo pipefail
cd "$(dirname "$0")"
PROJETO=ora26ai-teste
IMG=container-registry.oracle.com/database/free:latest   # só para ter tar
ZIP="${1:-}"
mkdir -p snapshot

inicio=$(date +%s)
docker compose stop
for v in oradata ords_config; do
  if [ "$ZIP" = --gzip ]; then
    docker run --rm --user 0 -v "${PROJETO}_${v}:/v:ro" -v "$PWD/snapshot:/s" \
      --entrypoint bash "$IMG" -c "tar -C /v -czf /s/${v}.tar.gz . && rm -f /s/${v}.tar"
  else
    docker run --rm --user 0 -v "${PROJETO}_${v}:/v:ro" -v "$PWD/snapshot:/s" \
      --entrypoint bash "$IMG" -c "tar -C /v -cf /s/${v}.tar . && rm -f /s/${v}.tar.gz"
  fi
done
# As senhas do .env são as que valem dentro do snapshot
cp .env snapshot/env && chmod 600 snapshot/env
date -u +%Y-%m-%dT%H:%M:%SZ > snapshot/criado_em
docker compose start
echo "Snapshot em ./snapshot ($(du -sh snapshot | cut -f1)) em $(( $(date +%s) - inicio ))s"
