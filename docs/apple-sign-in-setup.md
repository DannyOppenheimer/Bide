# Turning on Sign in with Apple

The code is finished — `AuthController` and `BideAuthProvider` do the whole
native flow. What's left is configuration in two places: Apple's developer
portal and the Supabase dashboard. This walks through every value you need and
exactly where it lives.

Good news first: **the native iOS flow needs no secrets in the app.** There is
no `.p8` key, no client secret, no Services ID. Apple's `ASAuthorizationAppleIDProvider`
mints an identity token on-device, and Supabase verifies it against Apple's
public keys. The Services ID / private key dance is only for the *web* OAuth
flow, which Bide doesn't use.

## 0. The bundle ID, and one that is gone for good

The app ships as **`app.trybide.bide`**, matching the `trybide.app` domain the
tile URLs already point at.

An earlier identifier, `com.dannyoppenheimer.bide`, **cannot be used and cannot
be recovered.** It once backed an App Store Connect app record, and deleting
that record does not release the bundle ID: Apple keeps it claimed forever, so
no new app record can use it and the identifier itself can no longer be deleted
from the portal. It will sit in the identifier list doing nothing.

The lesson is narrow and worth remembering: **registering an identifier in the
developer portal is free and reversible; creating an App Store Connect app
record with it is neither.** Don't create the App Store Connect record until
the bundle ID is the one you intend to ship.

## 1. Xcode — let it create the App ID

Do **not** pre-create `app.trybide.bide` in the developer portal by hand. An
App ID that Xcode creates gets its capabilities configured the way Xcode
expects; one created by hand needs every sub-option set exactly right, and
getting it wrong produces errors that don't say what's wrong — most memorably
`The capability associated with "APPLE_ID_AUTH" could not be determined`, which
is Sign in with Apple registered without its "Enable as a primary App ID"
setting.

1. Open `Bide.xcodeproj`.
2. Select the **Bide** target → **Signing & Capabilities**.
3. Confirm **Automatically manage signing** is on, and that **Team** reads
   "DANIEL ASHTON OPPENHEIMER" *without* a "(Personal Team)" suffix. If it
   still says Personal Team, Xcode has a stale copy of the account: remove the
   Apple ID under Xcode → Settings → Accounts, add it back, and relaunch Xcode.
   A personal team cannot use Sign in with Apple at all, and the error says so.
4. Click **Try Again** on the signing status. Xcode registers the App ID, both
   extension App IDs, the App Group, and the profiles.
5. Repeat for the **BideMessages** and **BideWidgets** targets. They need the
   App Group only — not Sign in with Apple.

> Bide works without the App Group; it just stops the Messages extension
> knowing your display name, so tiles say "Someone wants to go to…" instead of
> your name. Sign in with Apple genuinely requires its capability.

## 2. Supabase — enable Apple as a provider

**This is the step that is easy to skip and impossible to guess from the app.**
Until the toggle is on, every sign-in fails with a 400 no matter how correct
everything else is.

Dashboard → your project → **Authentication** → **Sign In / Providers** →
**Apple** → toggle on.

Two fields matter, and only one of them is required for Bide:

| Field | What to put | Where it comes from |
| --- | --- | --- |
| **Client IDs** (required) | `app.trybide.bide` | The app's bundle identifier — the `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`. This is the `aud` claim in the token, and Supabase rejects tokens whose audience isn't on this list. Comma-separate if you ever add more. |
| **Secret Key (for OAuth)** | leave empty | Only used by the web redirect flow. Bide never touches it. |

Click **Save**. That's the whole server-side setup.

### Check it took, without building anything

The project publishes which providers are on. No auth needed beyond the
publishable key that already ships in `BideBackend`:

```sh
curl -s -H "apikey: sb_publishable_WZZX2ZYV5iy0PCM0aY0cvA_M05uccNX" \
  https://uglncucsqhqtvzkconpq.supabase.co/auth/v1/settings | python3 -m json.tool
```

`external.apple` must be `true`. If it reads `false`, the toggle above did not
save, and no amount of work on the device will change the outcome — the app
gets a 400 on every attempt. `external.anonymous_users` must be `true` as well;
"Use without signing in" is that flag.

### While you're there

**Authentication → Sign In / Providers → Anonymous sign-ins** must stay on —
"Use without signing in" depends on it. If it's off, that path fails with a
422 and the message "Anonymous sign-ins are disabled".

## 2a. The scope that isn't optional

`AuthController.configure` asks Apple for `[.fullName, .email]`. The email is
not wanted for anything — nothing in Bide ever writes to it — but it cannot be
dropped: Apple puts an `email` claim in the identity token **only when the
scope was requested**, and Supabase refuses to create a user from a token
without one. It refuses with a 400, which the client reads as "not
authenticated", so the symptom is a sign-in that fails every time on a
perfectly configured project while the app says "You're signed out."

This cost a debugging session once. Don't trim that scope.

"Hide My Email" is fine — Apple still sends a claim, just a private relay
address.

## 3. Test it

Sign in with Apple does not work in the simulator with a signed-out Apple
account, and it never works in an unsigned build. Run on a device:

```sh
xcodegen generate
xcodebuild -scheme Bide -destination 'generic/platform=iOS' build
```

Then Product → Run on a real iPhone. Tap **Sign in with Apple**. Apple returns
your name **only on the very first authorisation** — `AuthController` catches
it there and saves it, so if you want to test that path again, revoke Bide
under Settings → your name → Sign-In & Security → Sign in with Apple.

### When it fails, read the red line

The app used to answer every server refusal with "Apple couldn't sign you in.
Try again", because `mapAuthFailure` folded all of 400/401/403 into
`notAuthenticated`. It no longer does: on the sign-in paths the server's own
message survives, and it names its own fix. The three worth recognising:

| What you see | What it means |
| --- | --- |
| "Unsupported provider: Provider is not enabled" | Step 2 above was never done. |
| "Unacceptable audience in id_token" | Provider is on, but `app.trybide.bide` isn't in its **Client IDs**. |
| "Signups not allowed for this instance" | Anonymous sign-ins are off, and this is the *other* button failing. |

"Apple couldn't sign you in. Try again" now means only what it says: a 4xx with
no message in it at all.

## What is deliberately not wired up

- **Account linking.** Signing in with Apple after using the app anonymously
  signs you in *as* the Apple user; bides created anonymously stay with the
  anonymous identity. Merging them is a visible product decision, not
  something to do quietly — see the comment on
  `BideAuthProvider.signInWithApple`.
- **APNs.** Push updates for Live Activities, and "time to leave" reminders to
  someone whose app isn't open, need an APNs key (`.p8`, Key ID, Team ID).
  Today the app starts and updates its Live Activity locally, and refreshes
  other people's ETAs by polling while it's on screen. That's the one file
  that changes: `Bide/App/Services/LiveActivityController.swift`.
