This file will hold documentation for all bugs and unintended parts of the app:


1. It looks like sign in with apple is currently broken. It opens up the dialog and I can sign in, but then my app just shows a red error message below saying "You're signed out. Sign in to keep sharing your ETA". It does not properly bring you to the next screen. Also the console shows:
nw_protocol_instance_set_output_handler Not calling remove_input_handler on 0x10b230f00:udp
2. When the user presses Use without sign in, sometimes it fails and displays a red error message saying "Couldn't reach Bide. Please check your connection" along with:

Task <5E947684-2FC6-46D7-B8C0-7534C9EFA9EF>.<3> finished with error [-1005] Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost." UserInfo={_kCFStreamErrorCodeKey=-4, NSUnderlyingError=0x10b269e30 {Error Domain=kCFErrorDomainCFNetwork Code=-1005 "(null)" UserInfo={NSErrorPeerAddressKey=<CFData 0x10b338190 [0x1f6d94d40]>{length = 16, capacity = 16, bytes = 0x100201bbac4095f60000000000000000}, _kCFStreamErrorCodeKey=-4, _kCFStreamErrorDomainKey=4}}, _NSURLErrorFailingURLSessionTaskErrorKey=LocalDataTask <5E947684-2FC6-46D7-B8C0-7534C9EFA9EF>.<3>, _NSURLErrorRelatedURLSessionTaskErrorKey=(
    "LocalDataTask <5E947684-2FC6-46D7-B8C0-7534C9EFA9EF>.<3>"
), NSLocalizedDescription=The network connection was lost., NSErrorFailingURLStringKey=https://uglncucsqhqtvzkconpq.supabase.co/auth/v1/token?grant_type=refresh_token, NSErrorFailingURLKey=https://uglncucsqhqtvzkconpq.supabase.co/auth/v1/token?grant_type=refresh_token, _kCFStreamErrorDomainKey=4}

3. "Couldn't reach Bide. Please check your connection" sometimes also appears after pressing continue without signing in and reloading the page.
4. When going on with continue without signing in and creating a solo bide, it just shows as "someone". It should say "You" instead
5. When the user goes to create a bide request, the icon in the "+" menu is sometimes showing as gray, not as the black + white logo.
6. When the user goes to create a bide request, it is showing a weird collapsed version of the creation menu that says "Where are we going" and "Tap to set up a Bide" along with teh vertical aux logo. This is wrong. Instead, we should just show exactly what the xpanded menu looks like, just cut off at the bottom. When the user goes to click on a menu, that's when it expands to full screen, and they can actually start editing stuff. There should be no animation played of vertical to horizontal, just always horizontal
7. The send request mini tile looks good on teh senders end, except for one quirk. There is our badge/logo that hangs out in the top left corner of the tile, which covers up our logo a little bit. Let's bump down all the tile content to avoid getting covered up by this badge.
8. After a sender sends a request tile, and is waiting for responses, it is cut off: waiting for re... Instead, put overflowed cotnent on a new line to be able to read everything
9. When a person creates a bide with teh creation menu and clicks send, it automatically creates a bide session for themselves. For bides that are meant to be sent to others or groups, lets do the following: ask them if they want to override a current bide session (if applicable). If it is appicable and they say yes, delete the old one but don't create the new one yet. Once one person accepts, THEN create a session for the sender.
10. It looks like once someone gets past the main screen by clicking continue without signing in, there is no way to go back. Add a back button to get to the landing page for those that do not sign in, so they have the opportunity to do so.
11. It looks like when someone tries to send a Bide by imessage without being signed it, it does correctly redirect them to the app intead of bringing them through the creation flow, but if they click continue without signing in, then it still lets them create bides, which is not the correct way. Only signed in users should be able to send imessage bides.
12. Not sure if it matters, but when the date picker is selected, the console is spammed with:
nw_protocol_instance_set_output_handler Not calling remove_input_handler on 0x10923f5c0:udp

---

# Resolutions

Every item above except 12 was a real defect and is fixed. 12 is not a Bide
bug — see below.

## 1 — Sign in with Apple

`AuthController.configure` asked Apple for `[.fullName]` only. Apple puts an
`email` claim in the identity token **only when the `email` scope was
requested**, and Supabase refuses to create a user from a token without one —
with a 400, which `mapAuthFailure` reads as `.notAuthenticated`, whose copy is
"You're signed out. Sign in to keep sharing your ETA." So sign-in failed every
time, on a correctly configured project, and said something unrelated about it.

