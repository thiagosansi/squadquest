-- SquadQuest · Milestone 1
-- Run this migration in Supabase SQL Editor or with `supabase db push`.

create extension if not exists "pgcrypto";

do $$
begin
  create type public.game_phase as enum ('waiting', 'identity');
exception when duplicate_object then null;
end $$;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9]{5}$'),
  phase public.game_phase not null default 'waiting',
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  session_id uuid not null default auth.uid(),
  name text not null check (char_length(name) between 2 and 32),
  avatar_id text not null,
  is_host boolean not null default false,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (room_id, session_id)
);

create or replace function public.protect_squadquest_room_identity()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.id <> old.id or new.code <> old.code or new.created_by <> old.created_by or new.created_at <> old.created_at then
    raise exception 'Room identity cannot be changed';
  end if;
  return new;
end;
$$;

drop trigger if exists squadquest_room_identity on public.rooms;
create trigger squadquest_room_identity
  before update on public.rooms
  for each row execute function public.protect_squadquest_room_identity();

create index if not exists players_room_id_idx on public.players(room_id);
create index if not exists players_last_seen_at_idx on public.players(last_seen_at);

create or replace function public.enforce_squadquest_capacity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  player_count integer;
begin
  -- Serialize joins per room so simultaneous last-seat joins cannot exceed capacity.
  perform 1 from public.rooms where id = new.room_id for update;

  if new.is_host then
    if exists (select 1 from public.players where room_id = new.room_id and is_host) then
      raise exception 'This room already has a Game Master';
    end if;
  else
    select count(*) into player_count from public.players where room_id = new.room_id and not is_host;
    if player_count >= 6 then
      raise exception 'This room is full';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists squadquest_capacity on public.players;
create trigger squadquest_capacity
  before insert on public.players
  for each row execute function public.enforce_squadquest_capacity();

create or replace function public.protect_squadquest_player_identity()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.room_id <> old.room_id or new.session_id <> old.session_id or new.is_host <> old.is_host then
    raise exception 'Player room, session, and role cannot be changed';
  end if;
  return new;
end;
$$;

drop trigger if exists squadquest_player_identity on public.players;
create trigger squadquest_player_identity
  before update on public.players
  for each row execute function public.protect_squadquest_player_identity();

create or replace function public.is_squadquest_room_member(target_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.players
    where room_id = target_room_id and session_id = auth.uid()
  );
$$;

grant execute on function public.is_squadquest_room_member(uuid) to authenticated;

alter table public.rooms enable row level security;
alter table public.players enable row level security;

drop policy if exists "rooms are readable by everyone" on public.rooms;
create policy "rooms are readable by everyone"
  on public.rooms for select using (true);

drop policy if exists "authenticated sessions create rooms" on public.rooms;
create policy "authenticated sessions create rooms"
  on public.rooms for insert to authenticated
  with check (created_by = auth.uid());

drop policy if exists "the host advances the room" on public.rooms;
create policy "the host advances the room"
  on public.rooms for update to authenticated
  using (exists (select 1 from public.players where room_id = rooms.id and session_id = auth.uid() and is_host))
  with check (phase in ('waiting', 'identity'));

drop policy if exists "players are readable by everyone" on public.players;
drop policy if exists "room members can see their roster" on public.players;
create policy "room members can see their roster"
  on public.players for select to authenticated
  using (public.is_squadquest_room_member(room_id));

drop policy if exists "sessions join as themselves" on public.players;
create policy "sessions join as themselves"
  on public.players for insert to authenticated
  with check (
    session_id = auth.uid()
    and (
      (is_host and exists (select 1 from public.rooms where id = room_id and created_by = auth.uid()))
      or not is_host
    )
  );

drop policy if exists "sessions update themselves" on public.players;
create policy "sessions update themselves"
  on public.players for update to authenticated
  using (session_id = auth.uid())
  with check (session_id = auth.uid());

drop policy if exists "sessions leave themselves" on public.players;
create policy "sessions leave themselves"
  on public.players for delete to authenticated
  using (session_id = auth.uid());

-- Required for the browser subscriptions in SquadQuestApp.
do $$
begin
  alter publication supabase_realtime add table public.rooms;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.players;
exception when duplicate_object then null;
end $$;
