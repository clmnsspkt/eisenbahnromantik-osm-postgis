import os
import sys
from pathlib import Path

import psycopg2


def _env(name, default=None):
    value = os.environ.get(name)
    return default if value is None or value == "" else value


def _env_float(name, default):
    raw = _env(name)
    if raw is None:
        return float(default)
    try:
        value = float(raw)
        return value if value > 0 else float(default)
    except (TypeError, ValueError):
        return float(default)


def _env_bool(name, default):
    raw = _env(name)
    if raw is None:
        return bool(default)
    return str(raw).strip().lower() in {"1", "true", "yes", "on"}


def _split_schemas(value):
    parts = [p.strip() for p in value.split(",") if p.strip()]
    return parts or ["osm_import"]


def _validate_schema_name(schema):
    if not schema.replace("_", "").isalnum():
        _fail(f"Invalid schema name: {schema}")


def _target_conn():
    database_url = _env("DATABASE_URL")
    if database_url:
        return psycopg2.connect(database_url)

    return psycopg2.connect(
        host=_env("TARGET_DB_HOST", "localhost"),
        port=int(_env("TARGET_DB_PORT", "5432")),
        dbname=_env("TARGET_DB_NAME", "eisenbahn_demo"),
        user=_env("TARGET_DB_USER", "postgres"),
        password=_env("TARGET_DB_PASSWORD", "postgres"),
    )


def _log(message):
    print(f"[osm2pgsql-import] {message}")


