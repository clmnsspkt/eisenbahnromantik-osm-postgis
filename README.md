# Eisenbahnromantik OSM/PostGIS Workflow

Eisenbahnromantik is a geospatial tracking project that combines GPX activity data, OpenStreetMap railway data, administrative boundaries and PostGIS processing into a map-based checkpoint and region-progress system.

This public slice starts with the OSM import workflow. It explains how OSM PBF extracts are transformed into application-ready PostGIS structures for railway checkpoints and administrative regions. The API, frontend, GPX upload flow and production deployment can be added later in separate, smaller releases.

## What This Repository Shows

- importing selected OpenStreetMap objects with `osm2pgsql` and a Lua flex style
- keeping raw OSM imports in isolated schemas
- building adapter views over one or more import schemas
- deriving administrative boundary target tables
- deriving railway checkpoint preview tables
- refreshing admin-unit hierarchy and checkpoint-to-region mappings
- providing a public workbench for improving railway checkpoint canonicalization rules

The workflow is intentionally scoped. It is not a full application release yet.

## Data Flow

```text
OSM PBF extract
  -> osm2pgsql flex import
  -> isolated import schema, for example osm_import_demo
  -> public adapter views
  -> OSM admin boundary target tables
  -> railway checkpoint preview tables
  -> admin-unit hierarchy
  -> checkpoint-to-admin-unit mapping
```

Raw OSM import data stays separate from application-facing tables. This makes imports easier to verify, rerun and extend to multiple countries or regions.

## Canonicalization Workbench

One goal of this repository is to make checkpoint canonicalization observable and improvable. Duplicate stations, stops or stop areas should be reduced by changing documented OSM-derived rules, not by one-off edits in the application database.

The intended loop is:

1. Reproduce duplicate checkpoints from a small PBF extract.
2. Inspect `t_checkpoints_preview_raw` and `t_checkpoints_preview` to see which OSM objects survived canonicalization.
3. Adjust the rules in `sql/railway_checkpoints_import_osm2pgsql.sql` or the parameters exposed by `scripts/import_osm2pgsql_targets.py`.
4. Rebuild the preview tables, publish to `t_checkpoints`, and verify that the duplicate is gone without losing valid nearby checkpoints.

Useful rule inputs include name normalization, stop-area membership, OSM identity refs, proximity thresholds and source priority.

## Repository Layout

```text
.
  README.md
  LICENSE
  .env.example
  Dockerfile.osm2pgsql
  docker-compose.osm2pgsql.yml
  requirements.txt

  osm2pgsql/
    flex.lua

  scripts/
    osm2pgsql_entrypoint.sh
    osm2pgsql_pipeline.py
    import_osm2pgsql_targets.py
    admin_webgis_refresh.py

  sql/
    demo_bootstrap.sql
    demo_publish_preview_checkpoints.sql
    admin_boundaries_schema.sql
    admin_boundaries_import_osm2pgsql.sql
    railway_checkpoints_schema.sql
    railway_checkpoints_import_osm2pgsql.sql
    admin_webgis_schema.sql

  docs/
    osm-workflow.md
    data-model-osm.md
    roadmap.md
```

## Quick Start

The Compose file includes a local PostGIS database for demo work. The repository does not include a PBF extract; provide your own small extract and mount it into the import container.

```bash
cp .env.example .env
docker compose -f docker-compose.osm2pgsql.yml up -d db
docker compose -f docker-compose.osm2pgsql.yml exec -T db \
  psql -U postgres -d eisenbahn_demo -v ON_ERROR_STOP=1 \
  -f /dev/stdin < sql/demo_bootstrap.sql
```

Run an import with an isolated schema. The `-v` source path must be an absolute path on your host:

```bash
TARGET_DB_HOST=db \
TARGET_DB_PORT=5432 \
TARGET_DB_NAME=eisenbahn_demo \
TARGET_DB_USER=postgres \
TARGET_DB_PASSWORD=postgres \
OSM_IMPORT_SCHEMA=osm_import_demo \
docker compose -f docker-compose.osm2pgsql.yml run --rm \
  -v /absolute/path/to/extract.osm.pbf:/hostdata/input.osm.pbf:ro \
  -e PBF_PATH=/hostdata/input.osm.pbf \
  osm2pgsql-import
```

Build target tables and adapter views:

```bash
docker compose -f docker-compose.osm2pgsql.yml run --rm \
  --entrypoint python3 \
  -v "$PWD:/work:ro" \
  -w /work \
  -e TARGET_DB_HOST=db \
  -e TARGET_DB_PORT=5432 \
  -e TARGET_DB_NAME=eisenbahn_demo \
  -e TARGET_DB_USER=postgres \
  -e TARGET_DB_PASSWORD=postgres \
  -e OSM_IMPORT_SCHEMAS=osm_import_demo \
  osm2pgsql-import scripts/import_osm2pgsql_targets.py
```

Alternatively, run the script from your host with `TARGET_DB_HOST=127.0.0.1`, `TARGET_DB_PORT=${POSTGRES_PORT:-5432}` and a Python environment that has `psycopg2` installed:

```bash
TARGET_DB_HOST=127.0.0.1 \
TARGET_DB_PORT=${POSTGRES_PORT:-5432} \
TARGET_DB_NAME=eisenbahn_demo \
TARGET_DB_USER=postgres \
TARGET_DB_PASSWORD=postgres \
OSM_IMPORT_SCHEMAS=osm_import_demo \
python scripts/import_osm2pgsql_targets.py
```

Publish the canonical preview checkpoints into the minimal demo checkpoint table:

```bash
docker compose -f docker-compose.osm2pgsql.yml exec -T db \
  psql -U postgres -d eisenbahn_demo -v ON_ERROR_STOP=1 \
  -f /dev/stdin < sql/demo_publish_preview_checkpoints.sql
```

Refresh derived admin-unit tables and mappings:

```bash
docker compose -f docker-compose.osm2pgsql.yml run --rm \
  --entrypoint python3 \
  -v "$PWD:/work:ro" \
  -w /work \
  -e TARGET_DB_HOST=db \
  -e TARGET_DB_PORT=5432 \
  -e TARGET_DB_NAME=eisenbahn_demo \
  -e TARGET_DB_USER=postgres \
  -e TARGET_DB_PASSWORD=postgres \
  osm2pgsql-import scripts/admin_webgis_refresh.py
```

See [docs/osm-workflow.md](docs/osm-workflow.md) for the full workflow and verification queries.

## Current Limitations

- No bundled PBF extract is included.
- No real GPX files, database dumps or production configuration are included.
- The first release does not include the FastAPI backend or React frontend.
- The demo bootstrap provides only the minimal checkpoint/intersection contract needed by the OSM admin-unit mapping workflow.

## Roadmap

The intended growth path is incremental:

1. OSM/PostGIS workflow.
2. Minimal demo database bootstrap. Done for the OSM workflow slice.
3. GPX parsing and checkpoint matching.
4. FastAPI endpoints for checkpoint and admin-unit data.
5. Lightweight frontend map demo.

## Privacy And Scope

This repository deliberately excludes private operational details:

- production deployment and Portainer workflows
- private hostnames, domains, credentials and environment files
- real user GPX files
- database dumps and backups
- internal release logs and project worklogs

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
