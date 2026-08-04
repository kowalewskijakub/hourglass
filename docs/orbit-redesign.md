# Orbit — implementation plan

This document is the complete hand-off for implementing the **Orbit** redesign of
Hourglass. It assumes no prior context beyond this repo. The visual reference is
the mockup in [`docs/mockups/orbit-v4.html`](mockups/orbit-v4.html) — open it in a
browser; it renders every screen and state described below. Where this document
and the mockup disagree, the mockup wins on looks and this document wins on
behaviour.

## 1. The concept in one paragraph

The timer screen becomes a view **from orbit above the user's day**. A huge
planet limb sits low on the screen; an orbital path runs above it representing
the 24-hour day. Worked stretches are solid arcs on that path, breaks are the
gaps between them, and the session running right now is a brighter arc head
growing into the "now" satellite at the top of the arc. Pomodoro and the workday
(clock-in/out/breaks, tracked by `WorkdayTracker`) are **equal citizens drawn on
the same orbit** — Pomodoro is an overlay on the day, not the main object. The
scene follows the real sun: before local sunset the planet is the day side
(blue, clouds), after sunset the night side (dark, city lights). Amber is the
only working accent; the cycle reads as dots, never digits; there are **no emoji
anywhere** — SF Symbols only.

## 2. Locked design decisions (do not re-litigate)

| Decision | Value |
| --- | --- |
| Direction | Orbit (planet + orbital day path) |
| Numerals | SF **semibold**, `.system(size:, weight: .semibold)` + `.monospacedDigit()`, tight tracking. No rounded, no light weights. |
| Cycle progress | `CycleDots` next to the kind label ("Focus ● ● ○ ○"). Never "02/04". |
| Workday controls | **Chip morph**: one glass status chip under the numerals; collapsed = read-out, tapped = morphs open into Break / Clock out. Bottom of screen is transport only. |
| Out-of-Pomodoro primary action | A **labelled pill "Start focus"** with a target icon (ring + center dot). Never a bare play triangle outside a running session. Idle states always use labelled pills ("Clock in", "Start focus", "Back to work"); bare glyphs appear only in the running-focus transport. |
| Stats day chart | **Day stripes** — one horizontal 0–24h track per day (see §6.2). Not arcs. |
| macOS panel | Landscape crop of the same scene, ~330×244 pt. Footer: Break · Clock out left, Stats + overflow icons right. **No streak / focus-count in the panel** — nothing appears on macOS that isn't on the iOS main screen. |
| Menu-bar badge | No border/stroke. Solid dot + `mm:ss` while a focus session runs; **hollow** dot + elapsed `h:mm` when clocked in without a timer; stone dot on break; dimmed hollow dot, no time, when clocked out. |
| Tab names | Orbit · Stats · Settings. The Log/History lives **under Stats**, not Settings. |

## 3. Design tokens

Define these as asset-catalog colors (light + dark variants) or a
`OrbitPalette` enum in a new `Shared/OrbitTheme.swift`. "Night" is the value
used on the night scene and dark-mode secondary screens, "Day" on the day scene
and light secondary screens.

| Token | Night | Day | Used for |
| --- | --- | --- | --- |
| `sky` | `#070A10` | `#DFE9F2` (top) → `#CDDFEE` | every canvas |
| `card` | `#0E1420` | `#FFFFFF` | elevated cards (stats/settings) |
| `ember` | `#F0A33F` | `#B3661A` | worked arcs, primary buttons, active toggles, badge dot, tab tint |
| `dawn` | `#FFD9A0` | `#8A4D10` | now-satellite, city lights, "now" dot in charts |
| `atmosphere` | `#7FB4E8` | `#8CC8FF` | planet rim glow **only — never UI chrome** |
| `stone` | `#8A8578` | `#8A8578` | breaks, paused, clocked-out |
| `ink` | `#EDF1F8` | `#16202E` | numerals, primary text |
| `inkSecondary` | ink @ 58% | ink @ 60% | labels, chip text |
| `hairline` | ink @ 9% | ink @ 10–14% | tracks, dividers, card borders |

Type scale (all SF via `.system`, all `.monospacedDigit()` where digits shown):

