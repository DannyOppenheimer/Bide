-- Joining a bide, without `ON CONFLICT`.
--
-- The obvious way to make joining idempotent is an upsert — PostgREST's
-- `Prefer: resolution=merge-duplicates`, which emits
-- `INSERT ... ON CONFLICT DO UPDATE`. For a newcomer that is refused with
-- `42501 new row violates row-level security policy`, even though a plain
-- INSERT of the identical row is allowed.
--
-- The reason is the SELECT policy, not the INSERT one. ON CONFLICT has to look
-- for a conflicting row, and `read participants of your own bides` hides every
-- row in a bide you have not joined yet — so the statement is rejected before
-- the INSERT branch is reached. Someone who is already a participant CAN see
-- those rows and their upsert succeeds, which is what makes this so easy to
-- miss: it fails only for the exact case joining is about. An explicit
-- `on_conflict` target does not help.
--
-- So: branch explicitly. An UPDATE that touches nothing, followed by an INSERT,
-- reaches the same end state while letting each statement be checked against
-- the one policy that should apply to it.
--
-- Idempotent by design — accepting a tile twice is something a real person
-- does, and the second accept should just refresh the travel mode.
create function public.join_bide(
  p_bide_id uuid,
  p_mode text
)
returns public.bides
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_bide public.bides;
begin
  if v_user_id is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  update public.participants
     set mode = p_mode
   where bide_id = p_bide_id
     and user_id = v_user_id;

  if not found then
    -- Fails with a foreign key violation if the bide does not exist, which the
    -- client maps to "no such bide" rather than a bare conflict.
    insert into public.participants (bide_id, user_id, mode)
    values (p_bide_id, v_user_id, p_mode);
  end if;

  select * into v_bide from public.bides where id = p_bide_id;
  return v_bide;
end;
$$;

comment on function public.join_bide is
  'Adds the calling user to a bide, or refreshes their travel mode. Avoids ON CONFLICT, which RLS refuses.';

revoke execute on function public.join_bide(uuid, text) from public, anon;
grant execute on function public.join_bide(uuid, text) to authenticated;
