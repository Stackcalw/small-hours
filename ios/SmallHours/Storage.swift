import Foundation

// One JSON file per night in Application Support, keyed by the date you WOKE on.
// Waking at 03:30 still belongs to that morning, so no rollover logic is needed.
enum Storage {
    static var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmallHours", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func dayKey(_ t: TimeInterval) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    /// Keyed by the date you woke on — but a daytime nap wakes on the same
    /// date as that morning's night, and would silently overwrite it. Sleeps
    /// are matched on their start time, so re-saving the SAME sleep (adding a
    /// rested rating) still updates in place.
    static func save(_ night: Night) {
        let key = dayKey(night.endAt)
        var url = dir.appendingPathComponent("\(key).json")
        if let existing = try? JSONDecoder().decode(Night.self, from: Data(contentsOf: url)),
           abs(existing.startAt - night.startAt) > 600 {
            var i = 2
            while FileManager.default.fileExists(atPath: url.path) {
                if let e = try? JSONDecoder().decode(Night.self, from: Data(contentsOf: url)),
                   abs(e.startAt - night.startAt) <= 600 { break }
                url = dir.appendingPathComponent("\(key)-\(i).json"); i += 1
            }
        }
        guard let data = try? JSONEncoder().encode(night) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load(limit: Int = 60) -> [Night] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "session.json" }
            .compactMap { try? JSONDecoder().decode(Night.self, from: Data(contentsOf: $0)) }
            .sorted { $0.endAt > $1.endAt }
            .prefix(limit).map { $0 }
    }

    /// Checkpointed every few minutes so a crash or an overnight kill loses the
    /// tail of the night, never the whole thing.
    struct LiveSession: Codable {
        var startAt: TimeInterval
        var target: TimeInterval
        var windowMinutes: Int
        var epochs: [Epoch]
    }
    static var liveURL: URL { dir.appendingPathComponent("session.json") }
    static func saveLive(_ s: LiveSession) {
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: liveURL, options: .atomic) }
    }
    static func loadLive() -> LiveSession? {
        guard let d = try? Data(contentsOf: liveURL) else { return nil }
        return try? JSONDecoder().decode(LiveSession.self, from: d)
    }
    static func clearLive() { try? FileManager.default.removeItem(at: liveURL) }
}
