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
            completed: 2, total: 4, tone: .ember, accessibilityLabel: "cycle 3 of 4"))
        #expect(presentation.contextPills.map(\.full) == ["Ends 14:56"])
        #expect(presentation.workdayRail?.inlineAction?.action != .startBreak)
        #expect(presentation.canStartManualBreak == false)

        guard case .transport(let transport) = presentation.controls else {
            Issue.record("expected transport controls"); return
        }
        #expect(transport.previous.accessibilityLabel == "Back to focus")
        #expect(transport.playPause.action == .pause)
        #expect(transport.next.accessibilityLabel == "Forward to focus break")
        // Restart moved off the transport row and onto the rail's one slot.
        #expect(presentation.workdayRail?.inlineAction?.action == .restartPhase)
    }

    /// Pausing a focus *is* taking a break, so it says so and the workday rests
    /// with it (the coordinator opens a real interval — see
    /// `pausingFocusOpensARealBreak`). The countdown stays frozen at whatever was
    /// left, because resuming continues that same focus.
    @Test func aPausedFocusIsAFocusBreak() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(
                workday: .onBreak(startedAt: Self.at(14, 32), source: .pomodoro(.focus)),
                pomodoro: .paused(kind: .focus, remaining: 24 * 60 + 53),
                pausedAt: Self.at(14, 32)
            )
        )

        #expect(presentation.stateLabel == "Focus break")
        #expect(presentation.stateTone == .stone)
        #expect(presentation.numeral.kind == .frozenCountdown)
        #expect(presentation.numeral.text == "24:53")
        // Same as every other break: the day's total, nothing to restart, and
        // a trace that has stopped rather than merely cooled.
        #expect(presentation.contextPills.map(\.full) == ["Workday 3h 12m"])
        #expect(presentation.workdayRail?.inlineAction == nil)
        #expect(presentation.sceneMode == .resting)
        #expect(presentation.cycleDots?.tone == .stone)
        #expect(presentation.canStartManualBreak == false)

        guard case .transport(let transport) = presentation.controls else {
            Issue.record("expected transport controls"); return
        }
        #expect(transport.playPause.action == .resume)
    }

    /// One pause control, drawn one way, in a focus and in a break alike. (The
    /// menu bar is the exception on purpose — see `everyRestingBadgeIsADisc`:
    /// an 8pt mark has no room for a glyph that reads as anything.)
    @Test func pausingLooksTheSameInEveryPhase() {
        for (workday, phase) in [
            (WorkdayState.working(startedAt: Self.at(9, 12)),
             PomodoroState.running(kind: .focus, remaining: 300)),
            (.onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.shortBreak)),
             .running(kind: .shortBreak, remaining: 250)),
        ] {
            guard case .transport(let transport) = OrbitPresentationResolver.resolve(
                snapshot(workday: workday, pomodoro: phase)).controls else {
                Issue.record("expected transport controls"); return
            }
            #expect(transport.playPause.action == .pause)
            #expect(transport.playPause.icon == .pause, "\(phase)")
        }
    }

    @Test func pomodoroBreakIsShownAsALinkedWorkBreak() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(
                workday: .onBreak(startedAt: Self.at(14, 27, 48), source: .pomodoro(.shortBreak)),
                pomodoro: .running(kind: .shortBreak, remaining: 4 * 60 + 12)
            )
        )

        #expect(presentation.stateLabel == "Focus break")
        #expect(presentation.numeral.text == "04:12")
        // One pill, and it is the running total — the fact a break does not
        // already carry.
        #expect(presentation.contextPills.map(\.full) == ["Workday 3h 12m"])
        #expect(presentation.workdayRail?.primary == "Break · 4m 12s")
        #expect(presentation.workdayRail?.secondary == "Started automatically")
        // No inline action in a break: the transport is the way through one.
        #expect(presentation.workdayRail?.inlineAction == nil)
        guard case .transport(let transport) = presentation.controls else {
            Issue.record("a Pomodoro break moves through the cycle like any phase"); return
        }
        #expect(transport.playPause.action == .pause)
        // The pause glyph, and ember like the centre button in every phase.
        #expect(transport.playPause.icon == .pause)
        #expect(transport.playPause.tone == .ember)
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

        #expect(presentation.stateLabel == "Focus break")
        #expect(presentation.numeral.text == "05:00")
        #expect(presentation.sceneMode == .resting)

        guard case .transport(let transport) = presentation.controls else {
            Issue.record("expected the cycle transport"); return
        }
        #expect(transport.playPause.action == .startPhase)
        #expect(transport.playPause.accessibilityLabel == "Start focus break")
        #expect(presentation.workdayRail?.inlineAction == nil)
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
        #expect(presentation.workdayRail?.inlineAction == nil)
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
        #expect(transport.next.accessibilityLabel == "Forward to focus break")
        #expect(presentation.workdayRail?.inlineAction?.action == .restartPhase)
    }

    @Test func aPausedBreakIsNamedAsSuchAndCanBeResumedOrLeft() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(
                workday: .onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.longBreak)),
                pomodoro: .paused(kind: .longBreak, remaining: 4 * 60 + 12)
            )
        )

        #expect(presentation.stateLabel == "Focus break paused")
        #expect(presentation.numeral.kind == .frozenCountdown)
        guard case .transport(let transport) = presentation.controls else {
            Issue.record("expected the cycle transport"); return
        }
        #expect(transport.playPause.accessibilityLabel == "Resume focus break")
        #expect(presentation.workdayRail?.inlineAction == nil)
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

    /// Every kind of rest carries exactly one pill on both surfaces, and it is
    /// always the same one: how the day is going. It is the fact a break does
    /// not already carry, and the only number on the surface that stops moving
    /// while you are resting.
    @Test func everyRestCarriesTheWorkdayTotalAndNothingElse() {
        let resting = WorkdayState.onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.shortBreak))
        let phases: [PomodoroState] = [
            .running(kind: .shortBreak, remaining: 250),
            .paused(kind: .shortBreak, remaining: 250),
            .ready(kind: .shortBreak, remaining: 300),
            .completed(kind: .shortBreak),
        ]
        for phase in phases {
            for surface in [OrbitSurface.phone, .panel] {
                let presentation = OrbitPresentationResolver.resolve(
                    snapshot(workday: resting, pomodoro: phase, surface: surface))
                #expect(presentation.contextPills.map(\.id) == ["workdayTotal"],
                        "\(phase) on \(surface)")
                #expect(presentation.contextPills.first?.tone == .stone)
            }
        }
    }

    /// Ember is work, stone is rest — including on the buttons. Break stops work
    /// and is stone; Back to work resumes it and is ember, in both the states it
    /// appears in.
    @Test func theActionsTakeTheToneOfWhatTheyDo() {
        let working = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)), pomodoro: .idle))
        #expect(working.workdayRail?.inlineAction?.action == .startBreak)
        #expect(working.workdayRail?.inlineAction?.tone == .stone)
        #expect(working.controls.allActions.first?.tone == .ember) // Pomodoro

        let manual = OrbitPresentationResolver.resolve(
            snapshot(workday: .onBreak(startedAt: Self.at(14, 20), source: .manual), pomodoro: .idle))
        #expect(manual.controls == .primary(LabeledAction(
            action: .backToWork,
            title: Copy.backToWork(Self.locale),
            icon: .backToWork,
            tone: .ember,
            accessibilityLabel: Copy.backToWork(Self.locale)
        )))

        // Restart takes the phase back rather than recording work, so it is stone.
        let focusing = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)),
                     pomodoro: .running(kind: .focus, remaining: 300)))
        #expect(focusing.workdayRail?.inlineAction?.action == .restartPhase)
        #expect(focusing.workdayRail?.inlineAction?.tone == .stone)
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
            (working, .paused(kind: .focus, remaining: 24 * 60 + 53), .solidStone, "24:53", .none),
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

    /// Every kind of rest is a disc in the menu bar, advancing or not — a
    /// scheduled break, and a focus the user paused. What says it is not
    /// advancing is the number: it stops moving, because the cadence does.
    @Test func everyRestingBadgeIsADisc() {
        let resting = WorkdayState.onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.shortBreak))
        let breaks: [PomodoroState] = [
            .running(kind: .shortBreak, remaining: 250),
            .paused(kind: .shortBreak, remaining: 4 * 60 + 12),
            .ready(kind: .shortBreak, remaining: 300),
        ]
        for phase in breaks {
            let badge = OrbitPresentationResolver.resolve(
                snapshot(workday: resting, pomodoro: phase)).menuBarBadge
            #expect(badge.mark == .solidStone, "\(phase) should be a disc, not the pause bars")
        }

        let paused = OrbitPresentationResolver.resolve(
            snapshot(workday: resting, pomodoro: .paused(kind: .shortBreak, remaining: 4 * 60 + 12))
        ).menuBarBadge
        #expect(paused.cadence == .none, "a frozen break must not tick")
        #expect(paused.accessibilityLabel == "Hourglass, focus break paused, 4 minutes, 12 seconds remaining.")

        // A paused focus is a rest too, so it takes the disc as well.
        let pausedFocus = OrbitPresentationResolver.resolve(
            snapshot(workday: .onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.focus)),
                     pomodoro: .paused(kind: .focus, remaining: 300))
        ).menuBarBadge
        #expect(pausedFocus.mark == .solidStone)

        // The bars are left for a phase that is staged and has never run.
        let staged = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)),
                     pomodoro: .ready(kind: .focus, remaining: 300))
        ).menuBarBadge
        #expect(staged.mark == .pause)
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

    /// Restart belongs to the work. It is on the rail while a focus is in play
    /// and offered nowhere at all during a rest — restarting one is not a thing
    /// anyone reaches for, and it was the only entry standing between the user
    /// and the menu's real contents.
    @Test func restartIsOnTheRailDuringFocusAndNowhereDuringARest() {
        let focus = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)),
                     pomodoro: .running(kind: .focus, remaining: 300)))
        #expect(focus.workdayRail?.inlineAction?.action == .restartPhase)
        #expect(focus.overflowActions.map(\.action).contains(.restartPhase) == false)

        for (workday, phase) in [
            (WorkdayState.onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.shortBreak)),
             PomodoroState.running(kind: .shortBreak, remaining: 250)),
            (.onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.focus)),
             .paused(kind: .focus, remaining: 300)),
        ] {
            let resting = OrbitPresentationResolver.resolve(snapshot(workday: workday, pomodoro: phase))
            #expect(resting.overflowActions.map(\.action).contains(.restartPhase) == false, "\(phase)")
            #expect(resting.workdayRail?.inlineAction == nil, "\(phase)")
        }
    }

    /// One rule, two surfaces. The panel has a footer to put leaving the timer
    /// in, so it is a control there; the phone has only the overflow, so it
    /// stays a menu item there — and neither offers it twice.
    @Test func leavingTheTimerIsAFooterControlOnThePanelAndAMenuItemOnThePhone() {
        let running = PomodoroState.running(kind: .focus, remaining: 300)
        let working = WorkdayState.working(startedAt: Self.at(9, 12))

        let phone = OrbitPresentationResolver.resolve(
            snapshot(workday: working, pomodoro: running, surface: .phone))
        #expect(phone.endPomodoro == nil)
        #expect(phone.overflowActions.map(\.action).contains(.endPomodoro))

        let panel = OrbitPresentationResolver.resolve(
            snapshot(workday: working, pomodoro: running, surface: .panel))
        #expect(panel.endPomodoro?.action == .endPomodoro)
        #expect(panel.endPomodoro?.title == "End Pomodoro")
        #expect(panel.overflowActions.map(\.action).contains(.endPomodoro) == false)
    }

    @Test func thereIsNothingToLeaveWithoutAPhase() {
        let plain = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)),
                     pomodoro: .idle, surface: .panel))
        #expect(plain.endPomodoro == nil)

        let resting = OrbitPresentationResolver.resolve(
            snapshot(workday: .onBreak(startedAt: Self.at(14, 20), source: .manual),
                     pomodoro: .idle, surface: .panel))
        #expect(resting.endPomodoro == nil)

        let out = OrbitPresentationResolver.resolve(
            snapshot(workday: .clockedOut, pomodoro: .idle,
                     clockedInAt: nil, surface: .panel))
        #expect(out.endPomodoro == nil)
    }

    /// Dots belong to the cycle, so a break keeps them. They used to vanish for
    /// the length of every break, which read as the app losing count.
    @Test func theCycleDotsStayUpThroughABreak() {
        let onBreak = OrbitPresentationResolver.resolve(
            snapshot(workday: .onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.shortBreak)),
                     pomodoro: .running(kind: .shortBreak, remaining: 250),
                     focusesCompletedInCycle: 2))
        #expect(onBreak.cycleDots?.completed == 2)
        #expect(onBreak.cycleDots?.total == 4)
        // Grey while resting: the dots take the state label's tone, so the row
        // stops insisting the screen is about work in the middle of a break.
        #expect(onBreak.cycleDots?.tone == .stone)
        #expect(OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)),
                     pomodoro: .running(kind: .focus, remaining: 300))
        ).cycleDots?.tone == .ember)
        // A frozen focus is stone too, exactly like its label.
        #expect(OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)),
                     pomodoro: .paused(kind: .focus, remaining: 300))
        ).cycleDots?.tone == .stone)

        let finished = OrbitPresentationResolver.resolve(
            snapshot(workday: .onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.longBreak)),
                     pomodoro: .completed(kind: .longBreak),
                     focusesCompletedInCycle: 4))
        #expect(finished.cycleDots?.completed == 4)
        // Never "session 5 of 4" at the end of the set.
        #expect(finished.cycleDots?.accessibilityLabel == Copy.cycle(4, 4, Self.locale))
    }

    /// A workday with no cycle running has no position to report.
    @Test func aWorkdayWithNoCycleHasNoDots() {
        #expect(OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)), pomodoro: .idle)
        ).cycleDots == nil)
        #expect(OrbitPresentationResolver.resolve(
            snapshot(workday: .onBreak(startedAt: Self.at(14, 20), source: .manual), pomodoro: .idle)
        ).cycleDots == nil)
        #expect(OrbitPresentationResolver.resolve(
            snapshot(workday: .clockedOut, pomodoro: .idle, clockedInAt: nil)
        ).cycleDots == nil)
    }

    /// Once the day is under way its labelled action joins the other controls in
    /// the footer; only the one that starts the day keeps the empty screen.
    @Test func onlyPomodoroJoinsTheFooter() {
        #expect(OrbitPresentationResolver.resolve(
            snapshot(workday: .clockedOut, pomodoro: .idle, clockedInAt: nil)
        ).primaryPlacement == .hero)

        let working = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)), pomodoro: .idle))
        #expect(working.primaryPlacement == .footer)
        #expect(working.controls == .primary(LabeledAction(
            action: .startFocus,
            title: Copy.startFocus(Self.locale),
            icon: .focus,
            tone: .ember,
            accessibilityLabel: Copy.startFocusSpoken(Self.locale)
        )))
        // Named for what it starts, so it pairs with "End Pomodoro" beside it.
        #expect(working.controls.allActions.first?.title == "Pomodoro")
        #expect(working.controls.allActions.first?.accessibilityLabel == "Start a Pomodoro")

        // Back to work is the one thing to do on a resting screen, so it keeps
        // the hero slot. Only Pomodoro joins the footer.
        #expect(OrbitPresentationResolver.resolve(
            snapshot(workday: .onBreak(startedAt: Self.at(14, 20), source: .manual), pomodoro: .idle)
        ).primaryPlacement == .hero)
    }

    // MARK: Running past the end

    /// A phase that has run out does not move on by itself. It says so, counts
    /// the other way, and offers exactly one thing: Continue.
    @Test func aFinishedFocusCountsOnAndOffersContinue() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(workday: .working(startedAt: Self.at(9, 12)),
                     pomodoro: .overrun(kind: .focus, over: 134))
        )

        #expect(presentation.stateLabel == "Focus", "a finished focus is still the focus")
        #expect(presentation.numeral.kind == .overrun)
        #expect(presentation.numeral.text == "+02:14", "counting up, and signed so")
        // A finished focus is still work being done.
        #expect(presentation.stateTone == .ember)
        #expect(presentation.sceneMode == .recording)
        #expect(presentation.cycleDots != nil, "still a phase of the cycle")
        #expect(presentation.workdayRail?.inlineAction == nil)

        #expect(presentation.controls == .primary(LabeledAction(
            action: .continuePhase,
            title: "Continue",
            icon: .continueOn,
            tone: .ember,
            accessibilityLabel: "Continue to the break"
        )))
        // Big and over the scene, not shrunk into the footer strip.
        #expect(presentation.primaryPlacement == .hero)
    }

    /// The same, for the other end of the cycle — and a finished break is still
    /// rest, so it cools where a finished focus stays ember.
    @Test func aFinishedBreakCountsOnAndOffersContinue() {
        let presentation = OrbitPresentationResolver.resolve(
            snapshot(workday: .onBreak(startedAt: Self.at(14, 28), source: .pomodoro(.shortBreak)),
                     pomodoro: .overrun(kind: .shortBreak, over: 61))
        )

        #expect(presentation.stateLabel == "Focus break")
        #expect(presentation.numeral.text == "+01:01")
        #expect(presentation.stateTone == .stone)
        #expect(presentation.sceneMode == .resting)
        #expect(presentation.controls.allActions.map(\.action) == [.continuePhase])
        #expect(presentation.controls.allActions.first?.accessibilityLabel == "Continue to the focus")
        // Leaving the timer altogether is still one click away.
        #expect(presentation.endPomodoro == nil, "phone keeps it in the overflow")
        #expect(presentation.overflowActions.map(\.action).contains(.endPomodoro))
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

    @Test func pomodoroStateIsDerivedFromWhetherACycleIsUnderWay() {
        // Idle with no cycle under way is the one state with no phase.
        #expect(PomodoroState.resolve(
            phase: .idle, kind: .focus, remaining: 1500, plannedDuration: 1500,
            overrun: 0, isCycleUnderWay: false, linkedBreak: nil) == .idle)

        // Idle *within* a cycle means the phase is staged, not absent — and this
        // is the case position alone could not express, because scrubbing back
        // to the first focus lands on position 0 with an idle phase.
        #expect(PomodoroState.resolve(
            phase: .idle, kind: .focus, remaining: 1500, plannedDuration: 1500,
            overrun: 0, isCycleUnderWay: true, linkedBreak: nil)
            == .ready(kind: .focus, remaining: 1500))

        #expect(PomodoroState.resolve(
            phase: .idle, kind: .shortBreak, remaining: 300, plannedDuration: 300,
            overrun: 0, isCycleUnderWay: true, linkedBreak: nil)
            == .ready(kind: .shortBreak, remaining: 300))

        // Staged at a focus while a linked break is still open is a *finished*
        // break waiting for the user, not a fresh focus.
        let linked = LinkedBreak(breakID: UUID(), kind: .shortBreak)
        #expect(PomodoroState.resolve(
            phase: .idle, kind: .focus, remaining: 1500, plannedDuration: 1500,
            overrun: 0, isCycleUnderWay: true, linkedBreak: linked)
            == .completed(kind: .shortBreak))

        // Running past the deadline is its own state: the phase has finished but
        // has not been left, and only the user leaves it.
        #expect(PomodoroState.resolve(
            phase: .running, kind: .focus, remaining: 0, plannedDuration: 1500,
            overrun: 134, isCycleUnderWay: true, linkedBreak: nil)
            == .overrun(kind: .focus, over: 134))
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
