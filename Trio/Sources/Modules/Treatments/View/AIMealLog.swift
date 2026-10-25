import Foundation

/// One AI meal analysis: the input the provider saw, its estimate, and the values the user finally applied.
struct AIMealLogEntry: Codable, Equatable, Identifiable {
    struct Applied: Codable, Equatable {
        let carbs: Double
        let fat: Double
        let protein: Double
        let note: String
        let at: Date
    }

    let id: UUID
    let createdAt: Date
    let provider: String
    let model: String
    let webSearch: Bool
    let description: String
    let hasPhoto: Bool
    let estimate: AIMealEstimate
    var applied: Applied?
    /// Increases with every change; the relay has seen the entry when `uploadedRevision == revision`.
    var revision: Int
    var uploadedRevision: Int?
}

/// Meal photos and analyses in Documents/ai-meals, uploaded to the AI bridge so MCP clients can read them.
///
/// Photos stay on this iPhone and the configured bridge only; they are not part of the Keychain backup.
final class AIMealLogStore {
    static let shared = AIMealLogStore()

    static let retention: TimeInterval = 365 * 24 * 3600
    static let maxEntries = 2000

    private let directory: URL
    private let lock = NSLock()

    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ai-meals"))
    {
        self.directory = directory
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    func photoURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }

    func entries() -> [AIMealLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    func photo(for id: UUID) -> Data? {
        try? Data(contentsOf: photoURL(for: id))
    }

    /// Records a successful analysis and returns its id, or nil when it could not be stored.
    @discardableResult func record(
        estimate: AIMealEstimate,
        configuration: AIMealConfiguration,
        webSearch: Bool,
        description: String,
        jpeg: Data?,
        now: Date = Date()
    ) -> UUID? {
        let entry = AIMealLogEntry(
            id: UUID(),
            createdAt: now,
            provider: configuration.provider.rawValue,
            model: configuration.model,
            webSearch: webSearch,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            hasPhoto: jpeg != nil,
            estimate: estimate,
            applied: nil,
            revision: 1,
            uploadedRevision: nil
        )
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let jpeg { try jpeg.write(to: photoURL(for: entry.id), options: .atomic) }
            var all = load()
            all.append(entry)
            try save(pruned(all, now: now))
            return entry.id
        } catch {
            warning(.service, "AI meal log could not be saved: \(error)")
            return nil
        }
    }

    func markApplied(_ id: UUID, carbs: Double, fat: Double, protein: Double, note: String, at: Date = Date()) {
        update(id) { entry in
            entry.applied = .init(carbs: carbs, fat: fat, protein: protein, note: note, at: at)
        }
    }

    func markUploaded(_ uploaded: [UUID: Int]) {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        for index in all.indices {
            if let revision = uploaded[all[index].id] { all[index].uploadedRevision = revision }
        }
        try? save(all)
    }

    /// A new bridge connection has none of the meals yet.
    func resetUploadState() {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        for index in all.indices { all[index].uploadedRevision = nil }
        try? save(all)
    }

    func pendingUploads(limit: Int) -> [AIMealLogEntry] {
        Array(entries().filter { $0.uploadedRevision != $0.revision }.prefix(limit))
    }

    private func update(_ id: UUID, _ change: (inout AIMealLogEntry) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        all[index].revision += 1
        try? save(all)
    }

    private func pruned(_ all: [AIMealLogEntry], now: Date) -> [AIMealLogEntry] {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let sorted = all.sorted { $0.createdAt < $1.createdAt }
        let kept = Array(sorted.filter { $0.createdAt >= cutoff }.suffix(Self.maxEntries))
        let keptIDs = Set(kept.map(\.id))
        for entry in sorted where !keptIDs.contains(entry.id) {
            try? FileManager.default.removeItem(at: photoURL(for: entry.id))
        }
        return kept
    }

    private func load() -> [AIMealLogEntry] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AIMealLogEntry].self, from: data)) ?? []
    }

    private func save(_ all: [AIMealLogEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(all).write(to: indexURL, options: .atomic)
    }

    /// Relay payload: metadata plus the photo as base64 JPEG.
    func uploadPayload(_ entry: AIMealLogEntry) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        // Same limits as the relay schema, so an unusual AI answer cannot make the upload fail.
        func text(_ value: String?, _ limit: Int) -> String { String((value ?? "").prefix(limit)) }
        func amount(_ value: Double) -> Double { min(max(value, 0), 10000) }
        var item: [String: Any] = [
            "id": entry.id.uuidString,
            "createdAt": iso.string(from: entry.createdAt),
            "provider": text(entry.provider, 64),
            "model": text(entry.model, 200),
            "webSearch": entry.webSearch,
            "description": text(entry.description, 4000),
            "revision": entry.revision,
            "estimate": [
                "carbs": amount(entry.estimate.carbs),
                "fat": amount(entry.estimate.fat),
                "protein": amount(entry.estimate.protein),
                "confidence": text(entry.estimate.confidence, 32),
                "notes": text(entry.estimate.notes, 4000),
                "shortNote": text(entry.estimate.shortNote, 200),
                "items": entry.estimate.items.prefix(100).map { item -> [String: Any] in
                    var value: [String: Any] = ["name": text(item.name, 200), "carbs": amount(item.carbs)]
                    if let grams = item.grams { value["grams"] = amount(grams) }
                    if let fat = item.fat { value["fat"] = amount(fat) }
                    if let protein = item.protein { value["protein"] = amount(protein) }
                    return value
                }
            ]
        ]
        if let applied = entry.applied {
            item["applied"] = [
                "carbs": amount(applied.carbs), "fat": amount(applied.fat), "protein": amount(applied.protein),
                "note": text(applied.note, 200), "at": iso.string(from: applied.at)
            ]
        }
        if entry.hasPhoto, let photo = photo(for: entry.id) {
            item["photo"] = photo.base64EncodedString()
        }
        return item
    }
}