Two changes: the scope is now `[.fullName, .email]`, and a failure *during*
sign-in gets its own wording rather than borrowing the "your session lapsed"
copy. Server messages come through verbatim, because the ones that reach that
path (a provider that isn't switched on, a bundle ID missing from the Client
IDs list) name their own fix.

"Hide My Email" is unaffected — Apple still sends a claim, just a private relay
address, and nothing here ever writes to it.

## 2 and 3 — "Couldn't reach Bide"

`-1005` with `_kCFStreamErrorCodeKey=-4` on the *first* request after the app
has been idle is a pooled connection that the far end closed while nobody was
looking. The request fails before anything is written to the socket, so the
user was never offline and the advice to check their connection was simply
wrong.

`URLSessionTransport` now replays a request once, and only for
`.networkConnectionLost`. A genuine outage still surfaces on the first attempt,
so "you're offline" stays fast and honest. Safe to replay: every id this client
sends is generated on the client, so a request that *did* land the first time
collides rather than duplicating. Covered by `URLSessionTransportTests`.

## 4 — "Someone" in your own roster

`BideFormat.name` had no way to know it was looking at the reader, so an
anonymous user — who by definition has no display name — appeared as the
placeholder. `name`/`initial` now take an optional `me:`, and "You" wins even
over a name that is set: a roster is read to find out where everyone *else* has
got to. Threaded through `ParticipantTile`, `BideSessionCard`, and
`ActivityParticipant`, so the lock screen agrees with the app.

## 5 — Grey icon in the "+" drawer

The artwork was there all along and correct. `ASSETCATALOG_COMPILER_APPICON_NAME`
was set for the **Bide** target but never for **BideMessages**, so `actool`
compiled the catalogue without ever naming that set as the target's icon, and
nothing wrote `CFBundleIcons` into the `.appex`. Messages drew its placeholder.
One line in `project.yml`; the built extension now carries `CFBundleIcons` and
the eight drawer sizes.

## 6 — The collapsed creation menu

`CompactPromptView` is gone. The drawer now renders the same `BidePlanForm` the
full height renders, laid out at its natural size and cropped by the drawer;
tapping anywhere asks Messages for the room. The form is inert while it's a
preview — half a date picker is not something to let anyone press — with one
transparent target over it. The mark is horizontal in both states and no longer
morphs, which is what made the drawer read as a different screen rather than
the top of this one.

## 7 and 8 — The tile

Content sits `BideMetrics.tileBadgeClearance` lower, so the badge Messages
stamps on the top-left corner stops covering the mark. The title and subtitle
now grow downwards instead of truncating, so "Today · 3:30 PM • Waiting for
replies" wraps rather than ending at "Waiting for re…".

## 9 — The sender's session

Sending a tile is a question, not a commitment. `BideStore.stage` now records
the invite in `PendingInviteStore` instead of creating anything, and
`claimPendingInvites` — run on every refresh — turns it into a real session the
moment somebody accepts.

`join_bide` is the test as much as the action: the bide row does not exist until
a recipient accepts (their app creates it on the way in), so a join that comes
back `notFound` means nobody has answered yet, and one that succeeds means
somebody has. The clash *prompt* still happens at send time, on purpose — the
user is asked while they are still looking at the thread, and saying yes drops
the old bide immediately, exactly as asked.

The sender's own bubble no longer records a local "accepted" answer either, so
their transcript says "Waiting for replies" — which is now both what it shows
and what the app is actually doing.

Solo bides and calendar-created bides are untouched: they have nobody to wait
for, so they are still created immediately.

Known edge, left alone deliberately: two *staged* invites that clash with each
other aren't compared, because neither has a travel window until someone
answers. Clashes with real sessions are checked as before.

## 10 — No way back

`AuthController.returnToSignIn()` and a chevron in the header, shown only to
users who aren't signed in with Apple. Deliberately **not** `signOut()`: that
throws away the refresh token, and for an anonymous user the refresh token *is*
the account — dropping it there would silently strand every bide they made
while looking around. Tapping "use without signing in" again lands them back on
the same identity.

## 11 — Anonymous users could send tiles

`BideProfileStore.isSignedInWithApple` is written by the app into the App Group
and read by the extension, which has no identity of its own. The compose form is
replaced by a "Sign in to send a Bide" screen that opens the app; `BideStore`
refuses the `action=create` hand-off independently, so the rule holds even if
the URL arrives some other way. Accepting a tile is unaffected — that only
commits the device that does it.

## 12 — nw_protocol console spam

