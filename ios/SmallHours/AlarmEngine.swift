import Foundation
import AVFoundation
import UserNotifications

// =============================================================================
// ALARM — the wake window, and making a noise at the end of it.
//
// A silent alarm is the one unforgivable bug, so there are three independent
// layers: the in-app synthesised chime (primary), a scheduled local
// notification at the hard deadline (survives the app being killed), and the
// standing instruction to keep a normal Clock alarm as a backstop.
//
// Playing through AVAudioSession .playback means the hardware silent switch is
// bypassed — something a web page cannot do at all.
// =============================================================================

@MainActor
final class AlarmEngine: ObservableObject {

    @Published private(set) var isRinging = false

    var target: Date?
    var windowMinutes: Int = 30
    var armed = false

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var ringStarted: Date?
    private var escalateTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?

    // MARK: - wake window

    /// Fire when the sleeper is closest to the surface inside
    /// [target - window, target], and unconditionally at the deadline.
    /// Thresholds are night-relative: absolute movement values depend on the
    /// mattress, the phone, and where it was put.
    func shouldFire(epochs: [Epoch], now: Date = Date()) -> Bool {
        guard armed, let target, !isRinging else { return false }
        if now >= target { return true }                       // never late
        guard windowMinutes > 0 else { return false }
        let open = target.addingTimeInterval(-Double(windowMinutes) * 60)
        guard now >= open, epochs.count >= 20 else { return false }

        let vals = epochs.compactMap(\.motionMean).sorted()
        guard vals.count >= 20 else { return false }
        let floorV = percentile(vals, 0.20)
        let light = percentile(vals, 0.75)
        let span = max(light - floorV, 1e-6)

        let recent = epochs.suffix(6).compactMap(\.motionMean)
        guard recent.count >= 3 else { return false }
        let cur = recent.suffix(3).reduce(0, +) / 3
        let norm = (cur - floorV) / span
        if norm >= 0.85 { return true }                        // clearly stirring

        let first = recent.prefix(3).reduce(0, +) / 3
        let rising = (cur - first) / span
        let frac = now.timeIntervalSince(open) / (Double(windowMinutes) * 60)
        if rising > 0.3 && norm > 0.5 && frac > 0.25 { return true }
        if frac > 0.75 && norm >= 0.6 { return true }          // take what we can get
        return false
    }

    // MARK: - the backstop notification

    func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Scheduled at the hard deadline so the alarm still lands if iOS kills the
    /// app overnight. Cancelled the moment the in-app alarm fires.
    func scheduleBackstop(at date: Date) {
        let c = UNMutableNotificationContent()
        c.title = "Good morning."
        c.body = "Open Small Hours to end the night and see your score."
        c.sound = .defaultCritical
        c.interruptionLevel = .timeSensitive
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let req = UNNotificationRequest(
            identifier: "smallhours.backstop",
            content: c,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        UNUserNotificationCenter.current().add(req)
    }

    func cancelBackstop() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["smallhours.backstop"])
    }

    // MARK: - sound

    /// Test chime at bedtime. The only volume meter available is a human ear,
    /// so the bedtime flow plays this and asks "hear that?".
    func playTest() { startEngineIfNeeded(); chime(peak: 0.5) }

    func fire() {
        guard !isRinging else { return }
        isRinging = true
        ringStarted = Date()
        cancelBackstop()
        // .playback bypasses the hardware silent switch, and gets us off the
        // record route so the sound leaves the speaker rather than the earpiece.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        startEngineIfNeeded()
        escalate()
    }

    func silence() {
        isRinging = false
        escalateTimer?.invalidate(); escalateTimer = nil
        engine?.stop(); engine = nil; player = nil
    }

    /// Gentle at second zero, unignorable by second ninety.
    private func escalate() {
        guard isRinging, let started = ringStarted else { return }
        let elapsed = Date().timeIntervalSince(started)
        let ramp = clampd(elapsed / 90, 0, 1)
        chime(peak: 0.04 + 0.66 * ramp * ramp)
        let gap = 5.5 + (1.4 - 5.5) * ramp
        escalateTimer = Timer.scheduledTimer(withTimeInterval: gap, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.escalate() }
        }
    }

    /// The alarm's own engine can be interrupted too — and unlike the recorder,
    /// a dead engine here means silence at the moment it matters most. If we
    /// are ringing when the interruption ends, rebuild and carry on escalating
    /// from where we were rather than starting the ramp again.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended else { return }
            Task { @MainActor in
                guard self.isRinging else { return }
                try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
                try? AVAudioSession.sharedInstance().setActive(true)
                self.engine?.stop(); self.engine = nil; self.player = nil
                self.startEngineIfNeeded()
                self.escalateTimer?.invalidate()
                self.escalate()
            }
        }
    }

    private func startEngineIfNeeded() {
        observeInterruptions()
        if let e = engine, !e.isRunning { engine = nil; player = nil }   // a stopped engine is a dead engine
        guard engine == nil else { return }
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        e.connect(p, to: e.mainMixerNode, format: fmt)
        try? e.start()
        p.play()
        engine = e; player = p
    }

    /// One warm bell: fundamental plus two inharmonic partials, exponential
    /// decay. Synthesised rather than shipped as a file, so it is a few lines
    /// instead of an asset.
    private func chime(peak: Double) {
        guard let player, let engine, engine.isRunning else { return }
        let sr = 44100.0, dur = 2.5
        let frames = AVAudioFrameCount(sr * dur)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        guard let ch = buf.floatChannelData?[0] else { return }

        let partials: [(Double, Double)] = [(1, 1), (2.01, 0.32), (3.02, 0.14)]
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            let env = exp(-t * 2.6)
            var v = 0.0
            for (mult, amp) in partials { v += sin(2 * .pi * 440 * mult * t) * amp }
            ch[i] = Float(v * env * peak / 1.5)
        }
        player.scheduleBuffer(buf, at: nil, options: [])
    }
}
