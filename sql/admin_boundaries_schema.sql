CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;

CREATE TABLE IF NOT EXISTS public.osm_admin_boundaries (
    id bigserial PRIMARY KEY,
    osm_type text NOT NULL,
    osm_id bigint NOT NULL,
    name text,
    admin_level int,
    boundary text,
    tags jsonb NOT NULL DEFAULT '{}'::jsonb,
    geom geometry(MultiPolygon, 4326),
    country_code text,
    imported_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS osm_admin_boundaries_osm_uidx
    ON public.osm_admin_boundaries (osm_type, osm_id);

CREATE INDEX IF NOT EXISTS osm_admin_boundaries_geom_gix
    ON public.osm_admin_boundaries USING gist (geom);

CREATE INDEX IF NOT EXISTS osm_admin_boundaries_tags_gin
    ON public.osm_admin_boundaries USING gin (tags);

CREATE INDEX IF NOT EXISTS osm_admin_boundaries_country_level_idx
    ON public.osm_admin_boundaries (country_code, admin_level);
