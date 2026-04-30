CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE IF NOT EXISTS public.admin_unit (
    id bigserial PRIMARY KEY,
    osm_type text NOT NULL,
    osm_id bigint NOT NULL,
    country_code text,
    admin_level int,
    name text,
    tags jsonb NOT NULL DEFAULT '{}'::jsonb,
    geom geometry(MultiPolygon, 4326),
    geom_3857 geometry(MultiPolygon, 3857),
    parent_id bigint,
    imported_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.admin_unit ADD COLUMN IF NOT EXISTS osm_type text;
ALTER TABLE public.admin_unit ADD COLUMN IF NOT EXISTS osm_id bigint;
ALTER TABLE public.admin_unit ADD COLUMN IF NOT EXISTS country_code text;
ALTER TABLE public.admin_unit ADD COLUMN IF NOT EXISTS admin_level int;
ALTER TABLE public.admin_unit ADD COLUMN IF NOT EXISTS name text;
ALTER TABLE public.admin_unit ADD COLUMN IF NOT EXISTS tags jsonb;
ALTER TABLE public.admin_unit ADD COLUMN IF NOT EXISTS geom geometry(MultiPolygon, 4326);
ALTER TABLE public.admin_unit ADD COLUMN IF NOT EXISTS geom_3857 geometry(MultiPolygon, 3857);
ALTER TABLE public.admin_unit ADD COLUMN IF NOT EXISTS parent_id bigint;
ALTER TABLE public.admin_unit ADD COLUMN IF NOT EXISTS imported_at timestamptz;

ALTER TABLE public.admin_unit ALTER COLUMN tags SET DEFAULT '{}'::jsonb;
ALTER TABLE public.admin_unit ALTER COLUMN imported_at SET DEFAULT now();

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'admin_unit_parent_id_fkey'
          AND conrelid = 'public.admin_unit'::regclass
    ) THEN
        ALTER TABLE public.admin_unit
            ADD CONSTRAINT admin_unit_parent_id_fkey
            FOREIGN KEY (parent_id)
            REFERENCES public.admin_unit(id)
            ON DELETE SET NULL;
    END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS admin_unit_osm_uidx
    ON public.admin_unit (osm_type, osm_id);

CREATE INDEX IF NOT EXISTS admin_unit_admin_level_idx
    ON public.admin_unit (admin_level);

CREATE INDEX IF NOT EXISTS admin_unit_parent_idx
    ON public.admin_unit (parent_id);

CREATE INDEX IF NOT EXISTS admin_unit_geom_gix
    ON public.admin_unit USING gist (geom);

CREATE INDEX IF NOT EXISTS admin_unit_geom_3857_gix
    ON public.admin_unit USING gist (geom_3857);

CREATE INDEX IF NOT EXISTS admin_unit_tags_gin
    ON public.admin_unit USING gin (tags);

CREATE TABLE IF NOT EXISTS public.admin_unit_settings (
    admin_unit_id bigint PRIMARY KEY,
    is_active boolean NOT NULL DEFAULT false,
    activated_at timestamptz,
    rules jsonb NOT NULL DEFAULT '{}'::jsonb,
    note text
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'admin_unit_settings_admin_unit_id_fkey'
          AND conrelid = 'public.admin_unit_settings'::regclass
    ) THEN
        ALTER TABLE public.admin_unit_settings
            ADD CONSTRAINT admin_unit_settings_admin_unit_id_fkey
            FOREIGN KEY (admin_unit_id)
            REFERENCES public.admin_unit(id)
            ON DELETE CASCADE;
    END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.checkpoint_admin_unit (
    checkpoint_stop_id int NOT NULL,
    admin_unit_id bigint NOT NULL,
    admin_level int NOT NULL,
    PRIMARY KEY (checkpoint_stop_id, admin_unit_id)
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'checkpoint_admin_unit'
          AND column_name = 'checkpoint_tid'
    ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'checkpoint_admin_unit'
          AND column_name = 'checkpoint_stop_id'
    ) THEN
        ALTER TABLE public.checkpoint_admin_unit
            RENAME COLUMN checkpoint_tid TO checkpoint_stop_id;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'checkpoint_admin_unit_checkpoint_tid_fkey'
          AND conrelid = 'public.checkpoint_admin_unit'::regclass
    ) THEN
        ALTER TABLE public.checkpoint_admin_unit
            DROP CONSTRAINT checkpoint_admin_unit_checkpoint_tid_fkey;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_index idx
        JOIN pg_attribute att ON att.attrelid = idx.indrelid
        WHERE idx.indrelid = 'public.t_checkpoints'::regclass
          AND idx.indisunique
          AND att.attname = 'stop_id'
          AND att.attnum = ANY(idx.indkey)
    ) AND NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'checkpoint_admin_unit_checkpoint_stop_id_fkey'
          AND conrelid = 'public.checkpoint_admin_unit'::regclass
    ) THEN
        ALTER TABLE public.checkpoint_admin_unit
            ADD CONSTRAINT checkpoint_admin_unit_checkpoint_stop_id_fkey
            FOREIGN KEY (checkpoint_stop_id)
            REFERENCES public.t_checkpoints(stop_id)
            ON DELETE CASCADE;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'checkpoint_admin_unit_admin_unit_id_fkey'
          AND conrelid = 'public.checkpoint_admin_unit'::regclass
    ) THEN
        ALTER TABLE public.checkpoint_admin_unit
            ADD CONSTRAINT checkpoint_admin_unit_admin_unit_id_fkey
            FOREIGN KEY (admin_unit_id)
            REFERENCES public.admin_unit(id)
            ON DELETE CASCADE;
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS checkpoint_admin_unit_admin_unit_idx
    ON public.checkpoint_admin_unit (admin_unit_id);

