# Octa suite: one account for all Octa Insight apps

This repository holds:

- **`app.py`**: the common Octa suite page. It has login, registration and forgotten username/password pages. After login it shows every Octa app, grouped as CloudEARTHi-Octa apps, Octa scientific apps, Innovation, Education and Training apps, and Octa games. Groups and the apps inside them are ordered by the user's own use, then by all users' use (last 6 months), and groups are separated by horizontal bars. Apps the user cannot open are greyed out, with **Request access** or **Coming soon**. Administrators also get an *Administration* page to approve access requests, grant or revoke access, and suspend accounts.
- **`octa_auth/`**: the shared Python module every Octa app copies in. It gives each app its own login/register page, which writes to the same user database. It also provides the sidebar buttons (**Log in**, **Log out**, **Octa suite**) and sends emails through Gmail.
- **`supabase/migrations/`**: the user database (tables `User_*`, functions `octa_user_*`) in the Supabase project *Octa_projects*.

## How signing in works

- **One account** works in every app. The fields asked for depend on the app:
  - scientific apps ask for name, email, username, password, affiliation and a scientific profile;
  - CloudEARTHi apps also ask for social media, affiliated institutes, projects, and which apps the user needs;
  - innovation, education and training apps ask for the type of organisation, LinkedIn and topics;
  - games ask for a player name.
- **Passwords** are bcrypt hashes and are checked inside the database. The apps never read the user tables. They call only the `octa_user_*` functions with the publishable key.
- **Sessions** are carried in the address bar (`?session=…`):
  - a browser refresh keeps the user signed in;
  - a link from the Octa suite opens another app without a new password;
  - after **3 hours without activity** the session ends.
  - In the database only a hash of the token is kept (`User_sessions`).
- **Forgotten username or password.** The app emails the user from octainsight@gmail.com:
  - if the email is unknown, the message says so and links to registration;
  - if it is known, the message shows the username and gives a one-hour link to a page for a new password (and, optionally, a new username).
  - After saving, the user logs in on the same app's login page. All old sessions end.
- **Access**:
  - `open` apps (scientific apps, games) are available to every account;
  - `approval` apps (CloudEARTHi) need an administrator's approval.
- **Usage** (sign-ins, app visits, activity) is recorded in `User_usage` and orders the Octa suite page.

## Database tables

| Table | Contents |
|---|---|
| `User_accounts` | one row per person: email, username, password hash, name, affiliation, country, position, ORCID, web page, profile text, status, role |
| `User_profiles` | extra fields per app family (`science`, `cloudearthi`, `games`) as JSON |
| `User_apps` | the app catalogue: family, name, address, status (live / construction), access mode |
| `User_app_access` | which user may use which approval app (granted / requested / revoked) |
| `User_sessions` | active sign-ins (token hash, last activity, expiry) |
| `User_password_resets` | one-time reset links (hash, 1 hour) |
| `User_email_requests` | emails asked for (limit of 5 per hour per address) |
| `User_usage` | usage statistics |
| `User_config` | private settings (hash of the server key) |

To add an app, insert a row in `User_apps`. To make someone an administrator, run
`update "User_accounts" set role = 'admin' where email = '…';` in the Supabase SQL editor.

## Adding login to an app

1. Copy the `octa_auth` folder into the app's repository.
2. Add this to the app's `app.py`:
   ```python
   import streamlit as st
   st.set_page_config(page_title="My app", layout="wide")
   from octa_auth import App, require_login, sidebar

   APP = App(id="octa_kpi", name="Objectives & Work Plan Designer", family="cloudearthi",
             url="https://octakpi.streamlit.app/")
   user = require_login(APP)          # the app's own login/register page until signed in
   with st.sidebar:
       sidebar(APP)                   # Log in / Log out / Octa suite
   ```
3. Add the secrets below to the app.

`user` is a dict with `id`, `email`, `username`, `first_name`, `last_name`, `affiliation`, `role`, `apps` (ids the user may open) and `profiles`.

## Streamlit secrets

```toml
[octa_users]
url = "https://uxqeukvmnfvpgsxktgvo.supabase.co"
key = "sb_publishable_…"
server_key = "…"                       # lets the app create password-reset links
portal_url = "https://octa-suite.streamlit.app/"

[email]
user = "octainsight@gmail.com"
app_password = "…"                     # Google account → Security → 2-Step Verification → App passwords
from_name = "Octa Insight"
```

## Tests

```
pip install -r requirements.txt pytest
pytest tests                            # uses an in-memory copy of the database functions
streamlit run tests/fake_app.py         # click through the pages without a database
```

© 2026 Octa Insight · Produced by Octa Systems
