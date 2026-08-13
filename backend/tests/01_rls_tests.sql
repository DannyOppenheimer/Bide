-- Exercises the policies as real users. Every check raises on failure, so a
-- clean run means the whole file passed.

\set ON_ERROR_STOP on

set session role postgres;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'alice@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'bob@example.com'),
  ('33333333-3333-3333-3333-333333333333', 'mallory@example.com');

create function pg_temp.become(who uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', who)::text, false);
  execute 'set role authenticated';
end;
$$;

create function pg_temp.check(label text, condition boolean) returns void
language plpgsql as $$
begin
  if condition then
    raise notice 'ok   %', label;
  else
    raise exception 'FAIL %', label;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- The privacy invariant, enforced as a test rather than a comment.
-- ---------------------------------------------------------------------------
do $$
declare
  offending text;
begin
  select string_agg(table_name || '.' || column_name, ', ')
    into offending
    from information_schema.columns
   where table_schema = 'public'
     and table_name in ('participants', 'devices')
     and (
       column_name ~* '(lat|lng|long|coord|geo|location|position|heading|speed|accuracy|altitude)'
       or udt_name in ('geography', 'geometry', 'point')
     );

  perform pg_temp.check(
    'no location columns on participants/devices',
    offending is null
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Alice creates a bide.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bide public.bides;
begin
  perform pg_temp.become('11111111-1111-1111-1111-111111111111');

  select * into v_bide from public.create_bide(
    'aaaaaaaa-0000-0000-0000-000000000001',
    'Blue Bottle Coffee',
    37.7952,
    -122.2718,
    now() + interval '2 hours',
    'on_time',
    false,
    now(),
    'walking'
  );

  perform pg_temp.check('create_bide returns the bide', v_bide.id = 'aaaaaaaa-0000-0000-0000-000000000001');
  perform pg_temp.check('create_bide sets created_by to the caller',
    v_bide.created_by = '11111111-1111-1111-1111-111111111111');
  perform pg_temp.check('creator can read own bide',
    (select count(*) from public.bides where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 1);
  perform pg_temp.check('creator got a participant row',
    (select count(*) from public.participants where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 1);
end
$$;

-- ---------------------------------------------------------------------------
-- Bob is a stranger until he joins.
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.become('22222222-2222-2222-2222-222222222222');

  perform pg_temp.check('non-participant cannot read the bide',
    (select count(*) from public.bides where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 0);
  perform pg_temp.check('non-participant cannot read participants',
    (select count(*) from public.participants where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 0);

  insert into public.participants (bide_id, user_id, mode)
  values ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'driving');

  perform pg_temp.check('after joining, can read the bide',
    (select count(*) from public.bides where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 1);
  perform pg_temp.check('after joining, can see both participants',
    (select count(*) from public.participants where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 2);
end
$$;

-- ---------------------------------------------------------------------------
-- Write only your own participant row.
-- ---------------------------------------------------------------------------
do $$
declare
  v_denied boolean := false;
  v_eta timestamptz := now() + interval '11 minutes';
  v_before timestamptz;
  v_after timestamptz;
begin
  perform pg_temp.become('22222222-2222-2222-2222-222222222222');

  -- Own row: allowed, and updated_at is maintained by the trigger.
  select updated_at into v_before from public.participants
   where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and user_id = '22222222-2222-2222-2222-222222222222';

  perform pg_sleep(0.01);

  update public.participants
     set eta_timestamp = v_eta, updated_at = 'epoch'
   where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and user_id = '22222222-2222-2222-2222-222222222222';

  select updated_at into v_after from public.participants
   where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and user_id = '22222222-2222-2222-2222-222222222222';

  perform pg_temp.check('can update own participant row',
    (select eta_timestamp from public.participants
      where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
        and user_id = '22222222-2222-2222-2222-222222222222') = v_eta);
  perform pg_temp.check('trigger overrides a client-supplied updated_at', v_after > v_before);

  -- Someone else's row: the USING clause filters it out, so nothing happens.
  update public.participants
     set eta_timestamp = 'epoch', status = 'arrived'
   where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and user_id = '11111111-1111-1111-1111-111111111111';

  perform pg_temp.check('cannot update another participant''s row',
    (select status from public.participants
      where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
        and user_id = '11111111-1111-1111-1111-111111111111') = 'accepted');

  -- Inserting a row on someone else's behalf is refused outright.
  begin
    insert into public.participants (bide_id, user_id, mode)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'walking');
  exception when insufficient_privilege then
    v_denied := true;
  end;
  perform pg_temp.check('cannot add someone else as a participant', v_denied);

  -- Deleting someone else's row is likewise filtered out.
  delete from public.participants
   where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and user_id = '11111111-1111-1111-1111-111111111111';
  perform pg_temp.check('cannot delete another participant''s row',
    (select count(*) from public.participants where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 2);
end
$$;

-- ---------------------------------------------------------------------------
-- Joining is idempotent, and does not go through ON CONFLICT.
-- ---------------------------------------------------------------------------
-- Regression guard for the reason public.join_bide exists.
--
-- A newcomer upserting their OWN row — the natural way to make joining
-- idempotent — is refused, even though a plain INSERT of the identical row is
-- allowed. ON CONFLICT has to look for a conflicting row, and the SELECT
-- policy hides every row in a bide you haven't joined yet, so the statement is
-- rejected before the INSERT branch is ever reached. Someone who is ALREADY a
-- participant can see those rows, and their upsert succeeds — which is why
-- this only bites the exact case joining cares about.
do $$
declare
  v_denied boolean := false;
begin
  perform pg_temp.become('33333333-3333-3333-3333-333333333333');

  begin
    insert into public.participants (bide_id, user_id, mode)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'walking')
    on conflict (bide_id, user_id) do update set mode = excluded.mode;
  exception when insufficient_privilege then
    v_denied := true;
  end;
  perform pg_temp.check('a newcomer''s ON CONFLICT upsert is refused by RLS', v_denied);

  perform pg_temp.check('and the newcomer is still not in the bide',
    (select count(*) from public.participants
      where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
        and user_id = '33333333-3333-3333-3333-333333333333') = 0);
end
$$;

do $$
declare
  v_bide public.bides;
begin
  perform pg_temp.become('22222222-2222-2222-2222-222222222222');

  -- join_bide on a bide you are already in refreshes the mode.
  select * into v_bide from public.join_bide('aaaaaaaa-0000-0000-0000-000000000001', 'walking', 'accepted');
  perform pg_temp.check('join_bide returns the bide', v_bide.id = 'aaaaaaaa-0000-0000-0000-000000000001');
  perform pg_temp.check('join_bide refreshes travel mode',
    (select mode from public.participants
      where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
        and user_id = '22222222-2222-2222-2222-222222222222') = 'walking');
  perform pg_temp.check('join_bide does not duplicate the participant',
    (select count(*) from public.participants
      where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
        and user_id = '22222222-2222-2222-2222-222222222222') = 1);
end
$$;

-- A newcomer joining through the function, rather than a raw insert.
do $$
declare
  v_bide public.bides;
  v_missing boolean := false;
begin
  perform pg_temp.become('33333333-3333-3333-3333-333333333333');

  select * into v_bide from public.join_bide('aaaaaaaa-0000-0000-0000-000000000001', 'driving', 'accepted');
  perform pg_temp.check('join_bide lets a newcomer in', v_bide.id = 'aaaaaaaa-0000-0000-0000-000000000001');
  perform pg_temp.check('newcomer can now read the bide',
    (select count(*) from public.bides where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 1);

  -- Joining a bide that does not exist trips the foreign key.
  begin
    perform public.join_bide('aaaaaaaa-0000-0000-0000-00000000dead', 'driving', 'accepted');
  exception when foreign_key_violation then
    v_missing := true;
  end;
  perform pg_temp.check('join_bide on a missing bide raises a foreign key violation', v_missing);

  -- Put things back for the checks that follow.
  delete from public.participants
   where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and user_id = '33333333-3333-3333-3333-333333333333';
end
$$;

-- ---------------------------------------------------------------------------
-- Mallory holds no invite and gets nothing.
-- ---------------------------------------------------------------------------
do $$
declare
  v_denied boolean := false;
begin
  perform pg_temp.become('33333333-3333-3333-3333-333333333333');

  perform pg_temp.check('outsider sees no bides',
    (select count(*) from public.bides) = 0);
  perform pg_temp.check('outsider sees no participants',
    (select count(*) from public.participants) = 0);
  perform pg_temp.check('membership helper is false for outsiders',
    public.is_bide_participant('aaaaaaaa-0000-0000-0000-000000000001') = false);

  -- A bide attributed to someone else is refused.
  begin
    insert into public.bides (id, destination_name, lat, lng, created_by)
    values ('aaaaaaaa-0000-0000-0000-000000000002', 'Fake', 1, 2,
            '11111111-1111-1111-1111-111111111111');
  exception when insufficient_privilege then
    v_denied := true;
  end;
  perform pg_temp.check('cannot create a bide as someone else', v_denied);
end
$$;

-- ---------------------------------------------------------------------------
-- Devices are private to their owner.
-- ---------------------------------------------------------------------------
do $$
declare
  v_denied boolean := false;
begin
  perform pg_temp.become('11111111-1111-1111-1111-111111111111');
  insert into public.devices (user_id, apns_token, live_activity_token)
  values ('11111111-1111-1111-1111-111111111111', 'apns-alice', 'la-alice');

  perform pg_temp.become('22222222-2222-2222-2222-222222222222');
  perform pg_temp.check('cannot read another user''s device',
    (select count(*) from public.devices) = 0);

  begin
    insert into public.devices (user_id, apns_token)
    values ('11111111-1111-1111-1111-111111111111', 'apns-stolen');
  exception when insufficient_privilege then
    v_denied := true;
  end;
  perform pg_temp.check('cannot register a device to another user', v_denied);

  insert into public.devices (user_id, apns_token) values
    ('22222222-2222-2222-2222-222222222222', 'apns-bob-phone'),
    ('22222222-2222-2222-2222-222222222222', 'apns-bob-ipad');
  perform pg_temp.check('one user may hold several devices',
    (select count(*) from public.devices) = 2);
end
$$;

-- ---------------------------------------------------------------------------
-- Unauthenticated access.
-- ---------------------------------------------------------------------------
do $$
declare
  v_denied boolean := false;
begin
  perform set_config('request.jwt.claims', null, false);
  set role anon;

  begin
    perform count(*) from public.bides;
  exception when insufficient_privilege then
    v_denied := true;
  end;
  perform pg_temp.check('anon cannot touch bides at all', v_denied);

  v_denied := false;
  begin
    perform count(*) from public.participants;
  exception when insufficient_privilege then
    v_denied := true;
  end;
  perform pg_temp.check('anon cannot touch participants at all', v_denied);
end
$$;

-- ---------------------------------------------------------------------------
-- delete_me(). Last, because it destroys the rows everything above asserts on.
-- ---------------------------------------------------------------------------
set session role postgres;

insert into auth.users (id, email) values
  ('44444444-4444-4444-4444-444444444444', 'dave@example.com');

do $$
declare
  v_denied boolean := false;
begin
  -- Dave makes a bide, Bob joins it, Dave registers a device.
  perform pg_temp.become('44444444-4444-4444-4444-444444444444');
  perform public.create_bide(
    'dddddddd-0000-0000-0000-000000000001', 'Union Market', 38.908, -76.997,
    null, 'on_time', false, now(), 'walking'
  );
  insert into public.devices (user_id, apns_token)
  values ('44444444-4444-4444-4444-444444444444', 'apns-dave-phone');

  perform pg_temp.become('22222222-2222-2222-2222-222222222222');
  perform public.join_bide('dddddddd-0000-0000-0000-000000000001', 'driving', 'accepted');

  -- Dave deletes himself. There is no argument to this function, so there is
  -- nothing a caller can pass to make it delete somebody else — which is what
  -- the survivors below are really asserting.
  perform pg_temp.become('44444444-4444-4444-4444-444444444444');
  perform public.delete_me();

  set session role postgres;

  perform pg_temp.check('delete_me removes the account',
    not exists (select 1 from auth.users where id = '44444444-4444-4444-4444-444444444444'));
  perform pg_temp.check('delete_me cascades to the bides they created',
    not exists (select 1 from public.bides where id = 'dddddddd-0000-0000-0000-000000000001'));
  perform pg_temp.check('delete_me cascades to every roster they appeared in',
    not exists (select 1 from public.participants
                 where user_id = '44444444-4444-4444-4444-444444444444'));
  perform pg_temp.check('delete_me cascades to their devices',
    not exists (select 1 from public.devices
                 where user_id = '44444444-4444-4444-4444-444444444444'));
  -- Bob's row went with the bide, not with Bob: the bide was Dave's.
  perform pg_temp.check('a deleted creator takes their bide''s roster with it',
    not exists (select 1 from public.participants
                 where bide_id = 'dddddddd-0000-0000-0000-000000000001'));
  -- But only the caller is deleted. Bob was in that bide and Alice was not in
  -- it at all; both are still here.
  perform pg_temp.check('a participant of the deleted bide survives',
    exists (select 1 from auth.users where id = '22222222-2222-2222-2222-222222222222'));
  perform pg_temp.check('everyone else survives',
    exists (select 1 from auth.users where id = '11111111-1111-1111-1111-111111111111'));
  perform pg_temp.check('other people''s bides are untouched',
    exists (select 1 from public.bides where created_by = '11111111-1111-1111-1111-111111111111'));

  -- And nobody who isn't signed in can reach it at all.
  perform set_config('request.jwt.claims', null, false);
  set role anon;
  begin
    perform public.delete_me();
  exception when insufficient_privilege then
    v_denied := true;
  end;
  perform pg_temp.check('anon cannot execute delete_me', v_denied);
end
$$;

set session role postgres;
select 'ALL RLS TESTS PASSED' as result;