DROP INDEX IF EXISTS checkpoint_admin_unit_checkpoint_idx;
CREATE INDEX IF NOT EXISTS checkpoint_admin_unit_checkpoint_stop_idx
    ON public.checkpoint_admin_unit (checkpoint_stop_id);

CREATE INDEX IF NOT EXISTS checkpoint_admin_unit_level_admin_idx
    ON public.checkpoint_admin_unit (admin_level, admin_unit_id);

CREATE OR REPLACE FUNCTION public.refresh_admin_unit()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO public.admin_unit (
        osm_type,
        osm_id,
        country_code,
        admin_level,
        name,
        tags,
        geom,
        geom_3857,
        imported_at
    )
    SELECT
        b.osm_type,
        b.osm_id,
        b.country_code,
        b.admin_level,
        b.name,
        b.tags,
        b.geom,
        ST_Multi(
            ST_Transform(
                CASE
                    WHEN ST_SRID(b.geom) = 0 THEN ST_SetSRID(b.geom, 4326)
                    ELSE b.geom
                END,
                3857
            )
        )::geometry(MultiPolygon, 3857) AS geom_3857,
        now() AS imported_at
    FROM (
        SELECT
            b.osm_type,
            b.osm_id,
            b.country_code,
            b.admin_level,
            b.name,
            b.tags,
            b.geom
        FROM public.osm_admin_boundaries b
        UNION ALL
        SELECT
            b.osm_type || '_lvl6' AS osm_type,
            b.osm_id,
            b.country_code,
            6 AS admin_level,
            b.name,
            b.tags || jsonb_build_object(
                'derived_admin_level', '6',
                'derived_from_admin_level', b.admin_level
            ) AS tags,
            b.geom
        FROM public.osm_admin_boundaries b
        WHERE b.admin_level = 4
          AND b.geom IS NOT NULL
          AND (
              COALESCE(b.tags->>'admin_level:6', '') = 'yes'
              OR COALESCE(b.tags->>'de:place', '') = 'city'
          )
          AND NOT EXISTS (
              SELECT 1
              FROM public.osm_admin_boundaries existing
              WHERE existing.admin_level = 6
                AND existing.name = b.name
                AND existing.country_code IS NOT DISTINCT FROM b.country_code
          )
    ) b
    ON CONFLICT (osm_type, osm_id) DO UPDATE
    SET country_code = EXCLUDED.country_code,
        admin_level = EXCLUDED.admin_level,
        name = EXCLUDED.name,
        tags = EXCLUDED.tags,
        geom = EXCLUDED.geom,
        geom_3857 = EXCLUDED.geom_3857,
        imported_at = EXCLUDED.imported_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_admin_unit_parents()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    WITH parent_candidates AS (
        SELECT
            child.id AS child_id,
            parent.id AS parent_id,
            parent.admin_level AS parent_level,
            ST_Area(ST_Intersection(parent.geom_3857, child.geom_3857)) AS area
        FROM public.admin_unit child
        JOIN public.admin_unit parent
          ON parent.admin_level < child.admin_level
         AND parent.geom_3857 IS NOT NULL
         AND child.geom_3857 IS NOT NULL
         AND ST_Intersects(parent.geom_3857, child.geom_3857)
    ),
    ranked AS (
        SELECT
            child_id,
            parent_id,
            row_number() OVER (
                PARTITION BY child_id
                ORDER BY parent_level DESC, area DESC
            ) AS rn
        FROM parent_candidates
    )
    UPDATE public.admin_unit child
    SET parent_id = ranked.parent_id
    FROM ranked
    WHERE child.id = ranked.child_id
      AND ranked.rn = 1;

    WITH parent_candidates AS (
        SELECT
            child.id AS child_id,
            parent.id AS parent_id,
            parent.admin_level AS parent_level,
            ST_Area(ST_Intersection(parent.geom_3857, child.geom_3857)) AS area
        FROM public.admin_unit child
        JOIN public.admin_unit parent
          ON parent.admin_level < child.admin_level
         AND parent.geom_3857 IS NOT NULL
         AND child.geom_3857 IS NOT NULL
         AND ST_Intersects(parent.geom_3857, child.geom_3857)
    ),
    ranked AS (
        SELECT
            child_id,
            parent_id,
            row_number() OVER (
                PARTITION BY child_id
                ORDER BY parent_level DESC, area DESC
            ) AS rn
        FROM parent_candidates
    )
    UPDATE public.admin_unit child
    SET parent_id = NULL
    WHERE child.admin_level IS NOT NULL
      AND child.admin_level > 2
      AND child.id NOT IN (SELECT child_id FROM ranked WHERE rn = 1);
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_checkpoint_admin_unit(levels int[] DEFAULT '{4,6,8}')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM public.checkpoint_admin_unit
    WHERE admin_level = ANY(levels);

    INSERT INTO public.checkpoint_admin_unit (checkpoint_stop_id, admin_unit_id, admin_level)
    SELECT
        c.stop_id,
        a.id,
        a.admin_level
    FROM public.t_checkpoints c
    JOIN public.admin_unit a
      ON a.admin_level = ANY(levels)
     AND a.geom_3857 IS NOT NULL
     AND ST_Covers(a.geom_3857, c.geom);
