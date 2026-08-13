# Making a Bide link open the app instead of the web

A Universal Link is an ordinary `https://` URL that iOS hands to your app
instead of to Safari, when — and only when — the app is installed and the
domain has vouched for it. There is no custom scheme in the recipient's face,
no "Open in app?" interstitial, and no web page flashing past on the way.

`https://trybide.app/trip?to=Nats%20Park&…` is that URL. Tapped in a Messages
thread on an iPhone with Bide installed, it opens straight into the app with the
invite attached. Tapped anywhere else it is a real web page, served by
`functions/trip.js`, which is what everyone on Android, on a desktop, or without
the app gets.

## What is already wired up

Three things have to agree, and all three are in the repo:

| Piece | Where | What it says |
| --- | --- | --- |
| Entitlement | `Bide/App/Bide.entitlements` | `applinks:trybide.app` — this app claims that domain |
| Site file | `web/.well-known/apple-app-site-association` | `FYL86KHVDH.app.trybide.bide` may open `/trip` and `/meet` |
| App code | `Bide/App/BideApp.swift` | `onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` reads `activity.webpageURL` |

The two identifiers have to match exactly: the AASA's `appIDs` entry is
`<TEAM ID>.<BUNDLE ID>`, so `FYL86KHVDH` from `DEVELOPMENT_TEAM` in
`project.yml`, then `app.trybide.bide` from `PRODUCT_BUNDLE_IDENTIFIER`. A typo
here fails silently — links simply open the browser, with nothing logged
anywhere you would think to look.

`components` is a list of path patterns. Unspecified parts are wildcards, so
`{"/": "/trip"}` matches `/trip` with any query string, which is what an invite
needs — the query *is* the invite.

## The one step that isn't in the repo

**Associated Domains has to be on for the App ID in Apple's developer portal.**
Xcode adds it when the capability is added to the target, which it already is —
but if signing was ever repaired by hand, check it:

1. Xcode → the **Bide** target → **Signing & Capabilities**
2. **Associated Domains** should be listed, containing `applinks:trybide.app`
3. If Xcode shows a provisioning error, "Try Again" re-registers the capability
   against the App ID

Nothing else needs configuring. There is no key, no secret, and no App Store
listing required — Universal Links work on a development build.

## How iOS actually finds the file

Not from your server, most of the time. Apple's CDN fetches
`https://trybide.app/.well-known/apple-app-site-association` on its own
schedule, and devices ask the CDN:

```sh
curl https://app-site-association.cdn-apple.com/a/v1/trybide.app
```

That is the copy that matters, and it is the reason a change to the file can
take up to 24 hours to take effect on real devices. The requirements are strict
and unforgiving:

- served over `https` with a valid certificate
- `Content-Type: application/json` (set in `web/_headers`)
- **no redirect**, including no `http` → `https` hop
- no `.json` extension on the filename

If the CDN is serving a copy you no longer recognise, it fetched it before you
deployed. Check the CDN response above before debugging anything on device.

For faster iteration, append `?mode=developer` to the entitlement —
`applinks:trybide.app?mode=developer` — and turn on **Settings → Developer →
Associated Domains Development** on the device. The device then fetches the
file straight from the domain and skips the CDN entirely. Take the flag back out
before shipping.

## Testing it, and the three ways it looks broken but isn't

Universal Links are refused in situations that feel like they should work, and
each one has cost somebody an afternoon:

1. **Typing or pasting the URL into Safari's address bar never opens the app.**
   This is deliberate — the address bar is how you get to the website when you
   want the website. It is not a bug in your setup.
2. **A link to `trybide.app` clicked on a page already on `trybide.app` stays in
   the browser.** Same-domain navigation is always the browser's.
3. **A redirect does not carry the claim.** Landing on `/trip` via the 302 from
   `/meet` gets you the web page, not the app. That is why `/meet` is still
   listed in the AASA — old tiles open the app directly instead of bouncing
   through a redirect that would drop them in Safari.

So test it the way a recipient meets it: **send yourself the link in Messages
and tap it.** Long-press also offers "Open in Bide" when the claim is live,
which is a quick way to confirm the association without leaving the thread.

If it opens Safari instead, in order: check the CDN copy above, delete and
reinstall the app (association is evaluated at install), and confirm the team
ID.

## What happens without the app

`functions/trip.js` renders the page — the invite as a tile, with who is going
where and when they are due. It also carries the Open Graph tags that Messages
turns into the preview card in the thread, which is what a shared link *looks*
like before anybody taps it. That card is per-invite text, which is why the
route is a Function and not a static file.

The page's "Open in Bide" button uses the `bide://invite?…` custom scheme rather
than the `https` URL, because of rule 2 above: an `https` link on the page would
never leave the browser. The custom scheme is also how the Messages extension
hands a tapped tile to the container app — see `BideInvite.appURL()`. It is
never sent to another person.
