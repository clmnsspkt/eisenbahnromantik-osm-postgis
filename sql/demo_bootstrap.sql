CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;

CREATE TABLE IF NOT EXISTS public.t_checkpoints (
    stop_id int PRIMARY KEY,
    name text,
    stop_name text,
    osm_type text,
    osm_id bigint,
    geom geometry(Point, 3857),
    geom_4326 geometry(Point, 4326),
    buffer geometry(Polygon, 3857),
    imported_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS t_checkpoints_osm_uidx
    ON public.t_checkpoints (osm_type, osm_id)
    WHERE osm_type IS NOT NULL AND osm_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS t_checkpoints_geom_gix
    ON public.t_checkpoints USING gist (geom);

CREATE INDEX IF NOT EXISTS t_checkpoints_geom_4326_gix
    ON public.t_checkpoints USING gist (geom_4326);

CREATE INDEX IF NOT EXISTS t_checkpoints_buffer_gix
    ON public.t_checkpoints USING gist (buffer);

CREATE TABLE IF NOT EXISTS public.t_intersections (
    id bigserial PRIMARY KEY,
    rider_id int NOT NULL,
    checkpoint int NOT NULL,
    "time" timestamp NOT NULL DEFAULT now(),
    source text NOT NULL DEFAULT 'demo',
    imported_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT t_intersections_checkpoint_fkey
        FOREIGN KEY (checkpoint)
        REFERENCES public.t_checkpoints(stop_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS t_intersections_checkpoint_idx
    ON public.t_intersections (checkpoint);

CREATE INDEX IF NOT EXISTS t_intersections_rider_idx
    ON public.t_intersections (rider_id);

CREATE INDEX IF NOT EXISTS t_intersections_time_idx
    ON public.t_intersections ("time");
