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

## Checkpoint Canonicalization

Canonicalization is intentionally part of the public OSM workflow. The purpose is to turn many overlapping OSM objects for the same real-world railway location into one auditable checkpoint candidate.

The current rules use:

- normalized checkpoint names and match keys
- public-transport `stop_area` relations and members
- OSM identity tags such as `wikidata`, `uic_ref` and `ifopt_ref`
- source priority for stations, halts, stops, platforms and stop positions
- distance-based clustering and stop-area swallowing thresholds

The rule output remains inspectable because raw candidates stay in `t_checkpoints_preview_raw` and canonical candidates stay in `t_checkpoints_preview`. When duplicate checkpoints appear downstream, use these two tables to identify whether the duplication came from missing stop-area membership, overly strict name matching, distance thresholds, or source-priority ranking.

Rule parameters are configured through environment variables consumed by `scripts/import_osm2pgsql_targets.py`, including:

- `CHECKPOINT_CLUSTER_RADIUS_M`
- `CHECKPOINT_STOPAREA_SWALLOW_RADIUS_M`
- `CHECKPOINT_STOPAREA_LINK_RADIUS_M`
- `CHECKPOINT_STOPAREA_DEDUP_GRID_M`
- `CHECKPOINT_NAME_STRIP_PARENS`
- `CHECKPOINT_KEEP_TIEF_VARIANTS`
- `CHECKPOINT_STRICT_RAIL_ONLY`
- `CHECKPOINT_EXCLUDE_TRAM_STOPS`

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
