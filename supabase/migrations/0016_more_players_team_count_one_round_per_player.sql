-- SquadQuest · rooms take up to 24 players, the Game Master chooses how many
-- teams to draw, and Who Is? runs one round per player.
--
-- enforce_squadquest_capacity (0002 body): the non-host cap goes from 6 to 24.
--   The trigger squadquest_capacity keeps pointing at this function, so it is
--   not recreated. Host uniqueness and the per-room lock are unchanged.
-- draw_squadquest_teams (0012 body): gains team_count (default 2; the old
--   one-argument signature is dropped so PostgREST does not see two overloads).
--   Checks, in order: host, Who Is? complete, at least four players (same
--   message), team_count between 2 and least(12, floor(players / 2)), teams
--   not yet drawn. Creates team_count teams named from a list of 12, each
--   taking a distinct persona, problem and restriction from the 12-card decks.
--   Players are shuffled and dealt round-robin (sizes differ by at most one);
--   roles still cycle devils_advocate / visionary / customer_voice per team.
-- gameplay_teams.team_number: the check (in (1, 2)) from 0007 becomes
--   between 1 and 12, named gameplay_teams_team_number_check.
-- identity_rounds.round_number: the check (between 1 and 3) becomes
--   round_number >= 1, named identity_rounds_round_number_check. The unique
--   (room_id, author_player_id) already guarantees one round per author.
-- start_squadquest_identity_round (0004 body): the next_round > 3 early exit
--   is removed; the round ends when no author without a drawn story is left
--   (that branch already existed).
-- reveal_squadquest_identity_round (0004 body): the step becomes 'complete'
--   only when every submitted author already has a round; otherwise 'reveal'.
-- finish_squadquest_identity (new): the host closes Who Is? early once at
--   least three stories have been revealed; bumps state_version.
-- get_squadquest_identity_state (0004 body): adds authors_remaining
--   (submissions without a round) and rounds_revealed (rounds with
--   revealed_at), snake_case like the existing keys.

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
    if player_count >= 24 then
      raise exception 'This room is full';
    end if;
  end if;
  return new;
end;
$$;

drop function if exists squadquest.draw_squadquest_teams(uuid);

create or replace function squadquest.draw_squadquest_teams(target_room_id uuid, team_count integer default 2)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  actor_id uuid;
  player_count integer;
  team_ids uuid[];
  team_names text[] := array['Orbit', 'Nova', 'Pulsar', 'Quasar', 'Cometa', 'Aurora', 'Nebulosa', 'Eclipse', 'Meteoro', 'Zênite', 'Órion', 'Vega'];
  personas text[] := array['Astronauta', 'Avó de 80 anos', 'Influenciador com medo de câmera', 'Cachorro', 'CEO paranoico', 'Criança de 8 anos', 'Robô recém-chegado à Terra', 'Motorista de app que odeia trânsito', 'Professora de escola pública', 'Turista que não fala português', 'Atleta olímpico aposentado', 'Fantasma que mora num prédio comercial'];
  problems text[] := array['não consegue acordar cedo', 'gasta dinheiro demais', 'sempre chega atrasado', 'tem reuniões demais', 'não consegue decidir o que comer', 'esquece aniversários', 'vive perdendo objetos', 'não consegue dormir', 'não sabe dizer não', 'tem medo de falar em público', 'perde todos os prazos', 'nunca faz exercício'];
  restrictions text[] := array['não pode usar telas', 'precisa funcionar no espaço', 'só pode custar R$10', 'precisa usar IA', 'tem que funcionar por WhatsApp', 'precisa gerar receita no primeiro dia', 'tem que funcionar sem internet', 'tem que caber no bolso', 'precisa funcionar debaixo d’água', 'não pode usar palavras', 'tem que ser 100% gratuito', 'precisa resolver em 30 segundos'];
  personas_shuffled text[];
  problems_shuffled text[];
  restrictions_shuffled text[];
  i integer;
