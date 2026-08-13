-- Brings a database up to the current schema, by hand.
--
-- Paste into the Supabase SQL editor and run. It is the four migrations dated
-- 2026-08-13 rewritten so that running it twice — or on a database that already
-- has some of them — changes nothing and raises nothing. Use it when
-- `supabase db push` is unavailable; the migrations remain the source of truth.
--
-- Assumes the three original migrations (20260811*, 20260812*) are already
-- applied. It reports what it found at the end.
--
--   1. participants.travel_seconds and left_at   20260813120000
--   2. cycling as a travel mode                  20260813140000
--   3. editing a bide in place                   20260813160000
--   4. watchers, and deleting a solo bide        20260813180000
--   5. repair: solo creators left watching their own bide
--
-- Every statement stands alone, so a failure part-way leaves the database
-- consistent and the script can simply be run again.


-- 1. Departure and journey duration -----------------------------------------
--
-- `left_at` records only that an on-device radius check saw a departure, and
-- `travel_seconds` a measured duration. Neither is a location.

alter table public.participants
  add column if not exists travel_seconds integer check (travel_seconds >= 0);

alter table public.participants
  add column if not exists left_at timestamptz;

comment on column public.participants.travel_seconds is
  'How long this person''s journey takes, as their device last measured it. A duration, never a distance from anywhere.';
comment on column public.participants.left_at is
  'When they left the area they started in. NOT a location: the radius test runs on-device and only its answer is sent.';


-- 2. Cycling ----------------------------------------------------------------
--
-- Dropped and re-added rather than altered: a CHECK constraint cannot be
-- widened in place. Existing rows are revalidated against a strictly larger set,
-- so this cannot fail on data.

alter table public.participants drop constraint if exists participants_mode_check;

alter table public.participants
  add constraint participants_mode_check
    check (mode in ('driving', 'walking', 'cycling', 'transit'));

comment on column public.participants.mode is
  'Travel mode, which sets the re-anchor cadence: 5 min driving and transit, 10 min walking and cycling.';


-- 3. Editing a bide in place ------------------------------------------------
--
-- The column grant decides what may change; the policy decides who may change
-- it. Any participant may edit a shared bide, only the creator a solo one.

grant update (destination_name, lat, lng, scheduled_for) on public.bides to authenticated;

drop policy if exists "edit a bide you are part of" on public.bides;
create policy "edit a bide you are part of"
  on public.bides for update to authenticated
  using (
    case
      when is_solo then created_by = (select auth.uid())
      else public.is_bide_participant(id)
    end
  )
  with check (
    case
      when is_solo then created_by = (select auth.uid())
      else public.is_bide_participant(id)
    end
  );

comment on policy "edit a bide you are part of" on public.bides is
  'Shared bides are editable by any participant; solo bides only by their creator. The column grant decides what may change.';


-- 4a. Watching as a status --------------------------------------------------

alter table public.participants drop constraint if exists participants_status_check;

alter table public.participants
  add constraint participants_status_check
    check (status in ('invited', 'accepted', 'declined', 'arrived', 'watching'));

comment on column public.participants.status is
  'invited / accepted / declined / arrived for people going; watching for an audience following somebody else''s solo bide.';


-- 4b. The role rule ---------------------------------------------------------
--
-- A status is also a role, and the role depends on the bide. Takes no user id:
-- the identity comes from auth.uid(), so a caller cannot use it to ask questions
-- about another account. Nil means the bide does not exist.

create or replace function public.is_valid_participant_status(target_bide uuid, target_status text)
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


-- 4c. Rows created before the rule existed ----------------------------------
--
-- Solo bides were always one person's trip, but another user holding the invite
-- UUID could once join as accepted. They are audience now, and audience rows
-- carry no journey state. The status test keeps a re-run a genuine no-op.

