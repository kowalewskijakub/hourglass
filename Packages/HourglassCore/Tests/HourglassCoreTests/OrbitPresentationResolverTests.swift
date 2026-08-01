import Testing
import Foundation
@testable import HourglassCore

/// The resolver is the only thing that decides what the Orbit surfaces say, so
/// these tests are the specification: every reference state, the Break
/// eligibility rule, the badge grammar, and the pill rules that keep the face
/// from repeating itself.
@Suite struct OrbitPresentationResolverTests {

    // A fixed locale and calendar: the copy under test is locale-aware, so a
    // machine in Warsaw must not produce different assertions from one in
    // London. UTC keeps "9:12" meaning 9:12.
    private static let locale = Locale(identifier: "en_GB")
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = locale
        return calendar
    }()

    private static let day = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 00:00 UTC

    private static func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
    }

    private func snapshot(
        workday: WorkdayState,
        pomodoro: PomodoroState,
        now: Date = at(14, 32),
        clockedInAt: Date? = at(9, 12),
        netWorkedToday: TimeInterval = 3 * 3600 + 12 * 60,
        timeSinceLastBreak: TimeInterval? = 41 * 60,
        pausedAt: Date? = nil,
        focusesCompletedInCycle: Int = 2,
        nextPhaseKind: SessionKind = .shortBreak,
        yesterdayWorked: TimeInterval? = 6 * 3600 + 40 * 60,
        surface: OrbitSurface = .phone
    ) -> OrbitSnapshot {
        OrbitSnapshot(
            now: now,
            workday: workday,
            pomodoro: pomodoro,
            clockedInAt: clockedInAt,
            netWorkedToday: netWorkedToday,
            timeSinceLastBreak: timeSinceLastBreak,
            pausedAt: pausedAt,
            focusesCompletedInCycle: focusesCompletedInCycle,
            sessionsUntilLongBreak: 4,
            nextPhaseKind: nextPhaseKind,
            nextFocusDuration: 25 * 60,
            yesterdayWorked: yesterdayWorked,
            surface: surface,
            locale: Self.locale,
            calendar: Self.calendar
        )
    }

    // MARK: The six reference states

    @Test func clockedOutShowsWallClockAndClockIn() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(workday: .clockedOut, pomodoro: .idle, clockedInAt: nil)
        )

        #expect(presentation.stateLabel == "Clocked out")
        #expect(presentation.numeral.kind == .wallClock)
        #expect(presentation.numeral.text == "14:32")
        #expect(presentation.workdayRail == nil)
        #expect(presentation.cycleDots == nil)
        #expect(presentation.contextPills.map(\.full) == ["Yesterday · 6h 40m"])
        #expect(presentation.controls == .primary(
            LabeledAction(action: .clockIn, title: "Clock in", icon: .clockIn,
                          tone: .ember, accessibilityLabel: "Clock in")
        ))
        #expect(presentation.sceneMode == .inactive)
        #expect(presentation.canStartManualBreak == false)
    }

    @Test func clockedInWithoutPomodoroCountsWorkAndOffersBreak() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)), pomodoro: .idle)
        )

        #expect(presentation.stateLabel == "Clocked in")
        #expect(presentation.numeral.kind == .workedToday)
        #expect(presentation.numeral.text == "3:12:00")
        #expect(presentation.contextPills.map(\.full) == ["Last break · 41m ago"])
        #expect(presentation.workdayRail?.primary == "3h 12m worked")
        #expect(presentation.workdayRail?.secondary == "Clocked in 9:12")
        #expect(presentation.workdayRail?.inlineAction?.action == .startBreak)
        #expect(presentation.canStartManualBreak)
        #expect(presentation.sceneMode == .recording)
    }

    @Test func focusRunningShowsTransportAndEndTime() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(
                workday: .working(startedAt: Self.at(9, 12)),
                pomodoro: .running(kind: .focus, remaining: 24 * 60 + 53)
            )
        )

        #expect(presentation.stateLabel == "Focus")
        #expect(presentation.numeral.text == "24:53")
        #expect(presentation.numeral.kind == .countdown)
        #expect(presentation.cycleDots == CycleDotsPresentation(
            completed: 2, total: 4, accessibilityLabel: "cycle 3 of 4"))
        #expect(presentation.contextPills.map(\.full) == ["Ends 14:56"])
        #expect(presentation.workdayRail?.inlineAction?.action != .startBreak)
        #expect(presentation.canStartManualBreak == false)

        guard case .transport(let transport) = presentation.controls else {
            Issue.record("expected transport controls"); return
        }
        #expect(transport.previous.accessibilityLabel == "Back to focus")
        #expect(transport.playPause.action == .pause)
        #expect(transport.next.accessibilityLabel == "Forward to short break")
        // Restart moved off the transport row and onto the rail's one slot.
        #expect(presentation.workdayRail?.inlineAction?.action == .restartPhase)
    }

    @Test func focusPausedFreezesTheCountdownButNotTheWorkday() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(
                workday: .working(startedAt: Self.at(9, 12)),
                pomodoro: .paused(kind: .focus, remaining: 24 * 60 + 53),
                pausedAt: Self.at(14, 32)
            )
        )

        #expect(presentation.stateLabel == "Focus paused")
        #expect(presentation.numeral.kind == .frozenCountdown)
        #expect(presentation.contextPills.map(\.full) == ["Since 14:32"])
        // The workday keeps recording: the rail still reads worked time, and the
        // scene keeps its ember trace even though the phase itself has cooled.
        #expect(presentation.workdayRail?.primary == "3h 12m worked")
        #expect(presentation.workdayRail?.tone == .ember)
        #expect(presentation.sceneMode == .paused)

        guard case .transport(let transport) = presentation.controls else {
            Issue.record("expected transport controls"); return
        }
        #expect(transport.playPause.action == .resume)
    }

    @Test func pomodoroBreakIsShownAsALinkedWorkBreak() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(
                workday: .onBreak(startedAt: Self.at(14, 27, 48), source: .pomodoro(.shortBreak)),
                pomodoro: .running(kind: .shortBreak, remaining: 4 * 60 + 12)
            )
        )

        #expect(presentation.stateLabel == "Short break")
        #expect(presentation.numeral.text == "04:12")
        #expect(presentation.contextPills.map(\.full) == ["Next · Focus 25m"])
        #expect(presentation.workdayRail?.primary == "Break · 4m 12s")
        #expect(presentation.workdayRail?.secondary == "Started automatically")
        #expect(presentation.workdayRail?.inlineAction?.action != .startBreak)
        #expect(presentation.workdayRail?.inlineAction?.action == .backToWork)
        guard case .transport(let transport) = presentation.controls else {
            Issue.record("a Pomodoro break moves through the cycle like any phase"); return
        }
        #expect(transport.playPause.action == .pause)
        #expect(presentation.sceneMode == .resting)
    }

    @Test func manualBreakExplainsItsAccounting() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(
                workday: .onBreak(startedAt: Self.at(14, 20), source: .manual),
                pomodoro: .idle,
                now: Self.at(14, 32, 8)
            )
        )

        #expect(presentation.stateLabel == "Break")
        #expect(presentation.numeral.kind == .breakElapsed)
        #expect(presentation.numeral.text == "12:08")
        #expect(presentation.contextPills.map(\.full) == ["Workday 3h 12m"])
        #expect(presentation.workdayRail?.secondary == "Started 14:20")
        #expect(presentation.canStartManualBreak == false)
    }

    // MARK: Break eligibility — the rule the whole redesign turns on

    @Test func manualBreakIsOfferedOnlyWhileWorkingWithNoPomodoroPhase() {
        let working = WorkdayState.working(startedAt: Self.at(9, 12))
        let phases: [PomodoroState] = [
            .ready(kind: .focus, remaining: 25 * 60),
            .running(kind: .focus, remaining: 60),
            .paused(kind: .focus, remaining: 60),
            .ready(kind: .shortBreak, remaining: 5 * 60),
            .running(kind: .shortBreak, remaining: 60),
            .paused(kind: .shortBreak, remaining: 60),
            .completed(kind: .shortBreak),
        ]

        #expect(OrbitPresentationResolver.resolve(
            snapshot(workday: working, pomodoro: .idle)).canStartManualBreak)

        for phase in phases {
            let presentation = OrbitPresentationResolver.resolve(
                snapshot(workday: working, pomodoro: phase))
            #expect(presentation.canStartManualBreak == false, "\(phase) must hide Break")
            #expect(presentation.workdayRail?.inlineAction?.action != .startBreak, "\(phase) must hide Break")
        }
    }

    // MARK: Staged and completion states

    @Test func stagedBreakKeepsTheWorkdayRestingAndOffersToStartTheTimer() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(
                workday: .onBreak(startedAt: Self.at(14, 30), source: .pomodoro(.shortBreak)),
                pomodoro: .ready(kind: .shortBreak, remaining: 5 * 60)
            )
        )

        #expect(presentation.stateLabel == "Short break")
        #expect(presentation.numeral.text == "05:00")
        #expect(presentation.sceneMode == .resting)

        guard case .transport(let transport) = presentation.controls else {
            Issue.record("expected the cycle transport"); return
        }
        #expect(transport.playPause.action == .startPhase)
        #expect(transport.playPause.accessibilityLabel == "Start short break")
        // Leaving the rest is the rail's job, because it also ends the linked
        // work break — which neither arrow does.
        #expect(presentation.workdayRail?.inlineAction?.action == .backToWork)
    }

    @Test func aFinishedBreakWaitsAtZeroUntilTheUserComesBack() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(
                workday: .onBreak(startedAt: Self.at(14, 27), source: .pomodoro(.shortBreak)),
                pomodoro: .completed(kind: .shortBreak)
            )
        )

        #expect(presentation.stateLabel == "Break complete")
        #expect(presentation.numeral.text == "00:00")
        #expect(presentation.workdayRail?.inlineAction?.action == .backToWork)
        // Still resting: work must not resume on its own.
        #expect(presentation.sceneMode == .resting)
        #expect(presentation.workdayRail?.tone == .stone)
    }

    @Test func stagedFocusOffersStartAndKeepsSkipReachable() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(
                workday: .working(startedAt: Self.at(9, 12)),
                pomodoro: .ready(kind: .focus, remaining: 25 * 60)
            )
        )

        #expect(presentation.stateLabel == "Focus")
        #expect(presentation.numeral.text == "25:00")
        guard case .transport(let transport) = presentation.controls else {
            Issue.record("expected the cycle transport"); return
        }
        #expect(transport.playPause.action == .startPhase)
        #expect(transport.next.accessibilityLabel == "Forward to short break")
        #expect(presentation.workdayRail?.inlineAction?.action == .restartPhase)
    }

    @Test func aPausedBreakIsNamedAsSuchAndCanBeResumedOrLeft() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(
                workday: .onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.longBreak)),
                pomodoro: .paused(kind: .longBreak, remaining: 4 * 60 + 12)
            )
        )

        #expect(presentation.stateLabel == "Long break paused")
        #expect(presentation.numeral.kind == .frozenCountdown)
        guard case .transport(let transport) = presentation.controls else {
            Issue.record("expected the cycle transport"); return
        }
        #expect(transport.playPause.accessibilityLabel == "Resume long break")
        #expect(presentation.workdayRail?.inlineAction?.action == .backToWork)
    }

    // MARK: Pills

    @Test func thePhoneShowsOnePillAndThePanelTwo() {
        let workday = WorkdayState.working(startedAt: Self.at(9, 12))
        let pomodoro = PomodoroState.running(kind: .focus, remaining: 24 * 60 + 53)

        let phone = OrbitPresentationResolver.resolve(
            snapshot(workday: workday, pomodoro: pomodoro, surface: .phone))
        let panel = OrbitPresentationResolver.resolve(
            snapshot(workday: workday, pomodoro: pomodoro, surface: .panel))

        #expect(phone.contextPills.count == 1)
        #expect(panel.contextPills.count == 2)
        #expect(panel.contextPills.map(\.full) == ["Ends 14:56", "Workday 3h 12m"])
    }

    @Test func noPillEverRepeatsWhatIsAlreadyOnScreen() {
        let states: [(WorkdayState, PomodoroState)] = [
            (.clockedOut, .idle),
            (.working(startedAt: Self.at(9, 12)), .idle),
            (.working(startedAt: Self.at(9, 12)), .running(kind: .focus, remaining: 300)),
            (.working(startedAt: Self.at(9, 12)), .paused(kind: .focus, remaining: 300)),
            (.onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.shortBreak)),
             .running(kind: .shortBreak, remaining: 250)),
            (.onBreak(startedAt: Self.at(14, 20), source: .manual), .idle),
        ]

        for (workday, pomodoro) in states {
            for surface in [OrbitSurface.phone, .panel] {
                let presentation = OrbitPresentationResolver.resolve(
                    snapshot(workday: workday, pomodoro: pomodoro, surface: surface))
                for pill in presentation.contextPills {
                    #expect(pill.full != presentation.numeral.text)
                    #expect(!pill.full.isEmpty)
                    #expect(!pill.compact.isEmpty)
                    #expect(!pill.accessibilityLabel.isEmpty)
                    // The one permitted overlap is documented: "Work break" may
                    // appear as a macOS pill because the label there names the
                    // Pomodoro phase, not the workday accounting.
                    if pill.id != "linkedWorkBreak" {
                        #expect(pill.full != presentation.stateLabel)
                    }
                    if let rail = presentation.workdayRail {
                        #expect(pill.full != rail.primary)
                        #expect(pill.full != rail.secondary)
                    }
                }
                #expect(presentation.contextPills.count <= (surface == .phone ? 1 : 2))
            }
        }
    }

    @Test func aDayWithNoBreakYetSaysSoRatherThanShowingAnEmptyValue() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)),
                     pomodoro: .idle,
                     timeSinceLastBreak: nil)
        )
        #expect(presentation.contextPills.map(\.full) == ["No break yet"])
    }

    @Test func clockedOutWithNothingToReportShowsNoPill() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(workday: .clockedOut, pomodoro: .idle,
                     clockedInAt: nil, yesterdayWorked: nil)
        )
        #expect(presentation.contextPills.isEmpty)
    }

    // MARK: Menu-bar badge grammar and cadence

    @Test func badgeMarkValueAndCadenceBySate() {
        let working = WorkdayState.working(startedAt: Self.at(9, 12))
        let resting = WorkdayState.onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.shortBreak))
        let manual = WorkdayState.onBreak(startedAt: Self.at(14, 20), source: .manual)

        let cases: [(WorkdayState, PomodoroState, MenuBarMark, String?, MenuBarCadence)] = [
            (working, .running(kind: .focus, remaining: 24 * 60 + 53), .solidEmber, "24:53", .second),
            (working, .paused(kind: .focus, remaining: 24 * 60 + 53), .pause, "24:53", .none),
            (resting, .running(kind: .shortBreak, remaining: 4 * 60 + 12), .solidStone, "04:12", .second),
            (working, .idle, .hollowEmber, "3:12", .minute),
            (manual, .idle, .hollowStone, "12:08", .second),
            (.clockedOut, .idle, .dim, nil, MenuBarCadence.none),
        ]

        for (workday, pomodoro, mark, value, cadence) in cases {
            let badge = OrbitPresentationResolver.resolve(
                snapshot(workday: workday, pomodoro: pomodoro, now: Self.at(14, 32, 8))
            ).menuBarBadge
            #expect(badge.mark == mark, "\(workday) / \(pomodoro)")
            #expect(badge.value == value, "\(workday) / \(pomodoro)")
            #expect(badge.cadence == cadence, "\(workday) / \(pomodoro)")
            #expect(!badge.accessibilityLabel.isEmpty)
        }
    }

    @Test func aPausedBreakBadgeNamesTheActualPhase() {
        let badge = OrbitPresentationResolver.resolve(
            snapshot(
                workday: .onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.shortBreak)),
                pomodoro: .paused(kind: .shortBreak, remaining: 4 * 60 + 12)
            )
        ).menuBarBadge

        #expect(badge.mark == .pause)
        #expect(badge.accessibilityLabel == "Hourglass, short break paused, 4 minutes, 12 seconds remaining.")
    }

    // MARK: Overflow and clock out

    @Test func clockOutIsSecondaryAndConfirmsWhatItWillStop() {
        let running = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)),
                     pomodoro: .running(kind: .focus, remaining: 300))
        )
        #expect(running.overflowActions.map(\.action).contains(.clockOut))
        #expect(running.overflowActions.last?.action == .clockOut)
        // A phase can be left without ending the working day.
        #expect(running.overflowActions.map(\.action).contains(.endPomodoro))
        #expect(running.clockOutNeedsConfirmation)
        #expect(running.clockOut.confirmationMessage == "This stops Focus.")

        let plain = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)), pomodoro: .idle))
        #expect(plain.clockOutNeedsConfirmation == false)

        let breaking = OrbitPresentationResolver.resolve(
            snapshot(workday: .onBreak(startedAt: Self.at(14, 20), source: .manual), pomodoro: .idle))
        #expect(breaking.clockOut.confirmationMessage == "This ends the current work break.")
    }

    @Test func restartIsOnlyOfferedInTheMenuWhenItIsNotAlreadyOnScreen() {
        let focus = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)),
                     pomodoro: .running(kind: .focus, remaining: 300)))
        #expect(focus.overflowActions.map(\.action).contains(.restartPhase) == false)

        let breaking = OrbitPresentationResolver.resolve(
            snapshot(workday: .onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.shortBreak)),
                     pomodoro: .running(kind: .shortBreak, remaining: 250)))
        #expect(breaking.overflowActions.map(\.action).contains(.restartPhase))
    }

    @Test func clockedOutOffersOnlyTheUtilities() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(workday: .clockedOut, pomodoro: .idle, clockedInAt: nil))
        #expect(presentation.overflowActions.map(\.action) == [.history, .settings])
        #expect(presentation.clockOut.isAvailable == false)
    }

    // MARK: Accessibility

    @Test func theSummaryExplainsBothTheTimerAndTheWorkday() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)),
                     pomodoro: .running(kind: .focus, remaining: 24 * 60 + 53))
        )

        #expect(presentation.accessibilitySummary ==
            "Focus, 24 minutes, 53 seconds remaining, cycle 3 of 4. Workday: 3 hours, 12 minutes worked, clocked in at 9:12.")
    }

    // MARK: Derivation of the states themselves

    @Test func clockingOutWinsOverAnyLeftoverPhase() {
        #expect(OrbitPresentationResolver.state(
            workday: .clockedOut,
            pomodoro: .running(kind: .focus, remaining: 60)) == .clockedOut)
    }

    @Test func pomodoroStateIsDerivedFromTheEnginePosition() {
        // Idle at the very start of the cycle is the one state with no phase.
        #expect(PomodoroState.resolve(
            phase: .idle, kind: .focus, remaining: 1500, plannedDuration: 1500,
            cyclePosition: 0, linkedBreak: nil) == .idle)

        // Idle further along means the next phase is staged, not absent.
        #expect(PomodoroState.resolve(
            phase: .idle, kind: .shortBreak, remaining: 300, plannedDuration: 300,
            cyclePosition: 1, linkedBreak: nil) == .ready(kind: .shortBreak, remaining: 300))

        // Staged at a focus while a linked break is still open is a *finished*
        // break waiting for the user, not a fresh focus.
        let linked = LinkedBreak(breakID: UUID(), kind: .shortBreak)
        #expect(PomodoroState.resolve(
            phase: .idle, kind: .focus, remaining: 1500, plannedDuration: 1500,
            cyclePosition: 2, linkedBreak: linked) == .completed(kind: .shortBreak))
    }

    @Test func breakSourceFollowsWhichIntervalThePhaseOwns() {
        let entry = WorkBreak(startedAt: Self.at(14, 20))
        let session = ClockSession(clockedInAt: Self.at(9, 12), breaks: [entry])

        #expect(WorkdayState.resolve(session: session, linkedBreak: nil)
            == .onBreak(startedAt: Self.at(14, 20), source: .manual))

        let linked = LinkedBreak(breakID: entry.id, kind: .longBreak)
        #expect(WorkdayState.resolve(session: session, linkedBreak: linked)
            == .onBreak(startedAt: Self.at(14, 20), source: .pomodoro(.longBreak)))

        // A link pointing at some other interval must not colour this one.
        let stale = LinkedBreak(breakID: UUID(), kind: .shortBreak)
        #expect(WorkdayState.resolve(session: session, linkedBreak: stale)
            == .onBreak(startedAt: Self.at(14, 20), source: .manual))
    }
}
