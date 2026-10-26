import SwiftUI

// The screen the whole app exists for.

struct MorningView: View {
    @EnvironmentObject var s: AppState

    var body: some View {
        ScrollView {
            if let n = s.night, let r = s.result {
                if n.ok, let total = r.total { scored(n, r, total) } else { unreadable(n) }
            }
        }
    }

    // MARK: - a night that read

    @ViewBuilder
    private func scored(_ n: Night, _ r: ScoreResult, _ total: Int) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Eyebrow(text: "\(hhmm(n.startAt)) → \(hhmm(n.endAt))")
                Spacer()
                Text(r.confidenceLabel)
                    .font(mono(11))
                    .foregroundStyle(r.confidence >= 0.85 ? Color.good : r.confidence >= 0.6 ? Color.warn : Color.bad)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .overlay(Capsule().stroke(Color.line, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(total)")
                        .font(serif(112, .light))
                        .foregroundStyle(Color.dawn)
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("out of 100").font(mono(12)).foregroundStyle(Color.dim)
                        if let avg = s.baseline.avgScore, s.history.count > 1 {
                            Text("\(total - avg >= 0 ? "+" : "")\(total - avg) vs your average")
                                .font(mono(12)).foregroundStyle(Color.dim)
                        }
                    }
                }
                Text(r.headline).font(serif(24)).foregroundStyle(Color.inkStrong)
                Text(r.subhead).font(.system(size: 15)).foregroundStyle(Color.dim)
            }

            VStack(alignment: .leading, spacing: 8) {
                HypnogramView(night: n).frame(height: 168)
                HStack(spacing: 14) {
                    legend(.dawn, "awake")
                    legend(Color.deepBlue.opacity(0.45), "restless")
                    legend(.deepBlue, "settled")
                    Spacer()
                    Text("\(durShort(n.asleep)) asleep of \(durShort(n.inBed))")
                        .font(mono(11)).foregroundStyle(Color.dim)
                }
            }

            if let worst = r.worst {
                Panel(tint: Color.dawn.opacity(0.35)) {
                    Eyebrow(text: "What cost you the most")
                    Text("\(worst.name) — \(Int(worst.lost.rounded())) points")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.inkStrong)
                    Text(worst.lever).font(.system(size: 13)).foregroundStyle(Color.dim)
                }
            } else {
                Panel {
                    Text("Nothing stands out as the problem — the points are spread evenly. That is what a good night looks like.")
                        .font(.system(size: 13)).foregroundStyle(Color.dim)
                }
            }

            Panel {
                ForEach(r.rows.filter { !$0.skipped }) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(row.name).font(.system(size: 14)).foregroundStyle(Color.ink)
                            Spacer()
                            Text(row.display).font(mono(12)).foregroundStyle(Color.dim)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.surface2)
                                Capsule().fill(barColor(row.value ?? 0))
                                    .frame(width: g.size.width * (row.value ?? 0))
                            }
                        }.frame(height: 7)
                    }
                    .padding(.bottom, 6)
                }
                let skipped = r.rows.filter(\.skipped)
                if !skipped.isEmpty {
                    Text("Not scored yet: \(skipped.map { $0.name.lowercased() }.joined(separator: ", ")). Steadiness needs three nights before it means anything.")
                        .font(.system(size: 12.5)).foregroundStyle(Color.dim)
                }
            }

            if n.hadAudio && n.snoreMinutes >= 15 {
                Panel {
                    Eyebrow(text: "Sound")
                    Text("Roughly \(n.snoreMinutes) minutes of loud, rhythmic breathing sound while you were asleep — that pattern is usually snoring. Worth knowing, not worth worrying about on its own.")
                        .font(.system(size: 13)).foregroundStyle(Color.dim)
                }
            }

            Panel {
                Eyebrow(text: "How rested do you actually feel?")
                HStack(spacing: 8) {
                    ForEach(Array(["Wrecked", "Meh", "Fine", "Great"].enumerated()), id: \.offset) { i, label in
                        Button(label) { s.setRested(i + 1) }
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .foregroundStyle(n.rested == i + 1 ? Color(red: 0.10, green: 0.07, blue: 0.02) : Color.inkStrong)
                            .background(n.rested == i + 1 ? Color.dawn : Color.surface2,
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                if let rested = n.rested {
                    Text(restedNote(score: total, rested: rested))
                        .font(.system(size: 12.5)).foregroundStyle(Color.dim)
                }
            }

            Text("This is a phone on a mattress, not a sleep lab. It measures how still you were and how quiet the room was. It deliberately does not claim REM or deep sleep: movement alone cannot tell those apart, and apps that show them are drawing a textbook diagram, not your night.")
                .font(.system(size: 12.5)).foregroundStyle(Color.dim)

            HStack(spacing: 10) {
                BigButton(title: "All nights") { s.screen = .history }
                BigButton(title: "Done", primary: true) { s.screen = .bedtime }
            }
        }
        .padding(20)
    }

    // MARK: - a night that did not read

    @ViewBuilder
    private func unreadable(_ n: Night) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow(text: "\(hhmm(n.startAt)) → \(hhmm(n.endAt))")
            Text("I couldn't read that night.").font(serif(28)).foregroundStyle(Color.inkStrong)
            Text(n.reason ?? "The signal was not usable.")
                .font(.system(size: 15)).foregroundStyle(Color.dim)
            Panel {
                Text("No score is better than a made-up one. The times are saved — \(durShort(n.inBed)) in bed. Nothing to make up for; tonight runs as normal.")
                    .font(.system(size: 13)).foregroundStyle(Color.dim)
            }
            BigButton(title: "Back to tonight", primary: true) { s.screen = .bedtime }
        }
        .padding(20)
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(t).font(mono(11)).foregroundStyle(Color.dim)
        }
    }

    private func barColor(_ v: Double) -> Color {
        v >= 0.8 ? .good : v >= 0.55 ? .dawn : v >= 0.35 ? .warn : .bad
    }

    private func restedNote(score: Int, rested: Int) -> String {
        let felt = rested * 25 - 12
        let gap = score - felt
        if gap > 25 { return "The night measured better than it felt. When that keeps happening the cause is usually something other than sleep — timing, morning light, or what happens in the first hour after waking." }
        if gap < -25 { return "You felt better than the night measured. Worth trusting your own read on this one." }
        return "That matches what the night measured."
    }
}