begin
  select p.id into actor_id from squadquest.players p
  where p.room_id = target_room_id and p.session_id = auth.uid() and p.is_host;
  if actor_id is null then raise exception 'Only this room’s Game Master can draw the teams'; end if;
  perform 1 from squadquest.rooms where id = target_room_id and phase = 'identity' and identity_step = 'complete' for update;
  if not found then raise exception 'Finish Who Is? before drawing the teams'; end if;
  select count(*) into player_count from squadquest.players where room_id = target_room_id and not is_host;
  if player_count < 4 then raise exception 'At least four players are needed to make two playable teams'; end if;
  if team_count < 2 or team_count > least(12, floor(player_count / 2)) then
    raise exception 'Choose between 2 and % teams', least(12, floor(player_count / 2));
  end if;
  if exists (select 1 from squadquest.gameplay_teams where room_id = target_room_id) then
    raise exception 'Teams have already been drawn';
  end if;

  select array_agg(x order by random()) into personas_shuffled from unnest(personas) x;
  select array_agg(x order by random()) into problems_shuffled from unnest(problems) x;
  select array_agg(x order by random()) into restrictions_shuffled from unnest(restrictions) x;

  for i in 1..team_count loop
    insert into squadquest.gameplay_teams(room_id, name, team_number, persona, problem, restriction)
    values (target_room_id, team_names[i], i, personas_shuffled[i], problems_shuffled[i], restrictions_shuffled[i]);
  end loop;

  select array_agg(id order by team_number) into team_ids
  from squadquest.gameplay_teams where room_id = target_room_id;

  with shuffled as (
    select p.id as player_id,
      row_number() over (order by random()) as rn
    from squadquest.players p where p.room_id = target_room_id and not p.is_host
  ), balanced as (
    select player_id,
      team_ids[((rn - 1) % team_count) + 1] as team_id,
      rn
    from shuffled
  ), with_roles as (
    select player_id, team_id,
      row_number() over (partition by team_id order by random()) as role_number
    from balanced
  )
  insert into squadquest.gameplay_assignments(room_id, player_id, team_id, role_key)
  select target_room_id, player_id, team_id,
    case ((role_number - 1)::int % 3)
      when 0 then 'devils_advocate'
      when 1 then 'visionary'
      else 'customer_voice'
    end
  from with_roles;

  update squadquest.rooms set phase = 'teams', phase_started_at = now(), state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

-- Postgres named the inline check identity_rounds_round_number_check; drop
-- whatever check mentions round_number, by its real name, then add ours.
do $$
declare
  cname text;
begin
  for cname in
    select conname from pg_constraint
    where conrelid = 'squadquest.identity_rounds'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) like '%round_number%'
  loop
    execute format('alter table squadquest.identity_rounds drop constraint %I', cname);
  end loop;
end
$$;
alter table squadquest.identity_rounds
  add constraint identity_rounds_round_number_check check (round_number >= 1);

-- gameplay_teams.team_number was check (team_number in (1, 2)) since 0007
-- (named gameplay_teams_team_number_check by Postgres); same drop-by-name, then
-- allow up to the 12 names/cards available.
do $$
declare
  cname text;
begin
  for cname in
    select conname from pg_constraint
    where conrelid = 'squadquest.gameplay_teams'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) like '%team_number%'
  loop
    execute format('alter table squadquest.gameplay_teams drop constraint %I', cname);
  end loop;
end
$$;
alter table squadquest.gameplay_teams
  add constraint gameplay_teams_team_number_check check (team_number between 1 and 12);

