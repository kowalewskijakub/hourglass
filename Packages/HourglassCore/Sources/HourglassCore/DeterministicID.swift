import Foundation
import CryptoKit

extension UUID {
    /// A UUID two devices derive identically from the same facts.
    ///
    /// Records that more than one device can independently decide to create need
    /// an identity neither of them invents. The engine already solves this for
    /// Pomodoro sessions by minting one id at `start()` and sharing it through
    /// the live state; a linked work break has no such moment — both devices
    /// notice the same focus completing and each opens a rest — so its identity
    /// is derived instead. Same day, same phase, same id: the stores and the
    /// server upsert the two writes into one interval rather than charging the
    /// user twice for one break.
    ///
    /// A name-based (version 5) UUID over SHA-256, so the derivation is stable
    /// across launches, platforms and releases.
    public static func deterministic(namespace: UUID, name: String) -> UUID {
        var hasher = SHA256()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))

        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
