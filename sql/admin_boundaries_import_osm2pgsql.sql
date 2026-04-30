WITH country_polygons AS (
    SELECT
        osm_id,
        COALESCE(
            NULLIF(tags_jsonb->>'ISO3166-1:alpha2', ''),
            NULLIF(tags_jsonb->>'ISO3166-1', ''),
            NULLIF(tags_jsonb->>'iso3166-1', ''),
            NULLIF(tags_jsonb->>'iso3166-1:alpha2', ''),
            NULLIF(tags_jsonb->>'is_in:country_code', ''),
            NULLIF(tags_jsonb->>'addr:country', ''),
            NULLIF(tags_jsonb->>'country_code', ''),
            CASE
                WHEN NULLIF(tags_jsonb->>'ISO3166-2', '') ~ '^[A-Za-z]{2}-'
                    THEN split_part(tags_jsonb->>'ISO3166-2', '-', 1)
                ELSE NULL
            END,
            CASE
                WHEN NULLIF(tags_jsonb->>'iso3166-2', '') ~ '^[A-Za-z]{2}-'
                    THEN split_part(tags_jsonb->>'iso3166-2', '-', 1)
                ELSE NULL
            END
        ) AS country_code,
        geom
    FROM public.v_osm_admin_boundaries_osm2pgsql
    WHERE admin_level IN (2, 4)
      AND geom IS NOT NULL
),
normalized_countries AS (
    SELECT
        osm_id,
        NULLIF(upper(country_code), '') AS country_code,
        geom
    FROM country_polygons
),
source_rows AS (
    SELECT DISTINCT ON (osm_id)
        'relation'::text AS osm_type,
        osm_id,
        name,
        admin_level,
        boundary,
        tags_jsonb AS tags,
        geom,
        COALESCE(
            NULLIF(tags_jsonb->>'ISO3166-1:alpha2', ''),
            NULLIF(tags_jsonb->>'ISO3166-1', ''),
            NULLIF(tags_jsonb->>'iso3166-1', ''),
            NULLIF(tags_jsonb->>'iso3166-1:alpha2', ''),
            NULLIF(tags_jsonb->>'is_in:country_code', ''),
            NULLIF(tags_jsonb->>'addr:country', ''),
            NULLIF(tags_jsonb->>'country_code', ''),
            CASE
                WHEN NULLIF(tags_jsonb->>'ISO3166-2', '') ~ '^[A-Za-z]{2}-'
                    THEN split_part(tags_jsonb->>'ISO3166-2', '-', 1)
                ELSE NULL
            END,
            CASE
                WHEN NULLIF(tags_jsonb->>'iso3166-2', '') ~ '^[A-Za-z]{2}-'
                    THEN split_part(tags_jsonb->>'iso3166-2', '-', 1)
                ELSE NULL
            END
        ) AS tag_country_code
    FROM public.v_osm_admin_boundaries_osm2pgsql
    WHERE geom IS NOT NULL
    ORDER BY osm_id, ST_Area(geom) DESC
)
INSERT INTO public.osm_admin_boundaries (
    osm_type,
    osm_id,
    name,
    admin_level,
    boundary,
    tags,
    geom,
    country_code,
    imported_at
)
SELECT
    s.osm_type,
    s.osm_id,
    s.name,
    s.admin_level,
    s.boundary,
    s.tags,
    s.geom,
    CASE
        WHEN s.admin_level = 2 THEN NULLIF(upper(s.tag_country_code), '')
        ELSE COALESCE(
            NULLIF(upper(s.tag_country_code), ''),
            (
                SELECT nc.country_code
                FROM normalized_countries nc
                WHERE nc.country_code IS NOT NULL
                  AND (ST_Contains(nc.geom, s.geom) OR ST_Intersects(nc.geom, s.geom))
                ORDER BY ST_Area(ST_Intersection(nc.geom, s.geom)) DESC
                LIMIT 1
            )
        )
    END AS country_code,
    now() AS imported_at
FROM source_rows s
ON CONFLICT (osm_type, osm_id) DO UPDATE
SET admin_level = EXCLUDED.admin_level,
    name = EXCLUDED.name,
    tags = EXCLUDED.tags,
    geom = EXCLUDED.geom,
    country_code = EXCLUDED.country_code,
    imported_at = EXCLUDED.imported_at;