Not a Bide bug and nothing to fix. `nw_protocol_instance_set_output_handler Not
calling remove_input_handler on …:udp` is emitted by Network.framework inside
`libnetwork`, one line per UDP flow being torn down. Nothing in this repository
calls it and no app-level API can silence it. The date picker isn't the cause —
it just forces a redraw at a moment when QUIC connections happen to be closing,
which is also why the same line appears in the sign-in log in item 1. `OS_ACTIVITY_MODE=disable`
in the scheme's environment hides it if it becomes annoying, at the cost of
every other OS log.

---

# Round two

Reported after the fixes above shipped.

13. Sign in with Apple still fails — the app shows "Apple couldn't sign you
    in. Try again."
14. The Bide icon in the Messages "+" drawer is still the grey placeholder.
15. The live update cards never say where you are going.
16. The Live Activity on the Lock Screen is cut off top and bottom — the mark
    goes off the top, the ETAs off the bottom.
17. Old bide sessions survive between runs of Xcode.

## 13 — Apple sign-in: the toggle was never flipped

The client is correct and always was. The Supabase project has the Apple
provider **switched off**, which the project will tell anyone who asks:

```sh
curl -s -H "apikey: <publishable key>" \
  https://uglncucsqhqtvzkconpq.supabase.co/auth/v1/settings
```

came back with `"apple": false`. GoTrue answers that with a 400 —
"Unsupported provider: Provider is not enabled" — and `mapAuthFailure` folded
*every* 400 into `.notAuthenticated`, so the one sentence naming the fix was
thrown away and replaced with "try again". Two rounds of debugging went into a
message the server had already sent.

The code fix is that discarding. `authenticate` now says what a 4xx means for
the request it just made: `.identityLost` for a refresh token the server no
longer knows, where there is genuinely nothing to explain and
``currentSession`` needs `.notAuthenticated` to mint a new identity; and
`.explained` for a token the server was just handed and refused, where the
message *is* the response. Sign in with Apple and anonymous signup are both
`.explained`. Covered by three cases in `BideAuthProviderTests`, including the
one that keeps the refresh path honest: a 4xx with no message still reads as
signed out.

**The toggle still has to be flipped** — Dashboard → Authentication → Sign In /
Providers → Apple, with `app.trybide.bide` in Client IDs. `docs/apple-sign-in-setup.md`
now leads with that and has the curl above for confirming it. Nothing on the
device can substitute for it.

## 14 — The drawer icon: the build is right, the phone is stale

Nothing left to fix in this repository. The built extension carries the icon:

```
$ plutil -extract CFBundleIcons xml1 -o - …/BideMessages.appex/Info.plist
CFBundlePrimaryIcon → CFBundleIconFiles →
  iMessage App Icon60x45, 67x50, 74x55, 27x20, 32x24
```

and the eight PNGs sit beside it in the bundle. `ASSETCATALOG_COMPILER_APPICON_NAME`
from the previous round did its job.

What's left is the device. Messages caches the app-strip icon per extension,
and the *first* build installed on this phone had no `CFBundleIcons` at all —
so what got cached was "this one has no icon", and reinstalling over the top
doesn't dislodge it. Delete Bide from the phone, **restart the phone**, then
run again. The restart is the part that matters; without it the cache usually
survives the reinstall.

## 15 — The destination was nowhere

`BideActivityAttributes` carried `destinationName` and the Lock Screen view
never read it — it took `ContentState` alone. The in-app card had the same
hole for a different reason: `headline` says "Leave in 10 minutes" from the
moment there's an ETA, and only mentions the place in the one fallback nobody
reaches.

The destination is now a line of its own on both, so it stops depending on the
headline's mood — under the headline on `BideSessionCard`, and up in the header
row beside the mark on the Lock Screen, where it also earns its keep as chrome.
The Dynamic Island's expanded view gets it too.

With the place always on screen, `BidePlanner.headline`'s "Heading to <place>"
fallback would only have said it twice, so it now says the thing the
destination can't: "Nobody has set off yet".

## 16 — 202 points into a 160-point box

iOS gives a Lock Screen Live Activity a fixed box —
`BideMetrics.liveActivityMaxHeight`, 160pt — and *clips* what overflows rather
than scaling it. It clips from both ends, which is why the mark went off the
top and the ETAs off the bottom while the middle looked perfectly fine.

Measured, not guessed. The old layout came to **202pt**: 32 of padding, a
three-line brand header, and 52pt avatars over two lines of text each. The 42pt
it lost is exactly what was missing.

The new one is 156pt at 40pt avatars. The savings are the brand header, which
was three stacked lines of chrome — mark, wordmark, then the LIVE pill — and is
now one row carrying the mark, the destination, and the pill together.

