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
  work break and clocked-in stretch, plus CSV export.

- **macOS** (Tahoe 26+) — one borderless menu-bar item whose mark and value
  change with state (fill = bounded vs open-ended, colour = work vs rest, and a
  distinct pause mark); clicking it only opens or closes the 370 × 268 pt Orbit
  panel. A Settings toggle switches between **menu-bar** and a **floating
  window** (with keep-on-top).
- **iOS** — a full-bleed Orbit face with Orbit / Stats / Settings tabs; a **Live
  Activity** (Lock Screen + Dynamic Island) in the same state grammar, ticking
  off the device clock; wall-clock accurate across backgrounding with a
  look-ahead local notification.
- **Sky** — the Orbit scene alone follows local daylight (`SolarClock`, coarse
  location, 06:00–18:00 fallback). Stats, History and Settings follow the system
  appearance, so a sunset never flips the information UI.

### Photographic Earth

The planet renders real Earth imagery, blended across the day/night terminator
and turning with the time of day. `OrbitPlanetTexture` reads two images from each
app's asset catalog, and falls back to a procedural planet if they are absent —
so removing them is a supported way to ship without imagery:

| Asset name | What it is |
| --- | --- |
| `OrbitEarthDay` | Equirectangular (plate carrée) colour map, 2:1, longitude −180…180 left to right |
| `OrbitEarthNight` | Same projection and size, city lights on black. Optional — without it the night side simply darkens |

`OrbitPlanetTexture` picks them up automatically; the scene then blends the two
across the terminator and turns the visible face with the time of day.

Both apps currently ship NASA imagery, downscaled to 2048 × 1024 (~440 KB total
per app):

- `OrbitEarthDay` — [Blue Marble: Land Surface, Shallow Water and Shaded
  Topography](https://visibleearth.nasa.gov/images/57752), NASA Earth Observatory
- `OrbitEarthNight` — [Earth at Night 2012](https://visibleearth.nasa.gov/images/79765),
  NASA Earth Observatory / NOAA Suomi NPP VIIRS

NASA content is generally not copyrighted and may be used for any purpose; NASA
asks that it be credited, which the app does in Settings → Workday.

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
- `SettingsStore` (UserDefaults) and `HistoryStore` (JSON in Application Support),
  each behind a protocol with an in-memory fake for tests.
- `StatisticsCalculator` — pure functions for daily totals, streaks, the 7-day
  chart and the day's worked stretches, with an injectable calendar/date for
  deterministic tests.
- **State axes** (`OrbitState`) — `WorkdayState` and `PomodoroState` are modelled
  separately and combined only in `OrbitPresentationResolver`, a pure function
  from a snapshot to everything the surfaces draw. Views never re-derive a label,
  a badge mark, or whether Break belongs on screen.
- `PomodoroWorkdayCoordinator` — keeps a Pomodoro break and the workday's rest
  interval the same thing. Expressed as one idempotent `reconcile()` rather than
  per-transition handlers, because the transitions arrive repeatedly and out of
  order (callback, foreground, sync pull, cold-launch restore); converging on the
  state cannot open a second break, and a handler per transition did.
- `SolarClock` — pure sunrise/sunset (NOAA), including the polar cases, with a
  fixed 06:00 / 18:00 fallback when no coordinate is available.

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
