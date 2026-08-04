import SwiftUI
import HourglassCore

/// The iOS Orbit face: a full-bleed scene with the workday and the Pomodoro
/// resolved into one HUD, one contextual pill, one workday rail, and the single
/// set of controls the user is most likely to need next.
///
/// Everything on screen comes from `OrbitPresentationResolver`. The view decides
/// where things sit and how they animate; it never decides what they say.
struct OrbitFaceView: View {
    @Bindable var model: AppModel
    var openHistory: () -> Void
    var openSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingClockOut = false
    @State private var hasAppeared = false

    var body: some View {
        // Resolved once for the chrome that is not on the per-second path; the
        // face itself re-resolves inside the timeline below.
        let clockOut = model.orbitPresentation(surface: .phone).clockOut

        // One second is the finest cadence anything here needs: the countdown,
        // the worked total and the break elapsed all move at that rate.
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let presentation = model.orbitPresentation(now: now, surface: .phone)
            let sky = model.daylight.sky(at: now, mode: model.settings.skyMode)
            let palette = sky.palette

            ZStack(alignment: .top) {
                OrbitSceneView(
                    worked: model.workedStretches(now: now),
                    mode: presentation.sceneMode,
                    now: now,
                    window: traceWindow(now: now),
                    crop: .portrait,
                    sky: sky
                )
                .ignoresSafeArea()

                OrbitHUD(
                    presentation: presentation,
                    hasAppeared: hasAppeared,
                    perform: { model.perform($0) },
                    overflow: { item in act(item, presentation) }
                )
                .padding(.horizontal, 24)
                .padding(.top, 8)

                VStack {
                    Spacer(minLength: 0)
                    OrbitControlsView(controls: presentation.controls, surface: .phone) {
                        model.perform($0)
                    }
                    .padding(.bottom, 26)
                }
            }
            .environment(\.orbitPalette, palette)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: palette.isNight)
        }
        .background(Color.black.ignoresSafeArea())
        // An alert rather than a confirmation dialog: this is a destructive
        // choice with something to read, and it must appear in the middle of the
        // screen rather than anchored to whatever was tapped.
        .alert(clockOut.confirmationTitle, isPresented: $confirmingClockOut) {
            Button(clockOut.title, role: .destructive) { model.clockOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Names exactly what stopping now will end.
            Text(clockOut.confirmationMessage)
        }
        .task {
            // Asked once the scene is visible, so the purpose string arrives
            // next to a sky that visibly follows the light.
            model.daylight.requestIfNeeded(for: model.settings.skyMode)
            hasAppeared = true
        }
        .onChange(of: model.settings.skyMode) { _, mode in
            model.daylight.requestIfNeeded(for: mode)
        }
    }

    // MARK: Intent

    private func act(_ item: OverflowItem, _ presentation: OrbitPresentation) {
        switch item.action {
        case .restartPhase:
            model.perform(.restartPhase)
        case .endPomodoro:
            model.endPomodoro()
        case .history:
            openHistory()
        case .settings:
            openSettings()
        case .clockOut:
            if presentation.clockOutNeedsConfirmation {
                confirmingClockOut = true
            } else {
                model.clockOut()
            }
        }
    }

    // MARK: Scene inputs

    /// How far back the visible track reaches: the day so far, widened to at
    /// least two hours so a fresh clock-in is not a single dot, and capped so a
    /// very long day still leaves the recent past readable.
    private func traceWindow(now: Date) -> TimeInterval {
        let start = model.workday.currentSession?.clockedInAt
            ?? model.workedStretches(now: now).first?.start
        guard let start else { return 4 * 3600 }
        return min(12 * 3600, max(2 * 3600, now.timeIntervalSince(start) * 1.25))
    }
}

/// State label, cycle dots, numeral, contextual pill and workday rail — the
/// left-aligned HUD, with the overflow button balancing it on the right.
private struct OrbitHUD: View {
    let presentation: OrbitPresentation
    let hasAppeared: Bool
    let perform: (OrbitAction) -> Void
    let overflow: (OverflowItem) -> Void

    @Environment(\.orbitPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    stateRow
                    numeral
                }
                Spacer(minLength: 12)
                overflowMenu
            }

            if !presentation.contextPills.isEmpty {
                ContextPillRow(pills: presentation.contextPills, surface: .phone)
                    .padding(.top, 13)
            }

            if let rail = presentation.workdayRail {
                WorkdayRail(rail: rail, perform: perform)
                    .padding(.top, 11)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Clock-in ignition: the HUD fades up once rather than snapping in.
        .opacity(hasAppeared ? 1 : 0)
        .animation(reduceMotion ? .easeIn(duration: 0.2) : .easeOut(duration: 1.2), value: hasAppeared)
    }

    private var stateRow: some View {
        HStack(spacing: 9) {
            Text(presentation.stateLabel)
                .font(OrbitType.stateLabel(.phone))
                .tracking(OrbitType.stateLabelTracking(.phone))
                .textCase(.uppercase)
                .foregroundStyle(palette.color(presentation.stateTone))
                .lineLimit(1)

            if let dots = presentation.cycleDots {
                CycleDots(
                    completedInCycle: dots.completed,
                    total: dots.total,
                    tint: palette.color(dots.tone)
                )
            }
        }
        // One concise summary for the whole state instead of five fragments the
        // user has to assemble by swiping.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(presentation.accessibilitySummary))
    }

    private var numeral: some View {
        Text(presentation.numeral.text)
            .font(OrbitType.numeral(presentation.numeral.kind, surface: .phone))
            .kerning(-2)
            // The numeral is always ink: the *tone* of the state is carried by
            // the label above it, and a countdown that changed colour with every
            // phase would read as a second, competing status signal.
            .foregroundStyle(palette.ink)
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityHidden(true) // already spoken in the state summary
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(presentation.overflowActions) { item in
                if item.isDestructive { Divider() }
                Button(role: item.isDestructive ? .destructive : nil) {
                    overflow(item)
                } label: {
                    Label(item.title, systemImage: item.icon.symbolName)
                }
            }
        } label: {
            Image(systemName: OrbitIcon.overflow.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.inkSecondary)
                .frame(width: 44, height: 44)
                .orbitGlass(in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(Text("More actions"))
    }
}