`ViewThatFits` picks between 40 / 32 / 24pt avatars against a
`frame(maxHeight:)` of the budget, so Dynamic Type takes the room out of the
avatars instead of off the ends. Every rung measures under the budget with four
people in the roster.

## 17 — A bide was forever

`isComplete` is the ending the model was built around, and it needs *every*
participant marked `arrived` — which needs their app open and tracking at the
far end. People put the phone in a pocket instead, so most bides never reach
it, and `fetchMyBides` returns everything else for good.

`BideState.isExpired(now:)` is the duller ending that actually fires: six hours
past the time the bide was aiming for, or past creation for an asap bide, which
has no other clock. Long enough that a table booked for 7pm is still live at
midnight; short enough that nothing survives the night. `refresh()` filters on
it alongside `isComplete`.

Worth being precise about *why* they came back, because it isn't a cache: the
anonymous identity is a keychain item, iOS does not clear keychain items when
an app is uninstalled, and the bides are rows on a server. So deleting the app
and reinstalling resumes the same user and pulls the same bides back down. Only
`signOut()` forgets it. The comments claiming the identity dies with the app
were wrong and have been corrected.

---

# Round three

18. The "+" drawer icon is *still* the grey placeholder.
19. Tapping the collapsed drawer cross-fades into the full screen; swiping it
    up slides cleanly. Same destination, two different animations.
20. Sending a Bide always jumps to the app, even with no clash to resolve.
21. The vertical mark on a sent tile looks wrong. Horizontal everywhere.
22. The Live Activity now has a band of black under it — the opposite of 16.
23. The default time should read "Now", and open a picker at the current time.

## 18 — The drawer icon, again

**Nothing left in this repository is wrong, and that is now established rather
than assumed.** For the record, everything that could be checked was:

| | |
| --- | --- |
| `CFBundleIcons` in the `.appex` | present, all five drawer groups |
| The eight loose PNGs | present, correct pixel dimensions |
| Alpha channel | none — an icon with alpha is rejected |
| Container app's own icon | present and valid |
| `actool` invocation | `--app-icon "iMessage App Icon" --stickers-icon-role extension`, correct |
| `actool` warnings | **none** |

One thing did change: the icon set declared `29x29` slots for iPhone and iPad,
which are not slots an iMessage App Icon set has. `actool` ignored them
silently — they never reached `Assets.car` or `CFBundleIconFiles` — so they
were dead files rather than the cause. They're gone, and the catalogue is now
byte-for-byte the shape Xcode's own template produces. If some ambiguity in
that set was the trigger, this removes it; the honest expectation is that it
won't be.

Which leaves the device. This is a known and unresolved iOS bug with several
Apple Developer Forums threads and no fix in any of them ([iOS 17][f1],
[iOS 16.4][f2]) — and the reporters describe exactly the symptom here, "the
default white grid-lines styled icon". The common thread is an extension that
was *first* installed without a valid icon, which is what happened on this
phone: the build before round one's `ASSETCATALOG_COMPILER_APPICON_NAME` fix
had no `CFBundleIcons` at all. Messages cached "no icon" and reinstalling over
the top does not dislodge it.

The sequence that clears it, in order, all three parts:

1. Delete Bide from the phone.
2. **Restart the phone.** This is the part that matters and the part that gets
   skipped; without it the cache generally survives.
3. Install again.

If it survives that, it is worth checking Messages → the app strip → **Edit**,
since an app can be toggled off there, and then filing feedback with Apple.

[f1]: https://developer.apple.com/forums/thread/746747
[f2]: https://developer.apple.com/forums/thread/728937

## 19 — Tap faded, swipe slid

`expandable` returned two different view trees from an `if isExpanded` — one
plain, one with `.fixedSize`, `.allowsHitTesting(false)` and a tap target. An
`if`/`else` gives SwiftUI two *identities*, so changing which branch is live is
a remove and an insert, and the default transition for that is opacity. Swiping
hid it because Messages was dragging the sheet at the same time and the
cross-fade happened under cover of a bigger movement; tapping had nothing to
hide behind.

One view now, in both heights. Everything that varies is a modifier *value* —
`allowsHitTesting(isExpanded)` — rather than a different tree, so there is
nothing to fade between and both gestures move the same content.

## 20 — Thrown out of Messages to be asked nothing

`stage` opened the container app on every send. The hand-off existed for the
clash check, and the check was in the wrong place twice over: it dragged the
user out of the thread they were writing in, to look at a screen that nine
times in ten had nothing to say — and when it *did* have something to say, it
was asking them to give up a real session for a hypothetical one, because a
sent tile is a question and nobody has answered it yet.

