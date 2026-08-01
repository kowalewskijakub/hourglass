import SwiftUI
import HourglassCore

/// The macOS Orbit panel — one fixed 370 × 268 pt surface used both as the
/// menu-bar popover and as the floating-window body, so the two are identical.
///
/// The panel has no workday rail, so the footer carries the rail's single
/// contextual action — Break while simply working, Restart during a focus phase,
/// Back to work during a break — beside Stats and the overflow menu.
struct HourglassPanel: View {
    @Bindable var model: AppModel
    let controller: MacAppController

    @State private var confirmingClockOut = false

    private static let size = CGSize(width: 370, height: 268)

    var body: some View {
        // Resolved once for the chrome that is not on the per-second path.
        let clockOut = model.orbitPresentation(surface: .panel).clockOut

        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let presentation = model.orbitPresentation(now: now, surface: .panel)
            let palette: OrbitPalette =
                model.daylight.isNight(at: now, mode: model.settings.skyMode) ? .night : .day

            ZStack(alignment: .topLeading) {
                OrbitSceneView(
                    worked: model.workedStretches(now: now),
                    mode: presentation.sceneMode,
                    now: now,
                    window: traceWindow(now: now),
                    crop: .landscape,
                    isDaylight: !palette.isNight
                )

                hud(presentation, palette: palette)
                    .padding(.leading, 20)
                    .padding(.top, 20)

                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        OrbitControlsView(controls: presentation.controls, surface: .panel) {
                            model.perform($0)
                        }
                        .padding(.trailing, 18)
                        .padding(.top, 22)
                    }
                    Spacer(minLength: 0)
                    footer(presentation, palette: palette)
                }
            }
            .environment(\.orbitPalette, palette)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .alert(clockOut.confirmationTitle, isPresented: $confirmingClockOut) {
            Button(clockOut.title, role: .destructive) { model.clockOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Names exactly what stopping now will end.
            Text(clockOut.confirmationMessage)
        }
    }

    // MARK: HUD

    private func hud(_ presentation: OrbitPresentation, palette: OrbitPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(presentation.stateLabel)
                    .font(OrbitType.stateLabel(.panel))
                    .tracking(OrbitType.stateLabelTracking(.panel))
                    .textCase(.uppercase)
                    .foregroundStyle(palette.color(presentation.stateTone))

                if let dots = presentation.cycleDots {
                    CycleDots(completedInCycle: dots.completed, total: dots.total, tint: palette.ember)
                }
            }

            Text(presentation.numeral.text)
                .font(OrbitType.numeral(presentation.numeral.kind, surface: .panel))
                .kerning(-1.4)
                .foregroundStyle(palette.ink)
                .contentTransition(.numericText())
                .padding(.top, 8)

            if !presentation.contextPills.isEmpty {
                ContextPillRow(pills: presentation.contextPills, surface: .panel)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(presentation.accessibilitySummary))
    }

    // MARK: Footer

    private func footer(_ presentation: OrbitPresentation, palette: OrbitPalette) -> some View {
        HStack(spacing: 7) {
            // The panel has no rail, so the rail's single contextual action —
            // Break, Restart, or Back to work — lives here instead. Same slot,
            // same rule, so the two platforms never offer different things.
            if let action = presentation.workdayRail?.inlineAction {
                OrbitInlineActionButton(action: action, surface: .panel) { model.perform($0) }
            }

            Spacer(minLength: 0)

            footerIcon(.stats, help: "Statistics", palette: palette) { controller.openStats() }

            // Settings is only worth a first-level slot on the panel that has
            // nothing else to offer; elsewhere it lives in the overflow.
            if !presentation.clockOut.isAvailable {
                footerIcon(.settings, help: "Settings", palette: palette) { controller.openSettings() }
            }

            Menu {
                ForEach(presentation.overflowActions) { item in
                    if item.isDestructive { Divider() }
                    Button(role: item.isDestructive ? .destructive : nil) {
                        act(item, presentation)
                    } label: {
                        Label(item.title, systemImage: item.icon.symbolName)
                    }
                }
                Divider()
                Button("Quit Hourglass") { controller.quit() }
            } label: {
                Image(systemName: OrbitIcon.overflow.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.inkSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("More actions"))
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        // Part of the panel, so it follows the sky rather than the desktop — a
        // system material here reads as a light bar glued under a night scene.
        .background(palette.sky.opacity(0.82))
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.hairline).frame(height: 1)
        }
    }

    private func footerIcon(
        _ icon: OrbitIcon,
        help: LocalizedStringKey,
        palette: OrbitPalette,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon.symbolName)
                .font(.system(size: 13, weight: .medium))
                // 32 pt drawn, comfortably past the 28 pt macOS minimum.
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.inkSecondary)
        .help(Text(help))
    }

    // MARK: Intent

    private func act(_ item: OverflowItem, _ presentation: OrbitPresentation) {
        switch item.action {
        case .restartPhase:
            model.perform(.restartPhase)
        case .endPomodoro:
            model.endPomodoro()
        case .history:
            controller.openHistory()
        case .settings:
            controller.openSettings()
        case .clockOut:
            if presentation.clockOutNeedsConfirmation {
                confirmingClockOut = true
            } else {
                model.clockOut()
            }
        }
    }

    private func traceWindow(now: Date) -> TimeInterval {
        let start = model.workday.currentSession?.clockedInAt
            ?? model.workedStretches(now: now).first?.start
        guard let start else { return 4 * 3600 }
        return min(12 * 3600, max(2 * 3600, now.timeIntervalSince(start) * 1.25))
    }
}
