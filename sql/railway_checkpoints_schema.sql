CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;

CREATE TABLE IF NOT EXISTS public.t_checkpoints_preview_raw (
    osm_type text NOT NULL,
    osm_id bigint NOT NULL,
    name text,
    railway text,
    public_transport text,
    operator text,
    ref text,
    uic_ref text,
    ifopt_ref text,
    wikidata text,
    tags jsonb NOT NULL DEFAULT '{}'::jsonb,
    geom geometry(Point, 4326),
    geom_3857 geometry(Point, 3857),
    country_code text,
    imported_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (osm_type, osm_id)
);

CREATE INDEX IF NOT EXISTS t_checkpoints_preview_raw_geom_gix
    ON public.t_checkpoints_preview_raw USING gist (geom);

CREATE INDEX IF NOT EXISTS t_checkpoints_preview_raw_geom_3857_gix
    ON public.t_checkpoints_preview_raw USING gist (geom_3857);

CREATE INDEX IF NOT EXISTS t_checkpoints_preview_raw_name_idx
    ON public.t_checkpoints_preview_raw (name);

CREATE INDEX IF NOT EXISTS t_checkpoints_preview_raw_railway_idx
    ON public.t_checkpoints_preview_raw (railway);

CREATE INDEX IF NOT EXISTS t_checkpoints_preview_raw_public_transport_idx
    ON public.t_checkpoints_preview_raw (public_transport);

