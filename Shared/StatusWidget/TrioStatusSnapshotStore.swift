import Foundation

/// A local App Group file shared by the containing app and its display widgets.
/// The app is the sole writer; widgets only load this bounded snapshot.
public struct TrioStatusSnapshotStore {
    public static let widgetKind = "TrioStatusWidget"
    public static let fileName = "TrioStatusWidget-v1.json"
    public static let maximumPayloadSize = 16 * 1024

    private let directoryURL: URL?

    public init(appGroupIdentifier: String) {
        directoryURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// Explicit directory injection supports synthetic tests without accessing
    /// any real app group or app data.
    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func configured(bundle: Bundle = .main) -> Self? {
        guard let identifier = bundle.object(forInfoDictionaryKey: "AppGroupID") as? String,
              !identifier.isEmpty, !identifier.contains("$(")
        else { return nil }
        return Self(appGroupIdentifier: identifier)
    }

    private func fileURL() throws -> URL {
        guard let directoryURL else { throw TrioStatusSnapshotError.unavailableContainer }
        return directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    public func load() throws -> TrioStatusSnapshot? {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: Self.maximumPayloadSize + 1) ?? Data()
        guard data.count <= Self.maximumPayloadSize else { throw TrioStatusSnapshotError.oversizedPayload }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(TrioStatusSnapshot.self, from: data)
    }

    public func save(_ snapshot: TrioStatusSnapshot) throws {
        let url = try fileURL()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumPayloadSize else { throw TrioStatusSnapshotError.oversizedPayload }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS) && !targetEnvironment(macCatalyst)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func remove() throws {
        let url = try fileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
