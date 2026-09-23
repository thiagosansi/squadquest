-- Move the SquadQuest objects from public into their own Postgres schema.
-- Existing room/player rows and dependencies are preserved.

create schema if not exists squadquest;

do $$
begin
  if to_regtype('public.game_phase') is not null
     and to_regtype('squadquest.game_phase') is null then
    alter type public.game_phase set schema squadquest;
  end if;

  if to_regclass('public.rooms') is not null
     and to_regclass('squadquest.rooms') is null then
    alter table public.rooms set schema squadquest;
  end if;

  if to_regclass('public.players') is not null
     and to_regclass('squadquest.players') is null then
    alter table public.players set schema squadquest;
  end if;

  if to_regprocedure('public.protect_squadquest_room_identity()') is not null
     and to_regprocedure('squadquest.protect_squadquest_room_identity()') is null then
    alter function public.protect_squadquest_room_identity() set schema squadquest;
  end if;

  if to_regprocedure('public.enforce_squadquest_capacity()') is not null
     and to_regprocedure('squadquest.enforce_squadquest_capacity()') is null then
    alter function public.enforce_squadquest_capacity() set schema squadquest;
  end if;

  if to_regprocedure('public.protect_squadquest_player_identity()') is not null
     and to_regprocedure('squadquest.protect_squadquest_player_identity()') is null then
    alter function public.protect_squadquest_player_identity() set schema squadquest;
  end if;

  if to_regprocedure('public.is_squadquest_room_member(uuid)') is not null
     and to_regprocedure('squadquest.is_squadquest_room_member(uuid)') is null then
    alter function public.is_squadquest_room_member(uuid) set schema squadquest;
  end if;
end $$;

create or replace function squadquest.protect_squadquest_room_identity()
returns trigger
language plpgsql
set search_path = pg_catalog, squadquest
as $$
begin
  if new.id <> old.id or new.code <> old.code or new.created_by <> old.created_by or new.created_at <> old.created_at then
    raise exception 'Room identity cannot be changed';
  end if;
  return new;
end;
$$;

create or replace function squadquest.enforce_squadquest_capacity()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  player_count integer;
begin
  -- Serialize joins per room so simultaneous last-seat joins cannot exceed capacity.
  perform 1 from squadquest.rooms where id = new.room_id for update;

  if new.is_host then
    if exists (select 1 from squadquest.players where room_id = new.room_id and is_host) then
      raise exception 'This room already has a Game Master';
    end if;
  else
    select count(*) into player_count from squadquest.players where room_id = new.room_id and not is_host;
    if player_count >= 6 then
      raise exception 'This room is full';
    end if;
  end if;
  return new;
end;
$$;

create or replace function squadquest.protect_squadquest_player_identity()
returns trigger
language plpgsql
set search_path = pg_catalog, squadquest
as $$
begin
  if new.room_id <> old.room_id or new.session_id <> old.session_id or new.is_host <> old.is_host then
    raise exception 'Player room, session, and role cannot be changed';
  end if;
  return new;
end;
$$;

create or replace function squadquest.is_squadquest_room_member(target_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, squadquest
as $$
  select exists (
    select 1 from squadquest.players
    where room_id = target_room_id and session_id = auth.uid()
  );
$$;

drop trigger if exists squadquest_room_identity on squadquest.rooms;
create trigger squadquest_room_identity
  before update on squadquest.rooms
  for each row execute function squadquest.protect_squadquest_room_identity();

drop trigger if exists squadquest_capacity on squadquest.players;
create trigger squadquest_capacity
  before insert on squadquest.players
  for each row execute function squadquest.enforce_squadquest_capacity();

drop trigger if exists squadquest_player_identity on squadquest.players;
create trigger squadquest_player_identity
  before update on squadquest.players
  for each row execute function squadquest.protect_squadquest_player_identity();

create index if not exists players_room_id_idx on squadquest.players(room_id);
create index if not exists players_last_seen_at_idx on squadquest.players(last_seen_at);

alter table squadquest.rooms enable row level security;
alter table squadquest.players enable row level security;

drop policy if exists "rooms are readable by everyone" on squadquest.rooms;
create policy "rooms are readable by everyone"
  on squadquest.rooms for select to authenticated using (true);

drop policy if exists "authenticated sessions create rooms" on squadquest.rooms;
create policy "authenticated sessions create rooms"
  on squadquest.rooms for insert to authenticated
  with check (created_by = auth.uid());

drop policy if exists "the host advances the room" on squadquest.rooms;
create policy "the host advances the room"
  on squadquest.rooms for update to authenticated
  using (exists (
    select 1 from squadquest.players
    where room_id = rooms.id and session_id = auth.uid() and is_host
  ))
  with check (phase in ('waiting', 'identity'));

drop policy if exists "players are readable by everyone" on squadquest.players;
drop policy if exists "room members can see their roster" on squadquest.players;
create policy "room members can see their roster"
  on squadquest.players for select to authenticated
  using (squadquest.is_squadquest_room_member(room_id));

drop policy if exists "sessions join as themselves" on squadquest.players;
create policy "sessions join as themselves"
  on squadquest.players for insert to authenticated
  with check (
    session_id = auth.uid()
    and (
      (is_host and exists (
        select 1 from squadquest.rooms where id = room_id and created_by = auth.uid()
      ))
      or not is_host
    )
  );

drop policy if exists "sessions update themselves" on squadquest.players;
create policy "sessions update themselves"
  on squadquest.players for update to authenticated
  using (session_id = auth.uid())
  with check (session_id = auth.uid());

drop policy if exists "sessions leave themselves" on squadquest.players;
create policy "sessions leave themselves"
  on squadquest.players for delete to authenticated
  using (session_id = auth.uid());

revoke all on function squadquest.protect_squadquest_room_identity() from public, anon, authenticated;
revoke all on function squadquest.enforce_squadquest_capacity() from public, anon, authenticated;
revoke all on function squadquest.protect_squadquest_player_identity() from public, anon, authenticated;
revoke all on function squadquest.is_squadquest_room_member(uuid) from public, anon;
grant execute on function squadquest.is_squadquest_room_member(uuid) to authenticated, service_role;

grant usage on schema squadquest to authenticated, service_role;
grant select, insert, update on squadquest.rooms to authenticated;
grant select, insert, update, delete on squadquest.players to authenticated;
grant all on all tables in schema squadquest to service_role;
grant execute on all routines in schema squadquest to service_role;

alter default privileges for role postgres in schema squadquest
  grant select, insert, update, delete on tables to authenticated;
alter default privileges for role postgres in schema squadquest
  grant execute on routines to authenticated;
alter default privileges for role postgres in schema squadquest
  grant all on tables to service_role;
alter default privileges for role postgres in schema squadquest
  grant execute on routines to service_role;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'squadquest' and tablename = 'rooms'
  ) then
    alter publication supabase_realtime add table squadquest.rooms;
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'squadquest' and tablename = 'players'
  ) then
    alter publication supabase_realtime add table squadquest.players;
  end if;
end $$;