CREATE TABLE IF NOT EXISTS public.t_osm_stop_area (
    osm_id bigint PRIMARY KEY,
    name text,
    public_transport text,
    relation_type text,
    operator text,
    ref text,
    uic_ref text,
    ifopt_ref text,
    wikidata text,
    tags jsonb NOT NULL DEFAULT '{}'::jsonb,
    imported_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS t_osm_stop_area_public_transport_idx
    ON public.t_osm_stop_area (public_transport);

CREATE TABLE IF NOT EXISTS public.t_osm_stop_area_member (
    stop_area_osm_id bigint NOT NULL,
    member_seq int NOT NULL,
    member_type text NOT NULL,
    member_osm_id bigint NOT NULL,
    member_role text NOT NULL DEFAULT '',
    imported_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (stop_area_osm_id, member_seq)
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 't_osm_stop_area_member_stop_area_fkey'
          AND conrelid = 'public.t_osm_stop_area_member'::regclass
    ) THEN
        ALTER TABLE public.t_osm_stop_area_member
            ADD CONSTRAINT t_osm_stop_area_member_stop_area_fkey
            FOREIGN KEY (stop_area_osm_id)
            REFERENCES public.t_osm_stop_area(osm_id)
            ON DELETE CASCADE;
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS t_osm_stop_area_member_lookup_idx
    ON public.t_osm_stop_area_member (member_type, member_osm_id);

CREATE TABLE IF NOT EXISTS public.t_checkpoints_preview (
    id bigserial PRIMARY KEY,
    osm_type text NOT NULL,
    osm_id bigint NOT NULL,
    name text,
    railway text,
    public_transport text,
    canonical_key text,
    source_type text NOT NULL DEFAULT 'legacy',
    source_priority int,
    name_norm text,
    members_count int,
    score int,
    refs jsonb NOT NULL DEFAULT '{}'::jsonb,
    tags jsonb NOT NULL DEFAULT '{}'::jsonb,
    geom geometry(Point, 4326),
    geom_3857 geometry(Point, 3857),
    buffer_3857 geometry(Polygon, 3857),
    country_code text,
    imported_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.t_checkpoints_preview
    ADD COLUMN IF NOT EXISTS public_transport text;

ALTER TABLE public.t_checkpoints_preview
    ADD COLUMN IF NOT EXISTS canonical_key text;

ALTER TABLE public.t_checkpoints_preview
    ADD COLUMN IF NOT EXISTS source_type text;

ALTER TABLE public.t_checkpoints_preview
    ADD COLUMN IF NOT EXISTS source_priority int;

ALTER TABLE public.t_checkpoints_preview
    ADD COLUMN IF NOT EXISTS name_norm text;

ALTER TABLE public.t_checkpoints_preview
    ADD COLUMN IF NOT EXISTS members_count int;

ALTER TABLE public.t_checkpoints_preview
    ADD COLUMN IF NOT EXISTS score int;

ALTER TABLE public.t_checkpoints_preview
    ADD COLUMN IF NOT EXISTS refs jsonb;

ALTER TABLE public.t_checkpoints_preview
    ADD COLUMN IF NOT EXISTS buffer_3857 geometry(Polygon, 3857);

ALTER TABLE public.t_checkpoints_preview
    ALTER COLUMN source_type SET DEFAULT 'legacy';

ALTER TABLE public.t_checkpoints_preview
    ALTER COLUMN refs SET DEFAULT '{}'::jsonb;

UPDATE public.t_checkpoints_preview
SET source_type = 'legacy'
WHERE source_type IS NULL;

UPDATE public.t_checkpoints_preview
SET refs = '{}'::jsonb
WHERE refs IS NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 't_checkpoints_preview_source_type_chk'
          AND conrelid = 'public.t_checkpoints_preview'::regclass
    ) THEN
        ALTER TABLE public.t_checkpoints_preview
            ADD CONSTRAINT t_checkpoints_preview_source_type_chk
            CHECK (source_type IN ('legacy', 'stop_area', 'station', 'halt', 'cluster'));
    END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS t_checkpoints_preview_osm_uidx
    ON public.t_checkpoints_preview (osm_type, osm_id);

CREATE UNIQUE INDEX IF NOT EXISTS t_checkpoints_preview_canonical_key_uidx
    ON public.t_checkpoints_preview (canonical_key)
    WHERE canonical_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS t_checkpoints_preview_geom_gix
    ON public.t_checkpoints_preview USING gist (geom);

CREATE INDEX IF NOT EXISTS t_checkpoints_preview_geom_3857_gix
    ON public.t_checkpoints_preview USING gist (geom_3857);

CREATE INDEX IF NOT EXISTS t_checkpoints_preview_buffer_3857_gix
    ON public.t_checkpoints_preview USING gist (buffer_3857);

CREATE INDEX IF NOT EXISTS t_checkpoints_preview_tags_gin
    ON public.t_checkpoints_preview USING gin (tags);

CREATE INDEX IF NOT EXISTS t_checkpoints_preview_railway_idx
    ON public.t_checkpoints_preview (railway);

CREATE INDEX IF NOT EXISTS t_checkpoints_preview_source_type_idx
    ON public.t_checkpoints_preview (source_type);

CREATE INDEX IF NOT EXISTS t_checkpoints_preview_name_norm_idx
    ON public.t_checkpoints_preview (name_norm);

CREATE OR REPLACE FUNCTION public.normalize_checkpoint_name(raw_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT NULLIF(
        regexp_replace(
            regexp_replace(
                translate(
                    lower(trim(COALESCE(raw_name, ''))),
                    'äöüß',
                    'aous'
                ),
                '\(.*?\)',
                ' ',
                'g'
            ),
            '\s+',
            ' ',
            'g'
        ),
        ''
    );
$$;

CREATE OR REPLACE FUNCTION public.normalize_checkpoint_name_cfg(raw_name text, strip_parens boolean)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT NULLIF(
        regexp_replace(
            regexp_replace(
                regexp_replace(
                    CASE
                        WHEN COALESCE(strip_parens, true) THEN
                            regexp_replace(
                                translate(
                                    lower(trim(COALESCE(raw_name, ''))),
                                    'äöüß',
                                    'aous'
                                ),
                                '\(.*?\)',
                                ' ',
                                'g'
                            )
                        ELSE
                            translate(
                                lower(trim(COALESCE(raw_name, ''))),
                                'äöüß',
                                'aous'
                            )
                    END,
                    '(^| )hauptbahnhof( |$)',
                    '\1hbf\2',
                    'g'
                ),
                '(^| )vorbahnhof( |$)',
                '\1vorbf\2',
                'g'
            ),
            '\s+',
            ' ',
            'g'
        ),
        ''
    );
$$;

CREATE OR REPLACE FUNCTION public.normalize_checkpoint_match_name_cfg(raw_name text, strip_parens boolean)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    WITH base AS (
        SELECT COALESCE(public.normalize_checkpoint_name_cfg(raw_name, strip_parens), '') AS n
    ),
    mode_city_combo AS (
        SELECT regexp_replace(n, '^([^,]+),\s*(s\+u|u\+s|s/u|u/s)\s+(.+)$', '\1 \3', 'g') AS n
        FROM base
    ),
    mode_city_single AS (
        SELECT regexp_replace(n, '^([^,]+),\s*(s|u|s-bahn|u-bahn|sbahn|ubahn|s\.|u\.)\s+(.+)$', '\1 \3', 'g') AS n
        FROM mode_city_combo
    ),
    suffix_bahnhof AS (
        SELECT regexp_replace(n, '([, ]+)(bahnhof|bhf|bf)$', '', 'g') AS n
        FROM mode_city_single
    ),
    mode_plain_combo AS (
        SELECT regexp_replace(n, '^(s\+u|u\+s|s/u|u/s)\s+', '', 'g') AS n
        FROM suffix_bahnhof
    ),
    mode_plain_single AS (
        SELECT regexp_replace(n, '^(s|u|s-bahn|u-bahn|sbahn|ubahn|s\.|u\.)\s+', '', 'g') AS n
        FROM mode_plain_combo
    ),
    punct_norm AS (
        SELECT regexp_replace(n, '[,;:/-]+', ' ', 'g') AS n
        FROM mode_plain_single
    ),
    locality_strip_long AS (
        SELECT regexp_replace(n, '^[a-z0-9.-]{2,}\s+([a-z0-9.-]+\s+.+)$', '\1', 'g') AS n
        FROM punct_norm
    )
    SELECT NULLIF(
        btrim(regexp_replace(n, '\s+', ' ', 'g')),
        ''
    )
    FROM locality_strip_long;
$$;
