-- SquadQuest · bigger decks with no repeats between teams, and the visionary
-- power moves to Build.
--
-- draw_squadquest_teams (0007 body): the persona, problem and restriction decks
--   grow from 7 to 12 cards each. Each deck is shuffled once per draw and team 1
--   takes the first card, team 2 the second, so the two teams never share a
--   persona, a problem or a restriction. Roles, balance and phase change are
--   unchanged.
-- release_squadquest_chaos (0007 body): the chaos deck grows from 5 to 12
--   cards. The deck is shuffled once per launch; when the Game Master launches
--   for both teams, each building team takes a different card (ordered by
--   team_number); when a single team is targeted it takes the top card. Host
--   check, timing rule (4 minutes into Build), messages and chaos_released_at
--   are unchanged.
-- use_squadquest_role_power (0010 body): the visionary ("Leve a ideia dez vezes
--   mais longe") is now valid in Build and Adapt, with no waiting time, instead
--   of Diverge after the two silent minutes. devils_advocate and customer_voice
--   are unchanged, as is the power challenge that opens after the power is used.
-- step_started stays declared in use_squadquest_role_power: it is still filled
--   by the select, only the visionary branch stopped reading it.

create or replace function squadquest.draw_squadquest_teams(target_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare
  actor_id uuid;
  player_count integer;
  team_ids uuid[];
  team_names text[] := array['Orbit', 'Nova'];
  personas text[] := array['Astronauta', 'Avó de 80 anos', 'Influenciador com medo de câmera', 'Cachorro', 'CEO paranoico', 'Criança de 8 anos', 'Robô recém-chegado à Terra', 'Motorista de app que odeia trânsito', 'Professora de escola pública', 'Turista que não fala português', 'Atleta olímpico aposentado', 'Fantasma que mora num prédio comercial'];
  problems text[] := array['não consegue acordar cedo', 'gasta dinheiro demais', 'sempre chega atrasado', 'tem reuniões demais', 'não consegue decidir o que comer', 'esquece aniversários', 'vive perdendo objetos', 'não consegue dormir', 'não sabe dizer não', 'tem medo de falar em público', 'perde todos os prazos', 'nunca faz exercício'];
  restrictions text[] := array['não pode usar telas', 'precisa funcionar no espaço', 'só pode custar R$10', 'precisa usar IA', 'tem que funcionar por WhatsApp', 'precisa gerar receita no primeiro dia', 'tem que funcionar sem internet', 'tem que caber no bolso', 'precisa funcionar debaixo d’água', 'não pode usar palavras', 'tem que ser 100% gratuito', 'precisa resolver em 30 segundos'];
  personas_shuffled text[];
  problems_shuffled text[];
  restrictions_shuffled text[];
begin
  select p.id into actor_id from squadquest.players p
  where p.room_id = target_room_id and p.session_id = auth.uid() and p.is_host;
  if actor_id is null then raise exception 'Only this room’s Game Master can draw the teams'; end if;
  perform 1 from squadquest.rooms where id = target_room_id and phase = 'identity' and identity_step = 'complete' for update;
  if not found then raise exception 'Finish Who Is? before drawing the teams'; end if;
  select count(*) into player_count from squadquest.players where room_id = target_room_id and not is_host;
  if player_count < 4 then raise exception 'At least four players are needed to make two playable teams'; end if;
  if exists (select 1 from squadquest.gameplay_teams where room_id = target_room_id) then
    raise exception 'Teams have already been drawn';
  end if;

  select array_agg(x order by random()) into personas_shuffled from unnest(personas) x;
  select array_agg(x order by random()) into problems_shuffled from unnest(problems) x;
  select array_agg(x order by random()) into restrictions_shuffled from unnest(restrictions) x;

  insert into squadquest.gameplay_teams(room_id, name, team_number, persona, problem, restriction)
  values
    (target_room_id, team_names[1], 1, personas_shuffled[1], problems_shuffled[1], restrictions_shuffled[1]),
    (target_room_id, team_names[2], 2, personas_shuffled[2], problems_shuffled[2], restrictions_shuffled[2]);

  select array_agg(id order by team_number) into team_ids
  from squadquest.gameplay_teams where room_id = target_room_id;

  with shuffled as (
    select p.id as player_id,
      row_number() over (order by random()) as rn
    from squadquest.players p where p.room_id = target_room_id and not p.is_host
  ), balanced as (
    select player_id,
      case when rn <= ceil(player_count::numeric / 2) then team_ids[1] else team_ids[2] end as team_id,
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

create or replace function squadquest.release_squadquest_chaos(target_room_id uuid, target_team_id uuid default null)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare cards_shuffled jsonb[]; target_count integer;
  cards jsonb[] := array[
    '{"title":"Budget Cut","text":"O produto só pode custar R$5 por usuário."}'::jsonb,
    '{"title":"Modo offline","text":"A internet deixou de existir. Como a solução continua funcionando?"}'::jsonb,
    '{"title":"Plot twist","text":"A persona agora tem mais de 70 anos."}'::jsonb,
    '{"title":"Monetização","text":"Um investidor apareceu. Como isso gera receita desde o primeiro dia?"}'::jsonb,
    '{"title":"Concorrente","text":"Um concorrente lançou exatamente a mesma solução."}'::jsonb,
    '{"title":"Viralizou","text":"Dez mil pessoas começaram a usar hoje. O que quebra primeiro e como vocês seguram?"}'::jsonb,
    '{"title":"Regulação","text":"Uma lei nova proibiu a parte central da solução. O que sobra e como reinventar?"}'::jsonb,
    '{"title":"Pivô de público","text":"O produto agora é para crianças de 6 anos. O que muda?"}'::jsonb,
    '{"title":"Reclamação pública","text":"Um cliente famoso detonou o produto nas redes. Como respondem sem perder a essência?"}'::jsonb,
    '{"title":"Só por voz","text":"A solução não pode ter tela nem texto. Tudo acontece por voz."}'::jsonb,
    '{"title":"Sem energia","text":"Só funciona com bateria e a bateria dura uma hora por dia."}'::jsonb,
    '{"title":"Prazo impossível","text":"Precisa lançar amanhã com metade do time. O que corta e o que fica?"}'::jsonb
  ];
begin
  if not exists (select 1 from squadquest.players where room_id = target_room_id and session_id = auth.uid() and is_host) then
    raise exception 'Only this room’s Game Master can launch chaos';
  end if;
  perform 1 from squadquest.rooms where id = target_room_id and phase = 'mission' and chaos_released_at is null for update;
  if not found then raise exception 'Chaos has already been launched or the mission is not active'; end if;
  if exists (
    select 1 from squadquest.gameplay_teams t
    where t.room_id=target_room_id and t.mission_step='build'
      and (target_team_id is null or t.id=target_team_id)
      and now() < t.step_started_at + interval '4 minutes'
  ) then raise exception 'The chaos card unlocks when about eight minutes remain in Build'; end if;
  select array_agg(c order by random()) into cards_shuffled from unnest(cards) c;
  if target_team_id is null then
    with ranked as (
      select id, row_number() over (order by team_number) rn
      from squadquest.gameplay_teams where room_id = target_room_id and mission_step = 'build'
    )
    update squadquest.gameplay_teams t set chaos = cards_shuffled[ranked.rn], mission_step = 'adapt', step_started_at = now()
    from ranked where t.id = ranked.id;
  else
    update squadquest.gameplay_teams set chaos = cards_shuffled[1], mission_step = 'adapt', step_started_at = now()
    where room_id = target_room_id and mission_step = 'build' and id = target_team_id;
  end if;
  get diagnostics target_count = row_count;
  if target_count = 0 then raise exception 'Choose one or more teams currently building'; end if;
  update squadquest.rooms set chaos_released_at = now(), state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

create or replace function squadquest.use_squadquest_role_power(target_room_id uuid, action_text text)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare actor_player_id uuid; actor_team_id uuid; actor_role text; current_step text; step_started timestamptz; solution_data jsonb;
  power_action_id uuid;
begin
  select p.id, a.team_id, a.role_key, t.mission_step, t.step_started_at, t.solution
  into actor_player_id, actor_team_id, actor_role, current_step, step_started, solution_data
  from squadquest.players p join squadquest.gameplay_assignments a on a.player_id = p.id
  join squadquest.gameplay_teams t on t.id = a.team_id join squadquest.rooms r on r.id = p.room_id
  where p.room_id = target_room_id and p.session_id = auth.uid() and not p.is_host and r.phase = 'mission' and not a.role_used;
  if actor_player_id is null then raise exception 'Your power is unavailable or already used'; end if;
  if char_length(btrim(action_text)) not between 8 and 400 then raise exception 'Add a short explanation to use your power'; end if;
  if actor_role = 'visionary' then
    if current_step not in ('build','adapt') then
      raise exception 'Leve a ideia dez vezes mais longe só vale em Construir, com a ideia escolhida';
    end if;
  elsif actor_role = 'devils_advocate' then
    if current_step <> 'decide' then
      raise exception 'E se estivermos errados? só vale em Decidir';
    end if;
  elsif actor_role = 'customer_voice' then
    if current_step not in ('build','adapt') or coalesce(solution_data->>'value','') = '' then
      raise exception 'Eu não compraria só vale em Construir, depois de escrever a proposta de valor';
    end if;
  else
    raise exception 'This power can be used later in the mission';
  end if;
  if exists (
    select 1 from squadquest.gameplay_power_challenges c
    where c.team_id = actor_team_id and c.status = 'open' and now() <= c.deadline_at
  ) then raise exception 'Wait for the current power challenge to finish'; end if;
  insert into squadquest.gameplay_power_actions(room_id, team_id, player_id, content)
  values (target_room_id, actor_team_id, actor_player_id, btrim(action_text))
  returning id into power_action_id;
  insert into squadquest.gameplay_power_challenges(room_id, team_id, power_action_id, holder_player_id, role_key, prompt, deadline_at)
  values (target_room_id, actor_team_id, power_action_id, actor_player_id, actor_role, btrim(action_text), now() + interval '90 seconds');
  update squadquest.gameplay_assignments set role_used = true where player_id = actor_player_id;
  update squadquest.rooms set state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

-- Same privileges as 0007/0010: create or replace keeps existing grants, but they are
-- restated so this migration is self-contained.
revoke all on function squadquest.draw_squadquest_teams(uuid) from public, anon;
revoke all on function squadquest.release_squadquest_chaos(uuid,uuid) from public, anon;
revoke all on function squadquest.use_squadquest_role_power(uuid,text) from public, anon;

grant execute on function squadquest.draw_squadquest_teams(uuid) to authenticated;
grant execute on function squadquest.release_squadquest_chaos(uuid,uuid) to authenticated;
grant execute on function squadquest.use_squadquest_role_power(uuid,text) to authenticated;
