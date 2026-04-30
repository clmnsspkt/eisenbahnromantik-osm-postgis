# OSM Workflow

This document describes the first public slice of Eisenbahnromantik: importing OpenStreetMap data and transforming it into application-ready PostGIS structures.

## Goal

The workflow converts OSM PBF extracts into two target data groups:

- railway checkpoint candidates derived from railway and public-transport OSM objects
- administrative units derived from OSM administrative boundaries

The broader application can use these structures for maps, GPX matching, rankings and region progress.

## Components

- `osm2pgsql/flex.lua`: selects the OSM objects kept during import
- `Dockerfile.osm2pgsql`: builds an import image with `osm2pgsql` and `psql`
- `docker-compose.osm2pgsql.yml`: runs one import job against a target PostGIS database
- `scripts/osm2pgsql_entrypoint.sh`: validates the PBF path and runs `osm2pgsql`
- `scripts/import_osm2pgsql_targets.py`: creates adapter views and applies target SQL
- `scripts/admin_webgis_refresh.py`: refreshes admin units and checkpoint-region mappings
- `sql/*.sql`: defines and populates the target PostGIS structures

## Step 1: Import OSM Into An Isolated Schema

Use one schema per PBF extract. For example:

```text
osm_import_de
osm_import_at
osm_import_ch
```

The flex style keeps:

- administrative boundaries
- railway points
- public transport stop areas
- stop-area members

Example import:

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

## Step 2: Build Adapter Views

`scripts/import_osm2pgsql_targets.py` checks the configured import schemas and creates public adapter views:

- `v_osm_admin_boundaries_osm2pgsql`
- `v_osm_railway_points_osm2pgsql`
- `v_osm_railway_stops_osm2pgsql`
- `v_osm_stop_area_osm2pgsql`
- `v_osm_stop_area_member_osm2pgsql`

For multiple import schemas, these views are built with `UNION ALL`.

```bash
TARGET_DB_HOST=db \
TARGET_DB_PORT=5432 \
TARGET_DB_NAME=eisenbahn_demo \
TARGET_DB_USER=postgres \
TARGET_DB_PASSWORD=postgres \
OSM_IMPORT_SCHEMAS=osm_import_de,osm_import_at,osm_import_ch \
python scripts/import_osm2pgsql_targets.py
```

## Step 3: Populate Target Tables

The same script applies:

- `sql/admin_boundaries_schema.sql`
- `sql/admin_boundaries_import_osm2pgsql.sql`
- `sql/railway_checkpoints_schema.sql`
- `sql/railway_checkpoints_import_osm2pgsql.sql`

The admin import stores curated OSM boundary data.

The railway import stores checkpoint preview data in two layers:

- `t_checkpoints_preview_raw`: raw railway and public-transport candidates
- `t_checkpoints_preview`: canonical checkpoint candidates

This split keeps the derivation auditable.

## Step 4: Refresh Admin Units

`scripts/admin_webgis_refresh.py` applies `sql/admin_webgis_schema.sql` and refreshes:

- `admin_unit`
- `admin_unit_settings`
- `checkpoint_admin_unit`
- admin-unit parent hierarchy
- admin-unit KPI and WebGIS views

```bash
TARGET_DB_HOST=db \
TARGET_DB_PORT=5432 \
TARGET_DB_NAME=eisenbahn_demo \
TARGET_DB_USER=postgres \
TARGET_DB_PASSWORD=postgres \
python scripts/admin_webgis_refresh.py
```

## Invariants

- Do not run two PostgreSQL containers against the same database volume.
- Keep raw OSM imports in dedicated schemas.
- Use one schema per PBF extract for multi-region imports.
- Rebuild adapter views after changing the import schema list.
- Verify target tables before deleting or replacing raw import data.
- Keep real PBF files, dumps and production configuration out of the repository.

## Verification Queries

Check import tables:

```sql
SELECT
  to_regclass('osm_import_demo.admin_boundary') AS admin_boundary,
  to_regclass('osm_import_demo.railway_point') AS railway_point;
```

Check canonical checkpoint candidates:

```sql
SELECT country_code, count(*)
FROM public.t_checkpoints_preview
GROUP BY country_code
ORDER BY country_code;
```

Check admin units:

```sql
SELECT country_code, admin_level, count(*)
FROM public.admin_unit
GROUP BY country_code, admin_level
ORDER BY country_code, admin_level;
```

Check checkpoint-region mapping:

```sql
SELECT admin_level, count(*)
FROM public.checkpoint_admin_unit
GROUP BY admin_level
ORDER BY admin_level;
```
