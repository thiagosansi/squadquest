-- INSERT ... RETURNING also applies SELECT policies to the returned row.
-- A new member must be able to read their own row before the roster helper can
-- observe that membership in a later statement. Other roster rows remain
-- visible only to existing room members.
drop policy if exists "room members can see their roster" on squadquest.players;
create policy "room members can see their roster"
  on squadquest.players for select to authenticated
  using (
    session_id = auth.uid()
    or squadquest.is_squadquest_room_member(room_id)
  );