| Role | Spec |
| --- | --- |
| Timer numerals (iOS) | 66 pt semibold; 46 pt for `h:mm:ss` elapsed-day |
| Timer numerals (macOS panel) | 40 pt semibold; 32 pt for elapsed-day |
| State label | 11 pt bold, uppercase, +0.18em tracking, colored `ember` (or `stone` for rest states) |
| Chip text | 12 pt semibold |
| Stats headline | 36–38 pt semibold |
| Card titles | 10.5 pt bold uppercase +0.1em, `inkSecondary` |

Replace `Shared/SessionTint.swift`'s three-hue scheme: all `SessionKind` tints
collapse to `ember` for `.focus` and `stone` for both breaks. Keep the
`symbolName` mapping but change `.focus` from `apple.intelligence` to
`target` (or `scope`), breaks stay `cup.and.saucer.fill` / `figure.walk`.

## 4. State machine for the face

One enum drives the whole main screen. Derive it in the face view from
`model.engine` + `model.workday` (both already `@Observable`):

```swift
enum FaceState {
    case clockedOut                 // !workday.isClockedIn
    case working                    // clocked in, engine idle/paused-idle
    case onBreak                    // workday.isOnBreak
    case focusRunning               // engine.isRunning (any SessionKind)
    case focusPaused                // engine.phase paused mid-session
}
```

Per-state contents (the mockup shows clockedOut / working / onBreak /
focusRunning explicitly):

