#!/bin/bash
# Creates one Postgres database per Backstage microservice.
# Runs automatically on first `docker compose up` via docker-entrypoint-initdb.d.
set -e

for db in backstage_core backstage_catalog backstage_scaffolder backstage_techdocs; do
  echo "Creating database: $db"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE $db;
    GRANT ALL PRIVILEGES ON DATABASE $db TO $POSTGRES_USER;
EOSQL
done
