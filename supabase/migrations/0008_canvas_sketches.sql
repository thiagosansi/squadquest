-- SquadQuest · storyboard sketches on the shared canvas.
-- Each of the three storyboard steps may carry a hand-drawn sketch stored as an
-- SVG path (viewBox 0 0 600 400, integer coordinates, only M and L commands,
-- e.g. "M12 34 L56 78 M100 100 L120 130"). The function below is the same as
-- in 0007, plus a 'sketches' key: always an array of exactly three strings, each
-- kept only when it matches ^[ML0-9 ]*$ and has at most 60000 characters,
-- otherwise replaced by '' without failing the save. Payloads without
-- 'sketches' keep working and store three empty strings.
-- get_squadquest_game_state already returns the whole t.solution, so nothing
-- else changes.

create or replace function squadquest.update_squadquest_solution(target_room_id uuid, solution_data jsonb)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, squadquest
as $$
declare actor_team_id uuid; current_step text; clean_solution jsonb;
begin
  select a.team_id, t.mission_step into actor_team_id, current_step
  from squadquest.players p join squadquest.gameplay_assignments a on a.player_id = p.id
  join squadquest.gameplay_teams t on t.id = a.team_id
  join squadquest.rooms r on r.id = p.room_id
  where p.room_id = target_room_id and p.session_id = auth.uid() and not p.is_host
    and r.phase = 'mission' and t.mission_step in ('build', 'adapt');
  if actor_team_id is null then raise exception 'The shared canvas is not open'; end if;
  clean_solution := jsonb_build_object(
    'name', left(coalesce(solution_data->>'name', ''), 80),
    'for_user', left(coalesce(solution_data->>'for_user', ''), 160),
    'problem', left(coalesce(solution_data->>'problem', ''), 240),
    'value', left(coalesce(solution_data->>'value', ''), 400),
    'how_works', jsonb_build_array(
      left(coalesce(solution_data->'how_works'->>0, ''), 180),
      left(coalesce(solution_data->'how_works'->>1, ''), 180),
      left(coalesce(solution_data->'how_works'->>2, ''), 180)
    ),
    'sketches', jsonb_build_array(
      case
        when coalesce(solution_data->'sketches'->>0, '') ~ '^[ML0-9 ]*$'
          and char_length(coalesce(solution_data->'sketches'->>0, '')) <= 60000
        then coalesce(solution_data->'sketches'->>0, '')
        else ''
      end,
      case
        when coalesce(solution_data->'sketches'->>1, '') ~ '^[ML0-9 ]*$'
          and char_length(coalesce(solution_data->'sketches'->>1, '')) <= 60000
        then coalesce(solution_data->'sketches'->>1, '')
        else ''
      end,
      case
        when coalesce(solution_data->'sketches'->>2, '') ~ '^[ML0-9 ]*$'
          and char_length(coalesce(solution_data->'sketches'->>2, '')) <= 60000
        then coalesce(solution_data->'sketches'->>2, '')
        else ''
      end
    ),
    'why_use', left(coalesce(solution_data->>'why_use', ''), 300),
    'adaptation', left(coalesce(solution_data->>'adaptation', ''), 300)
  );
  update squadquest.gameplay_teams set solution = clean_solution where id = actor_team_id;
  update squadquest.rooms set state_version = state_version + 1 where id = target_room_id;
  return true;
end;
$$;

-- Same privileges as 0007: create or replace keeps existing grants, but they are
-- restated so the function never ends up without the expected access.
revoke all on function squadquest.update_squadquest_solution(uuid,jsonb) from public, anon;
grant execute on function squadquest.update_squadquest_solution(uuid,jsonb) to authenticated;
