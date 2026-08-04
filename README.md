# Hourglass

A **workday tracker with a Pomodoro on top**, for **macOS** and **iOS**. The
workday is the spine — clock in, work, rest, clock out — and a Pomodoro is an
optional bounded phase layered over it. An editable history, completion alerts
and statistics share a single, fully-tested Swift core across both platforms.

The **Orbit Native** design presents all of that as one scene: a planet, an
orbital track, and the day traced along it. Solid ember arcs are stretches of
recorded work, gaps are rests, and the satellite marks now.

Common to both platforms:

- **One linked break** — a Pomodoro short or long break *is* a work break. It
  creates the same interval the daily totals and History count, so the two can
  never disagree about whether you were resting.
- **Break where it belongs** — a first-level Break action appears while clocked
  in with no Pomodoro phase, and is hidden (not disabled) in every Pomodoro
  state, where the phase controls own the transition into and out of rest.
- **One resolved presentation** — every surface renders
  `OrbitPresentationResolver`'s output rather than deriving its own labels, so
  the phone, the panel, the menu bar and the Live Activity cannot contradict
  each other.
- **Editable history** — view, add, edit and delete every recorded focus session,
  work break and clocked-in stretch, plus CSV export. Filter it by kind, by span
  and by text, select rows in bulk, and delete or export just those. A workday
  whose own row is filtered out still heads its matching rows, because the
  section header is the only thing saying which day a row belongs to.
- **Stats over the span you choose** — 7, 14 or 30 days drives the totals, the
  per-day chart and the day shapes together, so the three can't answer about
  three different periods.

- **macOS** (Tahoe 26+) — one borderless menu-bar item whose mark and value
  change with state (fill = bounded vs open-ended, colour = work vs rest, and a
  distinct pause mark); clicking it only opens or closes the 370 × 268 pt Orbit
  panel. A Settings toggle switches between **menu-bar** and a **floating
  window** (with keep-on-top).
- **iOS** — a full-bleed Orbit face with Orbit / Stats / Settings tabs; a **Live
  Activity** (Lock Screen + Dynamic Island) in the same state grammar, ticking
  off the device clock; wall-clock accurate across backgrounding with a
  look-ahead local notification.
- **Sky** — the Orbit scene alone follows the local sun, through the whole day
  rather than a day/night switch (`SolarClock`, coarse location, equatorial
  06:00–18:00 fallback). Stats, History and Settings follow the system
  appearance, so a sunset never flips the information UI.

### The phases of the day

The scene is a continuous function of the sun's **elevation**, not of a daylight
flag. `SolarClock.position` gives that elevation, its declination and its hour
angle; `SolarPhase` names the fourteen stretches it passes through at the
conventional twilight angles — `night`, `astronomicalDawn`, `nauticalDawn`,
`civilDawn`, `sunrise`, `goldenMorning`, `morning`, `noon`, and their mirror
through the afternoon to `astronomicalDusk`.

`OrbitSky` turns that into the scene: a three-stop sky gradient blended between
altitude anchors, a star field that fades in across twilight, the limb rim, and
the sun's own glow tracking along the horizon. Nothing steps — every colour is
interpolated — but the sky is materially different every half hour, and dawn is
rose where dusk is amber, at the same sun height.

The **chrome** still gets a two-way answer, from `OrbitSky.isNight`, and it flips
at +2° rather than at the horizon. That figure is measured, not chosen: it is
where the two inks' contrast against the sky crosses over. A sunrise sky passes
through a mid slate neither ink is comfortable on, so switching at the crossing
is the most legible thing available — never below 4:1, against 3.1:1 for a flip
at sunset.

### Photographic Earth

The planet renders real Earth imagery, centred on the viewer's own meridian and
parallel and lit where the sun is actually lighting it. `OrbitPlanetTexture`
reads two images from each app's asset catalog, and falls back to a procedural
planet if they are absent — so removing them is a supported way to ship without
imagery:

| Asset name | What it is |
| --- | --- |
| `OrbitEarthDay` | Equirectangular (plate carrée) colour map, 2:1, longitude −180…180 left to right |
| `OrbitEarthNight` | Same projection and size, city lights on black. Optional — without it the night side simply darkens |

