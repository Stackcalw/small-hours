import SwiftUI

// =============================================================================
// The same five states as the web build: one thing on screen, one action.
// It is operated half asleep in a dark room, so targets are large, the ground
// is near-black, and the tracking screen goes to true black — on an OLED phone
// that emits nothing into the bedroom.
// =============================================================================

extension Color {
    static let ground   = Color(red: 0.039, green: 0.051, blue: 0.078)  // #0A0D14
    static let surface  = Color(red: 0.082, green: 0.106, blue: 0.153)  // #151B27
    static let surface2 = Color(red: 0.114, green: 0.145, blue: 0.204)
    static let ink      = Color(red: 0.776, green: 0.808, blue: 0.863)  // #C6CEDC
    static let inkStrong = Color(red: 0.894, green: 0.914, blue: 0.945)
    static let dim      = Color(red: 0.373, green: 0.420, blue: 0.494)
    static let line     = Color(red: 0.137, green: 0.173, blue: 0.235)
    static let dawn     = Color(red: 0.910, green: 0.631, blue: 0.361)  // #E8A15C
    static let deepBlue = Color(red: 0.431, green: 0.490, blue: 0.878)  // #6E7DE0
    static let good     = Color(red: 0.310, green: 0.663, blue: 0.486)
    static let warn     = Color(red: 0.788, green: 0.529, blue: 0.247)
    static let bad      = Color(red: 0.706, green: 0.341, blue: 0.290)
}

func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .serif)
}
func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(mono(11)).tracking(1.4).foregroundStyle(Color.dim)
    }
}

struct Panel<Content: View>: View {
    var tint: Color = .line
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint, lineWidth: 1))
    }
}

struct BigButton: View {
    let title: String
    var primary = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: primary ? .semibold : .medium))
                .frame(maxWidth: .infinity, minHeight: primary ? 60 : 50)
        }
        .foregroundStyle(primary ? Color(red: 0.10, green: 0.07, blue: 0.02) : Color.inkStrong)
        .background(primary ? Color.dawn : Color.surface2, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(primary ? .clear : Color.line, lineWidth: 1))
    }
}

// MARK: - root

struct RootView: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        ZStack {
            (s.screen == .tracking ? Color.black : Color.ground).ignoresSafeArea()
            switch s.screen {
            case .bedtime:  BedtimeView()
            case .tracking: TrackingView()
            case .alarm:    AlarmView()
            case .morning:  MorningView()
            case .history:  HistoryView()
            case .resume:   ResumeView()
            }
        }
        .tint(.dawn)
    }
}

// MARK: - bedtime

struct BedtimeView: View {
    @EnvironmentObject var s: AppState
    @State private var tested = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Eyebrow(text: "Small Hours")
                    Spacer()
                    if !s.history.isEmpty {
                        Button("\(s.history.count) nights →") { s.screen = .history }
                            .font(mono(12)).foregroundStyle(Color.dim)
                    }
                }
                if let last = s.history.first {
                    Panel {
                        Eyebrow(text: "Last night")
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(last.score.map(String.init) ?? "—")
                                .font(serif(28)).foregroundStyle(Color.dawn)
                            Text(durShort(last.asleep)).font(.system(size: 15)).foregroundStyle(Color.ink)
                            Spacer()
                            Button("See it") { s.show(last) }.font(.system(size: 15)).foregroundStyle(Color.dim)
                        }
                    }
                } else {
                    Text("Put the phone on the mattress. That is the whole setup.")
                        .font(serif(28)).foregroundStyle(Color.inkStrong)
                }

                Panel {
                    Eyebrow(text: "Wake me by")
                    DatePicker("", selection: $s.alarmTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
                    Divider().overlay(Color.line)
                    Eyebrow(text: "Wake window")
                    Picker("", selection: $s.windowMinutes) {
                        Text("30 min — light moment").tag(30)
                        Text("20 min").tag(20)
                        Text("45 min").tag(45)
                        Text("Exactly on time").tag(0)
                    }.pickerStyle(.menu).tint(.dawn)
                }

                Panel {
                    Eyebrow(text: "Before you put it down")
                    VStack(alignment: .leading, spacing: 8) {
                        step(1, "Plug the phone in.")
                        step(2, "Ringer on, volume up. Tap the test below and actually listen — that is how loud it will be.")
                        step(3, "Set a normal Clock alarm for \(s.backstopText) as a backstop. Nice alarm, never the only alarm.")
                        step(4, "Phone flat on the mattress, screen down, near your hip. Not the nightstand — it has to feel you move.")
                    }
                    Button(tested ? "Heard it? Then you are set." : "Test the alarm sound") {
                        s.alarm.playTest(); tested = true
                    }
                    .font(.system(size: 15)).foregroundStyle(Color.dawn)
                }

                BigButton(title: "Start the night", primary: true) { s.startNight() }

                Text(s.baseline.nights >= 3
                     ? "Your usual middle-of-night is \(midText). Steadiness is being scored."
                     : "After three nights this starts scoring how steady your hours are.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.dim)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(20)
        }
    }
    private var midText: String {
        guard let m = s.baseline.midMinutes else { return "—" }
        return String(format: "%02d:%02d", Int(m) / 60, Int(m) % 60)
    }
    private func step(_ n: Int, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").font(mono(13)).foregroundStyle(Color.dim)
            Text(t).font(.system(size: 14.5)).foregroundStyle(Color.ink)
        }
    }
}

