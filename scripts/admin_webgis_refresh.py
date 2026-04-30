import os
import sys
from pathlib import Path

import psycopg2


def _env(name, default=None):
    value = os.environ.get(name)
    return default if value is None or value == "" else value


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
    print(f"[admin-webgis] {message}")


def _fail(message):
    print(f"[admin-webgis] ERROR: {message}", file=sys.stderr)
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
        nxt = sql_text[i + 1] if i + 1 < length else ""

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


def _run_query(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        if cur.description:
            return cur.fetchall()
    conn.commit()
    return []


def _print_stats(conn):
    _log("Admin unit counts by level:")
    rows = _run_query(
        conn,
        """
        SELECT admin_level, count(*)
        FROM public.admin_unit
        GROUP BY admin_level
        ORDER BY admin_level
        """,
    )
    for admin_level, count in rows:
        _log(f"  level {admin_level}: {count}")

    mapping_count = _run_query(
        conn,
        "SELECT count(*) FROM public.checkpoint_admin_unit",
    )
    if mapping_count:
        _log(f"Mapping rows: {mapping_count[0][0]}")

    _log("Top 10 Bundeslaender by total checkpoints:")
    rows = _run_query(
        conn,
        """
        SELECT a.name, t.total_checkpoints
        FROM public.v_admin_kpi_total t
        JOIN public.admin_unit a ON a.id = t.admin_unit_id
        WHERE a.admin_level = 4
        ORDER BY t.total_checkpoints DESC, a.name
        LIMIT 10
        """,
    )
    for name, total in rows:
        _log(f"  {name}: {total}")


def main():
    root = Path(__file__).resolve().parents[1]
    schema_sql = root / "sql" / "admin_webgis_schema.sql"

    _log("Connecting to target database...")
    try:
        with _target_conn() as conn:
            _log("Running schema migrations...")
            _execute_sql_file(conn, schema_sql)

            _log("Refreshing admin_unit from osm_admin_boundaries...")
            _run_query(conn, "SELECT public.refresh_admin_unit()")

            _log("Refreshing admin-unit tile geometry cache (if available)...")
            _run_query(
                conn,
                """
                DO $$
                BEGIN
                    IF to_regclass('public.mv_admin_unit_geom_tile') IS NOT NULL THEN
                        REFRESH MATERIALIZED VIEW public.mv_admin_unit_geom_tile;
                    END IF;
                END;
                $$;
                """,
            )

            _log("Seeding admin_unit_settings for admin_level=4...")
            _run_query(
                conn,
                """
                INSERT INTO public.admin_unit_settings (admin_unit_id, is_active)
                SELECT a.id, false
                FROM public.admin_unit a
                WHERE a.admin_level = 4
                  AND NOT EXISTS (
                      SELECT 1
                      FROM public.admin_unit_settings s
                      WHERE s.admin_unit_id = a.id
                  )
                """,
            )

            _log("Refreshing admin_unit parent hierarchy...")
            _run_query(conn, "SELECT public.refresh_admin_unit_parents()")

            _log("Refreshing checkpoint_admin_unit mappings...")
            _run_query(conn, "SELECT public.refresh_checkpoint_admin_unit(ARRAY[4, 6])")

            _log("Refreshing unlock-neighbor cache (if available)...")
            _run_query(
                conn,
                """
                DO $$
                BEGIN
                    IF to_regclass('public.mv_unlock_admin_neighbors') IS NOT NULL THEN
                        REFRESH MATERIALIZED VIEW public.mv_unlock_admin_neighbors;
                    END IF;
                END;
                $$;
                """,
            )

            _print_stats(conn)

    except Exception as exc:
        _fail(f"Admin webgis refresh failed: {exc}")

    _log("Admin webgis refresh complete.")


if __name__ == "__main__":
    main()
