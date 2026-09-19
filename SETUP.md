# PathOS — Setup & Install

PathOS is a personal iOS 26+ app for iPhone 16 Plus. The Xcode project is generated from `project.yml` with XcodeGen, so never edit `PathOS.xcodeproj` by hand.

## 1. One-time Mac setup

1. **Install Xcode 27.**
   - Get it from the Mac App Store, or the RC from developer.apple.com/download.
   - It needs about 15–20 GB. Clear some disk space first.
2. **Open Xcode once.** Accept the license and install the **iOS** platform when prompted.
3. **Point the command-line tools at Xcode.** Run:
   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
4. **Add your Apple ID.** Go to **Xcode → Settings → Accounts → +** and sign in. A free account works.
5. **Copy your Team ID.**
   - In the same Accounts pane, select your team; the ID is shown there.
   - Paste it into `project.yml` in place of `DEVELOPMENT_TEAM: ""`.
6. **Install XcodeGen** if it isn't already: `brew install xcodegen`.

## 2. Build

```sh
cd "/Volumes/Extra Storage/Projects/PathOS App"
xcodegen generate

# Simulator build (compile check)
xcodebuild -scheme PathOS -destination 'generic/platform=iOS Simulator' build

# Unit tests (pick any installed simulator: xcrun simctl list devices available)
xcodebuild test -scheme PathOS -destination 'platform=iOS Simulator,name=iPhone 17'
```

## 3. Install on your iPhone

1. **Turn on Developer Mode.** On the iPhone: **Settings → Privacy & Security → Developer Mode → On**. The phone restarts.
2. **Connect the phone.** Plug it in with USB and tap **Trust**.
3. **Build and install.**
   - The easiest route: `open PathOS.xcodeproj`, pick your iPhone as the run destination, then press **⌘R**.
   - Command-line route:
     ```sh
     xcrun devicectl list devices            # copy your iPhone's identifier
     xcodebuild -scheme PathOS -destination 'platform=iOS,id=<DEVICE_ID>' -allowProvisioningUpdates build
     xcrun devicectl device install app --device <DEVICE_ID> \
       ~/Library/Developer/Xcode/DerivedData/PathOS-*/Build/Products/Debug-iphoneos/PathOS.app
     ```
4. **Trust your developer certificate.** The first time only, go to **Settings → General → VPN & Device Management → your Apple ID → Trust**.

> **Free Apple ID:** the app stops launching after **7 days**. Repeat step 3 to refresh it. Your data is kept.

## 4. First run on the phone

1. **Grant permissions.**
   - Allow **Location**, then allow **Always** when iOS asks again. Exit checks and spatial notes need Always to work in the background.
   - Allow **Notifications**.
   - Microphone, Speech and Camera access are requested the first time you use those features.
2. **Turn on Apple Intelligence** (Settings → Apple Intelligence & Siri). Scans, Radar ranking and voice answers use the on-device model. Without it, PathOS falls back to simpler rules.
3. **Set Home and Work.** Pull up the panel at the bottom of the map. In **Now**, stand at each place and tap **I'm at Home** or **I'm at Work**. You can also use **Vault → Places**.
4. **Map the Action Button.** Go to **Settings → Action Button → Shortcut → PathOS → Ask PathOS**.
5. **Optional: pin the context every morning.**
   - In **Shortcuts → Automation → + → Time of Day**, pick when your day starts and add **Pin Context to Lock Screen**.
   - Set it to *Run Immediately*.

## 5. What to test