The extension now records the invite in the App Group's `PendingInviteStore`
and stays put. That store was already shared, so this is one line doing what
the round-trip was doing, without the round trip.

The check moves to `warnIfClashing`, called from `claimPendingInvites` — the
moment someone accepts and the question becomes a commitment, which is the
first moment there is anything real to weigh. "Continue" still drops the bides
it clashes with. "Cancel" now keeps both, which is the honest option here and
wasn't at send time: somebody has already accepted this one, and quietly
walking out of it would strand them.

`BideStore.stage` is gone. The `action=create` URL is kept but now records a
pending invite rather than creating anything, so a URL from an older build
lands somewhere sensible instead of being mistaken for an acceptance.

## 21 — The vertical mark

Gone from the product. It only ever existed as the collapsed half of the morph
between the two forms, and that animation was removed in round one (item 6) —
which left a second logo with no reason to exist and, on the tile, a lone
glyph out to the left of centred text.

Every tile now leads with the horizontal mark, centred, above the text. The
travel-mode icon that used to share that left column sits inline with the
countdown instead, so it still says how you're getting there without needing a
column of its own. `BideTileView.Glyph` is gone; the mode is a plain
`TravelMode?`, and it now carries the *actual* mode from `LocalAnswer` rather
than the hardcoded `.driving` it had before.

## 22 — The opposite problem

The box is fixed, and the fix for 16 only solved half of it: the layout came to
156pt in a 160pt box, so it stopped being clipped and started being 4pt short —
2pt of background above and below, which is the band that showed.

Fitting was never the goal; *filling* is. The `ViewThatFits` ladder is gone,
and the space between the header, the headline and the roster is `Spacer`s
rather than fixed spacing. They take whatever is left over, so the layout is
exactly the height of its box — measured at 160.0pt with two, three, or four
people — and they collapse to their `minLength` first when Dynamic Type wants
the room, with `minimumScaleFactor` on the headline behind that.

That also makes the layout right at *any* box height from about 144pt up, which
matters because 160 is Apple's published figure rather than one this code can
measure.

## 23 — "Now"

The chips read "ASAP" when no time was set, which named the internal state
rather than the plan, and the drafts all started at the next quarter hour — so
the common case, leaving now, took two taps to get back to.

A fresh `BidePlanDraft` now has no time, and the chips read "Today" and "Now".
Tapping one opens the picker at the current time rather than the rounded
quarter hour: the chip said "Now", and a picker that opens somewhere else has
changed the plan before the user touched it. The moment is captured once, in
`@State`, so the wheel can't drift under their finger. `BidePlanDraft.defaultTime`
survives only as a rounding helper for tests.

---

# Round four

24. The picker always shows "Leave now — as soon as everyone can", even after
    a later time has been chosen.
25. Date and time chips are white in Messages and grey in the app.
26. The Live Activity says "Leave 28 minutes" — no "in" — and counts *up*,
    while the app says "Leave now"; the lock screen says someone is 10 minutes
    away while the app says 9.
27. In the Dynamic Island, the gap between the timer and the right edge is
    bigger than the gap between the mark and the left edge.

## 24 — A button that read as a caption

Shown unconditionally, so after picking 6pm tomorrow it sat under the wheel
still saying "Leave now", which reads as a statement about the plan rather than
a way to change it — and a wrong one.

It now appears only while the plan actually is "now": `scheduledFor == nil`, or
a selection in the same minute the sheet opened in. Scrolling the wheel back to
the current minute brings it back, so it is never a one-way door.

## 25 — Two chips, one control

`Style.send` used `.solid`. Both are `.subtle` now. Beyond the inconsistency,
white chips sat a step away from the white Send button underneath them, so the
compose sheet read as having two primary actions.

## 26 — Three separate bugs wearing one coat

**"Leave 28 minutes".** `Text(_, style: .relative)` renders the *distance* to a
date — "28 minutes" — and nothing else. The view wrote `"Leave \(…)"` around
it, so the preposition was never there to begin with. Now `"Leave in \(…)"`.

**Counting upwards.** The same style counts **up** once the date is behind it,
turning a departure into a stopwatch. And for an asap bide the departure is
`now` by definition — `BidePlanner` sets `target = now + myTravelTime` and
`departure = target - myTravelTime` — so it is behind the moment it is written.
This was the normal case, not an edge one. A countdown is now only rendered
while the departure is more than a minute ahead.