| State | Big numeral | State label | Chip (collapsed) | Bottom controls |
| --- | --- | --- | --- | --- |
| `clockedOut` | current wall-clock time (ticks 1/min) | `CLOCKED OUT` (stone) | none — sub-line "yesterday you worked Xh Ym" (from `dailyWorkStats`) | amber pill **Clock in** (arrow-up icon) |
| `working` | elapsed day `h:mm:ss` (`netWorkedToday`, ticks 1 s via `TimelineView`) | `CLOCKED IN` (ember) | `● since 9:12 · break 41m ago ▾` | amber pill **Start focus** (target icon) |
| `onBreak` | break elapsed `m:ss` (`currentSession.activeBreakDuration`) | `ON BREAK` (stone) | `● started 14:28 ▾` (stone dot) | stone pill **Back to work** (play icon is fine here — it resumes, doesn't start) |
| `focusRunning` | `engine.formattedRemaining` | `FOCUS` + `CycleDots` (ember; breaks show their name + stone) | `● 3h 12m · in since 9:12 ▾` | transport: ‹ glass 42 pt · pause **ember 64 pt** · › glass 42 pt |
| `focusPaused` | remaining, dimmed | as focusRunning, satellite stops pulsing | same | transport with play glyph in the big button (resumes — unambiguous while a session exists) |

Transport chevrons call `engine.goToPreviousPhase()` / `goToNextPhase()`; the
big button `engine.toggle()`. "Start focus" also just calls `engine.toggle()`
(engine is idle → starts focus). Clock in/out/break call the existing
`workday.clockIn() / clockOut() / toggleBreak()`. Reset moves to a long-press
on the numerals (confirmation via context menu) — the always-visible Reset
button is gone.

**The chip** (`Shared/WorkdayChip.swift`, new): a capsule that swaps content
between collapsed read-out and expanded actions (Break, Clock out, collapse).
On OS 26 wrap the states in `GlassEffectContainer` so the morph animates; below
26 fall back to `adaptiveGlass` + `matchedGeometryEffect`. Reuse the wording
logic from today's `ClockBar.statusText` (started-at + time-since-break).
`ClockBar.swift` is then deleted.

## 5. The scene (`Shared/OrbitSceneView.swift`, new)

**v1 is pure SwiftUI — no SceneKit.** The mockup's scene decomposes into layers
(back to front); implement with `Canvas`/`Circle` strokes:

1. **Sky** — flat `sky` color; night adds ~12 star dots (fixed positions,
   varied 0.3–0.75 opacity, radius 0.7–1.3 pt).
2. **Planet** — a circle of radius ≈ 2.3× screen width, center ≈ 1.75× screen
   height below the top, so its limb crosses at ~62% of screen height. Night
   fill: radial gradient `#101B2E → #0B1322 → #060A12`; day fill:
   `#4A80B5 → #31608F → #1E4269`.
3. **Surface detail** — night: 8–12 clusters of 1–2 pt `dawn`-colored dots
   (city lights), 2 large near-invisible land blobs; day: 4–5 blurred white
   ellipses (clouds).
4. **Atmosphere rim** — two strokes on the planet circle: 2 pt at
   `atmosphere` 55–60% with 1 pt blur, and 10–12 pt at 26–30% with 7–8 pt blur.
5. **Dawn glow** — a warm blurred ellipse on the *right* rim
   (`rgba(255,166,87,…)`), only while clocked in and there is day left; it
   fades out as the evening empties, and rests entirely on break.
6. **Orbit track** — a concentric circle 60–65 pt above the limb, dotted
   (`dash [2, 15]`, `hairline`).
7. **Day arcs** — on the orbit circle. Map time-of-day → angle with **the
   "now" point fixed at the top of the visible arc** (i.e. rotate the whole
   dial so `now` is at 12 o'clock of the orbit circle; earlier time trails to
   the left, future to the right). Data: `model.workday.sessions()` for
   today → each clock-in→out span minus breaks = one arc at `ember` 38%;
   the currently-recording stretch (or running focus) = `ember` 100% (or 55%
   for plain clocked-in work), round line caps, 7 pt line width (5 pt macOS).
8. **Now satellite** — a 5 pt `dawn` dot at the top of the orbit with a 1.5 pt
   ring at ember 45% and an outer 1 pt ring at 18%; soft glow (shadow). Pulses
   scale 1→1.15 once per second **only while recording** (focus running or
   clocked-in working); still when paused/on break; dimmed stone when clocked
   out.

Parametrize with a `crop` enum: `.portrait` (iOS) and `.landscape` (macOS
panel — planet lower, orbit flatter, smaller radii; see mockup §04).

**Sky mode**: add to `TimerSettings` (see §8) a `skyMode: SkyMode`
(`followSun` default / `alwaysNight` / `alwaysDay`). For `followSun`, compute
sunrise/sunset with a small pure solar-position function in
`Packages/HourglassCore` (NOAA algorithm, ~40 lines, deterministic — unit-test
it; input: date, lat/lon, TZ). Location: coarse, one-shot
`CLLocationManager` with `reducedAccuracy`, cached in UserDefaults; if denied
or unavailable fall back to fixed 6:00/18:00 local. The scene cross-fades
between day and night over ~2 min around the boundary.

**Reduce Motion**: pulse, launch and crossfades collapse to opacity fades; the
scene is a static render.

Phase 2 (behind a compile-time flag, do not block v1): replace layers 2–4 with
a SceneKit sphere using NASA Blue/Black Marble textures (public domain,
bundle ~2–4 MB downsampled), camera above the user's coarse location, real
terminator. The orbit/arc layer stays SwiftUI on top, unchanged.

## 6. Screen-by-screen

### 6.1 iOS main tab ("Orbit") — `Apps/iOS/RootView.swift`, `Shared/OrbitFaceView.swift` (new)

- `TimerScreen` becomes: `OrbitSceneView` full-bleed background, HUD
  top-left-aligned (state label + dots row, numerals, chip — left margin
  ~25 pt, top below the Dynamic Island), controls centered ~120 pt from the
  bottom, standard `TabView` below (the floating glass tab bar is free on
  iOS 26). Tab titles/icons: Orbit (`circle.dotted` or custom orbit glyph),
  Stats (`chart.bar`), Settings (`gearshape`).
- Keep the existing `scenePhase` refresh + `keepAwake` behaviour from
  `TimerScreen` verbatim.
- Delete `TimerFaceView.swift`, `TimerRingView.swift`, `ClockBar.swift` once
  the new face is in (grep for remaining references first — the Live Activity
  does *not* use them). `CycleDots.swift` survives (used in the HUD).

### 6.2 Stats — `Shared/StatisticsView.swift`

Keep the calculator and data flow; restyle:

- Headline: `netWorkedToday` at 36–38 pt semibold + "worked today"; below it
  one ember-colored line: "3 focus sessions · 75 min  ·  5-day streak"
  (streak stays *here* — it is allowed in Stats, just not on the Mac panel).
- Cards (`card` background, 18 pt radius, hairline border, uppercase titles):
  1. **This week** — existing stacked bar chart, recolored: focus = `ember`,
     other work = `ember` at 22–24%. Drop the explanatory caption sentence.
  2. **Day stripes** — replaces the `dayShapeChart`. One row per day, letter
     label (M T W T F S S) left, a 6 pt rounded 0–24h track (`hairline`), the
     span from `dailyClockSpans` (`startHour → endHour`) as a rounded fill:
     past days `ember` 55%, today 100% with a 5 pt `dawn` dot at the
     current-time position. Axis row "0h · noon · 24h". Plain SwiftUI
     (GeometryReader), not Swift Charts — it is simpler and matches the mock.
  3. **History** — embed the session list here. Move `LogView` content: rows
     of dot (+ ember/stone) · "Focus · 25m" · time range, grouped by day,
     tap to edit; keep all existing editing plumbing
     (`model.updateSession` etc.) and `LogExportButton` in the toolbar.

### 6.3 Settings — `Shared/SettingsFormView.swift`

- Remove the iOS-only "Session Log" section (History moved to Stats).
- Add to the Workday section: `Picker("Sky", selection: $model.settings.skyMode)`
  with Follow the sun / Always night / Always day.
- Everything else stays (durations, automation, alerts, reminder, sync,
  mac window mode). Steppers may stay steppers — the mock's tap-through rows
  are cosmetic, not required.

### 6.4 macOS — `Apps/macOS/HourglassPanel.swift`, `MenuBarBadge.swift`, `StatusItemController.swift`

- **Panel** ≈ 330×244 pt, fixed: `OrbitSceneView(crop: .landscape)` as the
  full background; HUD top-left (label+dots, 40/32 pt numerals, sub-line —
  the chip can stay a plain text line on macOS); transport (or state pill)
  top-right; a single bottom hairline **footer bar**: `Break` and `Clock out`
  text buttons left, spacer, chart icon (opens the Stats window) and `⋯` menu
  (Log, Settings…, Quit) right. Both working states are in the mockup —
  focus running and clocked-in-no-timer (the latter shows the "Start focus"
  pill top-right instead of the transport).
- **Badge**: rewrite `MenuBarBadge` per the table in §2 (dot + monospaced
  text, no stroke, no background). `StatusItemController` already re-renders
  an `NSImage` each tick — extend whatever drives it to also re-render on
  `workday` changes (`model.onWorkdayChanged` hook exists on `AppModel`).
- The floating-window mode (`MacAppMode.window`) reuses the same panel view
  unchanged.

### 6.5 Live Activity — `Apps/iOSWidgets/HourglassLiveActivity.swift`, `Shared/SessionTint.swift` extensions

`TimerActivityAttributes.ContentState` already models `timer / clockedIn /
onBreak` modes — no core changes needed. Restyle:

- Lock Screen band: left, a 52 pt crop of the orbit (planet edge + arc head +
  satellite — small `Canvas`, static); middle, state label + small dots row +
  26 pt numerals; right, a 40 pt ember pause/pill. Break state cools to stone.
- Dynamic Island compact: ember dot (hollow when clockedIn mode) + numerals.
  Expanded: label + dots + numerals + one action button.
- Colors from §3; remove any use of the old green/orange tints except: the
  workday `clockedIn` state may keep ember (hollow-dot motif) — do **not**
  reintroduce green.

## 7. Ceremonies (motion spec)

| Event | Animation |
| --- | --- |
| Satellite pulse | scale 1→1.15, opacity ring fade, 1 s loop, only while recording |
| Clock in | the orbit arc "ignites" from the planet limb and the HUD fades up — one-shot ~1.2 s spring; this is the only launch ceremony |
| Focus session completes | dawn-glow flashes across the rim (~0.8 s), one `CycleDots` dot lights with a spring, the finished segment settles from `dawn` to `ember` |
| Chip morph | `GlassEffectContainer` morph on OS 26; crossfade + `matchedGeometryEffect` fallback below |
| Numerals | keep `.contentTransition(.numericText())` |
| Play/pause glyph | `.contentTransition(.symbolEffect(.replace))` |
| Reduce Motion | all of the above become opacity fades; no pulse |

## 8. Core changes (`Packages/HourglassCore`)

Small and few — the engine/tracker/log are untouched:

1. `TimerSettings`: add `var skyMode: SkyMode = .followSun` (`enum SkyMode:
   String, Codable, CaseIterable { case followSun, alwaysNight, alwaysDay }`).
   **Decode with a default** (custom `init(from:)` or optional + accessor) so
   old persisted JSON and old sync payloads still decode; check `SyncWire`
   settings encoding for the same tolerance in the other direction.
2. New `SolarClock.swift`: pure `func sunEvents(on date: Date, latitude:
   Double, longitude: Double, timeZone: TimeZone) -> (sunrise: Date, sunset:
   Date)?` (NOAA approximation; returns nil at extreme latitudes → treat as
   always-day/always-night by solar elevation sign). Add unit tests with 3–4
   known city/date fixtures (±5 min tolerance).
3. Nothing else. Arc data comes from existing `workday.sessions()`,
   `WorkdayLog`, and `StatisticsCalculator.dailyClockSpans`.

Run `cd Packages/HourglassCore && swift test` after — the suite must stay green.

## 9. File plan

| Action | File |
| --- | --- |
| add | `Shared/OrbitTheme.swift` (tokens, fonts, `SessionKind` tint override) |
| add | `Shared/OrbitSceneView.swift` (scene, `crop: .portrait/.landscape`) |
| add | `Shared/OrbitFaceView.swift` (FaceState, HUD, controls, chip wiring) |
| add | `Shared/WorkdayChip.swift` (chip morph) |
| add | `Shared/DayStripesView.swift` (stats card) |
| add | `Packages/HourglassCore/Sources/HourglassCore/SolarClock.swift` + tests |
| modify | `Apps/iOS/RootView.swift` (tab names/icons, TimerScreen → Orbit face) |
| modify | `Shared/StatisticsView.swift` (restyle, stripes, embed History) |
| modify | `Shared/SettingsFormView.swift` (drop log link, add Sky picker) |
| modify | `Apps/macOS/HourglassPanel.swift` (rebuild on the scene) |
| modify | `Apps/macOS/MenuBarBadge.swift` + `StatusItemController.swift` (badge states) |
| modify | `Apps/iOSWidgets/HourglassLiveActivity.swift` (restyle) |
| modify | `Shared/SessionTint.swift` (collapse to ember/stone, new focus symbol) |
| delete | `Shared/TimerFaceView.swift`, `Shared/TimerRingView.swift`, `Shared/ClockBar.swift` (after references are gone) |
| keep | `Shared/CycleDots.swift`, `Shared/AdaptiveGlass.swift`, `Shared/LogView.swift` (re-hosted), everything in `Sync/` |

After adding/removing files: `xcodegen generate` (project is XcodeGen-driven —
`project.yml`). iOS needs location usage strings in `Apps/iOS/Info.plist`
(`NSLocationWhenInUseUsageDescription`, phrased around the sky following the
sun) — only requested when `skyMode == .followSun`.

## 10. Suggested implementation order

1. **Tokens + face skeleton** — `OrbitTheme`, static `OrbitSceneView` (night
   only, fixed arcs from real data), `OrbitFaceView` with all five states and
   plain-crossfade chip. Wire into iOS `TimerScreen`. *App is usable here.*
2. **macOS panel + badge** — landscape crop, footer, badge state table.
3. **Stats + Settings + History move.**
4. **Live Activity restyle.**
5. **Sky** — `SolarClock` + tests, settings row, location plumbing, day scene.
6. **Polish** — glass morph on OS 26, ceremonies, Reduce Motion audit.
7. *(Optional, flagged)* SceneKit globe.

Each step builds and runs on its own; commit per step.

## 11. QA checklist

- [ ] `swift test` green in `Packages/HourglassCore` (incl. new SolarClock tests)
- [ ] Both `xcodebuild` schemes build (commands in `README.md`)
- [ ] All five face states reachable and correct on iOS (clock in → start focus
      → pause → complete → break → clock out) and both on the macOS panel
- [ ] Badge shows: solid+countdown / hollow+elapsed / stone on break / dim when out
- [ ] Cycle dots advance on completion; long-break arrives when dots fill
- [ ] Chip expands/collapses; Break and Clock out work from it; no stacked bars anywhere
- [ ] No bare play glyph visible when no focus session exists
- [ ] Stats: stripes match `dailyClockSpans`; History editing + CSV export still work
- [ ] Sky: forced night/day via Settings; followSun falls back gracefully with
      location denied
- [ ] Live Activity truthful across background/kill (existing look-ahead
      notification behaviour untouched)
- [ ] Sync round-trip: settings with `skyMode` sync against an old-format payload
      without data loss
- [ ] Reduce Motion: no pulse, no launch animation
- [ ] Dark/light: night and day variants of Stats/Settings both legible

## 12. Explicit non-goals (v1)

- No SceneKit/real textures (phase-2 flag)
- No orbit scrubbing gesture (drag-to-review is a later feature)
- No year-in-review / lock-screen wallpaper ceremonies
- No changes to sync protocol, engine timing, stores, or the outbox
