import Foundation
import PiezoCore

struct ScopeSnapshot {
    var bins: [WaveBin] = []
    var peak: Float = 0
    var rms: Float = 0
    var received: UInt64 = 0
    var missing: UInt64 = 0
    var timingIssues: UInt64 = 0
    var fullScaleSamples: UInt64 = 0
    var rawMinimum: UInt16 = 4095
    var rawMaximum: UInt16 = 0
    var windowMS: Double = 200
}

enum SessionEvent {
    case message(String)
    case live
    case snapshot(ScopeSnapshot)
    case finished(String?)
}

final class CaptureSession {
    let audio = AudioMonitor()
    private let transport = SerialTransport()
    private let settingsLock = NSLock()
    private var windowSeconds: Double = 0.2
    private var rate = 16_000
    private var history = SignalHistory()
    private var dc = DCBlocker(rate: 16_000)
    private var snapshot = ScopeSnapshot()
    private var expectedSequence: UInt32 = 0
    private var audioBlock: [Float] = []
    private var sumSquares: Double = 0
    private var windowFrames = 0
    private var peak: Float = 0
    private var lastPublish: TimeInterval = 0
    var onEvent: ((SessionEvent) -> Void)?

    func setWindow(_ seconds: Double) {
        settingsLock.lock(); windowSeconds = seconds; settingsLock.unlock()
    }
    func start(_ config: CaptureConfiguration) {
        rate = config.rate
        history = SignalHistory(capacity: rate * 2)
        dc = DCBlocker(rate: rate)
        snapshot = ScopeSnapshot()
        expectedSequence = 0
        audioBlock.removeAll(keepingCapacity: true)
        sumSquares = 0; windowFrames = 0; peak = 0; lastPublish = 0
        transport.start(config) { [weak self] event in self?.handle(event) }
    }
    func stop() { transport.stop(); audio.finish() }
    func shutdown() { transport.shutdown(); audio.shutdown() }

    private func handle(_ event: SerialEvent) {
        switch event {
        case .message(let text): onEvent?(.message(text))
        case .finished(let error):
            publish(force: true)
            audio.finish()
            onEvent?(.finished(error))
        case .capture(.header):
            expectedSequence = 0
            dc.reset()
            audioBlock.removeAll(keepingCapacity: true)
            audio.configure(rate: rate)
            onEvent?(.live)
        case .capture(.frames(let frames)):
            for frame in frames {
                if frame.sequence > expectedSequence { gap(Int(frame.sequence - expectedSequence)) }
                expectedSequence = frame.sequence + 1
                let raw = frame.values[0]
                snapshot.rawMinimum = min(snapshot.rawMinimum, raw)
                snapshot.rawMaximum = max(snapshot.rawMaximum, raw)
                if raw == 4095 { snapshot.fullScaleSamples += 1 }
                let sample = dc.process(raw)
                history.append(sample)
                audioBlock.append(sample)
                snapshot.received += 1
                peak = max(peak, abs(sample))
                sumSquares += Double(sample * sample)
                windowFrames += 1
                if audioBlock.count >= 256 {
                    audio.append(audioBlock)
                    audioBlock.removeAll(keepingCapacity: true)
                }
            }
            publish(force: false)
        case .capture(.end(let stats)):
            if stats.attempted > expectedSequence { gap(Int(stats.attempted - expectedSequence)) }
            snapshot.timingIssues += UInt64(stats.slow) + UInt64(stats.late)
            publish(force: true)
        }
    }

    private func gap(_ count: Int) {
        snapshot.missing += UInt64(count)
        dc.reset()
        audioBlock.removeAll(keepingCapacity: true)
        audio.discardQueuedAudio()
        for _ in 0..<min(count, rate * 2) { history.append(0) }
    }

    private func publish(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPublish >= 1.0 / 30 else { return }
        lastPublish = now
        settingsLock.lock(); let seconds = windowSeconds; settingsLock.unlock()
        let samples = Int(seconds * Double(rate))
        snapshot.bins = history.envelope(last: samples)
        snapshot.windowMS = Double(min(samples, history.count)) / Double(rate) * 1000
        if windowFrames > 0 {
            snapshot.peak = peak
            snapshot.rms = Float(sqrt(sumSquares / Double(windowFrames)))
        }
        onEvent?(.snapshot(snapshot))
        peak = 0; sumSquares = 0; windowFrames = 0
    }
}
