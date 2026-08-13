# Overview
This file contains an in-english narrative of the entire idea and high-level design of Bide, with no specific architectural instructions. It reads more as a user story

Bide is an app that is 90% intended to be used solely as a iMessage extension and to be viewed as a "live activity" notification on the homescreen. Its goal is to allow friends 1-1 or in group settings to agree on a location they want to be at at a certain date and time (or asap). It allows them to select their mode of transportation, and then will calculate each persons ETA's along that mode of transportation. The idea is that those who are closer to the location can see when those furthest from the location leave, and how close they are, all live. This can influence their schedules, allow them rest before they *actually* have to leave, and even push-notify them to remind them to leave so that all parties arrive at exactly the same time.

The app can also function to improve picking people up from a place like a train station. One party on a train could send "union station" as a location, and then the person picking them up will have live updates on exactly when to leave to pick them up, fit with live train tracking.

The basic flow goes like this:
1. the initiator clicks the + button in imessages, and selects Bide from the list.
2. They fill out info like searchign for the location, the date and time, their own mode of transport, and whether they want everyone to arrive on time or the same time (Figma: ios-message-thread-send)
3. They send the tile to a group chat or a single person (Figma: ios-message-thread-collapsed)
4. recipients see a collapsed tile with basic info like location and intended date and time (Figma: ios-message-thread-collapsed)
5. they click on it, and it expands to allow them to enter in their own mode of transport and to accept or decline (Figma: ios-message-thread-expanded) (Figma 2: ios-message-thread-denied)
6. Once everyone accepts or declines (or we reach close to the time that the furthest person would have to leave), the system activates
7. A live activity notification appears on all accepted devices. (Figma: notifications-screen)
-- If the "arrive on time" was selected, everyone gets a simple "leave at this time". As each person leaves their home (not necessarily a set home, just the location where they accepted/sent the invite), their "waiting" status turns into their live eta, which may change as things get delayed or off schedule
-- If the "arrive at the same time" was selected, everyone starts in a waiting. When the person that is furthest from the meetup spot leaves, everyone else activates, showing "leave at X". then, as everyone leaves their own home locations, everyones live eta's still show.
-- Times can be highlighted green, red, or yellow, depending on how delayed they are from the original eta calculation (to show if they are stuck in traffic or something. Thresholds: more than 2 but less than 8 mins off schedule, yellow, more than 8, red)
8. When everyone makes it to the intended location, the tile deletes itself, and the notification deactivates

Presumably, this would require a sign in in the main app (not the imessage widget thingy). This would just be a simple page with a sign in with apple. However, there will also be an option to continue without sign in. No matter which option they choose, they will be brought to the main app.
- Here, there is just one screen:
-- At the top, there is a section that shows all currently joined bide sessions, which essentially copies the live activity feed in-app.
-- Below this section, there is another area labelled "Create a solo-bide". This allows a user to create basically a reminder system just for themselves, that will show in their live-activity feed and remind them when to leave. (Figma: bide-main-page)
-- Once a solo-bide is created, the user should have the option to "invite" others to track the bide. This would show up with the same figma design as sending a regular tile, but the buttons will show something "start tracking" instead of accept. Then, those tracking someones solo-bide will just see the trackee's eta climb down to their destination.

In the top right, only for signed-in customers, there will be a settings button, allowing them to change their display name. Additionally, here, there will be an ability to "automatically create solo-bides for calendar events". This will periodically scrape upcoming events that have location information and create bide events for them.

IMPORTANT!!!: Figma's are missing for some of the above things. that's okay, we can "best guess" them right now, trying to match the vibe and aesthetic of the existing figma screenshots. Additionally, the Figma's don't document every possible flow. For example, what cards look like exactly for a recipient and reciever and every possible view. So some we will need to infer.

This is mentioned in the open questions section, but we will infer what failed/errors should render as in each flow.

If there are 2 bide sessions that overlap **and go to different places**, then the most recently accepted one will override the other one at the same time (same time = similar enough time window that the ETA would be impossible to be at both places at once). They will be "removed" from the other session. This is also true for solo-bides. The user should be prompted "are you sure, this will remove you from X" when they try to accept or create a confliction session.

