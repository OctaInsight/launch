-- Fourth app family "Innovation, Education and Training apps" (id: education), with the matchmaking app.
-- The portal orders families and apps by the user's own use, then by everyone's use. Applied 2026-11-04 as
-- "user_education_family".
alter table public."User_apps" drop constraint "User_apps_family_check",
  add constraint "User_apps_family_check" check (family in ('science', 'cloudearthi', 'education', 'games'));
alter table public."User_profiles" drop constraint "User_profiles_family_check",
  add constraint "User_profiles_family_check" check (family in ('science', 'cloudearthi', 'education', 'games'));

-- registration and profile updates accept the new family
do $$ declare f record; def text; begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('octa_user_register', 'octa_user_update_profile') loop
    def := replace(pg_get_functiondef(f.oid), '(''science'', ''cloudearthi'', ''games'')',
                   '(''science'', ''cloudearthi'', ''education'', ''games'')');
    execute def;
  end loop;
end $$;

-- catalogue: family order and app statistics. Score = the user's own visits (last 180 days, approved access counts
-- as 5) first; everyone's visits break ties and order the page for new users.
create or replace function public.octa_user_catalogue(p_token text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid; mine jsonb;
begin
  select user_id into uid from public."User_sessions" where token_hash = public.octa_user_hash(coalesce(p_token, '')) and expires_at > now();
  mine := case when uid is null then '[]'::jsonb else public.octa_user_public(uid)->'apps' end;
  return jsonb_build_object(
    'signed_in', uid is not null,
    'family_order', (
      select jsonb_agg(f.family order by f.mine desc, f.everyone desc, f.base)
      from (select fam.family, fam.base,
                   coalesce((select count(*) from public."User_usage" u join public."User_apps" x on x.id = u.app_id
                             where u.user_id = uid and x.family = fam.family and u.created_at > now() - interval '180 days'), 0)
                   + coalesce((select count(*) from public."User_apps" x where x.family = fam.family
                               and mine ? x.id and x.access_mode = 'approval'), 0) * 5 as mine,
                   coalesce((select count(*) from public."User_usage" u join public."User_apps" x on x.id = u.app_id
                             where x.family = fam.family and u.created_at > now() - interval '180 days'), 0) as everyone
            from (values ('cloudearthi', 1), ('science', 2), ('education', 3), ('games', 4)) as fam(family, base)) f),
    'apps', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', x.id, 'family', x.family, 'name', x.name, 'description', x.description, 'icon', x.icon,
               'url', x.url, 'status', x.status, 'access_mode', x.access_mode, 'group_label', x.group_label,
               'sort_order', x.sort_order,
               'can_open', mine ? x.id,
               'requested', exists (select 1 from public."User_app_access" r where r.user_id = uid and r.app_id = x.id and r.status = 'requested'),
               'uses', (select count(*) from public."User_usage" u where u.user_id = uid and u.app_id = x.id
                        and u.created_at > now() - interval '180 days'),
               'everyone_uses', (select count(*) from public."User_usage" u where u.app_id = x.id
                                 and u.created_at > now() - interval '180 days'))
             order by x.family, x.sort_order, x.name)
      from public."User_apps" x where x.status <> 'retired'), '[]'::jsonb));
end $$;

insert into public."User_apps"(id, family, name, description, icon, url, status, access_mode, group_label, sort_order)
values ('octa_matchmaking', 'education', 'Matchmaking', 'Find partners for innovation, education and training projects and events',
        '🤝', '', 'construction', 'open', 'Innovation', 10)
on conflict (id) do nothing;
