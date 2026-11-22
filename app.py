"""Octa suite: the common login page and app launcher for all Octa Insight apps."""
import base64
from pathlib import Path
import html
import sys
import time

_T0 = time.time()


def _log(msg):  # progress lines in the Streamlit Cloud log ("Manage app"), to find where a page stops
    try:
        print(f"[octa-suite] {time.time() - _T0:5.2f}s {msg}", file=sys.stderr, flush=True)
    except Exception:       # the log may be closed; never let logging break the page
        pass


_log("script started")
import pandas as pd  # noqa: E402
import streamlit as st  # noqa: E402

st.set_page_config(page_title="Octa suite", page_icon="🔷", layout="wide")
_log("page config set")

from octa_auth import App, FAMILIES, client, display_name, require_login, with_session, logout, flash  # noqa: E402
from octa_auth.ui import FAMILY_HELP, _show_flash, _state  # noqa: E402
from octa_auth import mail  # noqa: E402

PORTAL = App(id="portal", name="Octa suite", family="science", url=client.setting("portal_url", ""),
             tagline="All Octa Insight apps in one place", icon="🔷")
VERSION = "1.0.0"

st.markdown("""<style>
.octa-card{border:1px solid #e4e3df;border-radius:10px;padding:14px 16px 6px 16px;min-height:118px;background:#fff}
.octa-card.off{background:#f7f6f3;opacity:.55}
.octa-card h4{margin:0 0 4px 0;font-size:1.02rem}
.octa-card p{margin:0;color:#52514e;font-size:.86rem;line-height:1.35}
.octa-tag{font-size:.72rem;color:#52514e;border:1px solid #d9d7d1;border-radius:9px;padding:0 7px;margin-left:6px}
</style>""", unsafe_allow_html=True)

_log(f"secrets found: {client.enabled()}; checking login")
user = require_login(PORTAL)
_log("signed in")
if user is None:   # no user database configured (local copy without secrets)
    st.error("The Octa user database is not configured. Add the [octa_users] section to the Streamlit secrets.")
    st.stop()
tok = _state()["token"]


def catalogue(fresh=False):
    """The app list for this user, kept for 30 s so clicks do not wait for the database each time."""
    c = st.session_state.get("_octa_cat")
    if fresh or not c or c[0] != tok or time.time() - c[1] > 30:
        c = (tok, time.time(), client.catalogue(tok))
        st.session_state["_octa_cat"] = c
    return c[2]


def page_apps():
    st.markdown(f"## Welcome, {html.escape(display_name(user))}")
    _show_flash()
    try:
        cat = catalogue()
    except client.OctaError as e:
        st.error(str(e))
        return
    apps = cat.get("apps", [])
    order = cat.get("family_order") or list(FAMILIES)
    st.caption("The groups and apps you use most come first; the order follows how you, and all Octa users, "
               "use the apps.")
    first = True
    for fam in order:
        items = [a for a in apps if a["family"] == fam]
        if not items:
            continue
        if not first:
            st.divider()
        first = False
        n_open = sum(a["can_open"] and a["status"] == "live" for a in items)
        st.markdown(f"### {FAMILIES.get(fam, fam.title())}")
        st.caption(f"{FAMILY_HELP.get(fam, '')} · you can open {n_open} of {len(items)}")
        # apps the user can open first; then the user's own use, everyone's use, and the catalogue order
        items.sort(key=lambda a: (not (a["can_open"] and a["status"] == "live"), -a.get("uses", 0),
                                  -a.get("everyone_uses", 0), a.get("sort_order", 100), a["name"]))
        cols = st.columns(3)
        for i, a in enumerate(items):
            with cols[i % 3]:
                _card(a)


def _card(a):
    live = a["status"] == "live" and a.get("url")
    active = a["can_open"] and live
    tag = "" if a["status"] == "live" else "<span class='octa-tag'>coming soon</span>"
    used = (f"<p style='margin-top:6px;font-size:.75rem;color:#2a78d6'>You opened it {a['uses']} "
            f"time{'s' if a['uses'] != 1 else ''} in the last 6 months</p>" if a.get("uses") else "")
    st.markdown(f"<div class='octa-card{'' if active else ' off'}'><h4>{a['icon']} {html.escape(a['name'])}{tag}</h4>"
                f"<p>{html.escape(a.get('description') or '')}</p>{used}</div>", unsafe_allow_html=True)
    if active:
        st.link_button("Open", with_session(a["url"]), use_container_width=True, type="primary")
    elif not live:
        st.button("Coming soon", key=f"cs_{a['id']}", disabled=True, use_container_width=True)
    elif a.get("requested"):
        st.button("Access requested", key=f"rq_{a['id']}", disabled=True, use_container_width=True)
    else:
        if st.button("Request access", key=f"ask_{a['id']}", use_container_width=True):
            try:
                r = client.request_access(tok, a["id"])
                st.session_state.pop("_octa_cat", None)
                flash("success" if r.get("ok") else "error",
                      f"Your request for {a['name']} was sent." if r.get("ok") else r.get("error"))
            except client.OctaError as e:
                flash("error", str(e))
            st.rerun()
    st.write("")