update public.participants as participant
   set status = 'watching',
       eta_timestamp = null,
       baseline_eta = null,
       travel_seconds = null,
       left_at = null
  from public.bides as bide
 where participant.bide_id = bide.id
   and bide.is_solo
   and participant.user_id <> bide.created_by
   and participant.status <> 'watching';


-- 4d. Policies that enforce the role ----------------------------------------
--
-- Closes direct table writes as well as the RPC path: a holder of an invite
-- UUID cannot insert `watching` into a shared bide, or turn a solo creator into
-- their own watcher.

drop policy if exists "join a bide only as yourself" on public.participants;
create policy "join a bide only as yourself"
  on public.participants for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and public.is_valid_participant_status(bide_id, status)
  );

drop policy if exists "update only your own participant row" on public.participants;
create policy "update only your own participant row"
  on public.participants for update to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and public.is_valid_participant_status(bide_id, status)
  );


-- 4e. join_bide, refusing an invalid role -----------------------------------

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


-- 4f. Ending a solo bide ----------------------------------------------------
--
-- Narrow on purpose. A shared bide is more than one person's arrangement, so no
-- participant may delete it out from under the others; walking out of one stays
-- a DELETE on your own participants row. A solo bide is the person who made it,
-- and deleting cascades to participants, which is what clears the audience.

grant delete on public.bides to authenticated;

drop policy if exists "delete a solo bide you created" on public.bides;
create policy "delete a solo bide you created"
  on public.bides for delete to authenticated
  using (is_solo and created_by = (select auth.uid()));

comment on policy "delete a solo bide you created" on public.bides is
  'Only solo bides, only their creator. A shared bide is other people''s arrangement too — leaving one is a delete on your own participant row.';


-- 5. Repair: a solo bide watching itself ------------------------------------
--
-- Only reachable on a database that ran without 4b, where opening your own
-- tracking link could set your own row to `watching`. That row is the only thing
-- holding the journey, so the bide was left with no traveller and read as
-- "Nobody is going any more". Puts the creator back on their own trip.
--
-- Their travel mode survives; the ETA columns stay null so the next reading from
-- the device establishes a fresh baseline rather than grading against one taken
-- before the row was broken.

update public.participants as participant
   set status = 'accepted'
  from public.bides as bide
 where participant.bide_id = bide.id
   and bide.is_solo
   and participant.user_id = bide.created_by
   and participant.status = 'watching';


-- What the database looks like now ------------------------------------------

select check_name, ok
from (values
  (
    '1. participants.travel_seconds',
    exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'participants'
         and column_name = 'travel_seconds'
    )
  ),
  (
    '1. participants.left_at',
    exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'participants'
         and column_name = 'left_at'
    )
  ),
  (
    '2. mode allows cycling',
    exists (
      select 1 from pg_constraint
       where conname = 'participants_mode_check'
         and pg_get_constraintdef(oid) like '%cycling%'
    )
  ),
  (
    '3. bides are editable',
    exists (
      select 1 from pg_policies
       where schemaname = 'public' and tablename = 'bides'
         and policyname = 'edit a bide you are part of'
    )
  ),
  (
    '4a. status allows watching',
    exists (
      select 1 from pg_constraint
       where conname = 'participants_status_check'
         and pg_get_constraintdef(oid) like '%watching%'
    )
  ),
  (
    '4b. the role rule exists',
    to_regprocedure('public.is_valid_participant_status(uuid, text)') is not null
  ),
  (
    '4f. a solo bide can be deleted',
    exists (
      select 1 from pg_policies
       where schemaname = 'public' and tablename = 'bides'
         and policyname = 'delete a solo bide you created'
    )
  ),
  (
    '5. no solo bide is watching itself',
    not exists (
      select 1
        from public.participants as participant
        join public.bides as bide on bide.id = participant.bide_id
       where bide.is_solo
         and participant.user_id = bide.created_by
         and participant.status = 'watching'
    )
  )
) as checks(check_name, ok)
order by check_name;
