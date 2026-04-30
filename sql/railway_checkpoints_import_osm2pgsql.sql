TRUNCATE TABLE public.t_checkpoints_preview_raw;

WITH strict_settings AS (
    SELECT
        COALESCE(
            NULLIF(current_setting('app.checkpoint_strict_rail_only', true), ''),
            'true'
        )::boolean AS strict_rail_only,
        COALESCE(
            NULLIF(current_setting('app.checkpoint_exclude_tram_stops', true), ''),
            'true'
        )::boolean AS exclude_tram_stops
),
country_polygons AS (
    SELECT
        osm_id,
        COALESCE(
            NULLIF(tags->>'ISO3166-1', ''),
            NULLIF(tags->>'ISO3166-1:alpha2', ''),
            NULLIF(tags->>'iso3166-1', ''),
            NULLIF(tags->>'iso3166-1:alpha2', '')
        ) AS country_code,
        geom
    FROM public.osm_admin_boundaries
    WHERE admin_level = 2
),
normalized_countries AS (
    SELECT
        osm_id,
        NULLIF(upper(country_code), '') AS country_code,
        geom
    FROM country_polygons
),
source_points AS (
    SELECT DISTINCT ON (p.osm_type, p.osm_id)
        p.osm_type,
        p.osm_id,
        CASE
            WHEN COALESCE(p.name, '') ~* '^OSM (node|way|relation):[0-9]+$' THEN NULL
            ELSE p.name
        END AS name,
        p.railway,
        p.public_transport,
        p.operator,
        p.ref,
        p.uic_ref,
        p.ifopt_ref,
        p.wikidata,
        p.tags_jsonb,
        p.geom,
        p.geom_3857
    FROM public.v_osm_railway_points_osm2pgsql p
    CROSS JOIN strict_settings cfg
    WHERE p.geom_3857 IS NOT NULL
      AND (
          p.railway IN ('station', 'halt', 'stop', 'platform')
          OR p.public_transport IN ('station', 'platform', 'stop_position')
      )
      AND (
          cfg.strict_rail_only = false
          OR (
              COALESCE(lower(p.railway), '') IN ('station', 'halt', 'stop', 'platform')
              OR (
                  p.public_transport IN ('station', 'platform', 'stop_position')
                  AND COALESCE(lower(p.tags_jsonb->>'train'), '') IN ('yes', 'designated')
              )
          )
      )
      AND (
          cfg.exclude_tram_stops = false
          OR COALESCE(lower(p.railway), '') <> 'tram_stop'
      )
      AND (
          cfg.exclude_tram_stops = false
          OR COALESCE(lower(p.tags_jsonb->>'railway'), '') <> 'tram_stop'
      )
      AND COALESCE(lower(p.tags_jsonb->>'amenity'), '') <> 'ferry_terminal'
      AND COALESCE(lower(p.tags_jsonb->>'ferry'), '') <> 'yes'
      AND COALESCE(lower(p.tags_jsonb->>'station'), '') <> 'funicular'
      AND NOT (
          (
              COALESCE(lower(p.tags_jsonb->>'amenity'), '') = 'bus_station'
              OR COALESCE(lower(p.tags_jsonb->>'highway'), '') = 'bus_stop'
              OR COALESCE(lower(p.tags_jsonb->>'bus'), '') IN ('yes', 'designated')
          )
          AND COALESCE(lower(p.railway), '') NOT IN ('station', 'halt', 'stop')
          AND COALESCE(lower(p.tags_jsonb->>'train'), '') NOT IN ('yes', 'designated')
      )
      AND NOT (
          COALESCE(p.name, '') ~* '^OSM (node|way|relation):[0-9]+$'
          AND COALESCE(
              NULLIF(p.ref, ''),
              NULLIF(p.uic_ref, ''),
              NULLIF(p.ifopt_ref, ''),
              NULLIF(p.wikidata, '')
          ) IS NULL
      )
    ORDER BY
        p.osm_type,
        p.osm_id,
        (p.railway = 'station' OR p.public_transport = 'station') DESC,
        (p.railway = 'halt') DESC,
        (p.railway = 'stop') DESC,
        (p.public_transport = 'platform' OR p.railway = 'platform') DESC,
        (p.public_transport = 'stop_position') DESC,
        (p.name IS NOT NULL) DESC,
        length(p.name) DESC NULLS LAST
)
INSERT INTO public.t_checkpoints_preview_raw (
    osm_type,
    osm_id,
    name,
    railway,
    public_transport,
    operator,
    ref,
    uic_ref,
    ifopt_ref,
    wikidata,
    tags,
    geom,
    geom_3857,
    country_code,
    imported_at
)
SELECT
    sp.osm_type,
    sp.osm_id,
    sp.name,
    sp.railway,
    sp.public_transport,
    sp.operator,
    sp.ref,
    sp.uic_ref,
    sp.ifopt_ref,
    sp.wikidata,
    sp.tags_jsonb AS tags,
    sp.geom,
    sp.geom_3857,
    COALESCE(
        NULLIF(upper(
            COALESCE(
                NULLIF(sp.tags_jsonb->>'ISO3166-1', ''),
                NULLIF(sp.tags_jsonb->>'ISO3166-1:alpha2', ''),
                NULLIF(sp.tags_jsonb->>'iso3166-1', ''),
                NULLIF(sp.tags_jsonb->>'iso3166-1:alpha2', '')
            )
        ), ''),
        (
            SELECT nc.country_code
            FROM normalized_countries nc
            WHERE nc.country_code IS NOT NULL
              AND (ST_Contains(nc.geom, sp.geom) OR ST_Intersects(nc.geom, sp.geom))
            ORDER BY ST_Area(ST_Intersection(nc.geom, sp.geom)) DESC
            LIMIT 1
        ),
        'DE'
    ) AS country_code,
    now() AS imported_at