def page_account():
    st.markdown("## My account")
    _show_flash()
    u = user
    fam_profiles = u.get("profiles") or {}
    with st.form("acc"):
        c1, c2 = st.columns(2)
        f = dict(first_name=c1.text_input("First name", u.get("first_name") or ""),
                 last_name=c2.text_input("Family name", u.get("last_name") or ""),
                 affiliation=c1.text_input("Affiliation", u.get("affiliation") or ""),
                 country=c2.text_input("Country", u.get("country") or ""),
                 job_title=c1.text_input("Position / job title", u.get("job_title") or ""),
                 orcid=c2.text_input("ORCID iD", u.get("orcid") or ""),
                 website=st.text_input("Web page", u.get("website") or ""),
                 biography=st.text_area("Short profile", u.get("biography") or "", max_chars=2000))
        cp = fam_profiles.get("cloudearthi", {})
        st.markdown("**CloudEARTHi details** (social media, institutes and projects)")
        c3, c4 = st.columns(2)
        prof = dict(linkedin=c3.text_input("LinkedIn", cp.get("linkedin", "")),
                    researchgate=c4.text_input("ResearchGate", cp.get("researchgate", "")),
                    x=c3.text_input("X (Twitter)", cp.get("x", "")),
                    other_social=c4.text_input("Other", cp.get("other_social", "")),
                    institutes=st.text_area("Affiliated institutes (one per line)", "\n".join(cp.get("institutes", []))),
                    projects=st.text_area("Proposals or projects (one per line)", "\n".join(cp.get("projects", []))))
        ok = st.form_submit_button("Save profile", type="primary")
    if ok:
        prof["institutes"] = [x.strip() for x in prof["institutes"].splitlines() if x.strip()]
        prof["projects"] = [x.strip() for x in prof["projects"].splitlines() if x.strip()]
        r = client.update_profile(tok, {**{k: v.strip() for k, v in f.items()}, "family": "cloudearthi",
                                        "profile": {k: v for k, v in prof.items()}})
        if r.get("ok"):
            _state()["user"] = r["user"]
            flash("success", "Profile saved.")
            st.rerun()
        st.error(r.get("error"))
    st.markdown(f"Email: **{u['email']}** · Username: **{u['username']}**")
    with st.expander("Change password"):
        with st.form("pw"):
            old = st.text_input("Current password", type="password")
            new = st.text_input("New password", type="password", help="At least 8 characters.")
            new2 = st.text_input("Repeat the new password", type="password")
            ok2 = st.form_submit_button("Change password")
        if ok2:
            if new != new2:
                st.error("The two new passwords are not the same.")
            else:
                r = client.change_password(tok, old, new)
                st.success("Password changed.") if r.get("ok") else st.error(r.get("error"))
    try:
        cat = catalogue()
        used = [(a["name"], FAMILIES.get(a["family"], a["family"].title()), a["uses"]) for a in cat.get("apps", []) if a.get("uses")]
        if used:
            st.markdown("**Your use of Octa apps (last 180 days)**")
            st.dataframe(pd.DataFrame(used, columns=["App", "Group", "Visits"]).sort_values("Visits", ascending=False),
                         hide_index=True, use_container_width=True)
    except client.OctaError:
        pass