Both apps currently ship NASA imagery, downscaled to 2048 × 1024 (~440 KB total
per app):

- `OrbitEarthDay` — [Blue Marble: Land Surface, Shallow Water and Shaded
  Topography](https://visibleearth.nasa.gov/images/57752), NASA Earth Observatory
- `OrbitEarthNight` — [Earth at Night 2012](https://visibleearth.nasa.gov/images/79765),
  NASA Earth Observatory / NOAA Suomi NPP VIIRS

NASA content is generally not copyrighted and may be used for any purpose; NASA
asks that it be credited, which the app does in Settings → Workday.

### A real sphere

The planet is projected, not pasted. [`OrbitGlobe.metal`](Shared/OrbitGlobe.metal)
maps every pixel of the disc onto the ball, rotates it in three dimensions and
reads the map there. So the ground foreshortens as it runs away to the horizon,
continents curve over the limb, and the poles behave like poles.

The planet is a **horizon**: a body far larger than the crop, with about a third
of the phone's height given to the curve of it. What is on screen is a shallow
band up near the limb, which makes the visible face an **orbital horizon view** —
the ground below you, stretching away and compressing as it goes.

That is a deliberate limit, and it was tested against the alternative. Pulling the
planet back until the whole ball fits does buy a ring that passes in front of the
world and hides behind it, and it was built and looked at — but it costs the
horizon the scene is built on: the sky above it carries the HUD, the light on it
carries the hour, and a ball floating in the middle is a different scene rather
than a better-drawn version of this one. The horizon stays; the orbit leans
instead.

**Which slice of the world you see** is `SceneGeometry.aimAngle`, how far out from
the point below the viewer their own latitude is placed. The horizon lands at
`viewerLatitude + (90 − aimAngle)` and the bottom of the screen at roughly
`viewerLatitude − (aimAngle − 38)`. Raise it to look toward the equator, lower it
toward the pole. At 68° a viewer in Warsaw gets about 17°N–74°N: Europe through
the middle, the Sahara along the bottom, a rind of ice at the top. At 53° they got
39°N–89°N and spent the whole top half of the scene on Arctic ice. Longitude needs
no such choice — the globe is aimed at the viewer's own meridian.

### The orbit

The track is a **circle in space around the planet**, concentric with it, tipped
slightly out of the screen plane and projected the same way the planet is.

Concentric came first, and mattered on its own: the track used to be a separate
circle with its own centre and a tighter radius, which on the panel sat 5 pt above
the limb at the middle of the screen and 28 pt at the edges. The two curves
disagreed about where the world was, and the result read as an arc drawn over a
planet rather than a path around one.

The **tilt** is what stops it reading as a line ruled parallel to that horizon.
`orbitTilt` leans the ring out of the screen, so its right-hand side stands nearer
the viewer than its left and the arc becomes a true ellipse; `orbitRoll` then tips
it within the screen, so one end of the arc sits clear of the other — about 50 pt
across the phone. `apexAngle` measures angles from the crop's high point rather
than the ring's, which keeps the satellite marking *now* at the middle of the
scene while the arc leans around it.

The **near half is the left one**, which is the half the day's trace runs down. So
the trace is drawn *over* the world rather than swallowed by it, and the track is
unbroken from the left edge of the crop right up to now. Putting the near side on
the right looked identical on the phone — nothing is occluded there — but on the
panel it cut the oldest work off in mid-air.

Where **now** sits along the ring is per-crop for the same reason. The phone only
needs the satellite in the middle of the crop, which is the ring's high point once
it is rolled. The panel needs it on the near/far boundary exactly: anywhere past
it and the newest work is on the far side, so the trace is cut short and the
satellite floats away from the end of its own arc.

The rest is per-crop too, because the two crops answer to different limits. On the
**phone** the track never reaches the world, so the ceiling is geometric — a
tipped ring is narrower than the circle it came from, so reaching the edge of the
screen means going further round it, where it has dropped further. With 79 pt of
altitude it tolerates about 54° and takes 45°.

The **panel** is allowed to overlap, which removes that ceiling. It takes 36° over
a planet at 0.90 of the crop's width, and there the limit is the footer instead:
the track has to still be above it when it reaches the left edge of the window, so
that the orbit visibly *starts* there rather than diving under the chrome. At 36°
and a 5° roll it arrives with about 8 pt to spare, over the Earth and on the near
side, so it is drawn.

Being in orbit, the track goes where the planet goes: dragging the globe carries
the ring and its satellite with it, through the flick and all the way home.

The **terminator** comes free with the projection. Once a pixel knows its own
point on the sphere, the sun's height there is one dot product against the
subsolar direction — so day and night meet along a real curve across a real ball,
and the city lights are masked by that same curve, coming up across a continent
through the evening rather than all at once.

**The globe is a thing you can pick up.** Dragging sideways turns it about its own
poles, scaled by the foreshortening where the finger actually is so the surface
keeps up instead of crawling. Dragging up and down shoves the whole planet — the
one object in the scene that behaves like an object. Both ends of that travel are
elastic, using the usual rubber band, so it can always be pulled a little past its
stop and never comes off it. The travel is deliberately short (9% of the crop):
under the old horizon composition a long pull was the only way to see more of the
ball and was worth 42%, but the whole body is in view now, so all a long pull
would do is post the planet behind the HUD.

Everything belonging to the body — the sphere, its rim, the glow on its horizon,
the ring around it — is drawn from one lifted geometry, so they move as one. The
aim is deliberately *not*: shoving the ball around must never quietly re-point it.

**It turns for home the moment it is let go of**, over about a second and a half —
so the scene is always explorable and never left wrong about where the light is. A
flick still carries, but it carries *into* the way home rather than stopping
somewhere and waiting there: the coast lasts however long the throw is worth, up
to 0.7 s, and is exactly zero when the release had no speed in it. Nothing ever
holds the globe still away from home. That return is walked in steps rather than
handed to one long animation, so a finger landing mid-return picks the globe up
where it looks instead of snapping. The gesture is confined to
the planet's own disc, wherever that disc has been pushed to, so the HUD above is
untouched. Reduce Motion keeps the direct manipulation and drops the momentum; on
macOS the pointer takes a grab cursor over the globe, since a cursor has to be told
a thing can be picked up before anyone tries.

On the **panel** the earth sits a tenth of the crop higher than it first did: with
the footer taking the bottom 50 pt, it had only about 100 pt of its own, which was
not enough of it to be worth looking at. The track stays where it is — there is
only about 15 pt of clear sky between the pills and the limb, and raising it puts
the satellite behind a pill, which is worse than letting it graze the horizon it
is flying over.

## Architecture

```
hourglass/
├── Packages/HourglassCore/     # UI-free, fully unit-tested Swift package
│   ├── Sources/HourglassCore/  #   models, PomodoroEngine, stores, statistics,
│   │                           #   state axes + OrbitPresentationResolver,
│   │                           #   PomodoroWorkdayCoordinator, SolarClock,
│   │                           #   TimerActivityAttributes (Live Activity state)
│   ├── Sources/HourglassCoreSelfCheck/  # `swift run` smoke test (no Xcode needed)
│   └── Tests/HourglassCoreTests/        # Swift Testing suite
├── Shared/                     # cross-platform SwiftUI (Orbit scene + face, pill,
│                               #   OrbitGlobe.metal — the projected sphere,
│                               #   workday rail, stats, history, settings, AppModel)
├── Apps/macOS/                 # custom NSStatusItem + AppKit windows + notifier
├── Apps/iOS/                   # tabs + timer + notifications + LiveActivityController
├── Apps/iOSWidgets/            # WidgetKit extension: Live Activity UI
└── project.yml                 # XcodeGen spec -> Hourglass.xcodeproj
```

**`HourglassCore`** holds all the logic and has no UI framework dependency:

- `PomodoroEngine` — an `@Observable @MainActor` state machine. Time is driven by
  an injected `PomodoroClock` and **`remaining` is always derived from a stored
  `endDate`**, never decremented — so the countdown is drift-free and stays
  correct across pauses, missed ticks, and system sleep / app suspension.
  A phase that runs out **does not advance itself**: it records the session,
  raises the alert, and keeps counting upward (`overrun`) until the user presses
  Continue. Auto-start then decides whether the next phase begins on its own.
  Pausing a focus is treated as taking a break, so the workday stops counting
  that time as work rather than billing a coffee run.
- `SettingsStore` (UserDefaults) and `HistoryStore` (JSON in Application Support),
  each behind a protocol with an in-memory fake for tests.
- `StatisticsCalculator` — pure functions for daily totals, streaks, the per-day
  chart, range roll-ups and the day's worked stretches, with an injectable
  calendar/date for deterministic tests.
- `HistoryFilter` — what History is narrowed to (kind, span, text) and what that
  leaves, resolved against an injected `now`, calendar and locale. Also resolves
  a set of selected row ids back to the records behind them, so a bulk delete
  never asks the tracker to remove a break out of a workday it is also deleting.
- **State axes** (`OrbitState`) — `WorkdayState` and `PomodoroState` are modelled
  separately and combined only in `OrbitPresentationResolver`, a pure function
  from a snapshot to everything the surfaces draw. Views never re-derive a label,
  a badge mark, or whether Break belongs on screen.
- `PomodoroWorkdayCoordinator` — keeps a Pomodoro break and the workday's rest
  interval the same thing. Expressed as one idempotent `reconcile()` rather than
  per-transition handlers, because the transitions arrive repeatedly and out of
  order (callback, foreground, sync pull, cold-launch restore); converging on the
  state cannot open a second break, and a handler per transition did.
- `SolarClock` — pure sunrise/sunset (NOAA) including the polar cases, plus the
  sun's elevation, declination and hour angle at an instant, and `SolarPhase` to
  name the stretch of day that elevation falls in. With no coordinate it stands
  on the equator at the time zone's own longitude, which keeps the documented
  06:00–18:00 day while still giving the scene a real sun to raise and set.

The apps are thin: a shared `AppModel` owns the engine + stores, and each platform
wires its own notification/sound behaviour onto the engine's callbacks.

### App icon

The icon is generated rather than drawn, so it stays in step with the palette and
uses the same SF Symbol vocabulary as the app:

```bash
swift Tools/MakeAppIcon.swift /tmp/icons
```

It writes `mac_*.png` (squircle, inset) and `ios_1024.png` (full-bleed opaque
square, as the App Store requires); copy them into the two `AppIcon.appiconset`
folders.

The mark is deliberately the only thing in it. An icon is read at 16 pt in a
Finder list and at a glance on a home screen, so scene detail that looks good at
1024 is only noise everywhere the icon is actually used. Pass `ember` as a second
argument for the inverse — a dark mark on an ember field.

## Requirements

- **macOS 26+ (Tahoe)** for the Mac app (required for Liquid Glass); **iOS 17+**
  for the iOS app (Live Activities need 16.1+; Liquid Glass applies on iOS 26+).
- Xcode 26, Swift 6.
- The **Metal toolchain**, which Xcode 26 no longer installs by default and which
  the globe's shader needs. If the build stops at `cannot execute tool 'metal'`:

  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- The iOS build embeds a WidgetKit extension (`Hourglass-iOSWidgets`) for the Live
  Activity.

## Build & run

Generate the Xcode project (run again after adding/removing files):

```bash
xcodegen generate
```

**Core logic** — runnable with only the Command Line Tools:

```bash
cd Packages/HourglassCore && swift run hourglass-selfcheck   # quick smoke test
cd Packages/HourglassCore && swift test                       # full Swift Testing suite (needs Xcode)
```

**macOS app:**

```bash
xcodebuild -project Hourglass.xcodeproj -scheme Hourglass-macOS \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/Hourglass.app
```

**iOS app** (needs the iOS Simulator platform: `xcodebuild -downloadPlatform iOS`):

```bash
xcodebuild -project Hourglass.xcodeproj -scheme Hourglass-iOS \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## Notes

- Signing is **ad-hoc** (`CODE_SIGN_IDENTITY = "-"`) so both apps build and run
  locally with no developer team. For distribution, set `DEVELOPMENT_TEAM`, switch
  to Automatic signing, and re-enable the macOS App Sandbox + Hardened Runtime.
- The macOS app is a menu-bar agent (`LSUIElement`); it shows a Dock icon only
  while a window is open.