END;
$$;

CREATE OR REPLACE VIEW public.v_admin_kpi_total AS
WITH RECURSIVE active_units AS (
    SELECT a.id
    FROM public.admin_unit a
    JOIN public.admin_unit_settings s
      ON s.admin_unit_id = a.id
    WHERE s.is_active = true
    UNION
    SELECT child.id
    FROM public.admin_unit child
    JOIN active_units parent
      ON child.parent_id = parent.id
)
SELECT
    m.admin_unit_id,
    m.admin_level,
    count(*) AS total_checkpoints
FROM public.checkpoint_admin_unit m
JOIN active_units au
  ON au.id = m.admin_unit_id
GROUP BY m.admin_unit_id, m.admin_level;

CREATE OR REPLACE VIEW public.v_admin_kpi_rider AS
WITH RECURSIVE active_units_raw AS (
    SELECT a.id
        , COALESCE(s.activated_at, '-infinity'::timestamptz) AS activated_from
    FROM public.admin_unit a
    JOIN public.admin_unit_settings s
      ON s.admin_unit_id = a.id
    WHERE s.is_active = true
    UNION
    SELECT child.id
        , parent.activated_from
    FROM public.admin_unit child
    JOIN active_units_raw parent
      ON child.parent_id = parent.id
),
active_units AS (
    SELECT
        id,
        MIN(activated_from) AS activated_from
    FROM active_units_raw
    GROUP BY id
)
SELECT
    m.admin_unit_id,
    m.admin_level,
    i.rider_id,
    count(DISTINCT i.checkpoint) AS visited_checkpoints
FROM public.checkpoint_admin_unit m
JOIN active_units au
  ON au.id = m.admin_unit_id
JOIN public.t_intersections i
  ON i.checkpoint = m.checkpoint_stop_id
 AND i."time" >= (au.activated_from AT TIME ZONE 'UTC')
GROUP BY m.admin_unit_id, m.admin_level, i.rider_id;

CREATE OR REPLACE VIEW public.v_admin_units_webgis AS
WITH RECURSIVE active_tree AS (
    SELECT a.id
    FROM public.admin_unit a
    JOIN public.admin_unit_settings s
      ON s.admin_unit_id = a.id
    WHERE s.is_active = true
    UNION
    SELECT child.id
    FROM public.admin_unit child
    JOIN active_tree parent
      ON child.parent_id = parent.id
)
SELECT
    a.id,
    a.name,
    a.admin_level,
    a.parent_id,
    a.country_code,
    (at.id IS NOT NULL) AS is_active,
    COALESCE(t.total_checkpoints, 0) AS total_checkpoints,
    a.geom
FROM public.admin_unit a
LEFT JOIN active_tree at
  ON at.id = a.id
LEFT JOIN public.v_admin_kpi_total t
  ON t.admin_unit_id = a.id;
