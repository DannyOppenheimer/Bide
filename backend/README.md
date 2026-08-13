# Bide backend

Supabase: Postgres, row-level security, and APNs routing. No application
server — the iOS app talks to PostgREST directly, and pushes go out from a
service-role job.

## Layout

```
supabase/config.toml                 local dev settings (realtime is off — see below)
supabase/migrations/                 applied in filename order
tests/                               RLS assertions, runnable without a Supabase project
run-tests.sh                         applies the migrations to a throwaway Postgres and asserts
```

## Schema

| table          | what it holds                                                                    |
| -------------- | -------------------------------------------------------------------------------- |
| `bides`        | a destination two people agreed on, when they're due, how they're arriving        |
| `participants` | one row per person per bide: name, travel mode, ETA, the ETA it started from, answer |
| `devices`      | APNs and Live Activity tokens, keyed by APNs token                               |

`bides.scheduled_for` is null for an "as soon as everyone can" bide.
`bides.arrival_style` is `on_time` (everyone lands by the agreed time) or
`together` (nobody leaves until the furthest person does).

`participants.status` is `invited` / `accepted` / `declined` / `arrived`. It
replaced an `arrived` boolean, which could not tell "hasn't answered" from
"said no" — the distinction the tile in a Messages thread is built around.
`participants.mode` is constrained to `walking`, `driving`, `cycling`,
`transit`: exactly the modes the ETA engine can answer for. Cycling is the one
it does not *route* — MapKit has no cycling transport type, so BideKit asks for
a walking route and models the ride from its distance. That stays entirely on
the device; nothing about it reaches this schema.

### The privacy invariant

**No table stores a participant's location, and none ever will.**

The only coordinates in the schema are `bides.lat` / `bides.lng`, which are the
*destination* — a place both people already agreed on in a text thread, not a
person. What a participant reports is `eta_timestamp`: an arrival timestamp,
computed on-device by BideKit's ETA engine.

This is asserted, not just documented. `tests/01_rls_tests.sql` fails the build
if a column matching `lat|lng|coord|geo|location|position|heading|speed|accuracy|altitude`,
or of type `geography`/`geometry`/`point`, ever appears on `participants` or
`devices`.

## Row-level security

Three rules:

- **Read a bide only if you're a participant in it.**
- **Write only your own participant row.**
- **Edit a bide if you're in it** — where it's going and when it's due, for
  everybody. A solo bide is the exception: only its creator may move it, since
  anyone else in one is an audience watching somebody travel. What may change is
  a column-level `grant update (destination_name, lat, lng, scheduled_for)`, so
  identity and `arrival_style` are refused by Postgres rather than by a client
  remembering not to send them.

`anon` has no privileges on any table — every path requires a signed-in user.

Two things are worth knowing before editing the policies:

1. **`is_bide_participant()` is `security definer` on purpose.** The obvious way
   to write the `participants` read policy is "you may read a participant row if
   you're a participant of the same bide", but that subquery reads
   `participants`, which re-runs the policy, and Postgres aborts with `infinite
   recursion detected in policy`. Running the membership lookup as the function
   owner breaks the cycle. It's safe because the function only ever answers
   "is the *caller* in this bide?" — it takes the caller from `auth.uid()`, not
   from an argument.

2. **Creating a bide has to write two rows in one transaction.** A bide with no
   participants is unreadable even to the person who just created it, since the
   read policy requires membership. `create_bide()` inserts the bide and the
   creator's participant row together. Note the ordering inside it: the `INSERT`
   deliberately has no `RETURNING`, because `RETURNING` is checked against the
   read policy and the caller isn't a participant yet at that point.

A bide is reachable only by someone who was sent its id in a tile URL and then
joined. The URL is the capability.

3. **`delete_me()` is `security definer` for the same reason, and safe for the
   same reason.** GoTrue has no client-callable account deletion — the admin
   endpoint needs the service_role key, which cannot ship in an app — so
   deleting your own account has to be a function. `authenticated` has no delete
   privilege on `auth.users` and must not be given one. The function takes its
   subject from `auth.uid()` and has **no arguments**, so there is no value a
   caller can pass that makes it touch a different row.

   Everything follows through the existing cascades: `bides.created_by`,
   `participants.user_id` and `devices.user_id` all reference
   `auth.users (id) on delete cascade`. Note the reach — deleting an account
   deletes the bides that account *created*, for everybody in them, which is
   wider than leaving a bide.

## Realtime is off

`config.toml` disables realtime, and that's deliberate — the Messages extension
can't hold a websocket, run in the background, or register for push. Delivery is
APNs, sent by the container app's service-role job. A realtime subscription
would work only while someone happened to be looking at the app, and would
quietly become the thing the feature depended on.

## Running the tests

Needs Docker. Does *not* need a Supabase project or the Supabase CLI —
`tests/00_supabase_stub.sql` stands in for the `auth` schema, `auth.uid()`, and
the `anon`/`authenticated` roles.

```sh
./run-tests.sh
```

It applies every migration in order, then exercises the policies as three real
users: a creator, someone who joins, and an outsider who holds no invite.

## Applying to a real project

```sh
brew install supabase/tap/supabase
supabase link --project-ref <ref>
supabase db push
```

The client reads the project URL and anon key from `SupabaseConfiguration` — see
`BideKit/Sources/BideKit/APIClient/`.