**"Leave now" here, "Leave 28 minutes" there.** The two surfaces disagreed
because the lock screen wasn't using the sentence the app had computed. The
view reached past `ContentState.headline` — `BidePlanner.headline`, which knows
the words for every case, including "Leave now" — and rendered a raw relative
date whenever a departure existed at all. It now falls back to that string for
everything except a live future countdown, so the two can only agree.

**10 minutes against 9.** `ActivityParticipant.line` was a *string*, rendered
when the app last pushed and frozen after that, while the app's own roster
recomputes every second off a ticking clock. So they were both right about
different instants. `ActivityParticipant` now carries `eta: Date?` as well, and
`ParticipantTile` renders the date live when it is in the future — on both
surfaces, through the same code, so they cannot drift. `line` stays as the
fallback for "Waiting…", "Arrived", "Not coming", which are statements rather
than countdowns and must never be handed a clock.

**And what neither surface could say.** `staleDate` was `nil`, so iOS was never
told the content could expire. Other people's ETAs only move while this app is
running and polling, so a phone in a pocket for half an hour left a lock screen
confidently asserting where everyone was half an hour ago, with nothing to
mark it as old. It's now 15 minutes — comfortably past the slowest re-anchor
cadence (10 minutes, walking), so normal tracking never trips it — and past
that, iOS dims the activity and shows it as out of date.

## 27 — The island's right margin

`compactTrailing` had `.frame(maxWidth: 52)` around a timer that renders at
about 30pt, and centred it there. The 11pt of leftover on each side became
visible padding between the digits and the edge of the island, while the mark
opposite sat flush — so one side had the system's margin and the other had the
system's margin plus ours.

The frame is gone; the text sizes to its content and both sides get the same
margin. `monospacedDigit()` keeps that width from twitching once a second as
the digits change. The trailing slot also stops showing `.timer` once the
departure has passed — same reason as the headline, it would count up — and
says "now" instead.

---

# Round five

28. Once past the landing page, pulling to refresh gives "Couldn't reach Bide.
    Check your connection" — and if the cards are live, why is there a refresh
    at all?
29. Can the display name be set automatically from the Apple account name?
30. A solo bide for "now" says "Leave now" at the top and then counts down in
    green underneath. What does that mean? It can't be my ETA — I haven't
    moved. It should say "Leave now" until I actually leave a radius around
    where I made the bide, then "On the way"; the green text should read
    ETA / Time, live from my location rather than counting down on its own; and
    the pill around the front camera should show my ETA, not "Now". The same
    goes for iMessage and group bides, and for "arrive at the same time":
    everyone else waits — "waiting…" — until the person with furthest to go
    actually leaves, and only then does everyone get a live "Leave in X" off
    that person's real ETA, turning into "Leave now" as they close the gap.

---

# Resolutions

## 28 — A refresh that could only make things worse

Two answers, and the second one is the real fix.

**Why it failed.** `APIError.transport` renders as "Couldn't reach Bide. Check
your connection", and `URLError(.cancelled)` is a `transport` error — so a
request that was *cancelled* said the network was down. Pull-to-refresh calls
the same `refresh()` the 30-second poll is already calling, and the two run
concurrently on the same session; whichever loses gets torn down, and its
cancellation was reported as an outage. `APIError.isCancellation` now names
that case, and `BideStore` never turns one into a message. A cancelled request
is this app tearing down its own work; there is nothing for the user to check.

**Why there is nothing to refresh.** The question in the report is the right
one. The cards count their own clocks off a one-second tick, and `BideStore`
re-reads everyone's ETAs every 30 seconds for as long as the screen is up.
Pull-to-refresh added no information — only a second, redundant fetch and a way
to collide with the first. It's gone. The one moment the poll can't cover is
the app coming back from the background, where it doesn't run at all, so
`scenePhase` becoming `.active` triggers a refresh.

## 29 — The name Apple says exactly once

Apple puts a person's name in `ASAuthorizationAppleIDCredential.fullName` on
the **first** authorisation of an app by an Apple ID, and never again — not in
the identity token, not on any later sign-in. The app was already reading it
there, but only into the App Group and the participant rows, both of which are
gone after a reinstall. And bug 1 of round one means the very first
authorisations *failed at Supabase* while consuming that one-time offer, so for
anyone who signed in on those builds the name is simply gone.

Three changes:

- `BideAuthProvider.record(displayName:)` writes the name to the account
  (`PUT /auth/v1/user`, `user_metadata.full_name`), which is the one place that
  survives a reinstall and reaches a second device.
