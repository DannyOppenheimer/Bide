-- Delete only the authenticated caller without exposing the service-role key.
-- `security definer` supplies the required privilege, while `auth.uid()` fixes
-- the target so callers cannot delete another account. Foreign-key cascades also
-- remove bides they created, participant rows, and device tokens.

create function public.delete_me()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
begin
  if v_user_id is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  delete from auth.users where id = v_user_id;
end;
$$;

comment on function public.delete_me is
  'Deletes the calling user and everything that cascades from them. Takes its subject from auth.uid(), never an argument.';

revoke execute on function public.delete_me() from public, anon;
grant execute on function public.delete_me() to authenticated;