create or replace function squadquest.start_squadquest_identity_round(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  next_round smallint;
  current_step text;
  participant_count integer;
  submission_count integer;
  selected_author uuid;
  selected_prompt text;
  selected_answer text;
begin
  if not exists (
    select 1 from squadquest.players
    where room_id = target_room_id and session_id = auth.uid() and is_host
  ) then
    raise exception 'Only this room’s Game Master can draw a story';
  end if;

  select identity_step into current_step
  from squadquest.rooms where id = target_room_id and phase = 'identity' for update;
  if not found then raise exception 'The activity is not in progress'; end if;

  select count(*) into participant_count
  from squadquest.players where room_id = target_room_id and not is_host;
  select count(*) into submission_count
  from squadquest.identity_submissions where room_id = target_room_id;
  if participant_count < 2 or submission_count <> participant_count then
    raise exception 'Wait until at least two players have submitted their answers';
  end if;

  select coalesce(max(round_number), 0) + 1 into next_round
  from squadquest.identity_rounds where room_id = target_room_id;
  if next_round > 1 and current_step <> 'reveal' then
    raise exception 'Reveal the current story before drawing another';
  end if;
  if next_round = 1 and current_step <> 'collecting' then
    raise exception 'The first story can only be drawn after answers are collected';
  end if;

  select candidate.player_id, candidate.prompt_key, candidate.answer_text
    into selected_author, selected_prompt, selected_answer
  from (
    select s.player_id, prompts.prompt_key, prompts.answer_text
    from squadquest.identity_submissions s
    cross join lateral (values
      ('hidden_story'::text, s.hidden_story),
      ('dream'::text, s.dream),
      ('unexpected_story'::text, s.unexpected_story)
    ) as prompts(prompt_key, answer_text)
    where s.room_id = target_room_id
      and not exists (
        select 1 from squadquest.identity_rounds used
        where used.room_id = target_room_id and used.author_player_id = s.player_id
      )
    order by random()
    limit 1
  ) candidate;

  if selected_author is null then
    update squadquest.rooms set identity_step = 'complete' where id = target_room_id;
    return true;
  end if;

  insert into squadquest.identity_rounds
    (room_id, round_number, prompt_key, answer_text, author_player_id)
  values (target_room_id, next_round, selected_prompt, selected_answer, selected_author);

  update squadquest.rooms set identity_step = 'voting' where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.reveal_squadquest_identity_round(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  active_round_id uuid;
  active_round_number smallint;
begin
  if not exists (
    select 1 from squadquest.players
    where room_id = target_room_id and session_id = auth.uid() and is_host
  ) then raise exception 'Only this room’s Game Master can reveal the story'; end if;

  select ir.id, ir.round_number into active_round_id, active_round_number
  from squadquest.identity_rounds ir
  join squadquest.rooms r on r.id = ir.room_id
  where ir.room_id = target_room_id and r.phase = 'identity' and r.identity_step = 'voting'
  order by ir.round_number desc limit 1;
  if active_round_id is null then raise exception 'There is no active story to reveal'; end if;

  update squadquest.identity_rounds set revealed_at = now() where id = active_round_id;
  update squadquest.rooms
  set identity_step = case when not exists (
    select 1 from squadquest.identity_submissions s
    where s.room_id = target_room_id
      and not exists (
        select 1 from squadquest.identity_rounds ir2
        where ir2.room_id = target_room_id and ir2.author_player_id = s.player_id
      )
  ) then 'complete' else 'reveal' end
  where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.finish_squadquest_identity(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  revealed_count integer;
begin
  if not exists (
    select 1 from squadquest.players
    where room_id = target_room_id and session_id = auth.uid() and is_host
  ) then raise exception 'Only this room’s Game Master can finish Who Is?'; end if;

  perform 1 from squadquest.rooms
  where id = target_room_id and phase = 'identity' and identity_step in ('reveal', 'voting', 'collecting')
  for update;
  if not found then raise exception 'The activity is not in progress'; end if;

  select count(*) into revealed_count
  from squadquest.identity_rounds where room_id = target_room_id and revealed_at is not null;
  if revealed_count < 3 then raise exception 'Reveal at least three stories before finishing'; end if;

  update squadquest.rooms
  set identity_step = 'complete', state_version = state_version + 1
  where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.get_squadquest_identity_state(target_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  actor_player_id uuid;
  actor_is_host boolean;
  current_step text;
  current_round jsonb;
  participants jsonb;
  submitted_count integer;
  participant_count integer;
  has_submitted boolean;
  has_voted boolean;
  authors_remaining integer;
  rounds_revealed integer;
begin
  select id, is_host into actor_player_id, actor_is_host
  from squadquest.players
  where room_id = target_room_id and session_id = auth.uid();
  if actor_player_id is null then raise exception 'You are not a member of this room'; end if;

  select identity_step into current_step
  from squadquest.rooms where id = target_room_id and phase = 'identity';
  if current_step is null then raise exception 'The activity has not started'; end if;

  select count(*) into participant_count
  from squadquest.players where room_id = target_room_id and not is_host;
  select count(*) into submitted_count
  from squadquest.identity_submissions where room_id = target_room_id;
  select count(*) into authors_remaining
  from squadquest.identity_submissions s
  where s.room_id = target_room_id and not exists (
    select 1 from squadquest.identity_rounds ir
    where ir.room_id = target_room_id and ir.author_player_id = s.player_id
  );
  select count(*) into rounds_revealed
  from squadquest.identity_rounds where room_id = target_room_id and revealed_at is not null;
  select exists (
    select 1 from squadquest.identity_submissions where room_id = target_room_id and player_id = actor_player_id
  ) into has_submitted;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id, 'name', p.name, 'avatar_id', p.avatar_id
  ) order by p.created_at), '[]'::jsonb) into participants
  from squadquest.players p where p.room_id = target_room_id and not p.is_host;

  select exists (
    select 1 from squadquest.identity_votes v
    join squadquest.identity_rounds ir on ir.id = v.round_id
    where ir.room_id = target_room_id and ir.round_number = (
      select max(round_number) from squadquest.identity_rounds where room_id = target_room_id
    ) and v.voter_player_id = actor_player_id
  ) into has_voted;

  select jsonb_build_object(
    'number', ir.round_number,
    'prompt_key', ir.prompt_key,
    'answer', ir.answer_text,
    'votes_count', (select count(*) from squadquest.identity_votes v where v.round_id = ir.id),
    'has_voted', has_voted,
    'author', case when current_step in ('reveal', 'complete') then (
      select jsonb_build_object('id', p.id, 'name', p.name, 'avatar_id', p.avatar_id)
      from squadquest.players p where p.id = ir.author_player_id
    ) else null end
  ) into current_round
  from squadquest.identity_rounds ir
  where ir.room_id = target_room_id
  order by ir.round_number desc limit 1;

  return jsonb_build_object(
    'step', current_step,
    'is_host', actor_is_host,
    'self_submitted', has_submitted,
    'submitted_count', submitted_count,
    'participant_count', participant_count,
    'authors_remaining', authors_remaining,
    'rounds_revealed', rounds_revealed,
    'players', participants,
    'current_round', current_round
  );
end;
$$;

-- Same privileges as 0004/0012: create or replace keeps existing grants, but they are
-- repeated so the file is self-contained, and the new signatures get theirs.
revoke all on function squadquest.enforce_squadquest_capacity() from public, anon, authenticated;
revoke all on function squadquest.draw_squadquest_teams(uuid, integer) from public, anon;
revoke all on function squadquest.start_squadquest_identity_round(uuid) from public, anon;
revoke all on function squadquest.reveal_squadquest_identity_round(uuid) from public, anon;
revoke all on function squadquest.finish_squadquest_identity(uuid) from public, anon;
revoke all on function squadquest.get_squadquest_identity_state(uuid) from public, anon;

grant execute on function squadquest.draw_squadquest_teams(uuid, integer) to authenticated;
grant execute on function squadquest.start_squadquest_identity_round(uuid) to authenticated;
grant execute on function squadquest.reveal_squadquest_identity_round(uuid) to authenticated;
grant execute on function squadquest.finish_squadquest_identity(uuid) to authenticated;
grant execute on function squadquest.get_squadquest_identity_state(uuid) to authenticated;