- `BideSession.displayName` reads it back — GoTrue returns `user_metadata` on
  every sign-in — and `AuthController.adoptAccountName()` takes it whenever
  this device hasn't got a name of its own. It never overwrites one the user
  typed: this answers "what should we call you" for somebody who was never
  asked, it doesn't correct somebody who answered.
- A name typed in Settings goes to the account too, for the same reason.

The full name is shortened to its first word. "Danny Oppenheimer" under a 52pt
avatar in a roster four people wide is a truncation waiting to happen.

**For an Apple ID that has already authorised Bide, there is nothing to
recover.** Apple will not re-offer the name. Settings → your name → Sign in
with Apple → Bide → "Stop Using Apple ID", then sign in again, makes the next
sign-in a first authorisation and the name arrives.

## 30 — Having an ETA is not having left

One wrong assumption, in one line, behind every symptom in the report:

```swift
public var hasLeft: Bool { status == .accepted && etaTimestamp != nil }
```

The ETA engine anchors an estimate the moment a bide starts being tracked,
which is normally while its owner is still indoors. So "has an ETA" meant "a
phone is running Bide", not "a person is on their way" — and an arrival
timestamp built that way is only ever *now plus the journey*, re-stated on
every anchor. Counting down to it is counting down to a moment nobody is
travelling towards. That is the green number in the report, and it is why it
ran down while its owner stood still.

**Departure is now a fact about movement.** `MapKitETAEngine` keeps the
location it first saw for a tracking session, and reports
`ETAReading.hasDeparted` once a fix lands more than 150m from it — generous
enough that a drifting indoor fix, a car park, or the far end of an office all
still read as "here". The location never leaves the engine; what leaves is a
boolean. `participants.left_at` records the moment on the server, because in a
group the answer belongs to everyone. The migration's header explains at length
why a timestamp derived from an on-device radius test does not breach the
privacy invariant, and the invariant's own test — a regex over the column names
of `participants` and `devices` — still passes.

**Two numbers, and which one moves.** `participants.travel_seconds` carries the
journey's *length* alongside the arrival timestamp. It is not new information —
it is `eta_timestamp` minus the moment it was written — but it is the number
that survives standing still, and the one the roster leads with. Each person's
block is now `10 min` at 20pt, over `Scheduled ETA: 3:30 PM` and
`Actual: 3:45 PM` — the glance answer on top, and underneath it the comparison
that turns it into "fifteen minutes late" without anybody doing arithmetic.
And:

- **still where they started** — the headline number holds still and "Actual"
  slides forward with the clock, because sitting there is not getting them any
  closer;
- **on their way** — "Actual" holds still and the headline number counts down
  to it, rendered as a live `Text(_, style: .relative)` so the lock screen
  stays current without a push.

The roster grid drops from four columns to three, since a 75pt tile shrinks
"Scheduled ETA: 3:30 PM" past legibility. The Live Activity can't reflow at all
— fixed 160pt box, four across — so there the scheduled time is said once,
beside the destination in the header, and the tiles carry the number and
"Actual" only.

The colour follows the same rule. `delayGrade` used to compare a re-stated
estimate against the first one ever recorded, so a person who hadn't left yet
went yellow and then red for the crime of not having gone. Nothing has slipped
until the journey has started; before that it is green.

**The headline.** `BidePlanner` takes `hasDeparted` and returns it on the plan:

| state | top line |
| --- | --- |
| hasn't left, on-time bide | "Leave in 45 minutes" → "Leave now" |
| hasn't left, asap bide | "Leave now" from the moment it exists |
| left | "On the way" |
| arrived | "You're here" / "Everyone's here" |
| together, waiting | "Waiting for Sarah to leave" |

**Arrive at the same time.** The style is *defined* as nobody leaving until the
person with furthest to go has gone, and it was releasing everybody the moment
that person's phone produced its first estimate — sending the near people out
to stand at the other end, which is the exact thing it exists to prevent.
Now: while the furthest hasn't left, everyone else is held with no leave time
at all, and anyone without an estimate yet holds the bide too, since they could
turn out to be the furthest of all. The furthest person themselves is nobody's
follower — they get the ordinary rules and the earliest departure in the bide.
Once they go, the meeting *is* their arrival: everyone leaves their own journey
ahead of it, off that person's live ETA, so the near people are told to go one
by one, nearest last. Someone whose journey is longer than what's left of the
leader's gets a departure in the past, which reads as "leave now" because it is.

