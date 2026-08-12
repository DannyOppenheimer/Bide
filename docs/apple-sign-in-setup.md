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

Dashboard → your project → **Authentication** → **Sign In / Providers** →
**Apple** → toggle on.

Two fields matter, and only one of them is required for Bide:

| Field | What to put | Where it comes from |
| --- | --- | --- |
| **Client IDs** (required) | `app.trybide.bide` | The app's bundle identifier — the `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`. This is the `aud` claim in the token, and Supabase rejects tokens whose audience isn't on this list. Comma-separate if you ever add more. |
| **Secret Key (for OAuth)** | leave empty | Only used by the web redirect flow. Bide never touches it. |

Click **Save**. That's the whole server-side setup.

### While you're there

**Authentication → Sign In / Providers → Anonymous sign-ins** must stay on —
"Use without signing in" depends on it. If it's off, that path fails with a
422 and the message "Anonymous sign-ins are disabled".

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
