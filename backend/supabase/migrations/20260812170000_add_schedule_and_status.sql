-- Add scheduling, arrival style, and participant responses. These fields contain
-- times and state only; the schema still stores no participant location data.

-- Bides

alter table public.bides
  -- Null means the bide starts as soon as everyone can arrive.
  add column scheduled_for timestamptz,
  add column arrival_style text not null default 'on_time'
    check (arrival_style in ('on_time', 'together')),
  -- A solo bide has one traveler; other members only watch the journey.
  add column is_solo boolean not null default false;

comment on column public.bides.scheduled_for is
  'When everyone is due. Null for an asap bide.';
comment on column public.bides.arrival_style is
  'on_time: everyone lands by scheduled_for. together: nobody leaves until the furthest person does.';

-- Participants

alter table public.participants
  add column display_name text check (char_length(display_name) <= 80),
  -- Keep the first ETA fixed as the reference for later delay grades.
  add column baseline_eta timestamptz,
  add column status text not null default 'invited'
    check (status in ('invited', 'accepted', 'declined', 'arrived'));

-- Replace the boolean with a status that distinguishes no response from decline.
update public.participants
   set status = case when arrived then 'arrived' else 'accepted' end;

alter table public.participants drop column arrived;

-- Allow only modes with an implemented ETA source. Cycling is added separately.
alter table public.participants drop constraint participants_mode_check;
alter table public.participants
  add constraint participants_mode_check check (mode in ('driving', 'walking', 'transit'));

comment on column public.participants.status is
  'invited / accepted / declined / arrived. Replaces the old arrived boolean, which could not express "no".';
comment on column public.participants.baseline_eta is
  'First arrival timestamp recorded for this person. Immutable once set; delays are measured from it.';
comment on column public.participants.display_name is
  'What they call themselves. Null for someone who never set one — the UI shows a placeholder, never an id.';

-- create_bide

-- Drop the old signature to prevent ambiguous PostgREST overload resolution.
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

  -- `RETURNING` would fail its SELECT policy because membership is added next.
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

  -- The creator implicitly accepts the bide they send.
  insert into public.participants (bide_id, user_id, mode, status)
  values (p_bide_id, v_user_id, p_mode, 'accepted');

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

-- join_bide

drop function if exists public.join_bide(uuid, text);

-- Avoid `ON CONFLICT`; its conflict lookup is blocked by RLS before joining.
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
    -- A missing bide raises the foreign-key error that the client maps to not found.
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
