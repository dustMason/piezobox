import SwiftUI
import PiezoCore

enum ScopeColors {
    static let signal = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.75, alpha: 1)
        : NSColor(calibratedRed: 0.02, green: 0.43, blue: 0.39, alpha: 1)
    })
}

struct ContentView: View {
    @ObservedObject var model: ScopeModel
    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    routing
                    inputTable
                    selectedControls
                    waveform
                    listening
                    if let error = visibleError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }.padding(20)
            }
            Divider()
            HStack(spacing: 10) {
                Circle().fill(model.phase == .live ? ScopeColors.signal : .secondary).frame(width: 6, height: 6)
                Text(model.statusText).fontWeight(.medium)
                Text(model.message).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.snapshot.received.formatted()) frames").monospacedDigit()
                Text("\(model.snapshot.missing) missing frames")
                    .foregroundStyle(model.snapshot.missing > 0 ? Color.orange : .secondary).monospacedDigit()
                if model.snapshot.timingIssues > 0 { Label("Input discontinuity", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }.font(.caption).padding(.horizontal, 20).padding(.vertical, 10)
        }
        .frame(minWidth: 980, minHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private var visibleError: String? {
        model.error ?? model.midiStatus.error ?? model.audioStatus.error
    }
    private var connectionBar: some View {
        HStack(spacing: 16) {
            Picker("Device", selection: $model.selectedDeviceUID) {
                if model.devices.isEmpty { Text("No Teensy connected").tag("") }
                ForEach(model.devices) { Text($0.title).tag($0.uid) }
            }.frame(maxWidth: 360).disabled(model.isActive)
            Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh audio inputs").accessibilityLabel("Refresh audio inputs").disabled(model.isActive)
            Text("7 inputs · 32 kHz").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button(action: model.toggleCapture) {
                Label(model.isActive ? "Stop" : "Start", systemImage: model.isActive ? "stop.fill" : "play.fill").frame(width: 80)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled((!model.isActive && !model.canStart) || model.phase == .stopping)
                .keyboardShortcut("r", modifiers: .command)
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }
    private var routing: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Output mode", selection: $model.config.mode) {
                    ForEach(OutputMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 200)
                Spacer()
                if model.config.mode == .audio {
                    Label(model.devices.isEmpty ? "Connect the USB box" : "USB audio available", systemImage: "cable.connector")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("\(model.midiStatus.sent) MIDI hits sent").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if model.config.mode == .audio {
                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Piezo Box LC Mono").fontWeight(.medium)
                        Text("All seven inputs averaged into one channel.").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Piezo Box LC 7 Inputs").fontWeight(.medium)
                        Text("Each input on its own recording channel.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text("Choose either USB input in your music app. Both work even when Piezo Scope is closed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 18) {
                    Stepper("Channel \(model.config.midiChannel)", value: $model.config.midiChannel, in: 1...16).frame(width: 140)
                    Picker("Velocity", selection: $model.config.dynamicVelocity) {
                        Text("Hit strength").tag(true); Text("Fixed").tag(false)
                    }.pickerStyle(.segmented).frame(width: 210)
                    if !model.config.dynamicVelocity {
                        Stepper("\(model.config.fixedVelocity)", value: $model.config.fixedVelocity, in: 1...127).frame(width: 90).accessibilityLabel("Fixed MIDI velocity")
                    }
                    Spacer()
                    Text("Piezo Box Drums").fontWeight(.medium)
                }
                Text("Select “Piezo Box Drums” as a MIDI input in your music app. \(model.midiStatus.lastMessage).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var inputTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(model.config.mode == .midi ? "On" : "").frame(width: 26)
                Text("Input").frame(width: 92, alignment: .leading)
                Text("Name").frame(width: 120, alignment: .leading)
                Text("Signal").frame(maxWidth: .infinity, alignment: .leading)
                if model.config.mode == .midi {
                    Text("Trigger threshold · counts").frame(width: 220, alignment: .leading)
                    Text("MIDI note").frame(width: 85)
                    Text("Hits").frame(width: 55, alignment: .trailing)
                    Color.clear.frame(width: 42, height: 1)
                } else { Text("Peak · counts").frame(width: 100, alignment: .trailing) }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            ForEach(0..<7, id: \.self) { index in
                InputRow(model: model, index: index)
                if index < 6 { Divider() }
            }
        }.background(Color(nsColor: .textBackgroundColor))
            .overlay(Rectangle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
    }
    private var selectedControls: some View {
        HStack(spacing: 20) {
            Text("Input \(model.config.selectedChannel + 1) · \(model.config.pads[model.config.selectedChannel].name)").font(.headline)
            Spacer()
            if model.config.mode == .midi {
                Stepper("Retrigger \(Int(model.config.pads[model.config.selectedChannel].retriggerMS)) ms",
                        value: $model.config.pads[model.config.selectedChannel].retriggerMS, in: 5...500, step: 5).frame(width: 170)
                if model.config.dynamicVelocity {
                    HStack {
                        Text("Velocity 127 at")
                        TextField("Full velocity level", value: $model.config.pads[model.config.selectedChannel].velocityCeiling, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder).frame(width: 66)
                        Text("counts").foregroundStyle(.secondary)
                    }.font(.callout)
                }
            }
        }
    }
    private var waveform: some View {
        VStack(spacing: 10) {
            WaveformView(bins: model.waveform, range: model.waveformRange, windowMS: model.displayedWindowMS,
                         threshold: model.config.mode == .midi ? Float(model.config.pads[model.config.selectedChannel].threshold / 4096) : nil)
                .frame(height: 165)
                .overlay {
                    if model.waveform.isEmpty {
                        Text(model.isActive ? "Waiting for samples…" : "Press Start to see all seven inputs.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            HStack(spacing: 16) {
                Text("Window").font(.caption).foregroundStyle(.secondary)
                Picker("Time window", selection: $model.config.windowSeconds) {
                    Text("50 ms").tag(0.05); Text("200 ms").tag(0.2); Text("1 s").tag(1.0)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 205)
                Text("\(Int(model.selectedSignal.peak * 4096)) counts peak").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Picker("View scale", selection: $model.viewScale) {
                    Text("Auto").tag(0.0); Text("1×").tag(1.0); Text("4×").tag(0.25); Text("16×").tag(0.0625)
                }.frame(width: 145)
                Toggle("Hold", isOn: $model.hold).toggleStyle(.button).disabled(model.waveform.isEmpty)
            }
        }
    }
    private var listening: some View {
        HStack(spacing: 20) {
            Toggle("Listen to selected input", isOn: $model.listenEnabled).toggleStyle(.switch)
            Text("Volume").font(.caption)
            Slider(value: $model.volume, in: 0...1).frame(width: 130).disabled(!model.listenEnabled).accessibilityLabel("Listening volume")
            Text("\(Int(model.volume * 100))%").font(.caption.monospacedDigit()).frame(width: 36)
            Text("Listen boost").font(.caption)
            Slider(value: $model.boostDB, in: 0...36, step: 1).frame(width: 130).disabled(!model.listenEnabled).accessibilityLabel("Listening boost")
            Text("+\(Int(model.boostDB)) dB").font(.caption.monospacedDigit()).frame(width: 52)
            Spacer()
        }.padding(.top, 4)
            .help("Local listening uses the selected row. These controls do not change MIDI thresholds or the USB audio inputs.")
    }
}

private struct InputRow: View {
    @ObservedObject var model: ScopeModel
    let index: Int
    var body: some View {
        let signal = model.snapshot.channels[index]
        HStack(spacing: 12) {
            if model.config.mode == .midi {
                Toggle("Input \(index + 1) MIDI enabled", isOn: $model.config.pads[index].enabled).labelsHidden().frame(width: 26)
            } else { Color.clear.frame(width: 26, height: 1) }
            Button { model.config.selectedChannel = index } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input \(index + 1)").fontWeight(model.config.selectedChannel == index ? .semibold : .regular)
                    Text("A\(index + 1) · pin \(index + 15)").font(.caption2).foregroundStyle(.secondary)
                }.frame(width: 92, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("View input \(index + 1)")
            TextField("Input \(index + 1) name", text: $model.config.pads[index].name).textFieldStyle(.plain).frame(width: 120)
            LevelMeter(db: 20 * log10(max(0.000001, Double(signal.rms))), peakDB: 20 * log10(max(0.000001, Double(signal.peak))))
                .frame(minWidth: 100, maxWidth: .infinity).frame(height: 8)
                .accessibilityLabel("Input \(index + 1) level").accessibilityValue("\(Int(signal.peak * 4096)) ADC counts peak")
            if model.config.mode == .midi {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { log2(max(1, model.config.pads[index].threshold)) }, set: { model.config.pads[index].threshold = pow(2, $0) }), in: 0...log2(4095))
                        .accessibilityLabel("Input \(index + 1) trigger threshold")
                    TextField("Threshold", value: Binding(get: { Int(model.config.pads[index].threshold) }, set: { model.config.pads[index].threshold = Double(min(4095, max(1, $0))) }), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 55).accessibilityLabel("Input \(index + 1) threshold counts")
                }.frame(width: 220)
                Stepper(value: $model.config.pads[index].note, in: 0...127) {
                    Text("\(model.config.pads[index].note)").monospacedDigit()
                }.frame(width: 85).accessibilityLabel("Input \(index + 1) MIDI note")
                Text("\(signal.hits)").font(.callout.monospacedDigit()).frame(width: 55, alignment: .trailing)
                    .foregroundStyle(ProcessInfo.processInfo.systemUptime - signal.lastHitTime < 0.15 ? ScopeColors.signal : .secondary)
                Button("Test") { model.testMIDI(index) }.frame(width: 42).disabled(!model.midiStatus.available)
                    .accessibilityLabel("Send MIDI test for input \(index + 1)")
            } else {
                Text("\(Int(signal.peak * 4096))").font(.callout.monospacedDigit()).frame(width: 100, alignment: .trailing)
            }
        }.padding(.horizontal, 10).frame(height: 39)
            .background(model.config.selectedChannel == index ? ScopeColors.signal.opacity(0.08) : .clear)
    }
}
private struct LevelMeter: View {
    let db: Double
    let peakDB: Double
    var body: some View {
        GeometryReader { geometry in
            let fraction = max(0, min(1, (db + 80) / 80))
            let peakFraction = max(0, min(1, (peakDB + 80) / 80))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(ScopeColors.signal).frame(width: max(0, geometry.size.width * fraction))
                Rectangle().fill(Color.primary.opacity(0.65)).frame(width: 2)
                    .offset(x: max(0, geometry.size.width * peakFraction - 2))
            }
        }
    }
}

private struct WaveformView: View {
    let bins: [WaveBin]
    let range: Float
    let windowMS: Double
    var threshold: Float? = nil

    var body: some View {
        Canvas { context, size in
            let area = CGRect(x: 48, y: 24, width: max(1, size.width - 64), height: max(1, size.height - 48))
            var grid = Path()
            for index in 0...4 {
                let y = area.minY + area.height * Double(index) / 4
                grid.move(to: CGPoint(x: area.minX, y: y)); grid.addLine(to: CGPoint(x: area.maxX, y: y))
                let x = area.minX + area.width * Double(index) / 4
                grid.move(to: CGPoint(x: x, y: area.minY)); grid.addLine(to: CGPoint(x: x, y: area.maxY))
            }
            context.stroke(grid, with: .color(.primary.opacity(0.08)), lineWidth: 0.5)
            var zero = Path()
            zero.move(to: CGPoint(x: area.minX, y: area.midY)); zero.addLine(to: CGPoint(x: area.maxX, y: area.midY))
            context.stroke(zero, with: .color(.primary.opacity(0.18)), lineWidth: 0.6)
            let font = Font.system(size: 10, design: .monospaced)
            func label(_ text: String, x: Double, y: Double, anchor: UnitPoint) {
                context.draw(Text(text).font(font).foregroundColor(.secondary), at: CGPoint(x: x, y: y), anchor: anchor)
            }
            label(String(format: "+%.0f", range * 4096), x: area.minX - 7, y: area.minY, anchor: .trailing)
            label("0", x: area.minX - 7, y: area.midY, anchor: .trailing)
            label(String(format: "−%.0f", range * 4096), x: area.minX - 7, y: area.maxY, anchor: .trailing)
            label(String(format: "−%.0f ms", windowMS), x: area.minX, y: size.height - 9, anchor: .leading)
            label("now", x: area.maxX, y: size.height - 9, anchor: .trailing)
            if let threshold, threshold <= range {
                for sign: Float in [-1, 1] {
                    let y = area.midY - area.height * 0.5 * Double(sign * threshold / range)
                    var line = Path(); line.move(to: CGPoint(x: area.minX, y: y)); line.addLine(to: CGPoint(x: area.maxX, y: y))
                    context.stroke(line, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
            guard !bins.isEmpty else { return }
            context.clip(to: Path(area))
            func point(_ index: Int, _ value: Float) -> CGPoint {
                CGPoint(x: area.minX + area.width * Double(index) / Double(max(1, bins.count - 1)),
                        y: area.midY - area.height * 0.5 * Double(value / range))
            }
            var band = Path()
            band.move(to: point(0, bins[0].high))
            for index in bins.indices { band.addLine(to: point(index, bins[index].high)) }
            for index in bins.indices.reversed() { band.addLine(to: point(index, bins[index].low)) }
            band.closeSubpath()
            context.fill(band, with: .color(ScopeColors.signal.opacity(0.23)))
            var trace = Path()
            for index in bins.indices {
                let p = point(index, (bins[index].low + bins[index].high) / 2)
                if index == 0 { trace.move(to: p) } else { trace.addLine(to: p) }
                trace.move(to: point(index, bins[index].low))
                trace.addLine(to: point(index, bins[index].high))
                trace.move(to: p)
            }
            context.stroke(trace, with: .color(ScopeColors.signal), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .accessibilityLabel("Input waveform")
        .accessibilityValue(bins.isEmpty ? "No samples yet" : "\(Int(windowMS)) millisecond window, vertical range plus or minus \(range, specifier: "%.3f") full scale")
    }
}
