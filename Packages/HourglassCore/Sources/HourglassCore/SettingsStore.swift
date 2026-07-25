import Foundation
import Observation

/// Read/write access to the user's ``TimerSettings``.
@MainActor
public protocol SettingsStoring: AnyObject {
    var settings: TimerSettings { get set }
}

/// Persists settings as JSON in `UserDefaults`. Observable so settings screens
/// and the engine react to changes.
@MainActor
@Observable
public final class UserDefaultsSettingsStore: SettingsStoring {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    // Backing storage is observed; the computed `settings` persists on write.
    private var storage: TimerSettings

    public var settings: TimerSettings {
        get { storage }
        set {
            storage = newValue
            persist()
        }
    }

    public init(defaults: UserDefaults = .standard, key: String = "hourglass.settings") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(TimerSettings.self, from: data) {
            self.storage = decoded
        } else {
            self.storage = .default
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: key)
    }
}

/// In-memory settings for tests and previews.
@MainActor
@Observable
public final class InMemorySettingsStore: SettingsStoring {
    public var settings: TimerSettings
    public init(settings: TimerSettings = .default) {
        self.settings = settings
    }
}