def page_admin():
    st.markdown("## Administration")
    _show_flash()
    r = client.admin(tok, action="list_requests")
    if not r.get("ok"):
        st.error(r.get("error"))
        return
    st.markdown("### Access requests")
    if not r["requests"]:
        st.caption("No open requests.")
    for q in r["requests"]:
        c1, c2, c3 = st.columns([4, 1, 1])
        c1.markdown(f"**{html.escape(q['name'] or q['email'])}** ({html.escape(q['email'])}"
                    f"{', ' + html.escape(q['affiliation']) if q.get('affiliation') else ''}) → **{html.escape(q['app'])}**")
        for col, label, status in ((c2, "Approve", "granted"), (c3, "Decline", "revoked")):
            if col.button(label, key=f"{status}_{q['user_id']}_{q['app_id']}"):
                client.admin(tok, action="set_access", user_id=q["user_id"], app_id=q["app_id"], status=status)
                st.session_state.pop("_octa_cat", None)
                flash("success", f"{label}d: {q['email']} → {q['app']}")
                st.rerun()
    st.markdown("### Users")
    users = client.admin(tok, action="list_users").get("users", [])
    if users:
        df = pd.DataFrame(users)
        df["apps"] = df["apps"].apply(lambda x: ", ".join(x or []))
        st.dataframe(df[["name", "username", "email", "affiliation", "status", "role", "last_login_at", "apps"]],
                     hide_index=True, use_container_width=True)
        st.markdown("**Change access**")
        cat = {a["id"]: a["name"] for a in catalogue().get("apps", [])}
        c1, c2, c3, c4 = st.columns([3, 3, 2, 1])
        who = c1.selectbox("User", [x["user_id"] for x in users],
                           format_func=lambda i: next(f"{x['email']} ({x['username']})" for x in users if x["user_id"] == i))
        app_id = c2.selectbox("App", list(cat), format_func=cat.get)
        status = c3.selectbox("Access", ["granted", "revoked"])
        if c4.button("Apply"):
            client.admin(tok, action="set_access", user_id=who, app_id=app_id, status=status)
            flash("success", "Access updated.")
            st.rerun()
        c5, c6, c7 = st.columns([3, 2, 1])
        who2 = c5.selectbox("Account status of", [x["user_id"] for x in users], key="st_user",
                            format_func=lambda i: next(x["email"] for x in users if x["user_id"] == i))
        st2 = c6.selectbox("Status", ["active", "suspended"])
        if c7.button("Set"):
            client.admin(tok, action="set_status", user_id=who2, status=st2)
            flash("success", "Status updated.")
            st.rerun()
    _email_check()


def _email_check():
    """Admins check that this app can send emails (welcome, forgot password) through Resend."""
    st.markdown("### Email")
    kind = mail.provider()
    if kind == "resend":
        c = mail.sender()
        st.caption(f"Emails are sent through **Resend** from {html.escape(c.get('from_name', 'Octa Insight'))} "
                   f"<{html.escape(c['from_email'])}>"
                   + (f", replies go to {html.escape(c['reply_to'])}" if c.get("reply_to") else "") + ".")
    elif kind == "gmail":
        st.warning("Emails are still sent through **Gmail**. To use Resend: " + mail.diagnose())
    else:
        st.warning("Email is not set up: welcome and forgot-password emails are not sent. " + mail.diagnose())
        return
    if st.button("Send a test email to me"):
        try:
            with st.spinner("Sending…"):
                mid = mail.send(user["email"], "Octa suite: test email",
                                ["This is a test email from the Octa suite Administration page.",
                                 "If you can read it, welcome and forgot-password emails work."])
            st.success(f"Sent to {user['email']}" + (f" (Resend id {mid})" if mid else "")
                       + ". Check the inbox and the spam folder.")
        except mail.MailError as e:
            st.error(str(e))


pages = {"Apps": page_apps, "My account": page_account}
if user.get("role") == "admin":
    pages["Administration"] = page_admin

with st.sidebar:
    st.markdown("### 🔷 Octa suite")
    choice = st.radio("Menu", list(pages), label_visibility="collapsed", key="menu")
    st.divider()
    st.markdown(f"👤 **{html.escape(display_name(user))}**  \n<span style='color:#52514e;font-size:.85rem'>"
                f"{html.escape(user['username'])}</span>", unsafe_allow_html=True)
    if st.button("Log out", use_container_width=True):
        logout(PORTAL)
        st.rerun()
    st.caption("You stay signed in while you use the Octa apps; after 3 hours without activity you are "
               "logged out automatically.")
    st.divider()
    st.markdown(f"<div style='font-size:.8rem;color:#52514e'><b style='color:#0b0b0b'>Octa suite {VERSION}</b><br>"
                "© 2026 Octa Insight · Produced by Octa Systems</div>", unsafe_allow_html=True)
    _logo = Path(__file__).parent / "octa_auth" / "octa_logo.png"
    if _logo.exists():   # full-resolution logo, scaled by the browser so it stays sharp on high-density screens
        st.markdown(f"<img src='data:image/png;base64,{base64.b64encode(_logo.read_bytes()).decode()}' "
                    "alt='Octa Insight' style='width:150px;height:auto;margin-top:8px'>", unsafe_allow_html=True)

pages[choice]()
_log(f"page '{choice}' drawn")
