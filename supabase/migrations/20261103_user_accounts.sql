-- Octa user database (Supabase project Octa_projects). Applied 2026-11-03 as migration "user_accounts".
-- One account serves every Octa app (CloudEARTHi-Octa apps, Octa scientific apps, Octa games).
-- Passwords are bcrypt-hashed and checked inside the database; tokens are stored only as SHA-256 hashes.
-- All tables are closed to the public API; apps call the octa_user_* functions below.

-- ---------------------------------------------------------------- tables
create table public."User_accounts" (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  email text not null unique check (email = lower(email) and email like '%_@_%.__%' and char_length(email) <= 254),
  username text not null check (char_length(username) between 3 and 40 and username ~ '^[A-Za-z0-9._-]+$'),
  password_hash text not null,
  first_name text check (char_length(first_name) <= 100),
  last_name text check (char_length(last_name) <= 100),
  affiliation text check (char_length(affiliation) <= 300),
  country text check (char_length(country) <= 100),
  job_title text check (char_length(job_title) <= 200),
  orcid text check (char_length(orcid) <= 40),
  website text check (char_length(website) <= 300),
  biography text check (char_length(biography) <= 4000),
  status text not null default 'active' check (status in ('active', 'pending', 'suspended')),
  role text not null default 'user' check (role in ('user', 'admin')),
  registered_from text check (char_length(registered_from) <= 60),
  force_password_change boolean not null default false,
  last_login_at timestamptz,
  legacy_launcher_id bigint
);
create unique index "User_accounts_username_lower_idx" on public."User_accounts" (lower(username));
comment on table public."User_accounts" is 'Octa users: one account for all Octa apps. Common profile fields; app-family fields live in User_profiles.';

create table public."User_profiles" (
  user_id uuid not null references public."User_accounts"(id) on delete cascade,
  family text not null check (family in ('science', 'cloudearthi', 'games')),
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object' and pg_column_size(data) <= 65536),
  updated_at timestamptz not null default now(),
  primary key (user_id, family)
);
comment on table public."User_profiles" is 'Extra profile data collected by the registration pages of each app family (e.g. social media, institutes and projects for CloudEARTHi; gamer name for games).';

create table public."User_apps" (
  id text primary key check (id ~ '^[a-z0-9_]+$' and char_length(id) <= 40),
  family text not null check (family in ('science', 'cloudearthi', 'games')),
  name text not null check (char_length(name) <= 100),
  description text check (char_length(description) <= 500),
  icon text check (char_length(icon) <= 16),
  url text check (char_length(url) <= 300),
  status text not null default 'live' check (status in ('live', 'construction', 'retired')),
  access_mode text not null default 'open' check (access_mode in ('open', 'approval')),
  group_label text check (char_length(group_label) <= 100),
  sort_order integer not null default 100
);
comment on table public."User_apps" is 'Catalogue of Octa apps. access_mode open = every registered user may use it; approval = an admin grants access.';

create table public."User_app_access" (
  user_id uuid not null references public."User_accounts"(id) on delete cascade,
  app_id text not null references public."User_apps"(id) on delete cascade,
  status text not null check (status in ('granted', 'requested', 'revoked')),
  updated_at timestamptz not null default now(),
  updated_by uuid references public."User_accounts"(id) on delete set null,
  primary key (user_id, app_id)
);

