-- Core schema.
--
-- Privacy invariant: the server stores destination coordinates and device-computed
-- arrival times, never a participant's location, heading, speed, or accuracy.

create table public.bides (
  id uuid primary key default gen_random_uuid(),
  destination_name text not null check (char_length(destination_name) <= 900),
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  created_at timestamptz not null default now(),
  created_by uuid not null references auth.users (id) on delete cascade
);

comment on table public.bides is
  'A meetup: a destination two people agreed on. lat/lng are the DESTINATION, never a participant.';
comment on column public.bides.id is
  'Generated on-device and carried in the tile URL, so the client supplies it rather than the server.';
comment on column public.bides.destination_name is
  'Capped to match the tile URL budget, which truncates names to keep the payload under 1KB.';

-- One row per participant, containing arrival information but no location data.
create table public.participants (
  bide_id uuid not null references public.bides (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  mode text not null check (mode in ('driving', 'walking')),
  eta_timestamp timestamptz,
  updated_at timestamptz not null default now(),
  arrived boolean not null default false,
  primary key (bide_id, user_id)
);

comment on table public.participants is
  'One row per person per bide. NEVER add a location column here — see the header of this migration.';
comment on column public.participants.eta_timestamp is
  'Arrival timestamp computed on-device. Null until the first ETA is anchored.';
comment on column public.participants.mode is
  'Travel mode, which sets the re-anchor cadence: 5 min driving, 10 min walking.';

-- APNs routing for the container app, which handles all background delivery.
create table public.devices (
  user_id uuid not null references auth.users (id) on delete cascade,
  apns_token text not null,
  live_activity_token text,
  updated_at timestamptz not null default now(),
  primary key (apns_token)
);

comment on table public.devices is
  'APNs routing per device. Keyed by apns_token so one user can have several devices.';
comment on column public.devices.live_activity_token is
  'ActivityKit push-to-start token. Null until the container app starts a Live Activity.';

create index bides_created_by_idx on public.bides (created_by);
create index participants_user_id_idx on public.participants (user_id);
create index devices_user_id_idx on public.devices (user_id);

-- Set `updated_at` on the server for every update.
create function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger participants_touch_updated_at
  before update on public.participants
  for each row execute function public.touch_updated_at();

create trigger devices_touch_updated_at
  before update on public.devices
  for each row execute function public.touch_updated_at();
