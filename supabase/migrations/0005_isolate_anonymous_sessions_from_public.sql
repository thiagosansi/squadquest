-- SquadQuest anonymous-auth isolation for the shared Lista Compras project.
-- Anonymous Supabase Auth users use the `authenticated` Postgres role. Keep
-- them inside the dedicated SquadQuest schema without changing access for
-- ordinary authenticated users or unauthenticated (`anon`) clients.

-- Add an AND-only guard to every existing public table that already uses RLS.
-- This covers the Lista Compras tables (including its Realtime tables) while
-- preserving the existing permissive policies for non-anonymous users.
do $$
declare
  target record;
begin
  for target in
    select n.nspname as schema_name, c.relname as table_name
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
      and c.relrowsecurity
  loop
    execute pg_catalog.format(
      'drop policy if exists squadquest_restrict_anonymous_sessions on %I.%I',
      target.schema_name,
      target.table_name
    );
    execute pg_catalog.format(
      'create policy squadquest_restrict_anonymous_sessions on %I.%I as restrictive for all to authenticated using ((select auth.jwt() ->> ''is_anonymous'') is distinct from ''true'') with check ((select auth.jwt() ->> ''is_anonymous'') is distinct from ''true'')',
      target.schema_name,
      target.table_name
    );
  end loop;
end;
$$;

-- RLS cannot protect SECURITY DEFINER functions, views, or tables without RLS.
-- Reject anonymous PostgREST requests outside the SquadQuest API schema. The
-- hook is Data API-only; RLS policies above also protect Realtime subscriptions.
create or replace function public.squadquest_guard_anonymous_schema()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_claims jsonb;
  request_headers jsonb;
  request_method text;
  requested_schema text;
begin
  request_claims := coalesce(
    nullif(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb
  );

  if request_claims ->> 'is_anonymous' is distinct from 'true' then
    return;
  end if;

  request_headers := coalesce(
    nullif(pg_catalog.current_setting('request.headers', true), '')::jsonb,
    '{}'::jsonb
  );
  request_method := pg_catalog.upper(
    coalesce(nullif(pg_catalog.current_setting('request.method', true), ''), '')
  );

  if request_method in ('GET', 'HEAD') then
    requested_schema := pg_catalog.lower(
      coalesce(nullif(request_headers ->> 'accept-profile', ''), 'public')
    );
  else
    requested_schema := pg_catalog.lower(
      coalesce(nullif(request_headers ->> 'content-profile', ''), 'public')
    );
  end if;

  if requested_schema <> 'squadquest' then
    raise insufficient_privilege using
      message = 'Anonymous sessions are restricted to the SquadQuest API schema';
  end if;
end;
$$;

revoke all on function public.squadquest_guard_anonymous_schema() from public, anon;
grant execute on function public.squadquest_guard_anonymous_schema() to authenticated;

alter role authenticator
  set pgrst.db_pre_request = 'public.squadquest_guard_anonymous_schema';

notify pgrst, 'reload config';
