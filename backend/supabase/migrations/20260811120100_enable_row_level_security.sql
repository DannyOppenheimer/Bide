-- Row-level security.
--
-- Two rules drive everything below:
--   * You can read a bide only if you are a participant in it.
--   * You can write only your own participant row.
--
-- Nothing is readable to `anon`. A bide is reachable only by someone who was
-- sent its id in a tile URL and then joined it.

alter table public.bides enable row level security;
alter table public.participants enable row level security;
alter table public.devices enable row level security;

-- Membership test, used by the policies below.
--
-- This is `security definer` on purpose. The natural way to write the
-- `participants` SELECT policy is "you may read a participant row if you are a
-- participant of the same bide" — but that subquery reads `participants`,
-- which re-runs the policy, which runs the subquery, and Postgres aborts with
-- `infinite recursion detected in policy`. Running the lookup as the function
-- owner skips RLS for that one query and breaks the cycle.
--
-- It is safe to skip RLS here because the function answers exactly one
-- question — "is the CALLER in this bide?" — and takes the caller's identity
-- from `auth.uid()` rather than from an argument, so it cannot be asked about
-- anyone else.
create function public.is_bide_participant(target_bide uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1
    from public.participants
    where participants.bide_id = target_bide
      and participants.user_id = (select auth.uid())
  );
$$;

comment on function public.is_bide_participant(uuid) is
  'Is the calling user a participant in this bide? security definer to avoid recursive RLS on participants.';

revoke execute on function public.is_bide_participant(uuid) from public, anon;
grant execute on function public.is_bide_participant(uuid) to authenticated;

-- Table privileges. RLS narrows what you can reach; these decide whether you
-- can reach the table at all. `anon` gets nothing anywhere.
revoke all on public.bides from anon;
revoke all on public.participants from anon;
revoke all on public.devices from anon;

grant select, insert on public.bides to authenticated;
grant select, insert, update, delete on public.participants to authenticated;
grant select, insert, update, delete on public.devices to authenticated;

-- MARK: bides

create policy "read a bide only as a participant"
  on public.bides for select to authenticated
  using (public.is_bide_participant(id));

create policy "create a bide only as yourself"
  on public.bides for insert to authenticated
  with check (created_by = (select auth.uid()));

-- Deliberately no UPDATE or DELETE policy: a bide's destination is what both
-- people agreed on, so it is immutable once sent. Deleting the creator's
-- account cascades. Anything else is the service role's job.

-- MARK: participants

create policy "read participants of your own bides"
  on public.participants for select to authenticated
  using (public.is_bide_participant(bide_id));

-- Joining is open to anyone holding the bide id, which only travels in the
-- tile URL. The URL is the capability.
create policy "join a bide only as yourself"
  on public.participants for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy "update only your own participant row"
  on public.participants for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "leave a bide only as yourself"
  on public.participants for delete to authenticated
  using (user_id = (select auth.uid()));

-- MARK: devices

create policy "read only your own devices"
  on public.devices for select to authenticated
  using (user_id = (select auth.uid()));

create policy "register a device only to yourself"
  on public.devices for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy "update only your own devices"
  on public.devices for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "remove only your own devices"
  on public.devices for delete to authenticated
  using (user_id = (select auth.uid()));
