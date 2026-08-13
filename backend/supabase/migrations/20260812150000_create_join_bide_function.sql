-- Join idempotently without `ON CONFLICT`. An upsert must SELECT a possible
-- conflict, but RLS hides participant rows before a user joins. Trying UPDATE
-- first and INSERT second lets each operation use its intended policy.
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
    -- A missing bide raises the foreign-key error that the client maps to not found.
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