// MARK: - tracking

struct TrackingView: View {
    @EnvironmentObject var s: AppState
    @State private var confirming = false
    @State private var breathe = false
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            Circle().fill(Color(white: 0.12))
                .frame(width: breathe ? 14 : 8, height: breathe ? 14 : 8)
                .opacity(breathe ? 0.85 : 0.28)
                .animation(.easeInOut(duration: 5.5).repeatForever(autoreverses: true), value: breathe)
                .onAppear { breathe = true }
            VStack(spacing: 6) {
                Text(durShort(s.elapsed)).font(mono(15)).foregroundStyle(Color(white: 0.22))
                Text(s.windowMinutes > 0 ? "waking you at a light moment" : "alarm at the set time")
                    .font(mono(11)).foregroundStyle(Color(white: 0.18))
            }
            Spacer()
            Button(confirming ? "Tap again to confirm" : "I'm awake — end the night") {
                if confirming { s.endNight() } else {
                    confirming = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirming = false }
                }
            }
            .font(.system(size: 16)).foregroundStyle(Color(white: 0.25))
            .frame(maxWidth: .infinity, minHeight: 60)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(white: 0.11), lineWidth: 1))
            Text("Screen down. It keeps running.").font(mono(10)).foregroundStyle(Color(white: 0.14))
        }
        .padding(24)
    }
}

// MARK: - alarm

struct AlarmView: View {
    @EnvironmentObject var s: AppState
    @State private var holding = false
    @State private var progress = 0.0
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Good morning.").font(serif(40)).foregroundStyle(Color.inkStrong)
            Text("Hold the button for two seconds. That is on purpose.")
                .font(.system(size: 15)).foregroundStyle(Color.dim).multilineTextAlignment(.center)
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Color.dawn)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.25))
                        .frame(width: g.size.width * progress)
                }
                Text(holding ? "Keep holding…" : "Hold to get up")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color(red: 0.10, green: 0.07, blue: 0.02))
            }
            .frame(height: 96)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !holding else { return }
                        holding = true
                        withAnimation(.linear(duration: 2)) { progress = 1 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            if holding { s.endNight() }
                        }
                    }
                    .onEnded { _ in
                        holding = false
                        withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                    })
            Button("Nine more minutes") { s.snooze() }
            .font(.system(size: 15)).foregroundStyle(Color.dim)
        }
        .padding(24)
    }
}

// MARK: - resume

struct ResumeView: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow(text: "Picking up where it stopped")
            Text("A night was still running.").font(serif(28)).foregroundStyle(Color.inkStrong)
            Text("The app stopped before you ended it, but everything up to that point was saved.")
                .font(.system(size: 15)).foregroundStyle(Color.dim)
            Spacer()
            BigButton(title: "Finish it and score it", primary: true) { s.finishInterrupted() }
            BigButton(title: "Throw it away") { s.discardInterrupted() }
        }
        .padding(24)
    }
}
