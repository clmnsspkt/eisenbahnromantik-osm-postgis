import os
import subprocess
import sys
from pathlib import Path


def _env(name, default=None):
    value = os.environ.get(name)
    return default if value is None or value == "" else value


def _log(message):
    print(f"[osm2pgsql-pipeline] {message}")


def _fail(message):
    print(f"[osm2pgsql-pipeline] ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def _run(cmd, env=None):
    _log(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, env=env, check=False)
    if result.returncode != 0:
        _fail(f"Command failed with exit code {result.returncode}")


def main():
    repo_root = Path(__file__).resolve().parents[1]

    pbf_path = _env("PBF_PATH", "/data/osm.pbf")
    import_schema = _env("OSM_IMPORT_SCHEMA", "osm_import")
    target_db_name = _env("TARGET_DB_NAME", "eisenbahn_demo")
    target_db_port = _env("TARGET_DB_PORT", "25433")
    container_db_port = _env("OSM2PGSQL_DB_PORT", "5432")

    _log(f"PBF_PATH={pbf_path}")
    _log(f"OSM_IMPORT_SCHEMA={import_schema}")
    _log(f"TARGET_DB_NAME={target_db_name}")
    _log(f"TARGET_DB_PORT={target_db_port}")
    _log(f"OSM2PGSQL_DB_PORT={container_db_port}")

    env = os.environ.copy()
    env.update(
        {
            "PBF_PATH": pbf_path,
            "OSM_IMPORT_SCHEMA": import_schema,
            "TARGET_DB_NAME": target_db_name,
            "TARGET_DB_PORT": container_db_port,
        }
    )

    _run(
        [
            "docker",
            "compose",
            "-f",
            str(repo_root / "docker-compose.osm2pgsql.yml"),
            "up",
            "osm2pgsql-import",
        ],
        env=env,
    )

    import_env = os.environ.copy()
    import_env.update(
        {
            "TARGET_DB_NAME": target_db_name,
            "TARGET_DB_PORT": target_db_port,
            "OSM_IMPORT_SCHEMAS": import_schema,
        }
    )

    _run(
        [sys.executable, str(repo_root / "scripts" / "import_osm2pgsql_targets.py")],
        env=import_env,
    )

    _run(
        [sys.executable, str(repo_root / "scripts" / "admin_webgis_refresh.py")],
        env=import_env,
    )

    _log("Pipeline complete.")


if __name__ == "__main__":
    main()
