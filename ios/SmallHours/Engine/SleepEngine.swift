import Foundation

// =============================================================================
// SMALL HOURS — sleep engine
//
// Pure Foundation, no UIKit, no SwiftUI. Deliberately free of platform types so
// it can be unit-tested on macOS and shares its exact shape with the web app (docs/index.html).
//
//   Epoch    30 seconds of aggregated sensor data. Raw samples never persist.
//   Stager   epochs -> settledness curve + night metrics
//   Scorer   metrics + personal baseline -> 0...100 with per-component reasons
//
// It claims Awake / Restless / Settled and nothing more. Motion-only staging
// agrees with polysomnography at kappa = 0.084 (Walch et al. 2019), which is
// indistinguishable from chance, so REM and deep-sleep minutes are not offered.
// =============================================================================

public let epochSeconds: TimeInterval = 30

// MARK: - Epoch

public struct Epoch: Codable, Sendable {
    public var t: TimeInterval          // epoch start, seconds since 1970
    public var motionMean: Double?      // mean rectified, gravity-removed acceleration
    public var motionPeak: Double?
    public var dbMean: Double?          // mean dBFS
    public var dbPeak: Double?
    public var band: Double?            // 60-500 Hz energy, 0...255

    public init(t: TimeInterval, motionMean: Double? = nil, motionPeak: Double? = nil,
                dbMean: Double? = nil, dbPeak: Double? = nil, band: Double? = nil) {
        self.t = t; self.motionMean = motionMean; self.motionPeak = motionPeak
        self.dbMean = dbMean; self.dbPeak = dbPeak; self.band = band
    }
}

public enum SleepState: String, Codable, Sendable { case awake, restless, settled }

// MARK: - Night

public struct Night: Codable, Sendable {
    public var ok = false
    public var reason: String?
    public var estimated = false

    public var startAt: TimeInterval = 0
    public var endAt: TimeInterval = 0
    public var inBed: TimeInterval = 0

    public var states: [SleepState] = []
    public var depth: [Double] = []

    public var asleep: TimeInterval = 0
    public var latency: TimeInterval?
    public var waso: TimeInterval?
    public var awakenings: Int?
    public var efficiency: Double?
    public var settledShare: Double?
    public var midSleep: TimeInterval?
    public var onsetAt: TimeInterval?
    public var finalWakeAt: TimeInterval?

    public var coverage: Double = 0
    public var gapMinutes: Int = 0
    public var bursts: Int = 0
    public var hadMotion = false
    public var hadAudio = false
    public var snoreMinutes: Int = 0

    public var score: Int?
    public var confidence: Double = 0
    public var rested: Int?
}

// MARK: - small helpers

