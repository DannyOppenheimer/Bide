-- Authenticated users can read bides they have joined and write only their own
-- participant rows. Anonymous users receive no table privileges.

alter table public.bides enable row level security;
alter table public.participants enable row level security;
alter table public.devices enable row level security;

-- Use a security-definer membership check to avoid recursive RLS on
-- `participants`. The function reads identity from `auth.uid()`, so callers
-- cannot query membership for another user.
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

-- Table privileges define access before RLS narrows it to individual rows.
revoke all on public.bides from anon;
revoke all on public.participants from anon;
revoke all on public.devices from anon;

grant select, insert on public.bides to authenticated;
grant select, insert, update, delete on public.participants to authenticated;
grant select, insert, update, delete on public.devices to authenticated;

-- Bides

create policy "read a bide only as a participant"
  on public.bides for select to authenticated
  using (public.is_bide_participant(id));

create policy "create a bide only as yourself"
  on public.bides for insert to authenticated
  with check (created_by = (select auth.uid()));

-- Bides are initially immutable; a later migration adds limited update access.

-- Participants

create policy "read participants of your own bides"
  on public.participants for select to authenticated
  using (public.is_bide_participant(bide_id));

-- Possession of the unguessable bide ID grants the ability to join.
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

-- Devices

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