create table public."User_sessions" (
  token_hash text primary key check (char_length(token_hash) = 64),
  user_id uuid not null references public."User_accounts"(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_active_at timestamptz not null default now(),
  expires_at timestamptz not null,
  created_in_app text check (char_length(created_in_app) <= 40)
);
create index "User_sessions_user_idx" on public."User_sessions" (user_id);
comment on table public."User_sessions" is 'Active sign-ins. A session stays valid while used; it ends 3 hours after the last activity.';

create table public."User_password_resets" (
  token_hash text primary key check (char_length(token_hash) = 64),
  user_id uuid not null references public."User_accounts"(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  return_app text check (char_length(return_app) <= 40)
);
create index "User_password_resets_user_idx" on public."User_password_resets" (user_id, created_at);

create table public."User_email_requests" (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  email text not null check (char_length(email) <= 254),
  kind text not null check (kind in ('reset', 'not_registered', 'welcome'))
);
create index "User_email_requests_email_idx" on public."User_email_requests" (email, created_at);
comment on table public."User_email_requests" is 'Emails the apps were asked to send (for rate limiting).';

create table public."User_usage" (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid not null references public."User_accounts"(id) on delete cascade,
  app_id text references public."User_apps"(id) on delete set null,
  event text not null check (event in ('login', 'open', 'active', 'logout', 'register'))
);
create index "User_usage_user_idx" on public."User_usage" (user_id, created_at);
comment on table public."User_usage" is 'How each user uses the Octa apps (sign-ins, app opens, activity); orders the portal catalogue.';

create table public."User_config" (
  key text primary key,
  value text not null
);
comment on table public."User_config" is 'Private settings (e.g. the hash of the server key the apps use for password resets).';

do $$ declare t text; begin
  foreach t in array array['User_accounts','User_profiles','User_apps','User_app_access','User_sessions',
                           'User_password_resets','User_email_requests','User_usage','User_config'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- helpers (not callable through the API)
create or replace function public.octa_user_hash(p text) returns text
language sql immutable set search_path = '' as $$ select encode(extensions.digest(p, 'sha256'), 'hex') $$;

create or replace function public.octa_user_pw_ok(p_password text, p_hash text) returns boolean
language sql immutable set search_path = '' as $$
  -- bcrypt $2a$ and $2b$ hashes are identical apart from the prefix; pgcrypto checks $2a$
  select p_hash is not null and p_password is not null and
         extensions.crypt(p_password, '$2a$' || substr(p_hash, 5)) = '$2a$' || substr(p_hash, 5)
$$;

create or replace function public.octa_user_pw_make(p_password text) returns text
language sql volatile set search_path = '' as $$ select extensions.crypt(p_password, extensions.gen_salt('bf', 12)) $$;

create or replace function public.octa_user_server_ok(p_server_key text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public."User_config" where key = 'server_key_hash'
                 and value = public.octa_user_hash(coalesce(p_server_key, '')))
$$;

-- public part of a user, as returned to apps
create or replace function public.octa_user_public(p_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', a.id, 'email', a.email, 'username', a.username, 'first_name', a.first_name, 'last_name', a.last_name,
    'affiliation', a.affiliation, 'country', a.country, 'job_title', a.job_title, 'orcid', a.orcid,
    'website', a.website, 'biography', a.biography, 'role', a.role, 'status', a.status,
    'force_password_change', a.force_password_change, 'created_at', a.created_at,
    'profiles', coalesce((select jsonb_object_agg(p.family, p.data) from public."User_profiles" p where p.user_id = a.id), '{}'::jsonb),
    'apps', coalesce((select jsonb_agg(x.id order by x.id) from public."User_apps" x
                      where x.status <> 'retired' and (
                        (x.access_mode = 'open' and not exists (select 1 from public."User_app_access" r
                                                                where r.user_id = a.id and r.app_id = x.id and r.status = 'revoked'))
                        or exists (select 1 from public."User_app_access" g where g.user_id = a.id and g.app_id = x.id
                                   and g.status = 'granted'))), '[]'::jsonb))
  from public."User_accounts" a where a.id = p_id
$$;

create or replace function public.octa_user_new_session(p_user uuid, p_app text) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare tok text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  delete from public."User_sessions" where expires_at < now() - interval '1 day';
  insert into public."User_sessions"(token_hash, user_id, expires_at, created_in_app)
  values (public.octa_user_hash(tok), p_user, now() + interval '3 hours', p_app);
  return tok;
end $$;

-- ---------------------------------------------------------------- API (called by the apps)
-- Register. p: email, username, password, first_name, last_name, affiliation, country, job_title, orcid,
-- website, family ('science'|'cloudearthi'|'games'), profile (object), app (id of the app it came from).
create or replace function public.octa_user_register(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid; em text := lower(trim(p->>'email')); un text := trim(p->>'username');
        pw text := p->>'password'; app text := nullif(p->>'app', ''); fam text := coalesce(nullif(p->>'family', ''), 'science');
        mode text;
begin
  if em is null or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then return jsonb_build_object('ok', false, 'error', 'Please enter a valid email address.'); end if;
  if un is null or un !~ '^[A-Za-z0-9._-]{3,40}$' then
    return jsonb_build_object('ok', false, 'error', 'Username: 3–40 letters, numbers, dots, dashes or underscores.'); end if;
  if pw is null or char_length(pw) < 8 then return jsonb_build_object('ok', false, 'error', 'Password: at least 8 characters.'); end if;
  if exists (select 1 from public."User_accounts" where email = em) then
    return jsonb_build_object('ok', false, 'error', 'This email is already registered. Log in, or use “Forgot username or password”.'); end if;
  if exists (select 1 from public."User_accounts" where lower(username) = lower(un)) then
    return jsonb_build_object('ok', false, 'error', 'This username is taken. Please choose another.'); end if;
  if fam not in ('science', 'cloudearthi', 'games') then fam := 'science'; end if;
  if app is not null and not exists (select 1 from public."User_apps" where id = app) then app := null; end if;
  insert into public."User_accounts"(email, username, password_hash, first_name, last_name, affiliation, country,
                                     job_title, orcid, website, registered_from)
  values (em, un, public.octa_user_pw_make(pw), left(p->>'first_name', 100), left(p->>'last_name', 100),
          left(p->>'affiliation', 300), left(p->>'country', 100), left(p->>'job_title', 200), left(p->>'orcid', 40),
          left(p->>'website', 300), left(app, 60))
  returning id into uid;
  if jsonb_typeof(p->'profile') = 'object' then
    insert into public."User_profiles"(user_id, family, data) values (uid, fam, p->'profile');
  end if;
  if app is not null then
    select access_mode into mode from public."User_apps" where id = app;
    if mode = 'approval' then
      insert into public."User_app_access"(user_id, app_id, status) values (uid, app, 'requested') on conflict do nothing;
    end if;
  end if;
  insert into public."User_usage"(user_id, app_id, event) values (uid, app, 'register');
  return jsonb_build_object('ok', true, 'token', public.octa_user_new_session(uid, app), 'user', public.octa_user_public(uid));
end $$;

-- Log in with email or username.
create or replace function public.octa_user_login(p_login text, p_password text, p_app text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare a public."User_accounts"; app text := nullif(p_app, '');
begin
  select * into a from public."User_accounts"
  where email = lower(trim(p_login)) or lower(username) = lower(trim(p_login)) limit 1;
  if a.id is null or not public.octa_user_pw_ok(p_password, a.password_hash) then
    perform pg_sleep(0.3);
    return jsonb_build_object('ok', false, 'error', 'Wrong email/username or password.');
  end if;
  if a.status = 'suspended' then return jsonb_build_object('ok', false, 'error', 'This account is suspended. Please contact Octa Insight.'); end if;
  update public."User_accounts" set last_login_at = now() where id = a.id;
  if app is not null and not exists (select 1 from public."User_apps" where id = app) then app := null; end if;
  insert into public."User_usage"(user_id, app_id, event) values (a.id, app, 'login');
  return jsonb_build_object('ok', true, 'token', public.octa_user_new_session(a.id, app), 'user', public.octa_user_public(a.id));
end $$;

-- Check a session (on every page load). Extends it by 3 hours; records activity at most every 10 minutes.
create or replace function public.octa_user_session(p_token text, p_app text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare s public."User_sessions"; app text := nullif(p_app, '');
begin
  select * into s from public."User_sessions" where token_hash = public.octa_user_hash(coalesce(p_token, ''));
  if s.token_hash is null or s.expires_at < now() then
    return jsonb_build_object('ok', false, 'error', 'Your session has ended. Please log in again.');
  end if;
  if not exists (select 1 from public."User_accounts" where id = s.user_id and status <> 'suspended') then
    return jsonb_build_object('ok', false, 'error', 'This account is not active.');
  end if;
  if app is not null and not exists (select 1 from public."User_apps" where id = app) then app := null; end if;
  if s.last_active_at < now() - interval '10 minutes' or app is distinct from s.created_in_app then
    insert into public."User_usage"(user_id, app_id, event) values (s.user_id, app, 'active');
  end if;
  update public."User_sessions" set last_active_at = now(), expires_at = now() + interval '3 hours',
         created_in_app = coalesce(app, created_in_app)
  where token_hash = s.token_hash;
  return jsonb_build_object('ok', true, 'user', public.octa_user_public(s.user_id),
                            'expires_at', now() + interval '3 hours');
end $$;

create or replace function public.octa_user_logout(p_token text, p_app text) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid;
begin
  delete from public."User_sessions" where token_hash = public.octa_user_hash(coalesce(p_token, '')) returning user_id into uid;
  if uid is not null then
    insert into public."User_usage"(user_id, app_id, event)
    values (uid, (select id from public."User_apps" where id = nullif(p_app, '')), 'logout');
  end if;
end $$;

-- Record that the user opened an app (from the portal or a sidebar link).
create or replace function public.octa_user_track(p_token text, p_app text, p_event text) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid;
begin
  select user_id into uid from public."User_sessions" where token_hash = public.octa_user_hash(coalesce(p_token, '')) and expires_at > now();
  if uid is not null and p_event in ('open', 'active') and exists (select 1 from public."User_apps" where id = p_app) then
    insert into public."User_usage"(user_id, app_id, event) values (uid, p_app, p_event);
  end if;
end $$;

-- Catalogue for the portal: every app, whether the user may open it, and the order of the three families
-- (most used family first, from the last 180 days of use).
create or replace function public.octa_user_catalogue(p_token text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid; mine jsonb;
begin
  select user_id into uid from public."User_sessions" where token_hash = public.octa_user_hash(coalesce(p_token, '')) and expires_at > now();
  mine := case when uid is null then '[]'::jsonb else public.octa_user_public(uid)->'apps' end;
  return jsonb_build_object(
    'signed_in', uid is not null,
    'family_order', (
      select jsonb_agg(f.family order by f.uses desc, f.base)
      from (select fam.family, fam.base,
                   coalesce((select count(*) from public."User_usage" u join public."User_apps" x on x.id = u.app_id
                             where u.user_id = uid and x.family = fam.family and u.created_at > now() - interval '180 days'), 0)
                   + coalesce((select count(*) from public."User_apps" x where x.family = fam.family
                               and mine ? x.id and x.access_mode = 'approval'), 0) * 5 as uses
            from (values ('cloudearthi', 1), ('science', 2), ('games', 3)) as fam(family, base)) f),
    'apps', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', x.id, 'family', x.family, 'name', x.name, 'description', x.description, 'icon', x.icon,
               'url', x.url, 'status', x.status, 'access_mode', x.access_mode, 'group_label', x.group_label,
               'can_open', mine ? x.id,
               'requested', exists (select 1 from public."User_app_access" r where r.user_id = uid and r.app_id = x.id and r.status = 'requested'),
               'uses', (select count(*) from public."User_usage" u where u.user_id = uid and u.app_id = x.id
                        and u.created_at > now() - interval '180 days'))
             order by x.family, x.sort_order, x.name)
      from public."User_apps" x where x.status <> 'retired'), '[]'::jsonb));
end $$;

create or replace function public.octa_user_request_access(p_token text, p_app text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid; mode text;
begin
  select user_id into uid from public."User_sessions" where token_hash = public.octa_user_hash(coalesce(p_token, '')) and expires_at > now();
  if uid is null then return jsonb_build_object('ok', false, 'error', 'Please log in first.'); end if;
  select access_mode into mode from public."User_apps" where id = p_app and status <> 'retired';
  if mode is null then return jsonb_build_object('ok', false, 'error', 'Unknown app.'); end if;
  if mode = 'open' then return jsonb_build_object('ok', true, 'status', 'granted'); end if;
  insert into public."User_app_access"(user_id, app_id, status) values (uid, p_app, 'requested')
  on conflict (user_id, app_id) do update set status = case when public."User_app_access".status = 'granted'
                                                            then 'granted' else 'requested' end, updated_at = now();
  return jsonb_build_object('ok', true, 'status', 'requested');
end $$;

-- Update one's own profile. p: any of the common fields, plus family + profile (object, merged).
create or replace function public.octa_user_update_profile(p_token text, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid; fam text := p->>'family';
begin
  select user_id into uid from public."User_sessions" where token_hash = public.octa_user_hash(coalesce(p_token, '')) and expires_at > now();
  if uid is null then return jsonb_build_object('ok', false, 'error', 'Please log in first.'); end if;
  update public."User_accounts" set
    first_name = case when p ? 'first_name' then left(p->>'first_name', 100) else first_name end,
    last_name = case when p ? 'last_name' then left(p->>'last_name', 100) else last_name end,
    affiliation = case when p ? 'affiliation' then left(p->>'affiliation', 300) else affiliation end,
    country = case when p ? 'country' then left(p->>'country', 100) else country end,
    job_title = case when p ? 'job_title' then left(p->>'job_title', 200) else job_title end,
    orcid = case when p ? 'orcid' then left(p->>'orcid', 40) else orcid end,
    website = case when p ? 'website' then left(p->>'website', 300) else website end,
    biography = case when p ? 'biography' then left(p->>'biography', 4000) else biography end,
    updated_at = now()
  where id = uid;
  if fam in ('science', 'cloudearthi', 'games') and jsonb_typeof(p->'profile') = 'object' then
    insert into public."User_profiles"(user_id, family, data) values (uid, fam, p->'profile')
    on conflict (user_id, family) do update set data = public."User_profiles".data || excluded.data, updated_at = now();
  end if;
  return jsonb_build_object('ok', true, 'user', public.octa_user_public(uid));
end $$;

-- Change password while logged in.
create or replace function public.octa_user_change_password(p_token text, p_old text, p_new text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid; h text;
begin
  select s.user_id, a.password_hash into uid, h from public."User_sessions" s join public."User_accounts" a on a.id = s.user_id
  where s.token_hash = public.octa_user_hash(coalesce(p_token, '')) and s.expires_at > now();
  if uid is null then return jsonb_build_object('ok', false, 'error', 'Please log in first.'); end if;
  if not public.octa_user_pw_ok(p_old, h) then return jsonb_build_object('ok', false, 'error', 'The current password is wrong.'); end if;
  if p_new is null or char_length(p_new) < 8 then return jsonb_build_object('ok', false, 'error', 'Password: at least 8 characters.'); end if;
  update public."User_accounts" set password_hash = public.octa_user_pw_make(p_new), force_password_change = false, updated_at = now() where id = uid;
  return jsonb_build_object('ok', true);
end $$;

-- Forgotten username/password, step 1. Needs the server key held by the apps (it returns a reset token,
-- which the app emails). Returns whether the email exists; at most 5 requests per email per hour.
create or replace function public.octa_user_reset_request(p_server_key text, p_email text, p_app text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare em text := lower(trim(p_email)); a public."User_accounts"; tok text;
begin
  if not public.octa_user_server_ok(p_server_key) then return jsonb_build_object('ok', false, 'error', 'not allowed'); end if;
  if (select count(*) from public."User_email_requests" where email = em and created_at > now() - interval '1 hour') >= 5 then
    return jsonb_build_object('ok', false, 'error', 'Too many requests for this email. Please try again in an hour.');
  end if;
  select * into a from public."User_accounts" where email = em;
  if a.id is null then
    insert into public."User_email_requests"(email, kind) values (em, 'not_registered');
    return jsonb_build_object('ok', true, 'exists', false);
  end if;
  insert into public."User_email_requests"(email, kind) values (em, 'reset');
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public."User_password_resets"(token_hash, user_id, expires_at, return_app)
  values (public.octa_user_hash(tok), a.id, now() + interval '1 hour', nullif(p_app, ''));
  return jsonb_build_object('ok', true, 'exists', true, 'token', tok, 'username', a.username,
                            'first_name', a.first_name, 'email', a.email);
end $$;

-- Step 2: the page opened from the email shows the username for this reset link.
create or replace function public.octa_user_reset_check(p_token text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce((select jsonb_build_object('ok', true, 'username', a.username, 'email', a.email, 'return_app', r.return_app)
                   from public."User_password_resets" r join public."User_accounts" a on a.id = r.user_id
                   where r.token_hash = public.octa_user_hash(coalesce(p_token, '')) and r.used_at is null and r.expires_at > now()),
                  jsonb_build_object('ok', false, 'error', 'This link has expired or was already used. Please ask for a new one.'))
$$;

-- Step 3: set a new password (and optionally a new username). Ends all sessions of that user.
create or replace function public.octa_user_reset_complete(p_token text, p_new_password text, p_new_username text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare r public."User_password_resets"; un text := nullif(trim(coalesce(p_new_username, '')), '');
begin
  select * into r from public."User_password_resets" where token_hash = public.octa_user_hash(coalesce(p_token, ''))
  and used_at is null and expires_at > now();
  if r.token_hash is null then return jsonb_build_object('ok', false, 'error', 'This link has expired or was already used. Please ask for a new one.'); end if;
  if p_new_password is null or char_length(p_new_password) < 8 then return jsonb_build_object('ok', false, 'error', 'Password: at least 8 characters.'); end if;
  if un is not null then
    if un !~ '^[A-Za-z0-9._-]{3,40}$' then return jsonb_build_object('ok', false, 'error', 'Username: 3–40 letters, numbers, dots, dashes or underscores.'); end if;
    if exists (select 1 from public."User_accounts" where lower(username) = lower(un) and id <> r.user_id) then
      return jsonb_build_object('ok', false, 'error', 'This username is taken. Please choose another.'); end if;
  end if;
  update public."User_accounts" set password_hash = public.octa_user_pw_make(p_new_password),
         username = coalesce(un, username), force_password_change = false, updated_at = now() where id = r.user_id;
  update public."User_password_resets" set used_at = now() where user_id = r.user_id and used_at is null;
  delete from public."User_sessions" where user_id = r.user_id;
  return jsonb_build_object('ok', true, 'return_app', r.return_app,
                            'username', (select username from public."User_accounts" where id = r.user_id));
end $$;

-- Welcome email: lets the app record (and rate-limit) the welcome message it sends after registration.
create or replace function public.octa_user_note_email(p_server_key text, p_email text, p_kind text) returns boolean
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not public.octa_user_server_ok(p_server_key) or p_kind not in ('welcome') then return false; end if;
  insert into public."User_email_requests"(email, kind) values (lower(trim(p_email)), p_kind);
  return true;
end $$;

-- Admin: grant, revoke or approve app access, and change a user's status.
create or replace function public.octa_user_admin(p_token text, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare me uuid; target uuid := nullif(p->>'user_id', '')::uuid;
begin
  select s.user_id into me from public."User_sessions" s join public."User_accounts" a on a.id = s.user_id
  where s.token_hash = public.octa_user_hash(coalesce(p_token, '')) and s.expires_at > now() and a.role = 'admin';
  if me is null then return jsonb_build_object('ok', false, 'error', 'Admins only.'); end if;
  if p->>'action' = 'list_requests' then
    return jsonb_build_object('ok', true, 'requests', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', a.id, 'email', a.email, 'name', concat_ws(' ', a.first_name, a.last_name),
                                          'affiliation', a.affiliation, 'app_id', r.app_id, 'app', x.name, 'since', r.updated_at)
                       order by r.updated_at)
      from public."User_app_access" r join public."User_accounts" a on a.id = r.user_id join public."User_apps" x on x.id = r.app_id
      where r.status = 'requested'), '[]'::jsonb));
  elsif p->>'action' = 'list_users' then
    return jsonb_build_object('ok', true, 'users', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', a.id, 'email', a.email, 'username', a.username,
                                          'name', concat_ws(' ', a.first_name, a.last_name), 'affiliation', a.affiliation,
                                          'status', a.status, 'role', a.role, 'last_login_at', a.last_login_at,
                                          'apps', public.octa_user_public(a.id)->'apps') order by a.created_at desc)
      from public."User_accounts" a), '[]'::jsonb));
  elsif p->>'action' = 'set_access' then
    if p->>'status' not in ('granted', 'requested', 'revoked') then return jsonb_build_object('ok', false, 'error', 'bad status'); end if;
    insert into public."User_app_access"(user_id, app_id, status, updated_by) values (target, p->>'app_id', p->>'status', me)
    on conflict (user_id, app_id) do update set status = excluded.status, updated_at = now(), updated_by = me;
    return jsonb_build_object('ok', true);
  elsif p->>'action' = 'set_status' then
    if p->>'status' not in ('active', 'pending', 'suspended') then return jsonb_build_object('ok', false, 'error', 'bad status'); end if;
    update public."User_accounts" set status = p->>'status', updated_at = now() where id = target;
    if p->>'status' = 'suspended' then delete from public."User_sessions" where user_id = target; end if;
    return jsonb_build_object('ok', true);
  end if;
  return jsonb_build_object('ok', false, 'error', 'unknown action');
end $$;

-- ---------------------------------------------------------------- privileges
do $$ declare f text; begin
  foreach f in array array['octa_user_hash(text)', 'octa_user_pw_ok(text,text)', 'octa_user_pw_make(text)',
                           'octa_user_server_ok(text)', 'octa_user_public(uuid)', 'octa_user_new_session(uuid,text)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['octa_user_register(jsonb)', 'octa_user_login(text,text,text)', 'octa_user_session(text,text)',
                           'octa_user_logout(text,text)', 'octa_user_track(text,text,text)', 'octa_user_catalogue(text)',
                           'octa_user_request_access(text,text)', 'octa_user_update_profile(text,jsonb)',
                           'octa_user_change_password(text,text,text)', 'octa_user_reset_request(text,text,text)',
                           'octa_user_reset_check(text)', 'octa_user_reset_complete(text,text,text)',
                           'octa_user_note_email(text,text,text)', 'octa_user_admin(text,jsonb)'] loop
    execute format('revoke execute on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------- app catalogue
insert into public."User_apps"(id, family, name, description, icon, url, status, access_mode, group_label, sort_order) values
 ('igneosuite', 'science', 'IgneoSuite', 'Test, fill and explore gaps in igneous geochemical data', '🪨', 'https://igneosuite.streamlit.app/', 'live', 'open', 'Geoscience', 10),
 ('explain_earth', 'science', 'ExplainEarth', 'Explaining Earth and future data', '🌍', '', 'construction', 'open', 'Geoscience', 20),
 ('octa_partners', 'cloudearthi', 'Partner Network', 'Partner profiles, contacts, CloudEARTHi Alliance members', '🌐', 'https://octa-partners.streamlit.app/', 'live', 'approval', 'Partner & Network', 10),
 ('octa_social', 'cloudearthi', 'Social Media Hub', 'Create & publish content, tag partners across all channels', '📱', '', 'construction', 'approval', 'Partner & Network', 20),
 ('octa_communication', 'cloudearthi', 'Partner Communication', 'Centralised partner messaging and outreach across projects', '📧', '', 'construction', 'approval', 'Partner & Network', 30),
 ('octa_proposals', 'cloudearthi', 'Proposal Tracker', 'Track proposals, budgets, deadlines, PES fund & partners', '📋', 'https://proposal-progress.streamlit.app', 'live', 'approval', 'Proposal Suite', 40),
 ('octa_intelligence', 'cloudearthi', 'Proposal Intelligence', 'AI-powered call analysis, strategy & positioning suggestions', '🤖', 'https://octa-intelligence.streamlit.app', 'live', 'approval', 'Proposal Suite', 50),
 ('octa_kpi', 'cloudearthi', 'Objectives & Work Plan Designer', 'Design KPIs, deliverables, work packages, Gantt & budget', '📊', 'https://octakpi.streamlit.app/', 'live', 'approval', 'Proposal Suite', 60),
 ('octa_writer', 'cloudearthi', 'Proposal Writing Studio', 'Collaborative writing with AI assistance and version history', '📝', '', 'construction', 'approval', 'Proposal Suite', 70),
 ('octa_review', 'cloudearthi', 'Review & Evaluation', 'Internal review, scoring and quality control before submission', '🔍', '', 'construction', 'approval', 'Proposal Suite', 80),
 ('octa_projects', 'cloudearthi', 'Project Progress Tracker', 'Monitor funded project milestones, deadlines and deliverables', '🏗️', 'https://project-progress.streamlit.app/', 'live', 'approval', 'Project Management', 90),
 ('octa_financial', 'cloudearthi', 'Financial Control', 'Budget consumption, forecasting and financial reporting', '💶', 'https://octa-financial.streamlit.app/', 'live', 'approval', 'Project Management', 100),
 ('octa_risk_log', 'cloudearthi', 'Project Risk Log', 'Record, monitor and mitigate risks for ongoing funded projects', '🛡️', 'https://octa-risks.streamlit.app/', 'live', 'approval', 'Project Management', 110),
 ('octa_hours', 'cloudearthi', 'Working Hours', 'Log, approve and report working hours per proposal or project', '⏱️', 'https://working-hours.streamlit.app', 'live', 'approval', 'People & Tasks', 120),
 ('octa_tasks', 'cloudearthi', 'Task Manager', 'Assign tasks, track progress and manage team to-dos', '✅', 'https://octa-task-manager.streamlit.app', 'live', 'approval', 'People & Tasks', 130),
 ('octa_calendar', 'cloudearthi', 'Common Calendar', 'Unified calendar: deadlines, meetings, milestones & events across all apps', '📅', '', 'construction', 'approval', 'Calendar', 140),
 ('octa_game_1', 'games', 'Octa game', 'Our first game is on its way', '🎮', '', 'construction', 'open', 'Games', 10);