FROM source_points sp;

TRUNCATE TABLE public.t_osm_stop_area_member, public.t_osm_stop_area;

INSERT INTO public.t_osm_stop_area (
    osm_id,
    name,
    public_transport,
    relation_type,
    operator,
    ref,
    uic_ref,
    ifopt_ref,
    wikidata,
    tags,
    imported_at
)
SELECT DISTINCT ON (sa.osm_id)
    sa.osm_id,
    sa.name,
    sa.public_transport,
    sa.relation_type,
    sa.operator,
    sa.ref,
    sa.uic_ref,
    sa.ifopt_ref,
    sa.wikidata,
    sa.tags_jsonb,
    now()
FROM public.v_osm_stop_area_osm2pgsql sa
WHERE sa.osm_id IS NOT NULL
  AND sa.public_transport IN ('stop_area', 'stop_area_group')
ORDER BY
    sa.osm_id,
    (sa.public_transport = 'stop_area') DESC,
    (sa.name IS NOT NULL) DESC,
    length(sa.name) DESC NULLS LAST;

INSERT INTO public.t_osm_stop_area_member (
    stop_area_osm_id,
    member_seq,
    member_type,
    member_osm_id,
    member_role,
    imported_at
)
SELECT DISTINCT ON (m.stop_area_osm_id, m.member_seq)
    m.stop_area_osm_id,
    m.member_seq,
    m.member_type,
    m.member_osm_id,
    COALESCE(m.member_role, ''),
    now()
FROM public.v_osm_stop_area_member_osm2pgsql m
WHERE m.stop_area_osm_id IS NOT NULL
  AND EXISTS (
      SELECT 1
      FROM public.t_osm_stop_area sa
      WHERE sa.osm_id = m.stop_area_osm_id
  )
ORDER BY
    m.stop_area_osm_id,
    m.member_seq,
    m.member_type,
    m.member_osm_id,
    COALESCE(m.member_role, '');

TRUNCATE TABLE public.t_checkpoints_preview;

