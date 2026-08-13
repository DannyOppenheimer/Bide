-- Exercises RLS as authenticated and anonymous users. Each failed check raises.

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

-- Privacy invariant
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

-- Bide creation
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

-- Access before and after joining
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

-- Participant write permissions
do $$
declare
  v_denied boolean := false;
  v_eta timestamptz := now() + interval '11 minutes';
  v_before timestamptz;
  v_after timestamptz;
begin
  perform pg_temp.become('22222222-2222-2222-2222-222222222222');

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

  update public.participants
     set eta_timestamp = 'epoch', status = 'arrived'
   where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and user_id = '11111111-1111-1111-1111-111111111111';

  perform pg_temp.check('cannot update another participant''s row',
    (select status from public.participants
      where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
        and user_id = '11111111-1111-1111-1111-111111111111') = 'accepted');

  begin
    insert into public.participants (bide_id, user_id, mode)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'walking');
  exception when insufficient_privilege then
    v_denied := true;
  end;
  perform pg_temp.check('cannot add someone else as a participant', v_denied);

  delete from public.participants
   where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and user_id = '11111111-1111-1111-1111-111111111111';
  perform pg_temp.check('cannot delete another participant''s row',
    (select count(*) from public.participants where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 2);
end
$$;

-- Idempotent joining
-- A newcomer's `ON CONFLICT` lookup is blocked because RLS hides participant
-- rows until they join. The RPC avoids that lookup with UPDATE followed by INSERT.
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

  begin
    perform public.join_bide('aaaaaaaa-0000-0000-0000-00000000dead', 'driving', 'accepted');
  exception when foreign_key_violation then
    v_missing := true;
  end;
  perform pg_temp.check('join_bide on a missing bide raises a foreign key violation', v_missing);

  delete from public.participants
   where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and user_id = '33333333-3333-3333-3333-333333333333';
end
$$;

-- Outsider access
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

-- Device privacy
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

-- Unauthenticated access
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

-- Bide edit permissions
do $$
declare
  v_denied boolean := false;
begin
  perform pg_temp.become('22222222-2222-2222-2222-222222222222');

  update public.bides
     set destination_name = 'Union Market', lat = 38.908, lng = -76.997,
         scheduled_for = now() + interval '2 hours'
   where id = 'aaaaaaaa-0000-0000-0000-000000000001';

  perform pg_temp.check('a participant may edit a shared bide',
    (select destination_name from public.bides
      where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 'Union Market');

  begin
    update public.bides set created_by = '22222222-2222-2222-2222-222222222222'
     where id = 'aaaaaaaa-0000-0000-0000-000000000001';
  exception when insufficient_privilege then
    v_denied := true;
  end;
  perform pg_temp.check('nobody may reassign a bide''s creator', v_denied);

  v_denied := false;
  begin
    update public.bides set arrival_style = 'together'
     where id = 'aaaaaaaa-0000-0000-0000-000000000001';
  exception when insufficient_privilege then
    v_denied := true;
  end;
  perform pg_temp.check('nobody may change arrival style after the fact', v_denied);

  perform pg_temp.become('33333333-3333-3333-3333-333333333333');
  update public.bides set destination_name = 'Mallory''s house'
   where id = 'aaaaaaaa-0000-0000-0000-000000000001';
  perform pg_temp.check('an outsider cannot edit a bide they are not in',
    (select count(*) from public.bides
      where destination_name = 'Mallory''s house') = 0);
end
$$;

-- Solo-bide edit permissions
do $$
begin
  perform pg_temp.become('11111111-1111-1111-1111-111111111111');
  perform public.create_bide(
    'aaaaaaaa-0000-0000-0000-000000000002', 'The gym', 38.9, -77.0,
    null, 'on_time', true, now(), 'walking'
  );

  perform pg_temp.become('22222222-2222-2222-2222-222222222222');
  perform public.join_bide(
    'aaaaaaaa-0000-0000-0000-000000000002', 'driving', 'watching'
  );

  update public.bides set destination_name = 'The pub'
   where id = 'aaaaaaaa-0000-0000-0000-000000000002';
  perform pg_temp.check('a watcher cannot edit somebody else''s solo bide',
    (select destination_name from public.bides
      where id = 'aaaaaaaa-0000-0000-0000-000000000002') = 'The gym');

  perform pg_temp.become('11111111-1111-1111-1111-111111111111');
  update public.bides set destination_name = 'The pub'
   where id = 'aaaaaaaa-0000-0000-0000-000000000002';
  perform pg_temp.check('the creator may edit their own solo bide',
    (select destination_name from public.bides
      where id = 'aaaaaaaa-0000-0000-0000-000000000002') = 'The pub');
end
$$;

-- Watcher roles and solo-bide deletion
do $$
declare
  v_denied boolean := false;
begin
  perform pg_temp.become('22222222-2222-2222-2222-222222222222');

  perform pg_temp.check('another user may watch a solo bide',
    (select status from public.participants
      where bide_id = 'aaaaaaaa-0000-0000-0000-000000000002'
        and user_id = '22222222-2222-2222-2222-222222222222') = 'watching');

  begin
    perform public.join_bide(
      'aaaaaaaa-0000-0000-0000-000000000001', 'walking', 'watching'
    );
  exception when check_violation then
    v_denied := true;
  end;
  perform pg_temp.check('a shared bide cannot contain a watcher', v_denied);

  v_denied := false;
  begin
    update public.participants set status = 'accepted'
     where bide_id = 'aaaaaaaa-0000-0000-0000-000000000002'
       and user_id = '22222222-2222-2222-2222-222222222222';
  exception when insufficient_privilege then
    v_denied := true;
  end;
  perform pg_temp.check('a solo watcher cannot become a traveller', v_denied);

  perform pg_temp.become('33333333-3333-3333-3333-333333333333');
  v_denied := false;
  begin
    perform public.join_bide(
      'aaaaaaaa-0000-0000-0000-000000000002', 'walking', 'accepted'
    );
  exception when check_violation then
    v_denied := true;
  end;
  perform pg_temp.check('another user may not travel in a solo bide', v_denied);

  perform pg_temp.become('11111111-1111-1111-1111-111111111111');
  v_denied := false;
  begin
    perform public.join_bide(
      'aaaaaaaa-0000-0000-0000-000000000002', 'walking', 'watching'
    );
  exception when check_violation then
    v_denied := true;
  end;
  perform pg_temp.check('a solo creator cannot watch themselves', v_denied);

  perform pg_temp.become('22222222-2222-2222-2222-222222222222');

  update public.bides set destination_name = 'Mallory''s house'
   where id = 'aaaaaaaa-0000-0000-0000-000000000002';
  perform pg_temp.check('a watcher still cannot edit what they watch',
    (select destination_name from public.bides
      where id = 'aaaaaaaa-0000-0000-0000-000000000002') = 'The pub');

  delete from public.bides where id = 'aaaaaaaa-0000-0000-0000-000000000002';
  perform pg_temp.check('a watcher cannot delete the bide they watch',
    (select count(*) from public.bides
      where id = 'aaaaaaaa-0000-0000-0000-000000000002') = 1);

  perform pg_temp.become('11111111-1111-1111-1111-111111111111');
  delete from public.bides where id = 'aaaaaaaa-0000-0000-0000-000000000001';
  perform pg_temp.check('nobody may delete a shared bide',
    (select count(*) from public.bides
      where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 1);

  delete from public.bides where id = 'aaaaaaaa-0000-0000-0000-000000000002';
  perform pg_temp.check('the creator may end their own solo bide',
    (select count(*) from public.bides
      where id = 'aaaaaaaa-0000-0000-0000-000000000002') = 0);
  perform pg_temp.check('ending a solo bide clears its audience',
    (select count(*) from public.participants
      where bide_id = 'aaaaaaaa-0000-0000-0000-000000000002') = 0);

  v_denied := false;
  begin
    update public.participants set status = 'lurking'
     where bide_id = 'aaaaaaaa-0000-0000-0000-000000000001'
       and user_id = '11111111-1111-1111-1111-111111111111';
  exception when check_violation then
    v_denied := true;
  end;
  perform pg_temp.check('status is still a closed set', v_denied);
end
$$;

-- Account deletion (last because it removes shared fixtures)
set session role postgres;

insert into auth.users (id, email) values
  ('44444444-4444-4444-4444-444444444444', 'dave@example.com');

do $$
declare
  v_denied boolean := false;
begin
  perform pg_temp.become('44444444-4444-4444-4444-444444444444');
  perform public.create_bide(
    'dddddddd-0000-0000-0000-000000000001', 'Union Market', 38.908, -76.997,
    null, 'on_time', false, now(), 'walking'
  );
  insert into public.devices (user_id, apns_token)
  values ('44444444-4444-4444-4444-444444444444', 'apns-dave-phone');

  perform pg_temp.become('22222222-2222-2222-2222-222222222222');
  perform public.join_bide('dddddddd-0000-0000-0000-000000000001', 'driving', 'accepted');

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
  perform pg_temp.check('a deleted creator takes their bide''s roster with it',
    not exists (select 1 from public.participants
                 where bide_id = 'dddddddd-0000-0000-0000-000000000001'));
  perform pg_temp.check('a participant of the deleted bide survives',
    exists (select 1 from auth.users where id = '22222222-2222-2222-2222-222222222222'));
  perform pg_temp.check('everyone else survives',
    exists (select 1 from auth.users where id = '11111111-1111-1111-1111-111111111111'));
  perform pg_temp.check('other people''s bides are untouched',
    exists (select 1 from public.bides where created_by = '11111111-1111-1111-1111-111111111111'));

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
