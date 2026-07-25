# Hourglass

A minimalist **Pomodoro focus timer** for **macOS** and **iOS**, inspired by
[Flow](https://www.producthunt.com/products/flow-app). One big timer, focus /
short-break / long-break cycles, free bidirectional navigation through the cycle,
an editable session log, completion alerts, and focus statistics — sharing a
single, fully-tested Swift core across both platforms.

Common to both:

- **Scrub the cycle** — ◀ / ▶ arrows move freely backward/forward through the
  Pomodoro sequence (Focus 1 → Break 1 → Focus 2 → … → Long break → repeat).
- **Editable log** — view, add, edit, and delete every recorded focus/break session.
- Focus statistics with Swift Charts (today, streak, all-time, 7-day chart).

- **macOS** (Tahoe 26+) — a custom menu-bar item showing the **Flow-style minutes
  badge** in a rounded rectangle, tinted by session kind with a colour dot;
  **left-click** opens a popover, **right-click** starts/pauses. A Settings toggle
  switches between **menu-bar** and a **floating window** (with keep-on-top).
  Adopts **Liquid Glass** throughout.
- **iOS** — a full-screen timer with a progress ring; Timer / Log / Stats /
  Settings tabs; a **Live Activity** (Lock Screen + Dynamic Island) that ticks off
  the device clock; wall-clock accurate across backgrounding with a look-ahead
  local notification.

## Architecture

```
hourglass/
├── Packages/HourglassCore/     # UI-free, fully unit-tested Swift package
│   ├── Sources/HourglassCore/  #   models, PomodoroEngine, stores, statistics,
│   │                           #   TimerActivityAttributes (Live Activity state)
│   ├── Sources/HourglassCoreSelfCheck/  # `swift run` smoke test (no Xcode needed)
│   └── Tests/HourglassCoreTests/        # Swift Testing suite (29 tests)
├── Shared/                     # cross-platform SwiftUI (ring, face, log, settings,
│                               #   charts, AdaptiveGlass helper, AppModel)
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
- `StatisticsCalculator` — pure functions for daily totals, streaks, and the
  7-day chart, with an injectable calendar/date for deterministic tests.

The apps are thin: a shared `AppModel` owns the engine + stores, and each platform
wires its own notification/sound behaviour onto the engine's callbacks.

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
