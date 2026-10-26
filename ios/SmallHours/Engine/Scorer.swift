import Foundation

// =============================================================================
// SCORER — night metrics + personal baseline -> one number, and why.
//
// Six components, weights summing to 100. Every curve is written out so the
// number is arguable rather than magic. Components that cannot be evaluated
// (no baseline yet, no latency, no movement) drop out and their weight is
// redistributed, so night one gets a real score instead of a penalty for
// being night one.
//
// The score stays objective — it comes from the sensors. How rested you felt
// sits next to it and is never blended in: the gap between the two is the most
// interesting thing this app can show you.
// =============================================================================

public struct Baseline: Sendable {
    public var nights: Int = 0
    public var midMinutes: Double?
    public var avgAsleep: TimeInterval?
    public var avgScore: Int?
    public init(nights: Int = 0, midMinutes: Double? = nil, avgAsleep: TimeInterval? = nil, avgScore: Int? = nil) {
        self.nights = nights; self.midMinutes = midMinutes; self.avgAsleep = avgAsleep; self.avgScore = avgScore
    }
}

public struct ComponentResult: Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var name: String
    public var weight: Double
    public var value: Double?     // 0...1, nil when not scoreable
    public var points: Double = 0
    public var lost: Double = 0
    public var display: String
    public var lever: String
    public var skipped: Bool { value == nil }
}

public struct ScoreResult: Sendable {
    public var total: Int?
    public var rows: [ComponentResult] = []
    public var confidence: Double = 0
    public var confidenceLabel: String = ""
    public var headline: String = ""
    public var subhead: String = ""
    public var worst: ComponentResult?
}

public enum Scorer {

    static let bands: [(Int, String, String)] = [
        (86, "A strong night", "This is what your good nights look like."),
        (72, "A solid night",  "Nothing to fix here."),
        (58, "A patchy night", "The sleep was there, it just kept breaking."),
        (44, "A short night",  "Not a disaster. Tonight is the fix."),
        (0,  "A hard night",   "These happen. Nothing to make up for — just tonight, as normal."),
    ]

