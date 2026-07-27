import Foundation
import Supabase

/// Stores the Supabase auth session in a file instead of the Keychain.
///
/// The Keychain is the SDK's default, but on macOS an ad-hoc-signed app gets a
/// fresh code signature on every build, so the Keychain treats each build as a
/// different app and re-prompts for access. This keeps the session in the app's
/// own Application Support directory, readable only by the owning user
/// (`chmod 0600`), and never involves iCloud Keychain.
///
/// The file holds a refresh token, so it is created with restrictive
/// permissions and excluded from backups.
struct FileSessionStorage: AuthLocalStorage {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    func store(key: String, value: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: key)
        // Owner read/write only — no group or world access.
        try value.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func retrieve(key: String) throws -> Data? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func remove(key: String) throws {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Helpers

    /// Keys come from the SDK and can contain path-unfriendly characters.
    private func fileURL(for key: String) -> URL {
        let safe = key.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return directory.appendingPathComponent("\(safe).session")
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Hourglass", isDirectory: true)
            .appendingPathComponent("Session", isDirectory: true)
    }
}
