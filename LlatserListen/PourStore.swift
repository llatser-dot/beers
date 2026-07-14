import Foundation

/// One dictation = one pour, pinned behind the bar.
struct Pour: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let appName: String
    let date: Date
    let words: Int
    let duration: TimeInterval
    var isKeeper: Bool = false
    var deletedAt: Date? = nil

    init(text: String, appName: String, duration: TimeInterval, date: Date = Date()) {
        self.id = UUID()
        self.text = text
        self.appName = appName
        self.date = date
        self.words = text.split { $0.isWhitespace || $0.isNewline }.count
        self.duration = duration
    }
}

/// JSON-backed history at ~/Library/Application Support/Beers/pours.json.
/// Soft deletes go to the drip tray for 30 days, then purge.
@MainActor
final class PourStore: ObservableObject {
    @Published private(set) var pours: [Pour] = []

    /// Snapshot/preview mode seeds sample pours without touching disk.
    var persistenceEnabled = true

    private static let maxPours = 1000
    private static let dripTrayDays: TimeInterval = 30 * 24 * 3600

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Beers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("pours.json")
        load()
    }

    /// An isolated store that never reads or writes the user's real pours.
    /// The snapshot/demo harness MUST use this — a screenshot rendered from
    /// the real store is a privacy leak waiting for a commit.
    init(inMemory: Bool) {
        fileURL = URL(fileURLWithPath: "/dev/null")
        persistenceEnabled = false
    }

    // MARK: Queries

    var active: [Pour] { pours.filter { $0.deletedAt == nil } }
    var keepers: [Pour] { active.filter(\.isKeeper) }
    var dripTray: [Pour] { pours.filter { $0.deletedAt != nil } }

    var appNames: [String] {
        var counts: [String: Int] = [:]
        for pour in active { counts[pour.appName, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    var poursToday: Int { active.filter { Calendar.current.isDateInToday($0.date) }.count }

    var wordsToday: Int {
        active.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.words }
    }

    /// Consecutive days ending today (or yesterday) with at least one pour.
    var streak: Int {
        let calendar = Calendar.current
        let days = Set(active.map { calendar.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return 0 }

        var cursor = calendar.startOfDay(for: Date())
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(yesterday) else { return 0 }
            cursor = yesterday
        }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    // MARK: Mutations

    func add(_ pour: Pour) {
        pours.insert(pour, at: 0)
        if pours.count > Self.maxPours {
            pours = Array(pours.prefix(Self.maxPours))
        }
        save()
    }

    func toggleKeeper(_ pour: Pour) {
        guard let index = pours.firstIndex(where: { $0.id == pour.id }) else { return }
        pours[index].isKeeper.toggle()
        save()
    }

    func moveToDripTray(_ pour: Pour) {
        guard let index = pours.firstIndex(where: { $0.id == pour.id }) else { return }
        pours[index].deletedAt = Date()
        save()
    }

    func restore(_ pour: Pour) {
        guard let index = pours.firstIndex(where: { $0.id == pour.id }) else { return }
        pours[index].deletedAt = nil
        save()
    }

    /// Smash the glasses: everything gone, forever.
    func smashTheGlasses() {
        pours.removeAll()
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.pourDecoder.decode([Pour].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-Self.dripTrayDays)
        pours = decoded.filter { $0.deletedAt == nil || $0.deletedAt! > cutoff }
    }

    private func save() {
        guard persistenceEnabled else { return }
        guard let data = try? JSONEncoder.pourEncoder.encode(pours) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static var pourDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var pourEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
