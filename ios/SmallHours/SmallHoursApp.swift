import SwiftUI
import UIKit

@main
struct SmallHoursApp: App {
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(state)
                .preferredColorScheme(.dark)
                .task { await state.boot() }
        }
    }
}

enum Screen { case bedtime, tracking, alarm, morning, history, resume }

@MainActor
final class AppState: ObservableObject {
    @Published var screen: Screen = .bedtime
    @Published var alarmTime = Calendar.current.date(from: DateComponents(hour: 7, minute: 0)) ?? Date()
    @Published var windowMinutes = 30

    @Published var history: [Night] = []
    @Published var baseline = Baseline()
    @Published var night: Night?
    @Published var result: ScoreResult?
    @Published var elapsed: TimeInterval = 0

    let recorder = Recorder()
    let alarm = AlarmEngine()

    private var sessionStart: Date?
    private var checkpoint = Date.distantPast
    private var ticker: Timer?

    func boot() async {
        history = Storage.load()
        baseline = Scorer.baseline(from: history)
        await alarm.requestNotificationPermission()
        if let live = Storage.loadLive(),
           Date().timeIntervalSince1970 - live.startAt < 20 * 3600 {
            screen = .resume
        }
        // The screen may stay on during tracking; the OS still owns the decision.
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - night lifecycle

    func startNight() {
        let target = nextOccurrence(of: alarmTime)
        alarm.target = target
        alarm.windowMinutes = windowMinutes
        alarm.armed = true
        alarm.scheduleBackstop(at: target)

        do { try recorder.start(withAudio: true) }
        catch { print("recorder failed: \(error)") }
        // No microphone (permission denied) means nothing keeps us alive once the
        // screen locks, so hold the screen on instead. Black screen, face down.
        UIApplication.shared.isIdleTimerDisabled = !recorder.audioAvailable

        sessionStart = Date()
        recorder.onEpoch = { [weak self] _, all in
            guard let self, let start = self.sessionStart else { return }
            if Date().timeIntervalSince(self.checkpoint) > 120 {
                self.checkpoint = Date()
                Storage.saveLive(.init(startAt: start.timeIntervalSince1970,
                                       target: target.timeIntervalSince1970,
                                       windowMinutes: self.windowMinutes, epochs: all))
            }
            if self.alarm.shouldFire(epochs: all) { self.fireAlarm() }
        }
        // Independent watchdog: the deadline is honoured even if no epoch lands.
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.sessionStart else { return }
                self.elapsed = Date().timeIntervalSince(s)
                if self.alarm.shouldFire(epochs: self.recorder.epochs) { self.fireAlarm() }
            }
        }
        screen = .tracking
    }

    private func fireAlarm() {
        guard screen != .alarm else { return }
        recorder.releaseMicrophone()
        alarm.fire()
        screen = .alarm
    }

    func snooze() {
        alarm.silence()
        recorder.resumeMicrophone()
        let t = Date().addingTimeInterval(9 * 60)
        alarm.target = t; alarm.windowMinutes = 0; alarm.armed = true
        alarm.scheduleBackstop(at: t)
        screen = .tracking
    }

    func endNight() {
        UIApplication.shared.isIdleTimerDisabled = false
        alarm.silence(); alarm.armed = false; alarm.cancelBackstop()
        ticker?.invalidate(); ticker = nil
        let epochs = recorder.stop()
        let start = sessionStart?.timeIntervalSince1970 ?? Date().timeIntervalSince1970 - 3600
        let end = Date().timeIntervalSince1970

        var n = Stager.analyze(epochs, startAt: start, endAt: end)
        let r = Scorer.compute(n, baseline: baseline)
        n.score = r.total
        n.confidence = r.confidence
        Storage.save(n); Storage.clearLive()

        night = n; result = r
        history = Storage.load()
        baseline = Scorer.baseline(from: history)
        sessionStart = nil
        screen = .morning
    }

    func finishInterrupted() {
        guard let live = Storage.loadLive() else { screen = .bedtime; return }
        var n = Stager.analyze(live.epochs, startAt: live.startAt, endAt: Date().timeIntervalSince1970)
        let r = Scorer.compute(n, baseline: baseline)
        n.score = r.total; n.confidence = r.confidence
        Storage.save(n); Storage.clearLive()
        night = n; result = r
        history = Storage.load(); baseline = Scorer.baseline(from: history)
        screen = .morning
    }

    func discardInterrupted() { Storage.clearLive(); screen = .bedtime }

    func setRested(_ v: Int) {
        guard var n = night else { return }
        n.rested = v; night = n; Storage.save(n)
        history = Storage.load()
    }

    func show(_ n: Night) {
        night = n
        result = Scorer.compute(n, baseline: baseline)
        screen = .morning
    }

    private func nextOccurrence(of time: Date) -> Date {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: time)
        var next = cal.nextDate(after: Date(), matching: c, matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
        if next.timeIntervalSinceNow < 60 { next = next.addingTimeInterval(86400) }
        return next
    }

    var backstopText: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: nextOccurrence(of: alarmTime).addingTimeInterval(600))
    }
}
