import AVFoundation

/// How much audio is queued, and what to do with the next packet.
///
/// Network jitter makes packets arrive in bursts. After the queue runs dry,
/// a short cushion of silence goes in first, so the next burst doesn't crackle.
/// Above `maxQueued` new packets are dropped: late sound is worse than a
/// skipped 20ms, and the queue would otherwise only grow.
struct AudioBudget {
    static let maxQueued = Int(0.2 * AudioPayload.sampleRate)
    static let cushion = Int(0.04 * AudioPayload.sampleRate)

    private(set) var queued = 0

    /// Silence frames to schedule before this packet, or nil to drop it.
    mutating func admit(_ frames: Int) -> Int? {
        guard queued + frames <= Self.maxQueued else { return nil }
        let pad = queued == 0 ? Self.cushion : 0
        queued += pad + frames
        return pad
    }

    mutating func played(_ frames: Int) { queued = max(0, queued - frames) }
}

/// Plays the Mac's sound through AVAudioEngine. `enqueue` is safe from any one queue.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioPayload.sampleRate,
                                       channels: AVAudioChannelCount(AudioPayload.channels))!
    private let lock = NSLock()
    private var budget = AudioBudget()
    private var running = false
    private var observer: NSObjectProtocol?

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        // Route changes (headphones, AirPods) and interruptions stop the engine.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.reset()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        stop()
    }

    func enqueue(_ samples: [Int16]) {
        let frames = samples.count / AudioPayload.channels
        guard frames > 0 else { return }
        lock.lock()
        let pad = budget.admit(frames)
        lock.unlock()
        guard let pad, startIfNeeded() else { return }
        if pad > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pad)) {
            silence.frameLength = AVAudioFrameCount(pad) // zero-filled
            schedule(silence, frames: pad)
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            ch[0][i] = Float(samples[2 * i]) / 32767
            ch[1][i] = Float(samples[2 * i + 1]) / 32767
        }
        schedule(buf, frames: frames)
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        node.stop()
        engine.stop()
        budget = AudioBudget()
        running = false
    }

    private func reset() {
        lock.lock(); defer { lock.unlock() }
        budget = AudioBudget()
        running = false
    }

    private func schedule(_ buf: AVAudioPCMBuffer, frames: Int) {
        node.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.budget.played(frames); self.lock.unlock()
        }
    }

    private func startIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return true }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            node.play()
            running = true
        } catch {
            NSLog("RemoteMac: audio failed to start: \(error)")
        }
        return running
    }
}
