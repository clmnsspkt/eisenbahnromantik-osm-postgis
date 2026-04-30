# OSM Data Model

The OSM workflow separates raw import data from application-facing data.

## Raw Import Schemas

Each PBF extract is imported into its own schema, such as `osm_import_demo`.

The flex import creates these relevant tables:

- `admin_boundary`: administrative boundary polygons and tags
- `railway_point`: railway and public-transport point objects
- `pt_stop_area`: public transport stop-area relations
- `pt_stop_area_member`: members of stop-area relations

## Adapter Views

Adapter views normalize one or more import schemas into a stable public interface:

- `v_osm_admin_boundaries_osm2pgsql`
- `v_osm_railway_points_osm2pgsql`
- `v_osm_railway_stops_osm2pgsql`
- `v_osm_stop_area_osm2pgsql`
- `v_osm_stop_area_member_osm2pgsql`

These views allow the target import SQL to stay independent from the number of PBF extracts.

## Boundary Targets

`osm_admin_boundaries` stores curated administrative boundaries with normalized geometry and tags.

`admin_unit` stores application-facing administrative units. It supports:

- stable IDs
- OSM source identity
- country code
- admin level
- parent-child hierarchy
- geometry in WGS84 and Web Mercator

`admin_unit_settings` controls whether a unit is active in downstream views.

## Railway Checkpoint Targets

`t_checkpoints_preview_raw` stores raw checkpoint candidates from OSM railway and public-transport objects.

`t_checkpoints_preview` stores canonical checkpoint candidates after clustering, stop-area handling and name normalization.

The broader application can later decide which preview rows become active checkpoints.

## Demo Application Contract

`sql/demo_bootstrap.sql` creates the minimal application-side tables needed for the OSM workflow:

- `t_checkpoints`: active checkpoint points in Web Mercator, keyed by `stop_id`
- `t_intersections`: optional rider/checkpoint visit rows used by KPI views

`sql/demo_publish_preview_checkpoints.sql` replaces `t_checkpoints` with canonical preview checkpoints for local demo mapping. This is not a substitute for the full GPX import workflow; it is a small bridge that lets the OSM workflow produce checkpoint-region mappings on its own.

## Region Mapping

`checkpoint_admin_unit` maps checkpoints to administrative units. This enables coverage queries such as:

- total checkpoints per region
- visited checkpoints per region and rider
- map layers for active regions

The mapping is refreshed from checkpoint geometries and admin-unit polygons.