    public static func compute(_ a: Night, baseline b: Baseline) -> ScoreResult {
        var rows: [ComponentResult] = []

        // 1. duration ---------------------------------------------------------
        let hours = a.asleep / 3600
        var durationValue = curve([(0,0),(3,0.12),(4.5,0.34),(5.5,0.55),(6.5,0.80),
                                   (7,0.93),(7.5,1),(9,1),(9.75,0.88),(11,0.68),(13,0.5)], hours)
        if a.estimated { durationValue = min(durationValue, 0.85) }
        rows.append(ComponentResult(
            key: "duration", name: "How long you slept", weight: 30, value: durationValue,
            display: durShort(a.asleep) + (a.estimated ? " (estimated)" : ""),
            lever: "Going to bed 30 minutes earlier is the single biggest lever here."))

        // 2. efficiency -------------------------------------------------------
        rows.append(ComponentResult(
            key: "efficiency", name: "Time asleep vs time in bed", weight: 18,
            value: a.efficiency.map { curve([(0.5,0),(0.65,0.22),(0.75,0.48),(0.82,0.72),(0.88,0.93),(0.92,1),(1,1)], $0) },
            display: a.efficiency.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
            lever: "Get into bed closer to when you actually fall asleep — lying awake in bed costs you here."))

        // 3. continuity -------------------------------------------------------
        var continuityValue: Double?
        var continuityText = "—"
        if let waso = a.waso, let wakes = a.awakenings {
            let mins = waso / 60
            let base = curve([(0,1),(8,0.96),(18,0.84),(32,0.66),(50,0.45),(75,0.25),(110,0.08),(160,0)], mins)
            let pen = curve([(0,0),(2,0),(4,0.06),(7,0.15),(12,0.28)], Double(wakes))
            continuityValue = clampd(base - pen, 0, 1)
            continuityText = wakes == 0 ? "unbroken" : "\(wakes) wake-up\(wakes > 1 ? "s" : ""), \(Int(mins.rounded()))m"
        }
        rows.append(ComponentResult(
            key: "continuity", name: "Staying asleep", weight: 17, value: continuityValue, display: continuityText,
            lever: "Wake-ups this many times usually track with alcohol, a warm room, or a late heavy meal."))

        // 4. settledness ------------------------------------------------------
        rows.append(ComponentResult(
            key: "settled", name: "How settled the sleep was", weight: 12,
            value: a.settledShare.map { curve([(0,0.08),(0.06,0.32),(0.11,0.62),(0.16,0.90),(0.20,1),
                                               (0.27,1),(0.34,0.86),(0.45,0.62),(0.6,0.4)], $0) },
            display: a.settledShare.map { "\(Int(($0 * 100).rounded()))% of the night still" } ?? "—",
            lever: "The stillest sleep front-loads the night, so an earlier bedtime buys more of it than a later lie-in does."))

        // 5. latency ----------------------------------------------------------
        rows.append(ComponentResult(
            key: "latency", name: "Falling asleep", weight: 11,
            value: a.latency.map { curve([(0,0.62),(4,0.86),(8,1),(18,1),(26,0.88),(38,0.66),
                                          (52,0.44),(70,0.24),(95,0.08)], $0 / 60) },
            display: a.latency.map { "\(Int(($0 / 60).rounded())) min" } ?? "—",
            lever: "If it takes over 30 minutes most nights, the fix is usually a later bedtime, not an earlier one. This reads movement, so lying still and awake counts as asleep — if it felt longer than this says, trust yourself."))

        // 6. timing regularity -------------------------------------------------
        var timingValue: Double?
        var timingText = "learning"
        if b.nights >= 3, let baseMid = b.midMinutes, let mid = a.midSleep {
            let diff = circularDiffMinutes(minutesOfDay(mid), baseMid)
            timingValue = curve([(0,1),(20,0.96),(40,0.84),(65,0.66),(95,0.45),(130,0.26),(180,0.08),(240,0)], diff)
            timingText = diff < 15 ? "right on your usual" : "\(Int(diff.rounded())) min off your usual"
        }
        rows.append(ComponentResult(
            key: "timing", name: "Same hours as usual", weight: 12, value: timingValue, display: timingText,
            lever: "Your body scores the clock, not just the hours. Keeping the middle of the night steady is worth more than any single long night."))

        // --- combine ----------------------------------------------------------
        let available = rows.compactMap { $0.value != nil ? $0.weight : nil }.reduce(0, +)
        guard available > 0 else {
            return ScoreResult(total: nil, rows: rows, confidence: 0, confidenceLabel: "no read",
                               headline: bands[4].1, subhead: bands[4].2)
        }
        let k = 100 / available
        var total = 0.0
        for i in rows.indices {
            guard let v = rows[i].value else { continue }
            rows[i].points = rows[i].weight * k * v
            rows[i].lost = rows[i].weight * k * (1 - v)
            total += rows[i].points
        }
        // Without movement we know only how long you were in bed and when. That
        // cannot honestly produce a top score, so it is capped and labelled.
        if a.estimated { total = min(total, 78) }
        let final = Int(clampd(total, 0, 100).rounded())

        var conf = 1.0
        if !a.hadMotion { conf *= 0.35 } else { conf *= clampd(0.55 + 0.45 * a.coverage, 0, 1) }
        if !a.hadAudio { conf *= 0.92 }
        if a.inBed < 4 * 3600 { conf *= 0.7 }
        if rows.contains(where: { $0.value == nil }) { conf *= 0.9 }
        conf = clampd(conf, 0.1, 1)

        let band = bands.first { final >= $0.0 } ?? bands[bands.count - 1]
        let scored = rows.filter { $0.value != nil }.sorted { $0.lost > $1.lost }

        return ScoreResult(
            total: final, rows: rows, confidence: conf,
            confidenceLabel: conf >= 0.85 ? "full read" : conf >= 0.6 ? "partial read" : "thin read",
            headline: band.1, subhead: band.2,
            worst: (scored.first?.lost ?? 0) >= 4 ? scored.first : nil)
    }

    /// Rolling personal baseline. Timing regularity needs three nights before it
    /// means anything, so it stays out of the score until then rather than
    /// inventing a norm.
    public static func baseline(from nights: [Night]) -> Baseline {
        let usable = nights.filter { $0.ok && $0.asleep > 3 * 3600 }
        guard !usable.isEmpty else { return Baseline() }
        // circular mean, so 23:50 and 00:10 average to midnight rather than noon
        var sx = 0.0, sy = 0.0
        for nightItem in usable {
            guard let mid = nightItem.midSleep else { continue }
            let ang = minutesOfDay(mid) / 1440 * 2 * .pi
            sx += cos(ang); sy += sin(ang)
        }
        var midMinutes: Double?
        if sx != 0 || sy != 0 {
            var ang = atan2(sy, sx); if ang < 0 { ang += 2 * .pi }
            midMinutes = (ang / (2 * .pi) * 1440).rounded()
        }
        let scores = usable.compactMap(\.score)
        return Baseline(
            nights: usable.count,
            midMinutes: midMinutes,
            avgAsleep: usable.map(\.asleep).reduce(0, +) / Double(usable.count),
            avgScore: scores.isEmpty ? nil : Int((Double(scores.reduce(0, +)) / Double(scores.count)).rounded()))
    }
}

// MARK: - formatting

func minutesOfDay(_ t: TimeInterval) -> Double {
    let c = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t))
    return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
}

func circularDiffMinutes(_ a: Double, _ b: Double) -> Double {
    var d = abs(a - b)
    if d > 720 { d = 1440 - d }
    return d
}

public func durShort(_ s: TimeInterval) -> String {
    let m = max(0, Int((s / 60).rounded()))
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

public func hhmm(_ t: TimeInterval) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t))
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}
