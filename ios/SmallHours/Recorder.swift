import Foundation
import CoreMotion
import AVFoundation

// =============================================================================
// RECORDER — the thing a web page cannot do: keep sensing with the screen off.
//
// A phone on a mattress, all night, with the screen OFF. That works here for
// one reason: the `audio` background mode. An app capturing microphone input
// keeps running indefinitely in the background, and CoreMotion keeps delivering
// while it does. This is the same architecture Sleep Cycle uses.
//
// Raw samples never leave this file. Motion collapses to one figure per 30s
// epoch and audio collapses to level statistics — no audio buffer is retained,
// written, or transmitted, ever.
// =============================================================================

@MainActor
final class Recorder: ObservableObject {

    @Published private(set) var epochs: [Epoch] = []
    @Published private(set) var isRunning = false
    @Published private(set) var motionAvailable = false
    @Published private(set) var audioAvailable = false

    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var engine: AVAudioEngine?

    // accumulators for the epoch currently being filled
    private var epochStart: TimeInterval = 0
    private var mSum = 0.0, mPeak = 0.0, mCount = 0
    private var dbSum = 0.0, dbPeak = -140.0, bandPeak = 0.0, aCount = 0
    private var timer: Timer?
    private var wantAudio = false
    private var observers: [NSObjectProtocol] = []

    var onEpoch: ((Epoch, [Epoch]) -> Void)?

    // MARK: - session

    func start(withAudio wantAudio: Bool) throws {
        guard !isRunning else { return }
        epochs.removeAll()
        epochStart = Date().timeIntervalSince1970
        resetAccumulators()

        self.wantAudio = wantAudio
        try configureSession(wantAudio: wantAudio)
        observeInterruptions()
        startMotion()
        if wantAudio { startAudio() }

        // Self-correcting: each tick closes however many epoch boundaries have
        // actually passed, so eight hours of timer drift cannot accumulate.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        isRunning = true
    }

    /// A phone call, Siri, or an alarm takes the audio session away. Without
    /// this the AVAudioEngine stops and never comes back, so the rest of the
    /// night records nothing — silently. The same class of failure as Safari's
    /// 'interrupted' AudioContext state.
    private func observeInterruptions() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                switch type {
                case .began:
                    self.stopAudio()
                case .ended:
                    guard self.isRunning, self.wantAudio, !self.micReleased else { return }
                    try? self.configureSession(wantAudio: true)
                    self.startAudio()
                @unknown default: break
                }
            }
        })
        // The engine also stops on a route change (a charger, Bluetooth, the
        // speaker being taken over). It does not restart itself.
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, self.wantAudio, !self.micReleased else { return }
                if self.engine?.isRunning != true { self.stopAudio(); self.startAudio() }
            }
        })
    }

    func stop() -> [Epoch] {
        guard isRunning else { return epochs }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        timer?.invalidate(); timer = nil
        motion.stopDeviceMotionUpdates()
        stopAudio()
        if mCount + aCount > 0 { closeEpoch() }
        isRunning = false
        return epochs
    }

    /// Stop capturing and switch to playback for the alarm. The session stays
    /// ACTIVE throughout: on iOS the live audio session is the only thing keeping
    /// this app running with the screen locked, so deactivating it — even for a
    /// moment — lets the OS suspend us and the alarm never rings.
    private(set) var micReleased = false
    func releaseMicrophone() {
        guard !micReleased else { return }
        micReleased = true
        stopAudio()
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
    }

    /// Snooze: back to recording, which is also what keeps us alive until the
    /// snoozed alarm.
    func resumeMicrophone() {
        guard isRunning, micReleased else { return }
        micReleased = false
        try? configureSession(wantAudio: true)
        startAudio()
    }

    // MARK: - session configuration

    private func configureSession(wantAudio: Bool) throws {
        let s = AVAudioSession.sharedInstance()
        if wantAudio {
            // Deliberately NO Bluetooth: with AirPods or a paired speaker in range
            // the session would capture from those instead of the phone lying on
            // the mattress, which is the one microphone that matters here.
            try s.setCategory(.playAndRecord, mode: .measurement,
                              options: [.mixWithOthers, .defaultToSpeaker])
        } else {
            try s.setCategory(.playback, options: [.mixWithOthers])
        }
        try s.setActive(true)
    }

    // MARK: - motion

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { motionAvailable = false; return }
        motionAvailable = true
        motion.deviceMotionUpdateInterval = 1.0 / 50.0
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .utility
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] dm, _ in
            guard let dm else { return }
            // userAcceleration is already gravity-free, so no high-pass filter
            // is needed — a real advantage over the browser's raw reading.
            let a = dm.userAcceleration
            let mag = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            Task { @MainActor in self?.addMotion(mag) }
        }
    }

    private func addMotion(_ v: Double) {
        mSum += v; mPeak = max(mPeak, v); mCount += 1
    }

    // MARK: - audio

    private func startAudio() {
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { audioAvailable = false; return }
        // one-pole low-pass at 500 Hz: the band snoring lives in
        let a = Float(1 - exp(-2 * Double.pi * 500 / format.sampleRate))

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }

            var sum = 0.0, peak = 0.0, lowSum = 0.0
            var y: Float = 0      // ponytail: filter state resets per 85ms buffer; the transient is ~15 samples
            for i in 0..<count {
                let x = ch[i]
                y += a * (x - y)
                let v = Double(x); sum += v * v; peak = max(peak, abs(v))
                lowSum += Double(y * y)
            }
            let rms = (sum / Double(count)).squareRoot()
            let db = 20 * log10(max(rms, 1e-7))
            let dbPeakSample = 20 * log10(max(peak, 1e-7))
            // same 0-255 scale as the web build: -100 dBFS -> 0, -30 dBFS -> 255
            let lowDb = 20 * log10(max((lowSum / Double(count)).squareRoot(), 1e-7))
            let band = min(255, max(0, (lowDb + 100) / 70 * 255))

            Task { @MainActor in self?.addAudio(db: db, peak: dbPeakSample, band: band) }
        }
        do {
            try e.start()
            engine = e
            audioAvailable = true
        } catch {
            audioAvailable = false
        }
    }

    private func addAudio(db: Double, peak: Double, band: Double) {
        dbSum += db; dbPeak = max(dbPeak, peak); bandPeak = max(bandPeak, band); aCount += 1
    }

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    // MARK: - epochs

    private func resetAccumulators() {
        mSum = 0; mPeak = 0; mCount = 0
        dbSum = 0; dbPeak = -140; bandPeak = 0; aCount = 0
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        while now - epochStart >= epochSeconds {
            let next = epochStart + epochSeconds
            closeEpoch()
            epochStart = next
        }
    }

    private func closeEpoch() {
        let e = Epoch(
            t: epochStart,
            motionMean: mCount > 0 ? (mSum / Double(mCount)) * 1000 : nil,
            motionPeak: mCount > 0 ? mPeak * 1000 : nil,
            dbMean: aCount > 0 ? dbSum / Double(aCount) : nil,
            dbPeak: aCount > 0 ? dbPeak : nil,
            band: aCount > 0 ? bandPeak : nil)
        epochs.append(e)
        resetAccumulators()
        onEpoch?(e, epochs)
    }
}
