import Foundation

/// Persists the server-assigned `EnrolledIdentity` (user_id, device_id,
/// display_name, color_hint) post-enroll so subsequent app launches can
/// drive `SessionService.connect` instead of forcing a fresh enrollment.
///
/// Stored alongside `DeviceIdentity` in the Keychain (same accessibility
/// flag) so the first-launch wipe (`KeychainWipe`) picks it up too —
/// reinstall = new identity, atomically.
public enum EnrolledIdentityStore {
    public static let tag = "com.nesttalk.enrolled.v1"

    public static func save(_ identity: EnrolledIdentity) throws {
        let payload = try JSONEncoder().encode(Codable_(identity))
        try KeychainBlob.upsert(account: tag, data: payload)
    }

    public static func load() -> EnrolledIdentity? {
        guard
            let data = try? KeychainBlob.read(account: tag),
            let codable = try? JSONDecoder().decode(Codable_.self, from: data)
        else { return nil }
        return codable.identity
    }

    public static func delete() {
        try? KeychainBlob.delete(account: tag)
    }

    private struct Codable_: Codable {
        let userId: String
        let deviceId: String
        let displayName: String
        let colorHint: Int
        init(_ id: EnrolledIdentity) {
            userId = id.userId
            deviceId = id.deviceId
            displayName = id.displayName
            colorHint = id.colorHint
        }
        var identity: EnrolledIdentity {
            EnrolledIdentity(userId: userId, deviceId: deviceId,
                             displayName: displayName, colorHint: colorHint)
        }
    }
}
