import AVFoundation
import Foundation

struct AudioStatus {
    var running = false
    var scheduledFrames: UInt64 = 0
    var renderedFrames: Int64 = 0
    var clippedSamples: UInt64 = 0
    var rebufferCount: UInt64 = 0
    var queuedFrames = 0
    var error: String?
}

/// AVAudioEngine is a playback sink. It does not own the USB audio input.
final class AudioMonitor {
    private let queue = DispatchQueue(label: "com.dustmason.piezo.audio", qos: .userInteractive)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var observer: NSObjectProtocol?
    private var pending: [Float] = []
    private var queued = 0
    private var generation = 0
    private var rate = 16_000
    private var enabled = true
    private var capturing = false
    private var volume: Float = 0.2
    private var boost: Float = 3.9810717 // +12 dB
    private var status = AudioStatus()
    private var lastPublish: TimeInterval = 0
    var onStatus: ((AudioStatus) -> Void)?

    func configure(rate: Int) {
        queue.async {
            self.rate = rate
            self.capturing = true
            self.status = AudioStatus()
            self.rebuild()
        }
    }
    func setEnabled(_ value: Bool) {
        queue.async { self.enabled = value; self.rebuild() }
    }
    func setVolume(_ value: Float) {
        queue.async { self.volume = value; self.player?.volume = value }
    }
    func setBoostDB(_ value: Float) {
        queue.async { self.boost = pow(10, value / 20) }
    }
    func finish() {
        queue.async { self.capturing = false; self.tearDown(); self.publish(force: true) }
    }
    func shutdown() {
        queue.sync { self.capturing = false; self.tearDown() }
    }
    func discardQueuedAudio() {
        queue.async { if self.capturing { self.status.rebufferCount += 1; self.rebuild() } }
    }

    func append(_ samples: [Float]) {
        queue.async { [self] in
            guard self.enabled, self.capturing, let player = self.player, let format = self.format else { return }
            self.pending.append(contentsOf: samples)
            let block = 256
            while self.pending.count >= block {
                if self.queued > self.rate / 4 {
                    // Bound latency instead of allowing stale audio to accumulate.
                    self.generation += 1
                    player.stop()
                    self.queued = 0
                    self.status.rebufferCount += 1
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)),
                      let output = buffer.floatChannelData?[0] else { return }
                buffer.frameLength = AVAudioFrameCount(block)
                for index in 0..<block {
                    let value = self.pending[index] * self.boost
                    if abs(value) > 0.98 { self.status.clippedSamples += 1 }
                    output[index] = max(-0.98, min(0.98, value))
                }
                self.pending.removeFirst(block)
                self.queued += block
                self.status.scheduledFrames += UInt64(block)
                let generation = self.generation
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        guard generation == self.generation else { return }
                        self.queued = max(0, self.queued - block)
                    }
                }
                if !player.isPlaying && self.queued >= block * 3 { player.play() }
            }
            self.publish(force: false)
        }
    }

    private func rebuild() {
        tearDown()
        guard capturing && enabled else { publish(force: true); return }
        do {
            let newEngine = AVAudioEngine()
            let newPlayer = AVAudioPlayerNode()
            guard let newFormat = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1) else {
                throw NSError(domain: "PiezoScope", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported playback format."])
            }
            newEngine.attach(newPlayer)
            newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: newFormat)
            newPlayer.volume = volume
            newEngine.prepare()
            try newEngine.start()
            engine = newEngine; player = newPlayer; format = newFormat
            status.error = nil
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                              object: newEngine, queue: nil) { [weak self] _ in
                self?.queue.async { self?.rebuild() }
            }
        } catch {
            status.error = "Playback unavailable: \(error.localizedDescription) Check the Mac’s sound output, then toggle Listen off and on."
        }
        publish(force: true)
    }

    private func tearDown() {
        generation += 1
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        player?.stop(); engine?.stop()
        player = nil; engine = nil; format = nil
        queued = 0; pending.removeAll(keepingCapacity: true)
        status.running = false
        status.queuedFrames = 0
    }

    private func publish(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPublish >= 0.25 else { return }
        lastPublish = now
        status.running = engine?.isRunning == true && player?.isPlaying == true
        status.queuedFrames = queued
        if let time = player?.lastRenderTime, let played = player?.playerTime(forNodeTime: time) {
            status.renderedFrames = played.sampleTime
        }
        onStatus?(status)
    }
}
