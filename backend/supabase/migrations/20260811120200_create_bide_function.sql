-- Creating a bide writes two rows: the bide, and the creator's own participant
-- row. They must land together — a bide with no participants is unreadable
-- even to the person who just created it, because the SELECT policy on
-- `bides` requires membership. A function gets both in one transaction.
--
-- `security invoker` (the default, stated here for emphasis): every statement
-- below is still checked against the policies in the previous migration, so
-- this convenience wrapper grants no authority the caller doesn't already have.
create function public.create_bide(
  p_bide_id uuid,
  p_destination_name text,
  p_lat double precision,
  p_lng double precision,
  p_created_at timestamptz,
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

  -- No RETURNING here. RETURNING is checked against the SELECT policy, and
  -- the caller isn't a participant yet, so it would fail on its own row.
  insert into public.bides (id, destination_name, lat, lng, created_at, created_by)
  values (
    p_bide_id,
    p_destination_name,
    p_lat,
    p_lng,
    coalesce(p_created_at, now()),
    v_user_id
  );

  insert into public.participants (bide_id, user_id, mode)
  values (p_bide_id, v_user_id, p_mode);

  -- Readable now that membership exists.
  select * into v_bide from public.bides where id = p_bide_id;
  return v_bide;
end;
$$;

comment on function public.create_bide is
  'Creates a bide and the creator''s participant row in one transaction. Returns the bide.';

revoke execute on function public.create_bide(uuid, text, double precision, double precision, timestamptz, text)
  from public, anon;
grant execute on function public.create_bide(uuid, text, double precision, double precision, timestamptz, text)
  to authenticated;
