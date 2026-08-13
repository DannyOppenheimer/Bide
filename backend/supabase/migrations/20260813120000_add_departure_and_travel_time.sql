-- Add departure and journey-duration data without storing location. `left_at`
-- records only when an on-device radius check detects departure, distinguishing
-- active travel from an ETA calculated before leaving. `travel_seconds` stores
-- the measured duration explicitly because later updates can change `updated_at`.

alter table public.participants
  add column travel_seconds integer check (travel_seconds >= 0),
  add column left_at timestamptz;

comment on column public.participants.travel_seconds is
  'How long this person''s journey takes, as their device last measured it. A duration, never a distance from anywhere.';
comment on column public.participants.left_at is
  'When they left the area they started in. NOT a location: the radius test runs on-device and only its answer is sent.';

-- Null values preserve the unknown/not-departed state for existing rows.
