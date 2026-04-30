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

## Quick Start Shape

This first release is a documented workflow slice. It assumes a running PostGIS database with the extension set needed by the SQL files and, for the admin mapping step, the application checkpoint tables referenced by `sql/admin_webgis_schema.sql`.

```bash
cp .env.example .env
docker compose -f docker-compose.osm2pgsql.yml build
```

Place a PBF extract in the Docker volume or mount path used by the import container, then run an import with an isolated schema:

```bash
TARGET_DB_HOST=db \
TARGET_DB_PORT=5432 \
TARGET_DB_NAME=eisenbahn_demo \
TARGET_DB_USER=postgres \
TARGET_DB_PASSWORD=postgres \
OSM_IMPORT_SCHEMA=osm_import_demo \
PBF_PATH=/data/example.osm.pbf \
docker compose -f docker-compose.osm2pgsql.yml run --rm osm2pgsql-import
```

Build target tables and adapter views:

```bash
TARGET_DB_HOST=db \
TARGET_DB_PORT=5432 \
TARGET_DB_NAME=eisenbahn_demo \
TARGET_DB_USER=postgres \
TARGET_DB_PASSWORD=postgres \
OSM_IMPORT_SCHEMAS=osm_import_demo \
python scripts/import_osm2pgsql_targets.py
```

Refresh derived admin-unit tables and mappings:

```bash
TARGET_DB_HOST=db \
TARGET_DB_PORT=5432 \
TARGET_DB_NAME=eisenbahn_demo \
TARGET_DB_USER=postgres \
TARGET_DB_PASSWORD=postgres \
python scripts/admin_webgis_refresh.py
```

See [docs/osm-workflow.md](docs/osm-workflow.md) for the full workflow and verification queries.

## Current Limitations

- No bundled PBF extract is included.
- No real GPX files, database dumps or production configuration are included.
- The first release does not include the FastAPI backend or React frontend.
- `admin_webgis_schema.sql` references checkpoint and intersection tables from the broader application model. A minimal demo bootstrap for those tables is planned as a later step.

## Roadmap

The intended growth path is incremental:

1. OSM/PostGIS workflow.
2. Minimal demo database bootstrap.
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