WITH settings AS (
    SELECT
        COALESCE(NULLIF(current_setting('app.checkpoint_cluster_radius_m', true), ''), '350')::double precision AS cluster_radius_m,
        COALESCE(NULLIF(current_setting('app.checkpoint_buffer_m', true), ''), '500')::double precision AS buffer_m,
        COALESCE(NULLIF(current_setting('app.checkpoint_stoparea_swallow_radius_m', true), ''), '150')::double precision AS swallow_radius_m,
        COALESCE(NULLIF(current_setting('app.checkpoint_stoparea_link_radius_m', true), ''), '100')::double precision AS stop_area_link_radius_m,
        COALESCE(NULLIF(current_setting('app.checkpoint_name_strip_parens', true), ''), 'true')::boolean AS name_strip_parens,
        GREATEST(
            COALESCE(NULLIF(current_setting('app.checkpoint_stoparea_dedup_grid_m', true), ''), '1')::double precision,
            0.1
        ) AS stop_area_dedup_grid_m
),
raw_candidates AS (
    SELECT
        r.osm_type,
        r.osm_id,
        r.name,
        r.railway,
        r.public_transport,
        r.operator,
        r.ref,
        r.uic_ref,
        r.ifopt_ref,
        r.wikidata,
        r.tags,
        r.geom,
        r.geom_3857,
        r.country_code,
        public.normalize_checkpoint_name_cfg(r.name, s.name_strip_parens) AS name_norm,
        public.normalize_checkpoint_match_name_cfg(r.name, s.name_strip_parens) AS name_match_key,
        CASE
            WHEN COALESCE(r.railway, '') = 'station' OR COALESCE(r.public_transport, '') = 'station' THEN 500
            WHEN COALESCE(r.railway, '') = 'halt' THEN 400
            WHEN COALESCE(r.railway, '') = 'stop' THEN 350
            WHEN COALESCE(r.public_transport, '') = 'platform' OR COALESCE(r.railway, '') = 'platform' THEN 200
            WHEN COALESCE(r.public_transport, '') = 'stop_position' THEN 120
            ELSE 50
        END AS source_priority
    FROM public.t_checkpoints_preview_raw r
    CROSS JOIN settings s
    WHERE r.geom_3857 IS NOT NULL
),
stop_area_member_points AS (
    SELECT
        m.stop_area_osm_id,
        m.member_seq,
        m.member_role,
        rc.*
    FROM public.t_osm_stop_area_member m
    JOIN raw_candidates rc
      ON rc.osm_type = CASE m.member_type WHEN 'n' THEN 'node' WHEN 'w' THEN 'way' WHEN 'r' THEN 'relation' ELSE 'node' END
     AND rc.osm_id = m.member_osm_id
),
stop_area_best_member AS (
    SELECT
        smp.stop_area_osm_id,
        smp.osm_type,
        smp.osm_id,
        smp.name,
        smp.railway,
        smp.public_transport,
        smp.operator,
        smp.ref,
        smp.uic_ref,
        smp.ifopt_ref,
        smp.wikidata,
        smp.tags,
        smp.geom,
        smp.geom_3857,
        smp.country_code,
        smp.name_norm,
        smp.name_match_key,
        smp.source_priority,
        row_number() OVER (
            PARTITION BY smp.stop_area_osm_id
            ORDER BY
                smp.source_priority DESC,
                (smp.name IS NOT NULL) DESC,
                smp.member_seq ASC,
                smp.osm_id ASC
        ) AS rn
    FROM stop_area_member_points smp
),
stop_area_geom AS (
    SELECT
        smp.stop_area_osm_id,
        count(*) AS members_count,
        ST_Centroid(ST_Collect(smp.geom_3857)) AS geom_3857
    FROM stop_area_member_points smp
    GROUP BY smp.stop_area_osm_id
),
stop_area_canonical AS (
    SELECT
        format('stop_area:r:%s', sa.osm_id) AS canonical_key,
        'relation'::text AS osm_type,
        sa.osm_id,
        COALESCE(
            NULLIF(sa.name, ''),
            NULLIF(best.name, ''),
            NULLIF(best.ref, ''),
            NULLIF(trim(concat_ws(' ', best.operator, best.ref)), ''),
            format('Stop Area %s', sa.osm_id)
        ) AS name,
        best.railway,
        best.public_transport,
        public.normalize_checkpoint_name_cfg(
            COALESCE(
                NULLIF(sa.name, ''),
                NULLIF(best.name, ''),
                NULLIF(best.ref, ''),
                NULLIF(trim(concat_ws(' ', best.operator, best.ref)), ''),
                format('Stop Area %s', sa.osm_id)
            ),
            s.name_strip_parens
        ) AS name_norm,
        public.normalize_checkpoint_match_name_cfg(
            COALESCE(
                NULLIF(sa.name, ''),
                NULLIF(best.name, ''),
                NULLIF(best.ref, ''),
                NULLIF(trim(concat_ws(' ', best.operator, best.ref)), ''),
                format('Stop Area %s', sa.osm_id)
            ),
            s.name_strip_parens
        ) AS name_match_key,
        COALESCE(best.geom, ST_Transform(g.geom_3857, 4326))::geometry(Point, 4326) AS geom,
        COALESCE(best.geom_3857, g.geom_3857)::geometry(Point, 3857) AS geom_3857,
        ST_Buffer(COALESCE(best.geom_3857, g.geom_3857), s.buffer_m)::geometry(Polygon, 3857) AS buffer_3857,
        COALESCE(
            NULLIF(upper(
                COALESCE(
                    NULLIF(sa.tags->>'ISO3166-1', ''),
                    NULLIF(sa.tags->>'ISO3166-1:alpha2', ''),
                    NULLIF(sa.tags->>'iso3166-1', ''),
                    NULLIF(sa.tags->>'iso3166-1:alpha2', '')
                )
            ), ''),
            best.country_code,
            'DE'
        ) AS country_code,
        'stop_area'::text AS source_type,
        1000 + COALESCE(best.source_priority, 0) AS source_priority,
        COALESCE(g.members_count, 0) AS members_count,
        COALESCE(best.source_priority, 0) AS score,
        jsonb_strip_nulls(jsonb_build_object(
            'wikidata', COALESCE(NULLIF(sa.wikidata, ''), NULLIF(best.wikidata, '')),
            'ifopt_ref', COALESCE(NULLIF(sa.ifopt_ref, ''), NULLIF(best.ifopt_ref, '')),
            'uic_ref', COALESCE(NULLIF(sa.uic_ref, ''), NULLIF(best.uic_ref, '')),
            'ref', COALESCE(NULLIF(sa.ref, ''), NULLIF(best.ref, '')),
            'operator', COALESCE(NULLIF(sa.operator, ''), NULLIF(best.operator, ''))
        )) AS refs,
        sa.tags AS tags
    FROM public.t_osm_stop_area sa
    CROSS JOIN settings s
    LEFT JOIN stop_area_best_member best
      ON best.stop_area_osm_id = sa.osm_id
     AND best.rn = 1
    LEFT JOIN stop_area_geom g
      ON g.stop_area_osm_id = sa.osm_id
    WHERE sa.public_transport = 'stop_area'
      AND COALESCE(best.geom_3857, g.geom_3857) IS NOT NULL
),
stop_area_canonical_identity AS (
    SELECT
        sa.*,
        COALESCE(
            NULLIF(sa.refs->>'wikidata', ''),
            NULLIF(sa.refs->>'uic_ref', ''),
            NULLIF(sa.refs->>'ifopt_ref', '')
        ) AS identity_key
    FROM stop_area_canonical sa
),
stop_area_canonical_identity_clustered AS (
    SELECT
        sai.*,
        CASE
            WHEN COALESCE(sai.identity_key, '') <> ''
                 AND COALESCE(sai.name_match_key, '') <> ''
                 AND sai.geom_3857 IS NOT NULL
                THEN ST_ClusterDBSCAN(
                    sai.geom_3857,
                    eps := (SELECT stop_area_link_radius_m FROM settings),
                    minpoints := 1
                ) OVER (
                    PARTITION BY sai.name_match_key, sai.identity_key
                )
            ELSE NULL
        END AS identity_cluster_id
    FROM stop_area_canonical_identity sai
),
stop_area_canonical_with_key AS (
    SELECT
        sa.*,
        CASE
            WHEN COALESCE(sa.identity_key, '') <> ''
                 AND COALESCE(sa.name_match_key, '') <> ''
                 AND sa.identity_cluster_id IS NOT NULL
                THEN format(
                    'stop_area:identity:%s:%s:%s',
                    sa.name_match_key,
                    sa.identity_key,
                    sa.identity_cluster_id
                )
            WHEN COALESCE(sa.name_match_key, '') <> '' AND sa.geom_3857 IS NOT NULL THEN format(
                'stop_area:dedup:%s:%s:%s',
                sa.name_match_key,
                round(ST_X(ST_SnapToGrid(sa.geom_3857, (SELECT stop_area_dedup_grid_m FROM settings)))::numeric, 0),
                round(ST_Y(ST_SnapToGrid(sa.geom_3857, (SELECT stop_area_dedup_grid_m FROM settings)))::numeric, 0)
            )
            ELSE sa.canonical_key
        END AS dedup_key
    FROM stop_area_canonical_identity_clustered sa
),
stop_area_canonical_ranked AS (
    SELECT
        sak.*,
        row_number() OVER (
            PARTITION BY sak.dedup_key
            ORDER BY
                (COALESCE(sak.refs->>'uic_ref', '') <> '') DESC,
                (COALESCE(sak.refs->>'ifopt_ref', '') <> '') DESC,
                (COALESCE(sak.refs->>'wikidata', '') <> '') DESC,
                sak.members_count DESC,
                sak.osm_id ASC
        ) AS dedup_rn,
        count(*) OVER (PARTITION BY sak.dedup_key) AS dedup_group_size
    FROM stop_area_canonical_with_key sak
),
stop_area_canonical_final AS (
    SELECT
        CASE
            WHEN sr.dedup_group_size > 1 THEN sr.dedup_key
            ELSE sr.canonical_key
        END AS canonical_key,
        sr.osm_type,
        sr.osm_id,
        sr.name,
        sr.railway,
        sr.public_transport,
        sr.name_norm,
        sr.name_match_key,
        sr.geom,
        sr.geom_3857,
        sr.buffer_3857,
        sr.country_code,
        sr.source_type,
        sr.source_priority,
        sr.members_count,
        sr.score,
        jsonb_strip_nulls(
            COALESCE(sr.refs, '{}'::jsonb) ||
            jsonb_build_object(
                'stop_area_dedup_group_size',
                CASE WHEN sr.dedup_group_size > 1 THEN sr.dedup_group_size ELSE NULL END
            )
        ) AS refs,
        sr.tags
    FROM stop_area_canonical_ranked sr
    WHERE sr.dedup_rn = 1
),
stop_area_swallow AS (
    SELECT DISTINCT smp.osm_type, smp.osm_id
    FROM stop_area_member_points smp
    UNION
    SELECT DISTINCT rc.osm_type, rc.osm_id
    FROM raw_candidates rc
    JOIN stop_area_canonical_final sa
      ON sa.geom_3857 IS NOT NULL
     AND ST_DWithin(sa.geom_3857, rc.geom_3857, (SELECT swallow_radius_m FROM settings))
     AND sa.name_match_key IS NOT NULL
     AND rc.name_match_key IS NOT NULL
     AND sa.name_match_key = rc.name_match_key
),
remaining_candidates AS (
    SELECT rc.*
    FROM raw_candidates rc
    LEFT JOIN stop_area_swallow sw
      ON sw.osm_type = rc.osm_type
     AND sw.osm_id = rc.osm_id
    WHERE sw.osm_id IS NULL
),
cluster_seed AS (
    SELECT
        rc.*,
        COALESCE(rc.name_match_key, format('__unnamed__:%s:%s', rc.osm_type, rc.osm_id)) AS cluster_partition
    FROM remaining_candidates rc
),
clustered AS (
    SELECT
        cs.*,
        ST_ClusterDBSCAN(cs.geom_3857, eps := s.cluster_radius_m, minpoints := 1)
            OVER (PARTITION BY cs.cluster_partition) AS cluster_id
    FROM cluster_seed cs
    CROSS JOIN settings s
),
cluster_ranked AS (
    SELECT
        c.*,
        format('%s:%s', c.cluster_partition, c.cluster_id) AS cluster_key,
        row_number() OVER (
            PARTITION BY c.cluster_partition, c.cluster_id
            ORDER BY
                c.source_priority DESC,
                (c.name IS NOT NULL) DESC,
                c.osm_type ASC,
                c.osm_id ASC
        ) AS rep_rank,
        count(*) OVER (PARTITION BY c.cluster_partition, c.cluster_id) AS cluster_size
    FROM clustered c
),
cluster_canonical AS (
    SELECT
        CASE
            WHEN rep.source_priority >= 500 THEN format('osm:%s:%s', rep.osm_type, rep.osm_id)
            WHEN rep.source_priority >= 400 THEN format('osm:%s:%s', rep.osm_type, rep.osm_id)
            ELSE format(
                'cluster:%s:%s:%s:%s',
                COALESCE(rep.name_match_key, COALESCE(rep.name_norm, 'unnamed')),
                round(ST_X(ST_Transform(rep.geom_3857, 4326))::numeric, 4),
                round(ST_Y(ST_Transform(rep.geom_3857, 4326))::numeric, 4),
                COALESCE(public.normalize_checkpoint_name_cfg(rep.operator, false), '')
            )
        END AS canonical_key,
        rep.osm_type,
        rep.osm_id,
        COALESCE(
            NULLIF(rep.name, ''),
            NULLIF(rep.ref, ''),
            NULLIF(trim(concat_ws(' ', rep.operator, rep.ref)), ''),
            format(
                'Checkpoint %s %s',
                round(ST_X(ST_Transform(rep.geom_3857, 4326))::numeric, 4),
                round(ST_Y(ST_Transform(rep.geom_3857, 4326))::numeric, 4)
            )
        ) AS name,
        rep.railway,
        rep.public_transport,
        public.normalize_checkpoint_name_cfg(
            COALESCE(
                NULLIF(rep.name, ''),
                NULLIF(rep.ref, ''),
                NULLIF(trim(concat_ws(' ', rep.operator, rep.ref)), ''),
                format(
                    'Checkpoint %s %s',
                    round(ST_X(ST_Transform(rep.geom_3857, 4326))::numeric, 4),
                    round(ST_Y(ST_Transform(rep.geom_3857, 4326))::numeric, 4)
                )
            ),
            s.name_strip_parens
        ) AS name_norm,
        rep.geom,
        rep.geom_3857,
        ST_Buffer(rep.geom_3857, s.buffer_m)::geometry(Polygon, 3857) AS buffer_3857,
        COALESCE(rep.country_code, 'DE') AS country_code,
        CASE
            WHEN rep.source_priority >= 500 THEN 'station'
            WHEN rep.source_priority >= 400 THEN 'halt'
            ELSE 'cluster'
        END AS source_type,
        rep.source_priority,
        rep.cluster_size AS members_count,
        rep.source_priority AS score,
        jsonb_strip_nulls(jsonb_build_object(
            'wikidata', NULLIF(rep.wikidata, ''),
            'ifopt_ref', NULLIF(rep.ifopt_ref, ''),
            'uic_ref', NULLIF(rep.uic_ref, ''),
            'ref', NULLIF(rep.ref, ''),
            'operator', NULLIF(rep.operator, '')
        )) AS refs,
        rep.tags
    FROM cluster_ranked rep
    CROSS JOIN settings s
    WHERE rep.rep_rank = 1
),
canonical_union AS (
    SELECT
        c.canonical_key,
        c.osm_type,
        c.osm_id,
        c.name,
        c.railway,
        c.public_transport,
        c.name_norm,
        c.geom,
        c.geom_3857,
        c.buffer_3857,
        c.country_code,
        c.source_type,
        c.source_priority,
        c.members_count,
        c.score,
        c.refs,
        c.tags
    FROM stop_area_canonical_final c
    UNION ALL
    SELECT
        c.canonical_key,
        c.osm_type,
        c.osm_id,
        c.name,
        c.railway,
        c.public_transport,
        c.name_norm,
        c.geom,
        c.geom_3857,
        c.buffer_3857,
        c.country_code,
        c.source_type,
        c.source_priority,
        c.members_count,
        c.score,
        c.refs,
        c.tags
    FROM cluster_canonical c
),
canonical_dedup AS (
    SELECT
        cu.*,
        row_number() OVER (
            PARTITION BY cu.canonical_key
            ORDER BY
                cu.source_priority DESC,
                cu.members_count DESC,
                cu.score DESC,
                cu.osm_type ASC,
                cu.osm_id ASC
        ) AS rn
    FROM canonical_union cu
)
INSERT INTO public.t_checkpoints_preview (
    osm_type,
    osm_id,
    canonical_key,
    source_type,
    source_priority,
    name,
    name_norm,
    railway,
    public_transport,
    members_count,
    score,
    refs,
    tags,
    geom,
    geom_3857,
    buffer_3857,
    country_code,
    imported_at
)
SELECT
    cd.osm_type,
    cd.osm_id,
    cd.canonical_key,
    cd.source_type,
    cd.source_priority,
    cd.name,
    cd.name_norm,
    cd.railway,
    cd.public_transport,
    cd.members_count,
    cd.score,
    cd.refs,
    cd.tags,
    cd.geom,
    cd.geom_3857,
    cd.buffer_3857,
    cd.country_code,
    now()
FROM canonical_dedup cd
WHERE cd.rn = 1;
