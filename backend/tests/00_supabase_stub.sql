-- Minimal stand-in for the parts of a Supabase project the migrations rely on.
-- Not shipped — this exists so the real migrations can run against plain
-- Postgres and have their policies exercised.

create schema if not exists auth;

create table auth.users (
  id uuid primary key,
  email text
);

-- Supabase reads the caller's identity out of the request JWT.
create function auth.uid() returns uuid
language sql stable
as $$
  select nullif(current_setting('request.jwt.claims', true)::json ->> 'sub', '')::uuid;
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$$;

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth to anon, authenticated, service_role;
grant select on auth.users to authenticated;