Overlapping sessions to the *same* place are not a conflict. One person can be coordinating one meetup with two groups, or running their own solo-bide beside a tile they sent, and that is a single journey serving several arrangements. "Same place" is a distance test — within 100m — rather than a name or an exact coordinate, because one venue has several map records that disagree by a block. All of those sessions stay live in the app, share one ETA anchor, and each gets its own Live Activity (newest first, if the system runs out of room). Their meeting times may differ; the app anchors on the earliest, so a person leaving for a 3:00 group shows as on their way to the 3:30 one with an arrival time that says 3:00 — which is true.

A conversation holds at most one Bide at a time. Sending a second one to the same person or group means ending the first, which the extension offers directly: the container app performs the deletion, so anyone who joined or was tracking it loses it. A shared bide that other people have already accepted can only be left rather than deleted, because the server does not let one participant delete other people's arrangement.

# Styling and brand
Bide's logo is in two forms, as seen in the figma screenshots.
1. Main one: a horizontal line with 4 dots, almost like a subway line: o-o-o-o
2. Secondary: a vertical line with 3 dots:
o
|
o
|
o
3. Colors: Most text and icons should be #FFFFFF. Some subheadings are gray. Background colors are always #1D1D1F. Apple font is always used: SF Pro.
4. The actual little icon for Bide in the "+" menu in imessages is black background, with the horizontal 4 dot logo.
5. IMPORTANT!!!: The figma screenshots are a little rough: they have different fonts, colors, and especially differently-ratioed logos. Aim to create source-of-truth reusable components to enforce same-styles across the experience. There are already source-of-truth logos in the design folder in company_style/
6. Animations:

The text underneath "Bide" should look a face of a cube, and "rotate" to show different messages. the options for these are (random order):
- Know when to leave.
- You've got more time than you think.
- Stay on the couch a little longer.
- The last text you'll send before you leave.
- No more "where are you?"
- Stop guessing. Start relaxing.
- Never leave too early again.
- Wait less. Rush less.
- The "how far are you" text, automated.
- Because someone always leaves too early.
- Coordinate less. Meet on time.
- Get one more scroll in.

When a tile goes from collapsed to expanded on click in an imessage thread, our logo is always top left centered, but goes from vertical 3 dot to horizontal 4 dot. 
- This gives an opportunity for a cool transition animation. The one "dot" on the top left should remain static and always there. We can slide-collapse the 2 dots nad line below into it (so in-between it shows as just a dot), and then "slide" the 3 new horizontal dots out sideways as we transition betwen states. (ask questions if neede dto clarify this animation.
Example of above animation for collapsed to expanded:
Step 1
o
|
o
|
o
Step 2
o
|
o
Step 3
o
Step 4
o-o
Step 5
o-o-o
Step 6
o-o-o-o


# Open questions for future improvement
- Can we use stripe and hide some stuff behind a paywall (like maybe the calendar integration)
- What if someone is, say, already **on** an amtrak train and sends a bide to their mother trying to pick them up. Can we someone detect this, and catch up their trip to know which train they are on automatically, and send correct meetup information to both parties.
- Is there some way we can safely and without privacy issues collect movement data on users to build a "profile" on them to improve ETA discovery. (e.g. using iPhones altitude sensor to know using elevator=leaving home, ping others in their bide session)
- Is there some way we can analyze routes, movement sensors, or otherwise to accurately update eta's? For example, google and apple maps already have pretty good subway routing algorithms, but can we detect "this person missed the train, update their eta for the next subway train coming". Or, "this person parked their car, and is walking the rest of the way"
- Could a super lightweight ML model be used for the 2 above items?
- Can we implement a "carpool mode". One driver sends a carpool request, people join, and then a traveling-salesman algorithm runs to create the optimal pickup order ending in the final destination. People are then notified how close the carpool driver is to them, how many people they have picked up, etc... (display helpful things like "currently waiting at Johns house..."). We could also use Bide's logo to show stops along the way towards you).
- How do we handle super large groups of people?
- If someone doesn't leave, loses gps connection, or something else goes wrong, what do we do?
