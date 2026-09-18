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
5. **Optional: hands-free commute.**
   - In **Shortcuts → Automation → + → Time of Day**, pick your leave time minus 15 minutes and add **Start Commute**.
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
| Metro journey | **Now → Start a metro journey**: pick the line, then where you get on and off (**Start from the station I'm at** fills the first one). While travelling you get stops remaining, the next station, a Lock Screen activity, and a **Get off next** alert one stop early. |
| Timetable | **Day → Add timetable**: paste your timetable or pick a photo of it, tap **Read it**, check what the model found, then Save. Classes then appear in Day every week, with a reminder 10 minutes before each. **No classes today** marks a day off; long-press a class to skip just that one. |
| Add an event | **Day → Add an event**, or **Paste a message**: copy a WhatsApp message or invite, and the on-device model reads the title, time and venue out of it. Nothing saves until you confirm. Events also copy to your Apple Calendar. |
| Tag a place | **Vault → Save this spot**: add tags (Parking, Study, Food… or your own) and up to 5 photos. Tags show in the Vault and on the place card. |
| Place details | Tap any cyan place on the map, or a Radar row. The card shows street imagery where Apple has it, address, phone and website, plus **Photos, hours & reviews** for Apple's full card. |
| Island alerts | The capsule under the status bar shows the most important thing right now: amber for rain or an event starting soon, green for your commute or guidance, cyan for weather. Tap it for details. |
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

The colour is a four-stop ramp (`Palette.markRamp`) built from Ion's own hue and saturation, moved
along the lightness axis and drifting 25 degrees in hue from cyan to teal. Two rules there: never
lighten by mixing toward Ice, which drops saturation until the mark is a pale grey shape; and keep
the body clear of the top of the range, because the lighting adds on top and a body near white
clips the green channel, flattening the whole mark to one tone no matter how the ramp is built.
The ramp runs *along* the mark's diagonal, not across it — across shades each limb over its width,
which reads as a tube.

Green in the map is a route, not a glow: `CityMap.drawRoute`. Its ends follow the convention every
map app uses — a solid dot inside a dark collar where you start, and an Amber pin whose point sits
on the destination. The pin's sides are the real tangents from its tip to its head, and the markers
are drawn in icon space rather than map space so the pin stays upright instead of leaning with the
map's rotation. `--route-style` picks how the path between them is drawn — `dashed` (the default), `line`, `trail`, `points` or `none` — and the far stop is Amber,
the one point on the map worth a glance. It's clipped away from the mark (`clearance`), both because
the mark sits above the map and because a bright stop touching the outline collapses the contrast
right there, which is how it was found.

**Legibility.****Legibility.** `MarkLegibilityTests` renders the icon and measures contrast across the mark's
outline, along the outline's own normal. It holds the worst edge at or above 3:1 (WCAG 1.4.11 for
graphical objects) both as rendered and under a veiling-glare model standing in for a dim screen in
ambient light — that second case is the one that fails first, because reflected light lifts the dark
ground proportionally more than the bright mark. A third test stops the fix going too far: the
rendered mark has to keep at least a 1.9x luminance range, or it stops reading as glass. Current
figures are a worst edge of 4.7:1 and a median of 8.3:1 under veil, with the mark's colour
travelling ~156 of 441 across sRGB and 24 degrees in hue.

**Replacing the logo:** drop a new SVG in as `PathOS_Logo.svg` and re-run. The shadow, gradient,
glass edge, inner shading and bloom are all built from the path at run time, so they re-form around
the new shape — nothing is hand-fitted to the current one. `swift test --package-path Tools/IconForge`
covers the SVG parsing (including relative commands, shorthand curves, arcs and nested transforms).

`Tools/` sits outside the app's `sources:` in `project.yml`, so none of this compiles into PathOS.

## Simulator screenshots (debug builds only)

Launch arguments open any state without tapping:

```sh
xcrun simctl launch booted com.vaibhavreddy.pathos -PathOSDemoData YES \
  -PathOSDeepLink pathos://radar -PathOSDeckDetent medium
```

- `-PathOSDemoData YES` seeds Home, Work, two memories and an event around MG Road, Bengaluru. Set the simulator location with `xcrun simctl location booted set 12.9716,77.5946`.
- `-PathOSDeepLink <pathos:// link>` opens a screen: `radar`, `vault`, `voice` or `compass`.
- `-PathOSDeckDetent medium|large` sets the deck height.
- `-PathOSIslandExpanded YES` holds the island open.
- `-PathOSSelectFirstPlace YES` opens the first discovered place's card.
- `-PathOSDemoReadouts YES` fills the peek strip's readouts, which the simulator has no weather or altimeter to supply.

## Known limits

- iOS won't let an app start a Live Activity from the background by itself. For background events PathOS sends a notification instead, and the Shortcuts automation covers the commute.
- There is no free events API for India. Radar events come from Apple Maps venues plus posters you scan.
- Transit ETAs appear only where Apple Maps supports transit in your city. Rapido has no documented deep-link format, so its button just opens the app.
- **Metro times are estimates.** BMRCL publishes no live train positions, so PathOS tracks your own position along the line and estimates the rest at about 2.2 minutes per stop; underground, the clock carries the estimate until GPS returns. Line and station order come from Wikipedia (CC BY-SA, read 17 September 2026); station coordinates are looked up in Apple Maps on your iPhone.
- Buses aren't covered yet: BMTC's open GTFS is unofficial and only covers routes with live tracking.
- The barometer runs only while PathOS is active or during background refreshes. Rain warnings also check the Open-Meteo forecast.
