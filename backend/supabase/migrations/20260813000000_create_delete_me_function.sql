-- Deleting your own account.
--
-- There is no client-callable way to do this in GoTrue: the admin endpoint
-- (`DELETE /auth/v1/admin/users/:id`) needs the service_role key, which must
-- never ship inside an app. So the capability has to be a function the caller
-- is allowed to run on themselves and nobody else.
--
-- `security definer` is what makes it possible at all — `authenticated` has no
-- delete privilege on `auth.users` and must not be given one. It is safe here
-- for the same reason `is_bide_participant()` is: the function takes its
-- subject from `auth.uid()`, never from an argument, so there is no value a
-- caller can pass that makes it touch a different row.
--
-- Everything else goes with it. `bides.created_by`, `participants.user_id` and
-- `devices.user_id` all reference `auth.users (id) on delete cascade`, so one
-- delete takes the account, every bide it created, every roster it appeared in,
-- and its push tokens.
--
-- Note the reach of that: deleting your account deletes the bides you *created*
-- for everyone in them, not just your own place in them. That is the right
-- answer for an account deletion — a bide is the creator's destination, and
-- leaving it standing without them would strand the other people in a meetup
-- nobody owns — but it is worth knowing before calling this in anger.
--
-- Bide calls it from `DevBuildReset`, which is temporary. The function is not:
-- an app that lets people make an account has to let them delete it, and this
-- is the mechanism that will serve that.

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

  -- The only statement, and its subject is not an argument.
  delete from auth.users where id = v_user_id;
end;
$$;

comment on function public.delete_me is
  'Deletes the calling user and everything that cascades from them. Takes its subject from auth.uid(), never an argument.';

revoke execute on function public.delete_me() from public, anon;
grant execute on function public.delete_me() to authenticated;
