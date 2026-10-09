import SwiftUI
import AppKit
import PiezoCore

enum ScopePhase: Equatable {
    case idle, connecting, live, stopping, failed
}

@MainActor
final class ScopeModel: ObservableObject {
    @Published var devices: [SerialDevice] = []
    @Published var selectedPort = ""
    @Published var selectedPin = 21
    @Published var sampleRate = 16_000
    @Published var phase: ScopePhase = .idle
    @Published var message = "Connect your Teensy, then press Start."
    @Published var error: String?
    @Published var snapshot = ScopeSnapshot()
    @Published var waveform: [WaveBin] = []
    @Published var displayedWindowMS: Double = 200
    @Published var audioStatus = AudioStatus()
    @Published var listenEnabled = true { didSet { session.audio.setEnabled(listenEnabled) } }
    @Published var volume: Double = 0.2 { didSet { session.audio.setVolume(Float(volume)) } }
    @Published var boostDB: Double = 12 { didSet { session.audio.setBoostDB(Float(boostDB)) } }
    @Published var timeWindow: Double = 0.2 { didSet { session.setWindow(timeWindow) } }
    @Published var viewScale: Double = 0
    @Published var hold = false {
        didSet {
            if !hold { waveform = snapshot.bins; displayedWindowMS = snapshot.windowMS }
        }
    }

    private let session = CaptureSession()
    private var refreshTimer: Timer?
    private let diagnosticsURL: URL?
    private var lastDiagnostics: TimeInterval = 0
    var isActive: Bool { [.connecting, .live, .stopping].contains(phase) }
    var canStart: Bool { !isActive && devices.contains { $0.path == selectedPort } }
    var waveformRange: Float {
        if viewScale > 0 { return Float(viewScale) }
        let peak = waveform.reduce(Float(0)) { max($0, max(abs($1.low), abs($1.high))) }
        let minimum: Float = 0.01
        return max(minimum, pow(2, ceil(log2(max(minimum, peak * 1.2)))))
    }
    var peakDB: Double { 20 * log10(max(0.000001, Double(snapshot.peak))) }
    var rmsDB: Double { 20 * log10(max(0.000001, Double(snapshot.rms))) }
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
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--diagnostics"), arguments.indices.contains(index + 1) {
            diagnosticsURL = URL(fileURLWithPath: arguments[index + 1])
        } else { diagnosticsURL = nil }
        session.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        session.audio.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.audioStatus = status }
        }
        refreshDevices()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.isActive == false { self?.refreshDevices() } }
        }
    }

    func refreshDevices() {
        devices = DeviceDiscovery.teensys()
        if !devices.contains(where: { $0.path == selectedPort }) { selectedPort = devices.first?.path ?? "" }
    }

    func toggleCapture() { isActive ? stop() : start() }

    func start() {
        guard canStart else { return }
        error = nil
        snapshot = ScopeSnapshot(); waveform = []; audioStatus = AudioStatus(); hold = false
        phase = .connecting; message = "Opening Teensy…"
        session.audio.setEnabled(listenEnabled)
        session.audio.setVolume(Float(volume))
        session.audio.setBoostDB(Float(boostDB))
        session.setWindow(timeWindow)
        session.start(CaptureConfiguration(port: selectedPort, pin: selectedPin, rate: sampleRate))
    }

    func stop() {
        guard isActive else { return }
        phase = .stopping; message = "Stopping capture…"
        session.stop()
    }

    func shutdown() {
        refreshTimer?.invalidate()
        session.shutdown()
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .message(let text): message = text
        case .live: phase = .live; message = "Receiving A\(selectedPin - 14) · pin \(selectedPin)"
        case .snapshot(let value):
            snapshot = value
            if !hold { waveform = value.bins; displayedWindowMS = value.windowMS }
        case .finished(let failure):
            error = failure
            phase = failure == nil ? .idle : .failed
            message = failure == nil ? "Capture stopped." : "Reconnect the Teensy and try again."
        }
        writeDiagnostics()
    }

    private func writeDiagnostics() {
        guard let diagnosticsURL else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDiagnostics > 0.5 || !isActive else { return }
        lastDiagnostics = now
        let values: [String: Any] = [
            "phase": statusText, "port": selectedPort, "pin": selectedPin,
            "sampleRate": sampleRate, "receivedFrames": snapshot.received,
            "missingFrames": snapshot.missing, "timingIssues": snapshot.timingIssues,
            "rawMinimum": snapshot.rawMinimum, "rawMaximum": snapshot.rawMaximum,
            "inputPeakDBFS": peakDB, "waveformBins": waveform.count,
            "listenEnabled": listenEnabled, "volume": volume, "boostDB": boostDB,
            "audioRunning": audioStatus.running, "audioScheduledFrames": audioStatus.scheduledFrames,
            "audioRenderedFrames": audioStatus.renderedFrames, "audioQueuedFrames": audioStatus.queuedFrames,
            "audioClippedSamples": audioStatus.clippedSamples, "audioRebuffers": audioStatus.rebufferCount,
            "error": error ?? audioStatus.error ?? "",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: diagnosticsURL, options: .atomic)
        }
    }
}
