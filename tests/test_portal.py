import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

import pytest  # noqa: E402
from streamlit.testing.v1 import AppTest  # noqa: E402

import fake_db  # noqa: E402

SECRETS = {"octa_users": {"url": "https://example.supabase.co", "key": "sb_publishable_x",
                          "server_key": "test-server-key", "portal_url": "https://portal.example/"},
           "email": {"user": "a@b.c", "app_password": "x"}}


@pytest.fixture(autouse=True)
def db():
    fake_db.DB.__init__()
    fake_db.install()
    return fake_db.DB


def _at(qp=None):
    at = AppTest.from_file(str(ROOT / "app.py"), default_timeout=30)
    for k, v in SECRETS.items():
        at.secrets[k] = v
    for k, v in (qp or {}).items():
        at.query_params[k] = v
    return at.run()


def _btn(at, label):
    return next(b for b in at.button if b.label == label)


def test_login_page_then_login(db):
    db.add_user("ann@x.org", "ann", "Secret-123", first_name="Ann")
    at = _at()
    assert not at.exception
    assert any("Log in" == b.label for b in at.button)
    at.text_input[0].input("ann")
    at.text_input[1].input("Secret-123")
    _btn(at, "Log in").click().run()
    assert not at.exception
    assert any("Welcome, Ann" in m.value for m in at.markdown)
    assert at.query_params["session"]
    # apps: IgneoSuite can be opened, KPI needs access
    labels = [b.label for b in at.button]
    assert "Request access" in labels


def test_session_in_url_survives_refresh(db):
    uid = db.add_user("ann@x.org", "ann", "Secret-123", first_name="Ann")
    tok = db._new_session(uid)
    at = _at({"session": tok})
    assert any("Welcome, Ann" in m.value for m in at.markdown)
    at2 = _at({"session": "bad"})
    assert any(b.label == "Log in" for b in at2.button)


def test_register_cloudearthi_requests_access(db):
    at = _at()
    _btn(at, "New here? Create an account").click().run()
    at.radio(key="octa_reg_family").set_value("cloudearthi").run()
    vals = {"First name *": "Bo", "Family name *": "Li", "Email *": "bo@x.org", "Username *": "boli",
            "Password *": "Secret-123", "Repeat password *": "Secret-123",
            "Affiliation (university, institute or company) *": "UiT", "LinkedIn": "in/bo"}
    for t in at.text_input:
        if t.label in vals:
            t.input(vals[t.label])
    at.multiselect[0].select("octa_kpi")
    _btn(at, "Create account").click().run()
    assert not at.exception, at.exception
    assert any("Your Octa account is ready" in s.value for s in at.success)
    u = next(iter(db.users.values()))
    assert u["profiles"]["cloudearthi"]["linkedin"] == "in/bo"
    assert db.access[(u["id"], "octa_kpi")] == "requested"
    assert db.mails and db.mails[0]["subject"] == "Welcome to Octa Insight"


def test_forgot_and_reset(db):
    db.add_user("ann@x.org", "ann", "Secret-123", first_name="Ann")
    at = _at()
    _btn(at, "Forgot username or password?").click().run()
    at.text_input[0].input("nobody@x.org")
    _btn(at, "Send me an email").click().run()
    assert "no account" in db.mails[-1]["subject"]
    assert db.mails[-1]["link"].endswith("?register=1")
    at.text_input[0].input("ANN@x.org")
    _btn(at, "Send me an email").click().run()
    assert any("We have sent an email" in s.value for s in at.success)
    mail = db.mails[-1]
    assert "ann" in mail["text"]
    tok = re.search(r"reset=([0-9a-f]+)", mail["link"]).group(1)
    at = _at({"reset": tok})
    assert any("Your username: **ann**" in i.value for i in at.info)
    at.text_input[0].input("ann2")
    at.text_input[1].input("New-pass-456")
    at.text_input[2].input("New-pass-456")
    _btn(at, "Save").click().run()
    assert not at.exception
    assert "reset" not in at.query_params
    assert any("ann2" in s.value for s in at.success)
    assert db.login("ann2", "New-pass-456", None)["ok"]
    at = _at({"reset": tok})
    assert any("already used" in e.value for e in at.error)


def test_admin_approves(db):
    admin = db.add_user("boss@x.org", "boss", "Secret-123", role="admin", first_name="Boss")
    uid = db.add_user("bo@x.org", "bo", "Secret-123", first_name="Bo")
    db.access[(uid, "octa_kpi")] = "requested"
    at = _at({"session": db._new_session(admin)})
    at.sidebar.radio[0].set_value("Administration").run()
    assert not at.exception, at.exception
    _btn(at, "Approve").click().run()
    assert db.access[(uid, "octa_kpi")] == "granted"


def test_logout(db):
    uid = db.add_user("ann@x.org", "ann", "Secret-123", first_name="Ann")
    at = _at({"session": db._new_session(uid)})
    next(b for b in at.sidebar.button if b.label == "Log out").click().run()
    assert "session" not in at.query_params
    assert any(b.label == "Log in" for b in at.button)
    assert not db.sessions


def test_four_groups_ordered_by_use(db):
    uid = db.add_user("ann@x.org", "ann", "Secret-123", first_name="Ann")
    other = db.add_user("bo@x.org", "bo", "Secret-123")
    db.usage += [(other, "octa_matchmaking", "active")] * 9          # everyone's use
    at = _at({"session": db._new_session(uid)})
    heads = [m.value for m in at.main.markdown if m.value.startswith("### ")]
    assert heads[0] == "### Innovation, Education and Training apps"     # nobody else used anything
    assert len(heads) == 4
    db.usage += [(uid, "igneosuite", "active")] * 3                   # Ann's own use comes first
    at = _at({"session": db._new_session(uid)})
    heads = [m.value for m in at.main.markdown if m.value.startswith("### ")]
    assert heads[:2] == ["### Octa scientific apps", "### Innovation, Education and Training apps"]
    assert any("You opened it" in m.value for m in at.markdown)


def test_register_education_profile(db):
    at = _at()
    _btn(at, "New here? Create an account").click().run()
    at.radio(key="octa_reg_family").set_value("education").run()
    vals = {"First name *": "Ed", "Family name *": "U", "Email *": "ed@x.org", "Username *": "edu",
            "Password *": "Secret-123", "Repeat password *": "Secret-123",
            "Affiliation (university, institute or company) *": "UiT"}
    for t in at.text_input:
        if t.label in vals:
            t.input(vals[t.label])
    at.text_area[0].input("STEM education\nCircular economy")
    _btn(at, "Create account").click().run()
    assert not at.exception, at.exception
    u = next(iter(db.users.values()))
    assert u["profiles"]["education"]["interests"] == ["STEM education", "Circular economy"]


def test_octa_logo_at_the_bottom_of_the_sidebar(db):
    db.add_user("lia@x.org", "lia", "Secret-123", first_name="Lia")
    at = _at()
    at.text_input[0].input("lia")
    at.text_input[1].input("Secret-123")
    _btn(at, "Log in").click().run()
    assert not at.exception
    side = [m.value for m in at.sidebar.markdown]
    footer = next(i for i, v in enumerate(side) if "© 2026 Octa Insight · Produced by Octa Systems" in v)
    assert "data:image/png;base64," in side[footer + 1] and "alt='Octa Insight'" in side[footer + 1]
