TRUNCATE TABLE public.t_checkpoints CASCADE;

INSERT INTO public.t_checkpoints (
    stop_id,
    name,
    stop_name,
    osm_type,
    osm_id,
    geom,
    geom_4326,
    buffer,
    imported_at
)
SELECT
    row_number() OVER (ORDER BY p.country_code NULLS LAST, p.name NULLS LAST, p.osm_type, p.osm_id)::int AS stop_id,
    p.name,
    p.name,
    p.osm_type,
    p.osm_id,
    p.geom_3857,
    p.geom,
    p.buffer_3857,
    now()
FROM public.t_checkpoints_preview p
WHERE p.geom_3857 IS NOT NULL;
