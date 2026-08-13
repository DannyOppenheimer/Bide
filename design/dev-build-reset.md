# Dev build reset

**Temporary. Written to be deleted — see [Removing it](#removing-it).**

`Bide/App/Services/DevBuildReset.swift` gives every new build a genuine clean
slate: it deletes this device's account from Supabase, signs out, and drops
everything held locally. Each trip through Xcode starts at the sign-in screen
with nothing behind it.

## ⚠️ Before it works: push the migration

The account deletion goes through a new database function. Until it exists in
the project, every launch prints a failure and nothing is wiped:

```sh
cd backend
supabase db push          # applies 20260813000000_create_delete_me_function.sql
```

Or paste that migration into the dashboard's SQL editor. Its assertions run
under `backend/run-tests.sh` and pass against real Postgres.

## Why it has to go this far

Neither half of "just clear it" actually works, and both fail quietly:

- **Deleting the app doesn't.** The anonymous identity is a **keychain** item,
  and iOS does not clear keychain items on uninstall. Reinstall and the same
  `auth.uid()` comes back, with the same bides behind it.
- **Signing out doesn't either** — this is the one that catches people. Sign in
  with Apple maps the same Apple ID to the *same* Supabase user, so signing out
  and back in returns you to the same account and the same bides. It looks like
  a wipe and isn't.

Only deleting the account produces a genuinely new identity. That's the whole
argument for the heavier approach.

## What counts as "a new build"

`CFBundleVersion` is no use: nothing bumps it, so every build of this app is
`1`. The part that actually moves is the **modification date of the app's
executable**, which changes every time Xcode compiles and installs.

The fingerprint is `version(build)@mtime`, stored in `UserDefaults.standard`
under `bide.dev.buildFingerprint`. Every launch after the first compares equal
and does nothing.

If the date can't be read, nothing happens. Doing nothing is the safe answer
when the check itself is broken, and this is not an operation to run on a guess.

## What it does, in order

| | |
| --- | --- |
| 1 | `api.deleteMe()` — the account, and by cascade every bide it created, every roster it appeared in, its push tokens. |
| 2 | Ends everything in `Activity<BideActivityAttributes>.activities`, including orphans from the previous install. |
| 3 | `auth.signOut()` — drops the keychain token and resets `hasOnboarded`, which is what returns you to the sign-in screen. |
| 4 | `PendingInviteStore.removeAll()` and every `bide.answer.*` key, in both `.standard` and the App Group. |

### One thing it deliberately does *not* clear

**The display name.** Apple hands a name over exactly once — on the very first
authorisation, ever — so clearing it locally would leave every later build with
no name at all, and tiles reading "Someone wants to go to…". That looks
precisely like the class of bug this file exists to rule out, so introducing it
in the name of a clean slate would be a bad trade. It's one line in
`clearEverythingLocal` if you disagree.

(To get Apple to hand the name over again: Settings → your name → Sign-In &
Security → Sign in with Apple → Bide → Stop Using Apple ID.)

### Where it runs

From `RootView`'s `.task` in `BideApp.swift`, **before** `auth.restore()`. It
needs the stored refresh token to authenticate the delete, and it has to finish
before anything decides which screen to show — otherwise a new build flashes the
home screen on its way to being signed out.

If there is no stored token, there is no account to delete and it skips: asking
for a session there would *mint* an anonymous user purely so the next line could
throw it away.

### When it fails

The fingerprint is recorded only after a successful delete, so an offline launch
tries again next time rather than silently keeping yesterday's account — which
is the exact confusion the file exists to prevent. Both outcomes print:

```
[DevBuildReset] clean slate for build 1.0(1)@1786600000 — sign in again
[DevBuildReset] could not delete the account, retrying next launch: …
```

## Turning it off without removing it

```swift
static let isEnabled = false
```

Two cases need this:

- **Testing persistence itself** — session survival across launches,
  `claimPendingInvites` picking up an invite sent by the previous run. Otherwise
  this deletes the state the test was about.
- **Two devices sharing a bide.** Deleting an account takes the bides it
  *created* with it, for everyone in them. If phone A created the bide, phone A
  wiping means phone B's session vanishes mid-test. Turn it off on the creator,
  or on both.

## The migration is not temporary

`public.delete_me()` outlives this file. An app that lets people make an account
has to let them delete it — App Store guideline 5.1.1(v) — and this is the
mechanism that will serve it. `DevBuildReset` is just its first caller.

It's `security definer` because `authenticated` has no delete privilege on
`auth.users` and must not be given one. That's safe here for the same reason
`is_bide_participant()` is: the function takes its subject from `auth.uid()` and
has no arguments, so there is no value a caller can pass that makes it touch a
different row. `backend/tests/01_rls_tests.sql` asserts that — the account goes,
the cascades follow, everyone else survives, and `anon` can't execute it at all.

Worth knowing: deleting an account deletes the bides that account *created*, for
everybody in them. That's the right answer for a real account deletion — a bide
is the creator's destination, and leaving it standing without them strands the
others in a meetup nobody owns — but it's wider than `leaveBide`.

## Removing it

Three edits, no other call sites:

1. Delete `Bide/App/Services/DevBuildReset.swift`.
2. Delete the `#if DEBUG` block in `RootView` in `Bide/App/BideApp.swift`.
3. `xcodegen generate` — the project lists sources by directory, so a deleted
   file needs a regenerate to leave the target.

Keep `deleteMe()` on `BideAPI` and keep the migration; wire the settings screen
to it when account deletion becomes a real feature.

The stored `bide.dev.buildFingerprint` key is then dead but harmless — one
string in `UserDefaults`, on developer devices only.

It never reaches a release build: the `#if DEBUG` wraps the whole file rather
than the body, and `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` is set on the
Debug configuration alone.