**The Dynamic Island.** The compact slot said "now" — for an asap bide, from
the moment it was made until the moment it ended, because nothing could tell
the app its owner had gone. Departure being a real fact is what makes that slot
usable, and what it carries is the decision: a live countdown to leaving, then
"Now" when it's time, and — once there is nothing left to leave for — the trip.
Five characters is the budget, so it is the number rather than the sentence;
the expanded island right behind it says the words in full.

**The transcript tile.** A Messages tile is a snapshot with no server behind
it, so for an arrive-together bide it no longer prints a leave time at all —
that one depends on somebody else's phone, and a frozen guess would sit in the
thread saying "leave at 3:00" all afternoon. It says the app is tracking, which
is true, and the app takes over the moment they accept.

**Applying it.** `backend/supabase/migrations/20260813120000_add_departure_and_travel_time.sql`
has to be pushed before a build talks to the project — the client selects both
new columns, so PostgREST will refuse every read until they exist.

---

# Round six

31. The display name is meant to be set from the Apple account name on sign-in,
    but after signing in the Settings field was still empty — it should show
    what you are changing *from*.
32. The roster's `Scheduled ETA:` line is correctly omitted on a "leave now"
    bide, but `Actual:` is left behind on its own. Strip the tag too: actual
    compared to nothing.
33. A tile sent for "now" says "as soon as everyone can"; one sent for a time
    says that time. Once the clock passes that time, can the tile update itself
    to say "as soon as everyone can"?
34. The Messages compose sheet and the solo-bide form both label the field
    "Time". Call it "Meetup time".

---

# Resolutions

## 31 — A name the device had and the account didn't

`adoptAccountName()` only ever copied in one direction: account → device, and
only when the device had no name. The reverse case had nothing to carry it.
That case is the common one in development, and it is a real one in production:
the device's name survives an account being replaced (`DevBuildReset` preserves
it deliberately, since Apple offers a name exactly once), so a fresh account
gets no `user_metadata.full_name`, no participant rows, and no way to recover
the name on the next reinstall — while the device sat on it the whole time.

`reconcileName()` replaces it and runs in both directions, with the device
winning when both have an answer, since typing a name in Settings writes it to
both. And `record(_:)` now updates the session in hand as well as the account,
so the name just written is readable immediately rather than after the next
token refresh — without that, every launch would decide the account was still
nameless and write it again.

The settings field itself prefills from the device, falling back to
`AuthController.accountDisplayName` — which is what covers a reinstall or a
second phone, where the name is on the account and nowhere locally. It fills
only a blank, and re-runs `onChange` of the account name, so a sheet opened
while the session is still restoring fills in when the answer lands rather than
staying empty for as long as it is looked at.

**Still nothing to recover for an Apple ID that has already authorised Bide**
and never had a name captured — see round five, item 29. Apple will not
re-offer it; the way back is "Stop Using Apple ID" and signing in again.

## 32 — Half a comparison

"Actual" only means something next to the time the bide was set for. On an asap
bide there is no such time, so the word was drawing a contrast with nothing —
reading as though a second number had gone missing rather than never existed.

`BideFormat.arrivalLine(_:comparedTo:)` decides: labelled when a scheduled time
is on screen, bare when it isn't. The comparison is against `scheduledArrival`
rather than against the line directly above it, because the Live Activity hides
that line and prints the same time once in its header — so "Actual" still has
its other half there, and only a genuine asap bide drops the tag.

## 33 — A tile that outlives its own plan

`BideFormat.schedule` now returns "As soon as everyone can" for a time that has
gone by, not just for one that was never set. A bubble still reading
"Today · 3:30 PM" at four o'clock is worse than one that never named a time: it
describes a plan that has stopped existing.

Making it *update* is the other half. Nothing of ours runs in a transcript, and
a timer ticking behind a bubble that is mostly off screen would be the wrong way
to buy one. `TranscriptView` hands the system the handful of moments this tile's
words actually change — the departure it counts down to, and the meetup time —
as `TimelineView(.explicit(_:))` entries: one redraw each, at exactly the right
second, and nothing in between. "Now" leads the list, because `.explicit`
renders at the latest entry that isn't in the future and a tile dated from when
the bide was made would print a calendar date instead of "Today".

The fallback `MSMessageTemplateLayout` subcaption is still stamped at insert
time and cannot change — that is the layout for devices without Bide installed,
and an extension cannot rewrite a message somebody has already sent.

## 34 — "Time"

Now "Meetup time", in the field label and in the picker sheet's title. One
`BidePlanForm`, so the Messages compose sheet and the solo-bide card both get
it. Next to a travel-mode row and a countdown, a bare "Time" reads just as
easily as the time to set off — which is the one number in this app nobody
enters.
