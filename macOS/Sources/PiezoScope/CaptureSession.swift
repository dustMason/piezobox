import Foundation
import PiezoCore

enum OutputMode: String, Codable, CaseIterable { case audio = "Audio", midi = "MIDI" }
struct PerformanceConfiguration: Codable {
    var mode: OutputMode = .audio
    var pads = DrumConfiguration.defaults
    var dynamicVelocity = true
    var fixedVelocity = 100
    var midiChannel = 10
    var selectedChannel = 5
    var windowSeconds: Double = 0.05
}
struct ChannelSnapshot {
    var bins: [WaveBin] = []
    var peak: Float = 0
    var rms: Float = 0
    var hits: UInt64 = 0
    var lastVelocity = 0
    var lastHitTime: TimeInterval = 0
    var minimum: Float = 1
    var maximum: Float = -1
}
struct ScopeSnapshot {
    var channels = Array(repeating: ChannelSnapshot(), count: 7)
    var received: UInt64 = 0
    var missing: UInt64 = 0
    var timingIssues: UInt64 = 0
    var windowMS: Double = 50
    var bufferFrames = 0
}
enum SessionEvent {
    case message(String), live, snapshot(ScopeSnapshot), finished(String?)
}
final class CaptureSession {
    let audio = AudioMonitor()
    let midi = MIDIOutput()
    private let transport = CoreAudioInput()
    private let settingsLock = NSLock()
    private var settings = PerformanceConfiguration()
    private var histories = (0..<7).map { _ in SignalHistory(capacity: 64_000) }
    private var triggers = (0..<7).map { _ in DrumTrigger() }
    private var snapshot = ScopeSnapshot()
    private var sequence: UInt64 = 0
    private var monitorBlock: [Float] = []
    private var squares = [Double](repeating: 0, count: 7)
    private var peaks = [Float](repeating: 0, count: 7)
    private var windowFrames = 0
    private var lastPublish: TimeInterval = 0
    private var previousMode: OutputMode = .audio
    var onEvent: ((SessionEvent) -> Void)?

    func configure(_ value: PerformanceConfiguration) {
        settingsLock.lock(); settings = value; settingsLock.unlock()
        midi.configure(enabled: value.mode == .midi)
    }
    private func configuration() -> PerformanceConfiguration {
        settingsLock.lock(); defer { settingsLock.unlock() }; return settings
    }
    func start(_ device: AudioInputDevice) {
        histories = (0..<7).map { _ in SignalHistory(capacity: 64_000) }
        triggers = (0..<7).map { _ in DrumTrigger() }
        snapshot = ScopeSnapshot(); sequence = 0; monitorBlock = []
        squares = .init(repeating: 0, count: 7); peaks = .init(repeating: 0, count: 7)
        windowFrames = 0; lastPublish = 0
        transport.start(device) { [weak self] in self?.handle($0) }
    }
    func stop() { transport.stop(); midi.allNotesOff(); audio.finish() }
    func shutdown() { transport.shutdown(); midi.shutdown(); audio.shutdown() }
    func test(_ input: Int) {
        let c = configuration(); let p = c.pads[input]
        midi.hit(DrumHit(input: input, note: p.note, velocity: c.dynamicVelocity ? 100 : c.fixedVelocity, peakCounts: 0, sequence: 0), channel: c.midiChannel, test: true)
    }
    private func handle(_ event: AudioInputEvent) {
        switch event {
        case .message(let text): onEvent?(.message(text))
        case .finished(let error):
            publish(force: true); midi.allNotesOff(); audio.finish(); onEvent?(.finished(error))
        case .live(let quantum):
            snapshot.bufferFrames = quantum; audio.configure(rate: 32_000); onEvent?(.live)
        case .block(let block):
            let c = configuration()
            if block.dropped > snapshot.missing || block.discontinuities > snapshot.timingIssues {
                let gap = block.dropped - snapshot.missing
                sequence += gap
                for ch in 0..<7 {
                    triggers[ch].reset()
                    for _ in 0..<Int(min(gap, 64_000)) { histories[ch].append(0) }
                }
                monitorBlock.removeAll(keepingCapacity: true); audio.discardQueuedAudio(); midi.allNotesOff()
                snapshot.missing = block.dropped; snapshot.timingIssues = block.discontinuities
            }
            if previousMode != c.mode { for i in 0..<7 { triggers[i].reset() }; previousMode = c.mode }
            for frame in 0..<block.frames {
                for ch in 0..<7 {
                    // USB already supplies centered PCM. Avoid applying the DC filter twice.
                    let incoming = block.samples[frame * 7 + ch]
                    let sample = incoming.isFinite ? incoming : 0
                    snapshot.channels[ch].minimum = min(snapshot.channels[ch].minimum, sample)
                    snapshot.channels[ch].maximum = max(snapshot.channels[ch].maximum, sample)
                    histories[ch].append(sample)
                    peaks[ch] = max(peaks[ch], abs(sample)); squares[ch] += Double(sample * sample)
                    if ch == c.selectedChannel { monitorBlock.append(sample) }
                    if c.mode == .midi, let hit = triggers[ch].process(sample, sequence: sequence, config: c.pads[ch], dynamicVelocity: c.dynamicVelocity, fixedVelocity: c.fixedVelocity) {
                        snapshot.channels[ch].hits += 1; snapshot.channels[ch].lastVelocity = hit.velocity
                        snapshot.channels[ch].lastHitTime = ProcessInfo.processInfo.systemUptime
                        midi.hit(hit, channel: c.midiChannel)
                    }
                }
                sequence += 1; snapshot.received += 1; windowFrames += 1
                if monitorBlock.count >= 128 { audio.append(monitorBlock); monitorBlock.removeAll(keepingCapacity: true) }
            }
            publish(force: false)
        }
    }
    private func publish(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastPublish >= 1.0 / 30 else { return }; lastPublish = now
        let c = configuration(); let samples = Int(c.windowSeconds * 32_000)
        for ch in 0..<7 {
            snapshot.channels[ch].bins = histories[ch].envelope(last: samples, bins: 700)
            if windowFrames > 0 { snapshot.channels[ch].peak = peaks[ch]; snapshot.channels[ch].rms = Float(sqrt(squares[ch] / Double(windowFrames))) }
        }
        snapshot.windowMS = Double(min(samples, histories[0].count)) / 32
        onEvent?(.snapshot(snapshot))
        peaks = .init(repeating: 0, count: 7); squares = .init(repeating: 0, count: 7); windowFrames = 0
    }
}
