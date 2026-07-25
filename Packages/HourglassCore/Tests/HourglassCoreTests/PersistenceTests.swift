import Testing
import Foundation
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
}
