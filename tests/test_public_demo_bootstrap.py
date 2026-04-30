from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PublicDemoBootstrapTest(unittest.TestCase):
    def test_demo_bootstrap_defines_minimal_checkpoint_contract(self):
        bootstrap = ROOT / "sql" / "demo_bootstrap.sql"

        text = bootstrap.read_text()

        self.assertIn("CREATE TABLE IF NOT EXISTS public.t_checkpoints", text)
        self.assertIn("stop_id int PRIMARY KEY", text)
        self.assertIn("geom geometry(Point, 3857)", text)
        self.assertIn("geom_4326 geometry(Point, 4326)", text)
        self.assertIn("CREATE TABLE IF NOT EXISTS public.t_intersections", text)
        self.assertIn("checkpoint int", text)
        self.assertIn("rider_id int", text)
        self.assertIn("REFERENCES public.t_checkpoints(stop_id)", text)

    def test_compose_includes_local_demo_postgis_service_and_healthcheck(self):
        compose = (ROOT / "docker-compose.osm2pgsql.yml").read_text()

        self.assertIn("  db:", compose)
        self.assertIn("postgis/postgis:16-3.4", compose)
        self.assertIn("POSTGRES_DB: ${TARGET_DB_NAME:-eisenbahn_demo}", compose)
        self.assertIn('"${POSTGRES_PORT:-5432}:5432"', compose)
        self.assertIn("pg_isready", compose)
        self.assertIn("depends_on:", compose)
        self.assertIn("condition: service_healthy", compose)

    def test_demo_publish_replaces_checkpoint_table_from_preview(self):
        publish = (ROOT / "sql" / "demo_publish_preview_checkpoints.sql").read_text()

        self.assertIn("TRUNCATE TABLE public.t_checkpoints CASCADE", publish)
        self.assertIn("INSERT INTO public.t_checkpoints", publish)
        self.assertIn("FROM public.t_checkpoints_preview p", publish)
        self.assertNotIn("ON CONFLICT", publish)


if __name__ == "__main__":
    unittest.main()
