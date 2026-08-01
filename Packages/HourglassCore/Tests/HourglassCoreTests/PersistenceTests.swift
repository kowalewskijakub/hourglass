import Testing
import Foundation
import Observation
@testable import HourglassCore

@MainActor
@Suite struct PersistenceTests {

    @Test func settingsPersistThroughUserDefaults() {
        let suite = UserDefaults(suiteName: "hourglass.test.\(UUID().uuidString)")!
        let store = UserDefaultsSettingsStore(defaults: suite, key: "s")

        var updated = store.settings
        updated.focusDuration = 1234
        updated.autoStartBreaks = true
        store.settings = updated

        // A fresh store reading the same defaults should see the persisted value.
        let reloaded = UserDefaultsSettingsStore(defaults: suite, key: "s")
        #expect(reloaded.settings.focusDuration == 1234)
        #expect(reloaded.settings.autoStartBreaks == true)
    }

    @Test func historyPersistsToFileAndReloads() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileHistoryStore(fileURL: url)
        #expect(store.all().isEmpty)

        var session = FocusSession(
            kind: .focus,
            plannedDuration: 1500,
            startedAt: Date(),
            endedAt: Date(),
            completed: true
        )
        store.add(session)

        let reloaded = FileHistoryStore(fileURL: url)
        #expect(reloaded.all().count == 1)
        #expect(reloaded.all().first?.plannedDuration == 1500)

        // Full-edit CRUD survives reload.
        session.plannedDuration = 600
        reloaded.update(session)
        #expect(FileHistoryStore(fileURL: url).all().first?.plannedDuration == 600)

        reloaded.delete(id: session.id)
        #expect(FileHistoryStore(fileURL: url).all().isEmpty)

        reloaded.add(session)
        reloaded.clear()
        #expect(FileHistoryStore(fileURL: url).all().isEmpty)
    }

    /// The same generic store backs both seams, so workdays get the same
    /// round-trip coverage history has.
    @Test func workdaysPersistToFileAndReload() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileWorkdayStore(fileURL: url)
        #expect(store.all().isEmpty)

        let start = Date()
        var session = ClockSession(clockedInAt: start)
        store.add(session)

        let reloaded = FileWorkdayStore(fileURL: url)
        #expect(reloaded.all().count == 1)
        #expect(reloaded.all().first?.isActive == true)

        session.clockedOutAt = start.addingTimeInterval(3600)
        session.breaks = [WorkBreak(startedAt: start, endedAt: start.addingTimeInterval(600))]
        reloaded.update(session)

        let afterUpdate = FileWorkdayStore(fileURL: url).all().first
        #expect(afterUpdate?.isActive == false)
        #expect(afterUpdate?.netDuration() == 3000)

        reloaded.delete(id: session.id)
        #expect(FileWorkdayStore(fileURL: url).all().isEmpty)

        reloaded.add(session)
        reloaded.clear()
        #expect(FileWorkdayStore(fileURL: url).all().isEmpty)
    }

    /// Pins the on-disk names: the two seams share one generic store, and must
    /// keep reading the files a user already has.
    @Test func eachStoreKeepsItsOwnFileUnderApplicationSupport() {
        let history = FileHistoryStore.defaultURL()
        let workdays = FileWorkdayStore.defaultURL()

        #expect(history.lastPathComponent == "history.json")
        #expect(workdays.lastPathComponent == "workdays.json")
        #expect(history.deletingLastPathComponent() == workdays.deletingLastPathComponent())
        #expect(history.deletingLastPathComponent().lastPathComponent == "Hourglass")
    }

    /// Observation is what refreshes the statistics views when a session lands,
    /// so it has to survive the store being generic.
    @Test func writingToAStoreNotifiesObservers() {
        nonisolated(unsafe) var historyChanged = false
        nonisolated(unsafe) var workdaysChanged = false

        let history = InMemoryHistoryStore()
        let workdays = InMemoryWorkdayStore()

        withObservationTracking { _ = history.all() } onChange: { historyChanged = true }
        withObservationTracking { _ = workdays.all() } onChange: { workdaysChanged = true }

        history.add(FocusSession(kind: .focus, plannedDuration: 1500, startedAt: Date()))
        workdays.add(ClockSession(clockedInAt: Date()))

        #expect(historyChanged)
        #expect(workdaysChanged)
    }

    /// Update/delete/clear behave the same in the fakes both suites rely on.
    @Test func inMemoryStoresEditInPlaceForBothRecordTypes() {
        var focus = FocusSession(kind: .focus, plannedDuration: 1500, startedAt: Date())
        let history = InMemoryHistoryStore(sessions: [focus])
        focus.completed = true
        history.update(focus)
        #expect(history.all().first?.completed == true)
        history.delete(id: focus.id)
        #expect(history.all().isEmpty)

        var clock = ClockSession(clockedInAt: Date())
        let workdays = InMemoryWorkdayStore(sessions: [clock])
        clock.clockedOutAt = Date()
        workdays.update(clock)
        #expect(workdays.all().first?.isActive == false)
        workdays.clear()
        #expect(workdays.all().isEmpty)
    }

    @Test func settingsCodableRoundTrip() throws {
        let settings = TimerSettings(
            focusDuration: 111,
            shortBreakDuration: 22,
            longBreakDuration: 33,
            sessionsUntilLongBreak: 3,
            autoStartBreaks: true,
            autoStartFocus: true,
            soundEnabled: false,
            notificationsEnabled: false
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TimerSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func partialSettingsJSONDecodesWithDefaults() throws {
        // Simulates a payload written by an older version missing new keys.
        let json = #"{"focusDuration": 600}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TimerSettings.self, from: json)
        #expect(decoded.focusDuration == 600)
        #expect(decoded.shortBreakDuration == TimerSettings.default.shortBreakDuration)
        #expect(decoded.sessionsUntilLongBreak == TimerSettings.default.sessionsUntilLongBreak)
    }

    // MARK: Sky mode — added after the sync protocol shipped

    @Test func settingsWithoutASkyDecodeToFollowTheSun() throws {
        let json = #"{"focusDuration": 600, "autoStartBreaks": true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TimerSettings.self, from: json)
        #expect(decoded.skyMode == .followSun)
        #expect(decoded.autoStartBreaks)
    }

    @Test func skyModeSurvivesARoundTrip() throws {
        var settings = TimerSettings.default
        settings.skyMode = .alwaysNight
        let decoded = try JSONDecoder().decode(
            TimerSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    /// A sky written by a *newer* peer must not cost this device the rest of its
    /// settings — an unknown value falls back rather than failing the payload.
    @Test func anUnknownSkyDoesNotDiscardTheOtherSettings() throws {
        let json = #"{"focusDuration": 600, "skyMode": "eclipse", "soundEnabled": false}"#
            .data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TimerSettings.self, from: json)
        #expect(decoded.skyMode == .followSun)
        #expect(decoded.focusDuration == 600)
        #expect(decoded.soundEnabled == false)
    }
}
