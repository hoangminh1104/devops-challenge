#!/bin/sh
set -eu
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set=ON_ERROR_STOP=1 \
  --set=api_password="$(cat /run/secrets/api_password)" \
  --set=worker_password="$(cat /run/secrets/worker_password)" \
  --set=migrator_password="$(cat /run/secrets/migrator_password)" \
  --file=/opt/p5/security.sql
