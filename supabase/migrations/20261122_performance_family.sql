-- Fifth app family "Performance Apps" (id: performance), always listed last, below Octa games, whatever the use
-- statistics say. The Octa Watchdog moves there. Applied 2026-11-22 as "user_performance_family".
alter table public."User_apps" drop constraint "User_apps_family_check",
  add constraint "User_apps_family_check" check (family in ('science', 'cloudearthi', 'education', 'games', 'performance'));

do $$ declare f oid; def text; old text; begin
  select p.oid into f from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'octa_user_catalogue';
  def := pg_get_functiondef(f);
  old := '(''education'', 3), (''games'', 4)) as fam(family, base)';
  if position(old in def) = 0 then raise exception 'catalogue: family list not found'; end if;
  def := replace(def, old, '(''education'', 3), (''games'', 4), (''performance'', 5)) as fam(family, base)');
  old := 'jsonb_agg(f.family order by f.mine desc';
  if position(old in def) = 0 then raise exception 'catalogue: order not found'; end if;
  def := replace(def, old, 'jsonb_agg(f.family order by (f.family = ''performance''), f.mine desc');
  execute def;
end $$;

update public."User_apps" set family = 'performance', group_label = 'Performance' where id = 'octa_watchdog';
