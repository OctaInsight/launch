"""Run the portal against the in-memory database: streamlit run tests/fake_app.py"""
import runpy, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / "tests")]
import fake_db
db = fake_db.install()
if not db.users:
    a = db.add_user("tamer@example.org", "tamer", "Secret-123", first_name="Tamer", last_name="Abu-Alam", role="admin")
    b = db.add_user("bo@example.org", "bo", "Secret-123", first_name="Bo")
    db.access[(a, "octa_kpi")] = "granted"; db.access[(b, "octa_hours")] = "requested"
    db.usage += [(a, "igneosuite", "active")] * 5 + [(a, "octa_kpi", "active")] * 2
runpy.run_path(str(ROOT / "app.py"), run_name="__main__")