@inline(__always) func clampd(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

/// Piecewise-linear curve through ascending (x, y) points.
func curve(_ pts: [(Double, Double)], _ x: Double) -> Double {
    guard let first = pts.first, let last = pts.last else { return 0 }
    if x <= first.0 { return first.1 }
    for i in 1..<pts.count {
        if x <= pts[i].0 {
            let (x0, y0) = pts[i - 1], (x1, y1) = pts[i]
            if x1 == x0 { return y1 }
            return y0 + (y1 - y0) * ((x - x0) / (x1 - x0))
        }
    }
    return last.1
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let i = Int((p * Double(sorted.count - 1)).rounded())
    return sorted[min(max(i, 0), sorted.count - 1)]
}

// MARK: - Stager

public enum Stager {
    /// Cole-Kripke weight shape, epochs -4...+2, centre-heavy.
    static let W: [Double] = [404, 598, 326, 441, 1408, 508, 350]
    static let offset = 4
    static let epochsPerMinute = 2
    static let maxFillEpochs = 6          // 3 minutes; beyond that it is a hole

    public static func analyze(_ epochs: [Epoch], startAt: TimeInterval, endAt: TimeInterval) -> Night {
        var out = Night()
        out.startAt = startAt; out.endAt = endAt
        out.inBed = max(0, endAt - startAt)
        let n = epochs.count

        guard n >= 20 else {
            out.reason = "The night was too short to read — under ten minutes of data."
            return out
        }

        let raw = epochs.map(\.motionMean)
        let have = raw.compactMap { $0 }.count
        out.coverage = Double(have) / Double(n)
        out.hadMotion = have > Int(Double(n) * 0.4)

        if !out.hadMotion { return estimateFromTimes(&out) }

        // --- 1. gaps -------------------------------------------------------
        var m = raw
        var invalid = [Bool](repeating: false, count: n)
        for i in 0..<n where m[i] == nil {
            var a = i - 1; while a >= 0 && raw[a] == nil { a -= 1 }
            var b = i + 1; while b < n && raw[b] == nil { b += 1 }
            if a < 0 || b >= n || (b - a - 1) > maxFillEpochs { invalid[i] = true; continue }
            m[i] = (raw[a]! + raw[b]!) / 2
        }
        // A hole is not stillness — carry the median through it so it scores as
        // ordinary rather than as the deepest sleep of the night.
        let known = m.compactMap { $0 }.sorted()
        let med = known.isEmpty ? 0 : known[known.count / 2]
        var mm = m.map { $0 ?? med }
        let holes = invalid.filter { $0 }.count
        out.gapMinutes = Int((Double(holes) * epochSeconds / 60).rounded())
        out.coverage = min(out.coverage, 1 - Double(holes) / Double(n))

        // --- 2. night-relative normalisation --------------------------------
        let sorted = mm.sorted()
        let floorV = percentile(sorted, 0.15)
        let topV = max(percentile(sorted, 0.95), floorV + 1e-6)
        let span = max(topV - floorV, 1e-6)

        if topV / max(floorV, 1e-9) < 1.15 && topV < 0.5 {
            // The sensor ran but nothing reached it: a phone on the nightstand.
            // Unreadable — a still phone looks exactly like perfect sleep.
            out.reason = "The phone did not pick up any movement. Was it on the bed? No score, because a still phone looks exactly like perfect sleep."
            out = estimateFromTimes(&out)
            out.ok = false
            return out
        }
        let A = mm.map { clampd(($0 - floorV) / span, 0, 3) }

        // --- 3. Cole-Kripke shaped window, night-adaptive threshold ----------
        var D = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = 0.0
            for k in 0..<W.count {
                let j = i + k - offset
                s += W[k] * A[min(max(j, 0), n - 1)]
            }
            D[i] = s / 4035
        }
        let Ds = D.sorted()
        let thr = max(percentile(Ds, 0.55) * 1.9,
                      percentile(Ds, 0.30) + 0.28 * (percentile(Ds, 0.92) - percentile(Ds, 0.30)))
        var state: [Bool] = D.map { $0 >= thr }     // true == awake

        // --- 4. Webster rescoring -------------------------------------------
        // Each rule reads a snapshot and writes to a copy. Reading its own
        // writes makes every rescored epoch fresh wake-context for the next,
        // and the cascade swallows the whole night.
        func rescore(afterWakeMinutes wm: Int, rescoreMinutes sm: Int) {
            let src = state; var dst = state; var run = 0
            for i in 0..<n {
                if src[i] { run += 1; continue }
                if run >= wm * epochsPerMinute {
                    for k in 0..<(sm * epochsPerMinute) where i + k < n && !src[i + k] { dst[i + k] = true }
                }
                run = 0
            }
            state = dst
        }
        rescore(afterWakeMinutes: 4, rescoreMinutes: 1)
        rescore(afterWakeMinutes: 10, rescoreMinutes: 3)
        rescore(afterWakeMinutes: 15, rescoreMinutes: 4)

        func killIslands(maxSleep: Int, needWake: Int) {
            let src = state; var dst = state; var i = 0
            while i < n {
                guard !src[i] else { i += 1; continue }
                var j = i; while j < n && !src[j] { j += 1 }
                if j - i <= maxSleep * epochsPerMinute {
                    var before = 0, k = i - 1; while k >= 0 && src[k] { before += 1; k -= 1 }
                    var after = 0, k2 = j; while k2 < n && src[k2] { after += 1; k2 += 1 }
                    if before >= needWake * epochsPerMinute && after >= needWake * epochsPerMinute {
                        for x in i..<j { dst[x] = true }
                    }
                }
                i = j
            }
            state = dst
        }
        killIslands(maxSleep: 6, needWake: 10)
        killIslands(maxSleep: 10, needWake: 20)

        // --- 5. settledness curve, normalised WITHIN sleep -------------------
        // Normalising across the whole night spends all the range on wake-vs-
        // sleep, and every sleeping epoch then looks equally still.
        let sleepVals = (0..<n).filter { !state[$0] }.map { mm[$0] }.sorted()
        let sFloor = sleepVals.count > 20 ? percentile(sleepVals, 0.06) : floorV
        let sTop = sleepVals.count > 20 ? max(percentile(sleepVals, 0.94), sFloor + 1e-6) : topV
        let sSpan = max(sTop - sFloor, 1e-6)
        let As = mm.map { clampd(($0 - sFloor) / sSpan, 0, 1) }

        func smooth(_ arr: [Double], half: Int) -> [Double] {
            let sigma = Double(half) / 2
            return (0..<arr.count).map { i in
                var s = 0.0, w = 0.0
                for j in -half...half {
                    let k = i + j
                    guard k >= 0 && k < arr.count else { continue }
                    let g = exp(-Double(j * j) / (2 * sigma * sigma))
                    s += arr[k] * g; w += g
                }
                return w > 0 ? s / w : arr[i]
            }
        }
        let quiet = smooth(As.map { 1 - $0 }, half: 9)
        let depth: [Double] = (0..<n).map { i in
            guard !state[i] else { return 0 }
            // The stillest sleep front-loads the night. A gentle tilt only — a
            // strong prior would draw a textbook hypnogram on any input.
            let frac = Double(i) / Double(max(1, n - 1))
            return clampd(quiet[i] * (1.15 - 0.35 * frac), 0, 1)
        }

        let states: [SleepState] = (0..<n).map { i in
            if state[i] { return .awake }
            return depth[i] >= 0.62 ? .settled : .restless
        }

        // --- 6. coupling check ----------------------------------------------
        // A decoupled phone records a beautiful, entirely fictional night. This
        // is deliberately conservative: there is no reliable way to separate
        // "well-coupled, very still sleeper" from "phone under a pillow", so it
        // only refuses nights where essentially nothing happened at all.
        var bursts = 0, inBurst = false
        let burstThr = floorV + 0.35 * span
        for v in mm {
            if v > burstThr { if !inBurst { bursts += 1; inBurst = true } } else { inBurst = false }
        }
        out.bursts = bursts
        if out.inBed / 3600 >= 4 && bursts < 3 {
            out.reason = "Almost no movement reached the phone all night. That usually means it was not on the mattress. No score, because a still phone looks exactly like perfect sleep."
            return out
        }

        // --- 7. metrics -------------------------------------------------------
        func timeOf(_ i: Int) -> TimeInterval { i < epochs.count ? epochs[i].t : startAt + Double(i) * epochSeconds }

        var onset = -1
        if n >= 10 {
            for i in 0...(n - 10) where !(0..<10).contains(where: { states[i + $0] == .awake }) { onset = i; break }
        }
        var finalWake = n - 1
        for i in stride(from: n - 1, through: 0, by: -1) where states[i] != .awake { finalWake = i; break }

        var asleep = 0, waso = 0, settled = 0, bouts = 0, inBout = false
        for i in 0..<n {
            if states[i] == .awake {
                if onset >= 0 && i > onset && i < finalWake {
                    waso += 1
                    if !inBout { bouts += 1; inBout = true }
                }
            } else {
                inBout = false; asleep += 1
                if states[i] == .settled { settled += 1 }
            }
        }

        out.ok = true
        out.states = states
        out.depth = depth
        out.onsetAt = onset >= 0 ? timeOf(onset) : nil
        out.finalWakeAt = timeOf(finalWake)
        out.latency = onset >= 0 ? max(0, timeOf(onset) - startAt) : nil
        out.asleep = Double(asleep) * epochSeconds
        out.waso = Double(waso) * epochSeconds
        out.awakenings = bouts
        out.settledShare = asleep > 0 ? Double(settled) / Double(asleep) : 0
        out.efficiency = out.inBed > 0 ? clampd(out.asleep / out.inBed, 0, 1) : 0
        out.midSleep = onset >= 0 ? (timeOf(onset) + timeOf(finalWake)) / 2 : (startAt + endAt) / 2

        analyzeAudio(epochs, states: states, into: &out)

        if out.asleep < 45 * 60 {
            out.reason = "Under 45 minutes of sleep was detected. Treating this night as unreadable."
            out.ok = false
        }
        // A nap is real sleep but it is not a night, and scoring it would drag
        // the personal baseline that judges every actual night.
        if out.inBed < 180 * 60 {
            out.reason = "That was \(durShort(out.inBed)) in bed — logged as a nap, not scored as a night."
            out.ok = false
        }
        return out
    }

    /// No usable movement: efficiency, latency, WASO and settledness are all
    /// unknowable, so they go nil and the scorer drops them rather than
    /// awarding free marks. Sleep time becomes an estimate from time in bed.
    private static func estimateFromTimes(_ out: inout Night) -> Night {
        out.reason = out.reason ?? "No movement data — scored from your times only."
        out.estimated = true
        out.asleep = out.inBed * 0.88
        out.efficiency = nil; out.latency = nil; out.waso = nil
        out.awakenings = nil; out.settledShare = nil
        out.midSleep = (out.startAt + out.endAt) / 2
        // No motion sensor at all (sleep-log mode): still a night, capped at 78
        // by the scorer, when it was long enough to be one. Same rule as the web app.
        out.ok = out.inBed >= 180 * 60
        if !out.ok { out.reason = "That was \(durShort(out.inBed)) in bed — logged as a nap, not scored as a night." }
        return out
    }

    /// Audio is context, never a staging input. Snoring is loud in the
    /// 60-500 Hz band AND impulsive — it peaks on each breath and falls
    /// between them. A fan is loud and flat, so the peak-to-mean gap is what
    /// actually separates them, and it is scale-free.
    private static func analyzeAudio(_ epochs: [Epoch], states: [SleepState], into out: inout Night) {
        let n = epochs.count
        let dbs = epochs.compactMap(\.dbMean)
        guard dbs.count > Int(Double(n) * 0.4) else { return }
        out.hadAudio = true
        let bands = epochs.compactMap(\.band).sorted()
        guard !bands.isEmpty else { return }
        // Anchored to the QUIET decile: someone who snores most of the night
        // makes snoring the median, and a mid-anchored threshold then sits
        // above the very thing it is looking for.
        let floorB = percentile(bands, 0.10)
        let thr = floorB + max(14, 0.35 * (percentile(bands, 0.95) - floorB))
        var snore = 0
        for i in 0..<n {
            guard states[i] != .awake,
                  let b = epochs[i].band, let p = epochs[i].dbPeak, let mean = epochs[i].dbMean else { continue }
            if b > thr && (p - mean) > 11 { snore += 1 }
        }
        out.snoreMinutes = Int((Double(snore) * epochSeconds / 60).rounded())
    }
}
