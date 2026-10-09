import SwiftUI
import AppKit
import PiezoCore

enum ScopePhase: Equatable { case idle, connecting, live, stopping, failed }

@MainActor
final class ScopeModel: ObservableObject {
    @Published var devices: [AudioInputDevice] = []
    @Published var selectedDeviceUID = ""
    @Published var phase: ScopePhase = .idle
    @Published var message = "Connect your Teensy, then press Start."
    @Published var error: String?
    @Published var snapshot = ScopeSnapshot()
    @Published var waveform: [WaveBin] = []
    @Published var displayedWindowMS: Double = 50
    @Published var audioStatus = AudioStatus()
    @Published var midiStatus = MIDIStatus()
    @Published var config = PerformanceConfiguration() { didSet { applyConfiguration() } }
    @Published var listenEnabled = false { didSet { session.audio.setEnabled(listenEnabled); UserDefaults.standard.set(listenEnabled, forKey: "listen") } }
    @Published var volume: Double = 0.5831616620111733 { didSet { session.audio.setVolume(Float(volume)); UserDefaults.standard.set(volume, forKey: "volume") } }
    @Published var boostDB: Double = 24 { didSet { session.audio.setBoostDB(Float(boostDB)); UserDefaults.standard.set(boostDB, forKey: "boost") } }
    @Published var viewScale: Double = 0
    @Published var hold = false { didSet { if !hold { updateWaveform() } } }
    private let session = CaptureSession()
    private var refreshTimer: Timer?
    private let diagnosticsURL: URL?
    private var lastDiagnostics: TimeInterval = 0
    private var initialized = false
    let sampleRate = 32_000
    var selectedPin: Int { config.selectedChannel + 15 }
    var isActive: Bool { [.connecting, .live, .stopping].contains(phase) }
    var canStart: Bool { !isActive && devices.contains { $0.uid == selectedDeviceUID } }
    var selectedSignal: ChannelSnapshot { snapshot.channels[config.selectedChannel] }
    var waveformRange: Float {
        if viewScale > 0 { return Float(viewScale) }
        var peak = waveform.reduce(Float(0)) { max($0, max(abs($1.low), abs($1.high))) }
        if config.mode == .midi { peak = max(peak, Float(config.pads[config.selectedChannel].threshold / 4096)) }
        return max(0.01, pow(2, ceil(log2(max(0.01, peak * 1.2)))))
    }
    var peakDB: Double { 20 * log10(max(0.000001, Double(selectedSignal.peak))) }
    var rmsDB: Double { 20 * log10(max(0.000001, Double(selectedSignal.rms))) }
    var statusText: String {
        switch phase {
        case .idle: return snapshot.received > 0 ? "Stopped" : "Ready"
        case .connecting: return "Connecting"
        case .live: return "Live"
        case .stopping: return "Stopping"
        case .failed: return "Disconnected"
        }
    }
    init() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--diagnostics"), args.indices.contains(index+1) { diagnosticsURL = URL(fileURLWithPath: args[index+1]) }
        else { diagnosticsURL = nil }
        if let data = UserDefaults.standard.data(forKey: "performance.v2"),
           var value = try? JSONDecoder().decode(PerformanceConfiguration.self, from: data), value.pads.count == 7 {
            for i in 0..<7 { value.pads[i].id = i; value.pads[i].sanitize() }
            value.selectedChannel = min(6, max(0, value.selectedChannel)); config = value
        }
        if UserDefaults.standard.object(forKey: "listen") != nil { listenEnabled = UserDefaults.standard.bool(forKey: "listen") }
        if UserDefaults.standard.object(forKey: "volume") != nil { volume = UserDefaults.standard.double(forKey: "volume") }
        if UserDefaults.standard.object(forKey: "boost") != nil { boostDB = UserDefaults.standard.double(forKey: "boost") }
        session.onEvent = { [weak self] event in DispatchQueue.main.async { self?.handle(event) } }
        session.audio.onStatus = { [weak self] value in DispatchQueue.main.async { self?.audioStatus = value } }
                session.midi.onStatus = { [weak self] value in DispatchQueue.main.async { self?.midiStatus = value } }
        initialized = true; applyConfiguration(); refreshDevices()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.isActive == false { self?.refreshDevices() } }
        }
        if args.contains("--autostart") { DispatchQueue.main.async { [weak self] in self?.start() } }
    }
    private func applyConfiguration() {
        guard initialized else { return }
        var c = config
        for i in c.pads.indices { c.pads[i].sanitize() }
        c.midiChannel = min(16, max(1, c.midiChannel)); c.fixedVelocity = min(127, max(1, c.fixedVelocity))
        c.selectedChannel = min(6, max(0, c.selectedChannel))
        c.windowSeconds = [0.05,0.2,1].contains(c.windowSeconds) ? c.windowSeconds : 0.2
        session.configure(c)
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: "performance.v2") }
        if !hold { updateWaveform() }
    }
    private func updateWaveform() { waveform = selectedSignal.bins; displayedWindowMS = snapshot.windowMS }
    func refreshDevices() {
        devices = AudioInputDiscovery.devices()
        if !devices.contains(where: { $0.uid == selectedDeviceUID }) { selectedDeviceUID = devices.first?.uid ?? "" }
    }
    func testMIDI(_ input: Int) { session.test(input) }
    func toggleCapture() { isActive ? stop() : start() }
    func start() {
        guard canStart, let device = devices.first(where: { $0.uid == selectedDeviceUID }) else { return }
        error = nil; snapshot = ScopeSnapshot(); waveform = []; audioStatus = AudioStatus(); hold = false
        phase = .connecting; message = "Opening USB audio…"
        session.audio.setEnabled(listenEnabled); session.audio.setVolume(Float(volume)); session.audio.setBoostDB(Float(boostDB))
        applyConfiguration(); session.start(device)
    }
    func stop() { guard isActive else { return }; phase = .stopping; message = "Stopping capture…"; session.stop() }
    func shutdown() { refreshTimer?.invalidate(); session.shutdown() }
    private func handle(_ event: SessionEvent) {
        switch event {
        case .message(let text): message = text
        case .live: phase = .live; message = "USB Audio · 7 inputs · 32 kHz each"
        case .snapshot(let value): snapshot = value; if !hold { updateWaveform() }
        case .finished(let failure): error = failure; phase = failure == nil ? .idle : .failed; message = failure == nil ? "Capture stopped." : "Reconnect the Teensy and try again."
        }
        writeDiagnostics()
    }
    private func writeDiagnostics() {
        guard let diagnosticsURL else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDiagnostics > 0.5 || !isActive else { return }; lastDiagnostics = now
        let values: [String: Any] = [
            "phase": statusText, "deviceUID": selectedDeviceUID, "pins": Array(15...21), "selectedPin": selectedPin,
            "sampleRate": sampleRate, "receivedFrames": snapshot.received, "missingFrames": snapshot.missing,
            "timingIssues": snapshot.timingIssues, "mode": config.mode.rawValue, "inputBufferFrames": snapshot.bufferFrames,
            "listenEnabled": listenEnabled, "volume": volume, "boostDB": boostDB,
            "audioRunning": audioStatus.running, "audioRenderedFrames": audioStatus.renderedFrames,
            "midiAvailable": midiStatus.available, "midiHits": midiStatus.sent, "midiLastMessage": midiStatus.lastMessage,
            "channels": snapshot.channels.enumerated().map { i,c in ["input": i+1, "pin": i+15, "minimumPCM": c.minimum, "maximumPCM": c.maximum, "peakCounts": Double(c.peak)*4096, "hits": c.hits, "lastVelocity": c.lastVelocity] as [String:Any] },
            "error": error ?? midiStatus.error ?? audioStatus.error ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted,.sortedKeys]) { try? data.write(to: diagnosticsURL, options: .atomic) }
    }
}
