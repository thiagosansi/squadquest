-- SquadQuest · chaos waits for the open power challenge.
--
-- release_squadquest_chaos (0012 body), one check added and nothing else:
--   after the host check, the single-launch check and the 4-minute rule, the
--   launch is refused while any targeted team (every building team when
--   target_team_id is null, only that team otherwise) has a power challenge
--   with status 'open' whose deadline_at has not passed. The Game Master sees
--   the reason and the challenge clock in the panel and launches once the
--   challenge is approved or its deadline passes. Deck, shuffle, per-team
--   cards, chaos_released_at, state_version and every other message are
--   unchanged.

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
  if exists (
    select 1 from squadquest.gameplay_power_challenges c
    join squadquest.gameplay_teams t on t.id = c.team_id
    where t.room_id = target_room_id and t.mission_step = 'build'
      and (target_team_id is null or t.id = target_team_id)
      and c.status = 'open' and now() <= c.deadline_at
  ) then raise exception 'Wait for the open power challenge before launching chaos'; end if;
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

-- Same privileges as 0007/0012: create or replace keeps existing grants, but they are
-- restated so this migration is self-contained.
revoke all on function squadquest.release_squadquest_chaos(uuid,uuid) from public, anon;
grant execute on function squadquest.release_squadquest_chaos(uuid,uuid) to authenticated;
