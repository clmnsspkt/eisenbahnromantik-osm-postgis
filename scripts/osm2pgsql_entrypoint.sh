#!/usr/bin/env sh
set -eu

PBF_PATH=${PBF_PATH:-/data/osm.pbf}
DB_HOST=${TARGET_DB_HOST:-postgres}
DB_PORT=${TARGET_DB_PORT:-5432}
DB_NAME=${TARGET_DB_NAME:-eisenbahn_demo}
DB_USER=${TARGET_DB_USER:-postgres}
DB_PASSWORD=${TARGET_DB_PASSWORD:-postgres}
OSM_IMPORT_SCHEMA=${OSM_IMPORT_SCHEMA:-osm_import}
OSM2PGSQL_CACHE=${OSM2PGSQL_CACHE:-1024}
OSM2PGSQL_JOBS=${OSM2PGSQL_JOBS:-4}

case "$OSM_IMPORT_SCHEMA" in
  ''|*[!A-Za-z0-9_]*)
    echo "[osm2pgsql] ERROR: OSM_IMPORT_SCHEMA must contain only letters, numbers and underscores." >&2
    exit 1
    ;;
esac

echo "[osm2pgsql] Using PBF: $PBF_PATH"
echo "[osm2pgsql] Target DB: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"

if [ ! -f "$PBF_PATH" ]; then
  echo "[osm2pgsql] ERROR: PBF file not found at $PBF_PATH" >&2
  echo "[osm2pgsql] Available files in /data:"
  ls -la /data || true
  exit 1
fi

export PGPASSWORD="$DB_PASSWORD"

if command -v psql >/dev/null 2>&1; then
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "CREATE SCHEMA IF NOT EXISTS ${OSM_IMPORT_SCHEMA};"
else
  echo "[osm2pgsql] WARNING: psql not available; relying on osm2pgsql to create schema."
fi

echo "[osm2pgsql] Starting osm2pgsql import..."
osm2pgsql \
  --database "$DB_NAME" \
  --host "$DB_HOST" \
  --port "$DB_PORT" \
  --username "$DB_USER" \
  --output=flex \
  --style /app/osm2pgsql/flex.lua \
  --schema "$OSM_IMPORT_SCHEMA" \
  --create \
  --slim \
  --cache "$OSM2PGSQL_CACHE" \
  --number-processes "$OSM2PGSQL_JOBS" \
  "$PBF_PATH"

echo "[osm2pgsql] Import finished."

if command -v psql >/dev/null 2>&1; then
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "SELECT to_regclass('${OSM_IMPORT_SCHEMA}.admin_boundary') AS admin_boundary, to_regclass('${OSM_IMPORT_SCHEMA}.railway_point') AS railway_point;"
fi
