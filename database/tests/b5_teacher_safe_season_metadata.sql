-- Security checks introduced by 059 and retained after later metadata migrations.
begin;

do $test$
begin
  if to_regprocedure(
       'public.admin_update_scheduled_season_meta_self(text,integer,text)') is null then
    raise exception 'safe teacher metadata RPC is missing';
  end if;

  if has_function_privilege(
       'authenticated',
       'public.admin_save_season_v2_self(text,text,text,timestamptz,timestamptz,jsonb,boolean)',
       'EXECUTE') then
    raise exception 'authenticated must not execute full Season V2 mutation';
  end if;

  if has_function_privilege(
       'authenticated',
       'public.close_season_self()',
       'EXECUTE') then
    raise exception 'authenticated must not close a season manually';
  end if;

  if not has_function_privilege(
       'authenticated',
       'public.admin_update_scheduled_season_meta_self(text,integer,text)',
       'EXECUTE') then
    raise exception 'authenticated teacher gateway grant is missing';
  end if;
end;
$test$;

rollback;
