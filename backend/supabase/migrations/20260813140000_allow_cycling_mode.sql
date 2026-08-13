-- Allow cycling because the client can estimate it from a walking route's
-- distance. The calculation remains on-device; the server receives only the
-- selected mode and arrival timestamp.

alter table public.participants drop constraint participants_mode_check;

alter table public.participants
  add constraint participants_mode_check
    check (mode in ('driving', 'walking', 'cycling', 'transit'));

comment on column public.participants.mode is
  'Travel mode, which sets the re-anchor cadence: 5 min driving and transit, 10 min walking and cycling.';
