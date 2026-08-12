-- What a bide is *for*: a time, a way of arriving, and an answer from each
-- person.
--
-- The privacy invariant from the first migration is unchanged and still binding.
-- Nothing added here is a location. `scheduled_for` is a clock time everyone
-- agreed on, `baseline_eta` is the first arrival TIMESTAMP we recorded for a
-- person, and `status` is what they said. There is still no column anywhere
-- that could hold where somebody is.

-- MARK: bides

alter table public.bides
  -- Null means "as soon as everyone can get there" — the design's asap bide,
  -- where the arrival time is whatever the longest journey works out to.
  add column scheduled_for timestamptz,
  add column arrival_style text not null default 'on_time'
    check (arrival_style in ('on_time', 'together')),
  -- A bide with an audience rather than participants: one person is going
  -- somewhere, and anyone else in it is only watching.
  add column is_solo boolean not null default false;

comment on column public.bides.scheduled_for is
  'When everyone is due. Null for an asap bide.';
comment on column public.bides.arrival_style is
  'on_time: everyone lands by scheduled_for. together: nobody leaves until the furthest person does.';

-- MARK: participants

alter table public.participants
  add column display_name text check (char_length(display_name) <= 80),
  -- The first ETA ever recorded for this person. Every later one is graded
  -- against it for the green/yellow/red colouring, so it must not move.
  add column baseline_eta timestamptz,
  add column status text not null default 'invited'
    check (status in ('invited', 'accepted', 'declined', 'arrived'));

-- `arrived` couldn't tell "hasn't answered" from "said no", which is the
-- distinction the tile is built around. Existing rows carry over: anyone
-- already marked arrived stays arrived, everyone else was, by definition,
-- someone who had joined.
update public.participants
   set status = case when arrived then 'arrived' else 'accepted' end;

alter table public.participants drop column arrived;

-- Transit joins the modes that can be routed. Cycling, flights and trains are
-- deliberately absent: MapKit has no cycling directions, and the other two
-- need live carrier tracking that doesn't exist yet. The check is what stops
-- a client persisting one of them by accident.
alter table public.participants drop constraint participants_mode_check;
alter table public.participants
  add constraint participants_mode_check check (mode in ('driving', 'walking', 'transit'));

comment on column public.participants.status is
  'invited / accepted / declined / arrived. Replaces the old arrived boolean, which could not express "no".';
comment on column public.participants.baseline_eta is
  'First arrival timestamp recorded for this person. Immutable once set; delays are measured from it.';
comment on column public.participants.display_name is
  'What they call themselves. Null for someone who never set one — the UI shows a placeholder, never an id.';

-- MARK: create_bide

-- The signature changes, so the old function is replaced outright rather than
-- overloaded: two versions differing only by trailing arguments would make it
-- ambiguous which one PostgREST picks.
drop function if exists public.create_bide(uuid, text, double precision, double precision, timestamptz, text);

create function public.create_bide(
  p_bide_id uuid,
  p_destination_name text,
  p_lat double precision,
  p_lng double precision,
  p_scheduled_for timestamptz,
  p_arrival_style text,
  p_is_solo boolean,
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
  insert into public.bides (
    id, destination_name, lat, lng, scheduled_for, arrival_style, is_solo, created_at, created_by
  )
  values (
    p_bide_id,
    p_destination_name,
    p_lat,
    p_lng,
    p_scheduled_for,
    coalesce(p_arrival_style, 'on_time'),
    coalesce(p_is_solo, false),
    coalesce(p_created_at, now()),
    v_user_id
  );

  -- The creator has, by sending the tile, already accepted it.
  insert into public.participants (bide_id, user_id, mode, status)
  values (p_bide_id, v_user_id, p_mode, 'accepted');

  -- Readable now that membership exists.
  select * into v_bide from public.bides where id = p_bide_id;
  return v_bide;
end;
$$;

comment on function public.create_bide is
  'Creates a bide and the creator''s participant row in one transaction. Returns the bide.';

revoke execute on function public.create_bide(
  uuid, text, double precision, double precision, timestamptz, text, boolean, timestamptz, text
) from public, anon;
grant execute on function public.create_bide(
  uuid, text, double precision, double precision, timestamptz, text, boolean, timestamptz, text
) to authenticated;

-- MARK: join_bide

drop function if exists public.join_bide(uuid, text);

-- Still no ON CONFLICT — see the previous migration for why row-level security
-- refuses it for exactly the case joining is about.
create function public.join_bide(
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
begin
  if v_user_id is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  update public.participants
     set mode = p_mode,
         status = v_status
   where bide_id = p_bide_id
     and user_id = v_user_id;

  if not found then
    -- Fails with a foreign key violation if the bide does not exist, which the
    -- client maps to "no such bide" rather than a bare conflict.
    insert into public.participants (bide_id, user_id, mode, status)
    values (p_bide_id, v_user_id, p_mode, v_status);
  end if;

  select * into v_bide from public.bides where id = p_bide_id;
  return v_bide;
end;
$$;

comment on function public.join_bide is
  'Adds the calling user to a bide, or updates their mode and answer. Avoids ON CONFLICT, which RLS refuses.';

revoke execute on function public.join_bide(uuid, text, text) from public, anon;
grant execute on function public.join_bide(uuid, text, text) to authenticated;