| Feature | How |
|---|---|
| Guidance | **Vault** → the green arrow on a memory, or tap any signal on the map → **Point me there**. The map follows your heading and draws a green walking route. Turn until the arrow points up. Tap **Heads-up** for arrow only, or **Pin** to use it in StandBy. |
| Spatial memory | Save a spot, walk more than 150 m away, come back. The note appears on the Lock Screen or as a notification. |
| Receipt | Camera button on the right of the map → shoot a bill → **Log expense**. |
| Event poster | Camera button → scan a poster → **Add to Calendar**. It shows up on the map and in Radar. |
| Day | Pull up the deck → **Day**. Move between days with ‹ ›. Today shows **Next up** with a live countdown and **Point me there**; past days show what happened and how far you travelled. |
| Trips | **Day → Plan a trip**: name it, set the days, then add legs (walk, scooter, car, cab, bus, metro, train, flight, ferry). Legs show in Day alongside classes and events, remind you 45 minutes before departure, and each day gets a summary of what it added up to. |
| Metro journey | **Now → Plan a metro or bus journey**: pick any two stations (**I'm at a station** fills the first). You get the lines, which direction to board, where to change, and the time, fare and whether trains are running now. While travelling you get stops remaining, a **Change next** alert before each change, a **Get off next** alert one stop early, and a Lock Screen activity. These keep working with the phone in your pocket. |
| Bus journey | Same sheet, **Bus**: pick two stops and choose a direct bus. Or tap a bus stop on the map (the small cyan squares) to see what runs from it. Timings are approximate. |
| Change by talking | Open the assistant and say or type "move my 3pm class to 4", "cancel Thursday's lab", "no classes on Monday" or "push dinner to 9". A card shows the change: **Approve**, **Edit** or **Cancel**. Classes can change just once or every week. |
| Trip tracking | Open PathOS during a trip leg, tap **Start tracking** on its departure reminder, or tap the leg's pin on the map. The Lock Screen shows the ETA and distance to go, and it says when you're running late. Metro legs between two stations are followed stop by stop. |
| Calendar events | **Settings → Calendars → Show events from my calendars**. Subscribe to public calendars in the Calendar app, and their events appear on the map with times. |
| Timetable | **Day → Add timetable**: paste your timetable or pick a photo of it, tap **Read it**, check what the model found, then Save. Classes then appear in Day every week, with a reminder 10 minutes before each. **No classes today** marks a day off; long-press a class to skip just that one. |
| Add an event | **Day → Add an event**, or **Paste a message**: copy a WhatsApp message or invite, and the on-device model reads the title, time and venue out of it. Nothing saves until you confirm. Events also copy to your Apple Calendar. |
| Tag a place | **Vault → Save this spot**: add tags (Parking, Study, Food… or your own) and up to 5 photos. Tags show in the Vault and on the place card. |
| Place details | Tap any cyan place on the map, or a Radar row. The card shows street imagery where Apple has it, address, phone and website, plus **Photos, hours & reviews** for Apple's full card. |
| Island alerts | The capsule under the status bar shows the most important thing right now: amber for rain or an event starting soon, green for your journey or guidance, cyan for weather. Tap it for details. |
| Pinned context | **Now** → the pin beside where you are. The Lock Screen then leads with whatever matters: a class or event starting within the hour (counting down to its start) or under way (the time left, with a progress bar), else a note you left at this spot, else **Take an umbrella**, else where you are and the weather. Up to two notes follow, such as the umbrella, your travel time around when you usually leave, and what's next. During a metro or bus journey, a trip leg or the pointer, the directions take over and the context comes back after. Tap the pin again to unpin. iOS ends a Live Activity after eight hours or a restart; PathOS puts it back the next time you open it, unless you swiped it away. |
| Exit check | Deck gear → **Run exit check now**, or leave Home when rain is forecast. |
| Voice | Press the Action Button, or tap the waveform button on the map: "Top cafés within a 5-minute walk". The island opens into the assistant and answers appear on the map in cyan. |

## Colour meaning

| Colour | Means |
|---|---|
| Aurora green | **You**: your location, route, arrow, saved memories, the main action |
| Ion cyan | **The world**: places, events, transit, weather, AI suggestions |
| Amber | Worth your attention |
| Coral | Urgent (for example, location is off) |

## App icon

The icon is generated, not drawn. `PathOS_Logo.svg` at the repo root is the only source for the
mark, and `Shared/PathOSPalette.swift` is the only source for its colours.

```
swift run --package-path Tools/IconForge -c release IconForge
```

That writes `PathOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (1024, full-bleed,
no alpha — iOS applies the rounded mask itself). Useful flags:

- `--previews <dir>` also writes 180/120/87/60/40 copies, for checking the mark stays readable small.
- `--out <file>` renders somewhere else, which is the safe way to try changes.
- `--logo-scale 0.68` sizes the mark, `--map-intensity 1.0` sets how present the city is, and
  `--seed <n>` picks which city gets generated. Same seed, same city, every run.
- `--ground-lift 0.58` is how far the background sits above black, and `--ground-cool 0.88` swings
  its hue from teal to blue. These two carry most of the icon's character: at a low lift the tile
  reads as a hole punched in the wallpaper rather than an object on it, and with the ground left
  teal it and the mark blur into one dull mass.
- `--mark-shade 0.74` sets where the ramp's deepest stop sits. Lower is deeper and more
  saturated; don't lower it without re-checking the contrast tests below.
- `--glass-bevel 7` is how far in from the outline the glass rolls off.
- `--route-style dashed` picks the green treatment. `IconVariants.png` at the repo root shows them
  side by side; regenerate it by rendering each style with `--out`.
- `--mask <file>` writes the mark's silhouette on its own, which is what the contrast measurements
  sample against.

The mark is lit as glass rather than filled with a gradient (`GlassShading`). It computes the
mark's distance field, builds a lip over the last `--glass-bevel` pixels of it, and derives a tight
specular highlight, light returned at grazing angles, a hard bright line along the cut edge, and
refraction that bends the map behind the rim with each colour channel bending slightly differently.
All of it comes from the outline, so a different SVG gets the same treatment.

Two things carry that look and are easy to lose:
- **The bevel stays narrow.** A wide one spreads curvature across the whole face, so the mark
  inflates into a tube and the gradient has nowhere to show. Glass is flat across its face and
  turns hard at the edge.
- **The edge light is added, not screened.** Screening onto an already-bright body moves it almost
  nowhere, which leaves the edge soft instead of cut.

The colour is a three-stop ramp (`Palette.markRamp`) of the design's stops, #8DFFEE, #6DFFEA and
#00FFD0. All three sit on Ion's own hue at full saturation, so they're derived from the palette
(within 4/255 of each) rather than pasted in, and change with Ion. Two rules there: never
lighten by mixing toward Ice, which drops saturation until the mark is a pale grey shape; and keep
the body clear of the top of the range, because the lighting adds on top and a body near white
clips the green channel, flattening the whole mark to one tone no matter how the ramp is built.
The ramp runs *along* the mark's diagonal, not across it — across shades each limb over its width,
which reads as a tube.

Green in the map is a route, not a glow: `CityMap.drawRoute`. Its ends follow the convention every
map app uses — a solid dot inside a dark collar where you start, and an Amber pin whose point sits
on the destination. The pin's sides are the real tangents from its tip to its head, and the markers
are drawn in icon space rather than map space so the pin stays upright instead of leaning with the
map's rotation. The route places itself. `CityMap.plan` generates sixteen candidate routes through different pairs
of roads, all deliberately longer than anything that will be used, and `drawRoute` picks whichever
keeps the most length once the mark and the icon's rounded edge are accounted for — subject to
sitting below the figure's waist, since the longest corridor is often the strip across the top and a
route up there reads as a banner hung above the mark. Hand-placing one route means re-tuning it
whenever the mark or the street layout changes, and the position snaps to the nearest road anyway,
so small adjustments do nothing.

Each end marker is tested by its whole footprint against a stricter safe area than the path gets: a
marker is a solid object, it needs room, and it has to stay inside the rounded shape iOS masks to
rather than the square edge of the file. A marker slides inward along the route until it fits, and
the path is then cut to meet it — otherwise the route runs past its own destination — otherwise its length has to be hand-tuned until the ends happen
to miss the figure, and any later change to the mark quietly leaves a marker half-dissolved by the
clearance mask. `--route-style` picks how the path between them is drawn — `dashed` (the default), `line`, `trail`, `points` or `none` — and the far stop is Amber,
the one point on the map worth a glance. It's clipped away from the mark (`clearance`), both because
the mark sits above the map and because a bright stop touching the outline collapses the contrast
right there, which is how it was found.

**Sizing.** Everything here is authored at 1024 and almost only ever looked at near 180, so sizes
are chosen backwards from there: the pin is ~80px tall at 1024 because anything under about 11px on
a home screen is a speck. Judge changes from the `--previews` output, not the master.

**Legibility.****Legibility.** `MarkLegibilityTests` renders the icon and measures contrast across the mark's
outline, along the outline's own normal. It holds the worst edge at or above 3:1 (WCAG 1.4.11 for
graphical objects) both as rendered and under a veiling-glare model standing in for a dim screen in
ambient light — that second case is the one that fails first, because reflected light lifts the dark
ground proportionally more than the bright mark. A third test stops the fix going too far: the
rendered mark has to keep at least a 1.9x luminance range, or it stops reading as glass. Current
figures are a worst edge of 4.7:1 and a median of 8.3:1 under veil, with the mark's colour
travelling ~156 of 441 across sRGB and 24 degrees in hue.

**The launch screen** starts from the same render. IconForge also writes
`Assets.xcassets/LaunchMark.imageset`: the glass mark on its own, with no tile behind it, 140 pt wide.
It writes this whenever it writes the app icon (a trial render with `--out` leaves it alone).
`IconRenderer.renderMark` lights the mark exactly as the icon does, so the two can't drift.

iOS shows that image centred on Void. `LaunchView` then takes over at the same spot and plays:
1. the real streets of central Bengaluru around MG Road spread out from behind the mark, from Cubbon
   Park to Halasuru Lake
2. "PathOS" rises at the bottom
3. a dashed green route draws itself along real roads from a start dot, around the mark, to an
   Amber pin
4. while PathOS finishes starting, light runs along the route and the pin breathes

It lifts, zooming into the real map, once PathOS has your location. That's no sooner than 1.7 s, so
the route finishes drawing, and no later than 3.5 s. With Reduce Motion it shows the finished
picture and just fades.

The map is OpenStreetMap data (ODbL, credited in Settings), built by
`python3 Tools/TransitData/build.py city` into `PathOS/Resources/LaunchMap/launch-map.json` (about
270 KB):
- roads in four classes, from main roads down to service lanes
- parks, water and rail
- a route found on the real road network that keeps out of a box around the mark and inside the
  area every phone shows

If the Overpass servers are busy, `city --from saved.json` rebuilds from a saved answer. The app
draws the streets once into an image when the launch screen appears, and only the route, pin and
pulse redraw each frame. `LaunchSceneTests` checks the route on the iPhone SE, 13 mini, 16 Plus and
17 Pro Max: it keeps 36 pt from the mark and clear of the edges, the Dynamic Island and the name,
and runs on real roads.

iOS caches launch screens, so a change can take an app restart or a phone restart to appear.

**Replacing the logo:** drop a new SVG in as `PathOS_Logo.svg` and re-run. The shadow, gradient,
glass edge, inner shading and bloom are all built from the path at run time, so they re-form around
the new shape — nothing is hand-fitted to the current one. `swift test --package-path Tools/IconForge`
covers the SVG parsing (including relative commands, shorthand curves, arcs and nested transforms).

`Tools/` sits outside the app's `sources:` in `project.yml`, so none of this compiles into PathOS.

## Gmail

PathOS reads Gmail directly from the phone: there's no server, and nothing but Google sees the
mail. Connect it in **Settings → Gmail**.

**The Google Cloud side** (project `PathOS`, done once):

- The Gmail API is enabled.
- **Google Auth Platform → Audience:** External, publishing status **Testing**, with your Gmail
  address listed under Test users. Only listed test users can sign in.
- **Data Access:** one scope, `https://www.googleapis.com/auth/gmail.readonly`.
- **Clients:** an iOS client for bundle ID `com.vaibhavreddy.pathos`. Its client ID is in
  `PathOS/Core/Mail/GoogleOAuth.swift` (`GoogleConfig.clientID`). An iOS client has no secret, so the
  ID is safe to commit. To use a different Cloud project, create a new iOS client there and change
  that one line. The redirect is the client ID reversed and is derived from it.

**How a check works:** sign-in uses PKCE in iOS's secure browser sheet. The refresh token is kept
in the Keychain, readable after the first unlock and never synced. PathOS searches for mail since
the last check, skipping Promotions, Social, Forums, spam and sent mail. It reads the newest 30
matches, and each message is read by the on-device model in its own session. Without Apple
Intelligence, date and keyword rules do the reading instead. Events, deadlines and updates wait in
the Day deck until you choose **Add to Day**, **Edit** or **Not now**. Only the one-line summary is
stored, never the body.

Checks run when the app opens, at most every 10 minutes, and in background refreshes, reading up to
6 messages so the check fits in the time iOS allows.

**Why Google asks you to sign in again every 7 days:** while the Cloud project is in Testing,
Google expires sign-ins that go beyond basic profile access after 7 days. PathOS shows a
**Reconnect Gmail** card and sends one notification when that happens. Publishing the project would
remove the limit, but `gmail.readonly` is a restricted scope, so publishing means going through
Google's app verification review (a privacy policy, a demo video, and weeks of back-and-forth).
That isn't worth it for a personal app.

## Transit data

Metro and bus data ship inside the app, built by `Tools/TransitData/build.py` (Python standard
library only; downloads go through `curl`):

```sh
python3 Tools/TransitData/build.py metro   # → PathOS/Resources/Transit/metro.json (7 KB)
python3 Tools/TransitData/build.py bus     # → PathOS/Resources/Transit/bus.json (~2.9 MB)
```

- **Metro.** Station names and order live in `Tools/TransitData/metro_service.json`, from Wikipedia.
  Coordinates come from OpenStreetMap's route relations for each line (ODbL), matched by position
  with a name check. The script fails if a count, a name, a boundary or a gap between stations
  doesn't check out. First and last trains, headways and the fare slabs are entered by hand in the
  same file, each with a source and date. BMRCL publishes none of it as data.
- **Buses.** Derived from [bmtc-gtfs](https://github.com/Vonter/bmtc-gtfs) (ODbL 1.0), a community
  copy of the Namma BMTC app's data. For each route direction it keeps:
  - the stops it calls at
  - the scheduled minutes between stops
  - trips a day, the first and last bus, and peak and off-peak frequency

  Shapes and per-stop timetables are dropped, and KSRTC intercity routes that leave BMTC's area are
  left out. The derived file is itself ODbL: keep the attribution in Settings → About the transit data.
- **When the Pink Line opens:** add it to `metro_service.json` with its OpenStreetMap relation id,
  then re-run `metro`.

Conversational edits, trip tracking and the Live Activity don't need data files. Calendar events on
the map need full calendar access, which PathOS asks for only when you turn it on in Settings.

## Simulator screenshots (debug builds only)

Launch arguments open any state without tapping:

```sh
xcrun simctl launch booted com.vaibhavreddy.pathos -PathOSDemoData YES \
  -PathOSDeepLink pathos://radar -PathOSDeckDetent medium
```

- `-PathOSDemoData YES` seeds Home, Work, two memories and an event around MG Road, Bengaluru. Set the simulator location with `xcrun simctl location booted set 12.9716,77.5946`.
- `-PathOSDeepLink <pathos:// link>` opens a screen: `radar`, `vault`, `voice` or `compass`, or
  the journey planner with `pathos://journey?from=Whitefield&to=Silk%20Institute`
  (add `&by=bus` for bus stop names).
- `-PathOSChangeProposal YES` shows a drafted class move on the assistant, without the model.
- `-PathOSDeckDetent medium|large` sets the deck height.
- `-PathOSIslandExpanded YES` holds the island open.
- `-PathOSSelectFirstPlace YES` opens the first discovered place's card.
- `-PathOSDemoReadouts YES` fills the peek strip's readouts, which the simulator has no weather or altimeter to supply.

## Known limits

- iOS won't let an app start a Live Activity from the background by itself. For background events PathOS sends a notification instead, and the Shortcuts automation covers the commute.
- There is no free events API for India. Events on the map come from what you add, scan or
  approve from Gmail, and from calendars you subscribe to in Apple Calendar. Apple Maps venues are
  shown as places, not events.
- Transit ETAs appear only where Apple Maps supports transit in your city. Rapido has no documented deep-link format, so its button just opens the app.
- **Metro times and fares are estimates.** BMRCL publishes no live train positions, platform
  numbers or machine-readable timetable. PathOS tracks your own position along the route and
  estimates running time from station distances (about 33 km/h including stops), plus half a
  headway of waiting and a walk at each change. Underground, the clock carries the estimate until
  GPS returns. Platforms are shown the way stations sign them, by the end of the line the train is
  heading for. Fares use the station-count slabs in force since 14 February 2025, and BMRCL's own
  table can differ by a slab.
- **Bus timings are approximate and there are no live bus positions.** The source data comes from
  the Namma BMTC app, whose timetables its maintainer says are often wrong, and routes without live
  tracking are missing. BMTC's live tracking is private to its app. Only direct buses are planned,
  with no changes between buses.
- The barometer runs only while PathOS is active or during background refreshes. Rain warnings also check the Open-Meteo forecast.