def _fail(message):
    print(f"[osm2pgsql-import] ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def _execute_sql_file(conn, path):
    sql_text = Path(path).read_text()
    statements = _split_sql_statements(sql_text)
    with conn.cursor() as cur:
        for statement in statements:
            cur.execute(statement)
    conn.commit()


def _split_sql_statements(sql_text):
    statements = []
    buff = []
    in_single = False
    in_double = False
    dollar_tag = None
    i = 0
    length = len(sql_text)
    while i < length:
        ch = sql_text[i]

        if dollar_tag is None and not in_single and not in_double and ch == "$":
            end = sql_text.find("$", i + 1)
            if end != -1:
                tag = sql_text[i : end + 1]
                if tag.startswith("$") and tag.endswith("$"):
                    dollar_tag = tag
                    buff.append(tag)
                    i = end + 1
                    continue

        if dollar_tag is not None:
            if sql_text.startswith(dollar_tag, i):
                buff.append(dollar_tag)
                i += len(dollar_tag)
                dollar_tag = None
                continue
            buff.append(ch)
            i += 1
            continue

        if ch == "'" and not in_double:
            in_single = not in_single
            buff.append(ch)
            i += 1
            continue

        if ch == '"' and not in_single:
            in_double = not in_double
            buff.append(ch)
            i += 1
            continue

        if ch == ";" and not in_single and not in_double:
            statement = "".join(buff).strip()
            if statement:
                statements.append(statement)
            buff = []
            i += 1
            continue

        buff.append(ch)
        i += 1

    tail = "".join(buff).strip()
    if tail:
        statements.append(tail)
    return statements


def _table_exists(cur, schema, table_name):
    cur.execute(f"SELECT to_regclass('{schema}.{table_name}')")
    return cur.fetchone()[0] is not None


def _check_import_tables(conn, schemas):
    metadata = {}
    with conn.cursor() as cur:
        for schema in schemas:
            _validate_schema_name(schema)

            has_admin = _table_exists(cur, schema, "admin_boundary")
            has_railway = _table_exists(cur, schema, "railway_point")
            has_stop_area = _table_exists(cur, schema, "pt_stop_area")
            has_stop_area_member = _table_exists(cur, schema, "pt_stop_area_member")

            if not has_admin:
                _fail(f"{schema}.admin_boundary not found. Run the osm2pgsql import first.")
            if not has_railway:
                _fail(f"{schema}.railway_point not found. Run the osm2pgsql import first.")

            metadata[schema] = {
                "has_admin": has_admin,
                "has_railway": has_railway,
                "has_stop_area": has_stop_area,
                "has_stop_area_member": has_stop_area_member,
            }

            if not has_stop_area or not has_stop_area_member:
                _log(
                    f"Schema {schema}: PTv2 stop_area tables missing "
                    f"(pt_stop_area={has_stop_area}, pt_stop_area_member={has_stop_area_member}); "
                    "fallback clustering only for this schema."
                )

    return metadata


def _create_union_views(conn, schemas, metadata):
    admin_selects = []
    railway_point_selects = []
    stop_area_selects = []
    stop_area_member_selects = []

    for schema in schemas:
        admin_selects.append(
            f"""
            SELECT
                p.osm_id,
                p.name,
                CASE
                    WHEN p.admin_level IS NULL THEN NULL
                    WHEN p.admin_level ~ '^[0-9]+$' THEN p.admin_level::int
                    ELSE NULL
                END AS admin_level,
                p.boundary,
                COALESCE(hstore_to_jsonb(p.tags), '{{}}'::jsonb) AS tags_jsonb,
                ST_Multi(
                    ST_Transform(
                        CASE
                            WHEN ST_SRID(p.geom) = 0 THEN ST_SetSRID(p.geom, 3857)
                            ELSE p.geom
                        END,
                        4326
                    )
                )::geometry(MultiPolygon, 4326) AS geom
            FROM {schema}.admin_boundary p
            WHERE p.boundary = 'administrative'
              AND p.admin_level IN ('2', '4', '6')
            """
        )

        railway_point_selects.append(
            f"""
            SELECT
                'node'::text AS osm_type,
                p.osm_id,
                p.name,
                p.railway,
                COALESCE((hstore_to_jsonb(p.tags)->>'public_transport'), NULL) AS public_transport,
                COALESCE((hstore_to_jsonb(p.tags)->>'operator'), NULL) AS operator,
                COALESCE((hstore_to_jsonb(p.tags)->>'ref'), NULL) AS ref,
                COALESCE((hstore_to_jsonb(p.tags)->>'uic_ref'), NULL) AS uic_ref,
                COALESCE((hstore_to_jsonb(p.tags)->>'ref:IFOPT'), NULL) AS ifopt_ref,
                COALESCE((hstore_to_jsonb(p.tags)->>'wikidata'), NULL) AS wikidata,
                COALESCE(hstore_to_jsonb(p.tags), '{{}}'::jsonb) AS tags_jsonb,
                ST_Transform(
                    CASE
                        WHEN ST_SRID(p.geom) = 0 THEN ST_SetSRID(p.geom, 3857)
                        ELSE p.geom
                    END,
                    4326
                )::geometry(Point, 4326) AS geom,
                CASE
                    WHEN ST_SRID(p.geom) = 0 THEN ST_SetSRID(p.geom, 3857)
                    ELSE p.geom
                END::geometry(Point, 3857) AS geom_3857
            FROM {schema}.railway_point p
            """
        )

        if metadata[schema]["has_stop_area"]:
            stop_area_selects.append(
                f"""
                SELECT
                    p.osm_id,
                    p.name,
                    p.public_transport,
                    p.relation_type,
                    COALESCE((hstore_to_jsonb(p.tags)->>'operator'), NULL) AS operator,
                    COALESCE((hstore_to_jsonb(p.tags)->>'ref'), NULL) AS ref,
                    COALESCE((hstore_to_jsonb(p.tags)->>'uic_ref'), NULL) AS uic_ref,
                    COALESCE((hstore_to_jsonb(p.tags)->>'ref:IFOPT'), NULL) AS ifopt_ref,
                    COALESCE((hstore_to_jsonb(p.tags)->>'wikidata'), NULL) AS wikidata,
                    COALESCE(hstore_to_jsonb(p.tags), '{{}}'::jsonb) AS tags_jsonb
                FROM {schema}.pt_stop_area p
                WHERE p.public_transport IN ('stop_area', 'stop_area_group')
                """
            )

        if metadata[schema]["has_stop_area_member"]:
            stop_area_member_selects.append(
                f"""
                SELECT
                    m.stop_area_osm_id,
                    m.member_seq,
                    m.member_type,
                    m.member_osm_id,
                    m.member_role
                FROM {schema}.pt_stop_area_member m
                """
            )

    admin_view_sql = (
        "CREATE OR REPLACE VIEW public.v_osm_admin_boundaries_osm2pgsql AS\n"
        + "\nUNION ALL\n".join(admin_selects)
    )

    railway_points_view_sql = (
        "CREATE OR REPLACE VIEW public.v_osm_railway_points_osm2pgsql AS\n"
        + "\nUNION ALL\n".join(railway_point_selects)
    )

    railway_stops_view_sql = """
    CREATE OR REPLACE VIEW public.v_osm_railway_stops_osm2pgsql AS
    SELECT
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
        tags_jsonb,
        geom,
        geom_3857
    FROM public.v_osm_railway_points_osm2pgsql
    WHERE railway IN ('halt', 'stop', 'station')
       OR public_transport = 'station'
    """

    if stop_area_selects:
        stop_area_view_sql = (
            "CREATE OR REPLACE VIEW public.v_osm_stop_area_osm2pgsql AS\n"
            + "\nUNION ALL\n".join(stop_area_selects)
        )
    else:
        stop_area_view_sql = """
        CREATE OR REPLACE VIEW public.v_osm_stop_area_osm2pgsql AS
        SELECT
            NULL::bigint AS osm_id,
            NULL::text AS name,
            NULL::text AS public_transport,
            NULL::text AS relation_type,
            NULL::text AS operator,
            NULL::text AS ref,
            NULL::text AS uic_ref,
            NULL::text AS ifopt_ref,
            NULL::text AS wikidata,
            '{}'::jsonb AS tags_jsonb
        WHERE false
        """

    if stop_area_member_selects:
        stop_area_member_view_sql = (
            "CREATE OR REPLACE VIEW public.v_osm_stop_area_member_osm2pgsql AS\n"
            + "\nUNION ALL\n".join(stop_area_member_selects)
        )
    else:
        stop_area_member_view_sql = """
        CREATE OR REPLACE VIEW public.v_osm_stop_area_member_osm2pgsql AS
        SELECT
            NULL::bigint AS stop_area_osm_id,
            NULL::int AS member_seq,
            NULL::text AS member_type,
            NULL::bigint AS member_osm_id,
            NULL::text AS member_role
        WHERE false
        """

    with conn.cursor() as cur:
        cur.execute(admin_view_sql)
        cur.execute(railway_points_view_sql)
        cur.execute(railway_stops_view_sql)
        cur.execute(stop_area_view_sql)
        cur.execute(stop_area_member_view_sql)
    conn.commit()


def _set_checkpoint_import_settings(conn):
    cluster_radius_m = _env_float("CHECKPOINT_CLUSTER_RADIUS_M", 350.0)
    buffer_m = _env_float("CHECKPOINT_BUFFER_M", 500.0)
    swallow_radius_m = _env_float("CHECKPOINT_STOPAREA_SWALLOW_RADIUS_M", cluster_radius_m)
    alias_radius_m = _env_float("CHECKPOINT_ALIAS_RADIUS_M", buffer_m)
    stop_area_link_radius_m = _env_float("CHECKPOINT_STOPAREA_LINK_RADIUS_M", 100.0)
    stop_area_dedup_grid_m = _env_float("CHECKPOINT_STOPAREA_DEDUP_GRID_M", 1.0)
    strip_parens = _env_bool("CHECKPOINT_NAME_STRIP_PARENS", True)
    keep_tief_variants = _env_bool("CHECKPOINT_KEEP_TIEF_VARIANTS", True)
    strict_rail_only = _env_bool("CHECKPOINT_STRICT_RAIL_ONLY", True)
    exclude_tram_stops = _env_bool("CHECKPOINT_EXCLUDE_TRAM_STOPS", True)

    with conn.cursor() as cur:
        cur.execute("SELECT set_config('app.checkpoint_cluster_radius_m', %s, false)", (str(cluster_radius_m),))
        cur.execute("SELECT set_config('app.checkpoint_buffer_m', %s, false)", (str(buffer_m),))
        cur.execute(
            "SELECT set_config('app.checkpoint_stoparea_swallow_radius_m', %s, false)",
            (str(swallow_radius_m),),
        )
        cur.execute(
            "SELECT set_config('app.checkpoint_alias_radius_m', %s, false)",
            (str(alias_radius_m),),
        )
        cur.execute(
            "SELECT set_config('app.checkpoint_stoparea_link_radius_m', %s, false)",
            (str(stop_area_link_radius_m),),
        )
        cur.execute(
            "SELECT set_config('app.checkpoint_name_strip_parens', %s, false)",
            ("true" if strip_parens else "false",),
        )
        cur.execute(
            "SELECT set_config('app.checkpoint_keep_tief_variants', %s, false)",
            ("true" if keep_tief_variants else "false",),
        )
        cur.execute(
            "SELECT set_config('app.checkpoint_stoparea_dedup_grid_m', %s, false)",
            (str(stop_area_dedup_grid_m),),
        )
        cur.execute(
            "SELECT set_config('app.checkpoint_strict_rail_only', %s, false)",
            ("true" if strict_rail_only else "false",),
        )
        cur.execute(
            "SELECT set_config('app.checkpoint_exclude_tram_stops', %s, false)",
            ("true" if exclude_tram_stops else "false",),
        )
    conn.commit()

    _log(
        "Checkpoint derive settings: "
        f"CHECKPOINT_CLUSTER_RADIUS_M={cluster_radius_m}, "
        f"CHECKPOINT_BUFFER_M={buffer_m}, "
        f"CHECKPOINT_STOPAREA_SWALLOW_RADIUS_M={swallow_radius_m}, "
        f"CHECKPOINT_ALIAS_RADIUS_M={alias_radius_m}, "
        f"CHECKPOINT_STOPAREA_LINK_RADIUS_M={stop_area_link_radius_m}, "
        f"CHECKPOINT_NAME_STRIP_PARENS={strip_parens}, "
        f"CHECKPOINT_KEEP_TIEF_VARIANTS={keep_tief_variants}, "
        f"CHECKPOINT_STOPAREA_DEDUP_GRID_M={stop_area_dedup_grid_m}, "
        f"CHECKPOINT_STRICT_RAIL_ONLY={strict_rail_only}, "
        f"CHECKPOINT_EXCLUDE_TRAM_STOPS={exclude_tram_stops}"
    )


def _log_checkpoint_preview_stats(conn):
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT source_type, count(*)::bigint AS cnt
            FROM public.t_checkpoints_preview
            GROUP BY source_type
            ORDER BY source_type
            """
        )
        by_source = cur.fetchall()

        cur.execute("SELECT count(*)::bigint FROM public.t_checkpoints_preview")
        total = cur.fetchone()[0]

        cur.execute(
            """
            SELECT count(*)::bigint
            FROM public.t_checkpoints_preview
            WHERE name IS NULL OR btrim(name) = ''
            """
        )
        unnamed = cur.fetchone()[0]

        cur.execute("SELECT count(*)::bigint FROM public.t_osm_stop_area")
        stop_area_total = cur.fetchone()[0]

        cur.execute("SELECT count(*)::bigint FROM public.t_checkpoints_preview_raw")
        raw_total = cur.fetchone()[0]

    _log(f"Raw checkpoint candidates: {raw_total}")
    _log(f"PTv2 stop_areas imported: {stop_area_total}")
    _log(f"Canonical checkpoints total: {total}")
    _log(f"Canonical checkpoints without name: {unnamed}")
    if not by_source:
        _log("Canonical source breakdown: <empty>")
    else:
        for source_type, cnt in by_source:
            _log(f"Canonical source breakdown: {source_type}={cnt}")


def main():
    root = Path(__file__).resolve().parents[1]
    admin_schema_sql = root / "sql" / "admin_boundaries_schema.sql"
    railway_schema_sql = root / "sql" / "railway_checkpoints_schema.sql"
    admin_import_sql = root / "sql" / "admin_boundaries_import_osm2pgsql.sql"
    railway_import_sql = root / "sql" / "railway_checkpoints_import_osm2pgsql.sql"
    schemas = _split_schemas(_env("OSM_IMPORT_SCHEMAS", "osm_import"))

    _log("Connecting to target database...")
    try:
        with _target_conn() as conn:
            metadata = _check_import_tables(conn, schemas)

            _log("Running admin boundaries schema migration...")
            _execute_sql_file(conn, admin_schema_sql)

            _log("Running railway checkpoints schema migration...")
            _execute_sql_file(conn, railway_schema_sql)

            _set_checkpoint_import_settings(conn)

            _log(f"Creating osm2pgsql adapter views for schemas: {', '.join(schemas)}")
            _create_union_views(conn, schemas, metadata)

            _log("Importing administrative boundaries from osm_import...")
            _execute_sql_file(conn, admin_import_sql)

            _log("Importing railway checkpoints preview from osm_import...")
            _execute_sql_file(conn, railway_import_sql)

            _log_checkpoint_preview_stats(conn)

    except Exception as exc:
        _fail(f"osm2pgsql target import failed: {exc}")

    _log("osm2pgsql target import complete.")


if __name__ == "__main__":
    main()