// MARK: - hypnogram

/// Depth goes DOWN: awake along the top, settled sleep at the bottom, the way a
/// hypnogram is always drawn. The other way up, a deep trough reads as a spike
/// of activity — the exact opposite of what it means.
struct HypnogramView: View {
    let night: Night

    var body: some View {
        Canvas { ctx, size in
            let depth = night.depth, states = night.states
            guard !depth.isEmpty else {
                ctx.draw(Text("no readable signal").font(mono(12)).foregroundStyle(Color.dim),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let padT = 20.0, padB = 22.0, padX = 4.0
            let plotW = size.width - padX * 2
            let plotH = size.height - padT - padB
            let n = depth.count
            func x(_ i: Int) -> Double { padX + Double(i) / Double(max(1, n - 1)) * plotW }
            func y(_ d: Double) -> Double { padT + d * plotH }

            // the band guide, at the threshold the states actually use
            var guideLine = Path()
            guideLine.move(to: CGPoint(x: padX, y: y(0.62)))
            guideLine.addLine(to: CGPoint(x: size.width - padX, y: y(0.62)))
            ctx.stroke(guideLine, with: .color(Color.line), lineWidth: 1)
            ctx.draw(Text("settled").font(mono(9)).foregroundStyle(Color.dim),
                     at: CGPoint(x: padX + 24, y: y(0.62) - 8))

            // filled curve, from the wake line down into the night
            var area = Path()
            area.move(to: CGPoint(x: x(0), y: padT))
            for i in 0..<n { area.addLine(to: CGPoint(x: x(i), y: y(depth[i]))) }
            area.addLine(to: CGPoint(x: x(n - 1), y: padT))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [Color.deepBlue.opacity(0.18), Color.deepBlue.opacity(0.75)]),
                startPoint: CGPoint(x: 0, y: padT), endPoint: CGPoint(x: 0, y: padT + plotH)))

            var line = Path()
            for i in 0..<n {
                let p = CGPoint(x: x(i), y: y(depth[i]))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            ctx.stroke(line, with: .color(Color.deepBlue), lineWidth: 1.5)

            // wake marks along the top
            let markW = max(1.2, plotW / Double(n))
            for i in 0..<min(n, states.count) where states[i] == .awake {
                ctx.fill(Path(CGRect(x: x(i), y: 6, width: markW, height: 7)), with: .color(Color.dawn))
            }

            // hour ticks
            let hours = max(1, Int(((night.endAt - night.startAt) / 3600).rounded()))
            let step = hours > 9 ? 2 : 1
            for h in stride(from: 0, through: hours, by: step) {
                let t = night.startAt + Double(h) * 3600
                guard t <= night.endAt else { break }
                let px = padX + (t - night.startAt) / max(1, night.endAt - night.startAt) * plotW
                ctx.fill(Path(CGRect(x: px, y: padT + plotH, width: 1, height: 4)), with: .color(Color.dim))
                if px > 16 && px < size.width - 16 {
                    ctx.draw(Text(hhmm(t)).font(mono(10)).foregroundStyle(Color.dim),
                             at: CGPoint(x: px, y: size.height - 8))
                }
            }
        }
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - history

struct HistoryView: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Eyebrow(text: "Small Hours")
                let scored = s.history.filter { $0.score != nil }
                Text("\(scored.count) scored night\(scored.count == 1 ? "" : "s").")
                    .font(serif(28)).foregroundStyle(Color.inkStrong)
                if let avg = s.baseline.avgScore, let a = s.baseline.avgAsleep {
                    Text("Your average is \(avg), on \(durShort(a)) of sleep a night.")
                        .font(.system(size: 15)).foregroundStyle(Color.dim)
                }

                Panel {
                    Eyebrow(text: "Last \(min(14, s.history.count)) nights")
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(Array(s.history.prefix(14).reversed().enumerated()), id: \.offset) { _, n in
                            let v = Double(n.score ?? 0) / 100
                            RoundedRectangle(cornerRadius: 2)
                                .fill(n.score == nil ? Color.line
                                      : (n.score! >= 72 ? Color.good : n.score! >= 58 ? Color.dawn : Color.bad))
                                .frame(height: max(4, 88 * v))
                        }
                    }.frame(height: 88)
                }

                ForEach(Array(s.history.enumerated()), id: \.offset) { _, n in
                    Button { s.show(n) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Storage.dayKey(n.endAt)).font(mono(12)).foregroundStyle(Color.dim)
                                Text("\(hhmm(n.startAt)) → \(hhmm(n.endAt)) · \(durShort(n.asleep))")
                                    .font(.system(size: 14)).foregroundStyle(Color.ink)
                            }
                            Spacer()
                            Text(n.score.map(String.init) ?? "—")
                                .font(serif(26)).foregroundStyle(n.score == nil ? Color.dim : Color.dawn)
                        }
                        .padding(16)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.line, lineWidth: 1))
                    }
                }

                BigButton(title: "Back to tonight", primary: true) { s.screen = .bedtime }
            }
            .padding(20)
        }
    }
}
