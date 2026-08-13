-- Add a watcher role and allow creators to end solo bides cleanly.

-- Watcher roles

-- Watchers publish no journey state and do not count toward completion.
alter table public.participants drop constraint participants_status_check;

alter table public.participants
  add constraint participants_status_check
    check (status in ('invited', 'accepted', 'declined', 'arrived', 'watching'));

comment on column public.participants.status is
  'invited / accepted / declined / arrived for people going; watching for an audience following somebody else''s solo bide.';

-- Enforce the cross-table status rule in a security-definer predicate shared by
-- RLS and `join_bide`. Identity comes from `auth.uid()`, not a caller argument.
-- A null result means the bide does not exist.
create function public.is_valid_participant_status(target_bide uuid, target_status text)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select case
    when bides.is_solo then
      case
        when bides.created_by = (select auth.uid()) then target_status <> 'watching'
        else target_status = 'watching'
      end
    else target_status <> 'watching'
  end
  from public.bides
  where bides.id = target_bide;
$$;

comment on function public.is_valid_participant_status(uuid, text) is
  'Enforces participant roles: solo creators travel, other users may only watch solo bides, and shared bides have no watchers.';

revoke execute on function public.is_valid_participant_status(uuid, text) from public, anon;
grant execute on function public.is_valid_participant_status(uuid, text) to authenticated;

-- Convert non-creator members of existing solo bides to watchers and clear stale
-- journey state.
update public.participants as participant
   set status = 'watching',
       eta_timestamp = null,
       baseline_eta = null,
       travel_seconds = null,
       left_at = null
  from public.bides as bide
 where participant.bide_id = bide.id
   and bide.is_solo
   and participant.user_id <> bide.created_by;

-- Apply the same role validation to direct inserts and updates.
drop policy "join a bide only as yourself" on public.participants;
create policy "join a bide only as yourself"
  on public.participants for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and public.is_valid_participant_status(bide_id, status)
  );

drop policy "update only your own participant row" on public.participants;
create policy "update only your own participant row"
  on public.participants for update to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and public.is_valid_participant_status(bide_id, status)
  );

-- Validate the role before the idempotent update-or-insert sequence.
create or replace function public.join_bide(
  p_bide_id uuid,
  p_mode text,
  p_status text
)
returns public.bides
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_bide public.bides;
  v_status text := coalesce(p_status, 'accepted');
  v_valid_status boolean;
begin
  if v_user_id is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  v_valid_status := public.is_valid_participant_status(p_bide_id, v_status);
  if v_valid_status is null then
    -- Preserve the foreign-key SQLSTATE that the client maps to not found.
    raise exception 'participant refers to a missing bide'
      using errcode = '23503', constraint = 'participants_bide_id_fkey';
  end if;
  if v_valid_status is false then
    raise exception 'invalid participant role for this bide'
      using errcode = '23514', constraint = 'participants_status_role_check';
  end if;

  update public.participants
     set mode = p_mode,
         status = v_status
   where bide_id = p_bide_id
     and user_id = v_user_id;

  if not found then
    insert into public.participants (bide_id, user_id, mode, status)
    values (p_bide_id, v_user_id, p_mode, v_status);
  end if;

  select * into v_bide from public.bides where id = p_bide_id;
  return v_bide;
end;
$$;

comment on function public.join_bide(uuid, text, text) is
  'Adds the calling user with a role valid for this bide, or updates their mode and answer.';

-- Solo-bide deletion

-- Only a solo creator may delete the bide itself; the cascade removes watchers.
-- Members leave shared bides by deleting only their participant row.
grant delete on public.bides to authenticated;

create policy "delete a solo bide you created"
  on public.bides for delete to authenticated
  using (is_solo and created_by = (select auth.uid()));

comment on policy "delete a solo bide you created" on public.bides is
  'Only solo bides, only their creator. A shared bide is other people''s arrangement too — leaving one is a delete on your own participant row.';
