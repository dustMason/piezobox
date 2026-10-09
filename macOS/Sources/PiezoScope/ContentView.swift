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
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Input waveform").font(.headline)
                    Text("A\(model.selectedPin - 14) · pin \(model.selectedPin)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if model.hold {
                        Label("View held", systemImage: "pause.fill").font(.caption).foregroundStyle(.secondary)
                    } else if !model.isActive && !model.waveform.isEmpty {
                        Text("Last capture").font(.caption).foregroundStyle(.secondary)
                    }
                }

                WaveformView(bins: model.waveform, range: model.waveformRange, windowMS: model.displayedWindowMS)
                    .overlay {
                        if model.waveform.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "waveform").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                                Text(model.devices.isEmpty ? "Connect your Teensy" : "Ready for your piezo")
                                    .font(.title3.weight(.medium))
                                Text(model.phase == .connecting ? model.message : "Select an input and press Start to see its waveform.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            .padding(20)
                            .background(.background.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .frame(minHeight: 220, maxHeight: .infinity)

                HStack(spacing: 18) {
                    Text("Window").font(.caption).foregroundStyle(.secondary)
                    Picker("Time window", selection: $model.timeWindow) {
                        Text("50 ms").tag(0.05)
                        Text("200 ms").tag(0.2)
                        Text("1 s").tag(1.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                    Spacer(minLength: 12)
                    Picker("View scale", selection: $model.viewScale) {
                        Text("Auto").tag(0.0)
                        Text("1×").tag(1.0)
                        Text("4×").tag(0.25)
                        Text("16×").tag(0.0625)
                    }
                    .frame(width: 145)
                    .help("Changes the waveform’s visual scale only. It does not change the sound.")
                    Toggle(isOn: $model.hold) { Label("Hold", systemImage: "pause") }
                        .toggleStyle(.button).disabled(model.waveform.isEmpty)
                        .help("Hold the waveform for inspection while capture and listening continue.")
                }

                HStack(spacing: 14) {
                    Text("Input level").font(.callout)
                    LevelMeter(db: model.rmsDB, peakDB: model.peakDB)
                        .frame(height: 8)
                        .accessibilityLabel("Input RMS level")
                        .accessibilityValue("\(model.rmsDB, specifier: "%.1f") decibels full scale")
                    Text(String(format: "Peak %.1f dBFS", model.peakDB))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 138, alignment: .trailing)
                }
            }
            .padding(24)

            Divider()
            listeningBar
            if let error = model.error ?? model.audioStatus.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 14)
            } else if model.audioStatus.clippedSamples > 0 || model.snapshot.fullScaleSamples > 0 {
                Label(model.snapshot.fullScaleSamples > 0
                      ? "The input reached the ADC ceiling. Check the physical input level."
                      : "Listening boost clipped the output. Reduce Boost for a cleaner signal.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var connectionBar: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Device").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Picker("Device", selection: $model.selectedPort) {
                        if model.devices.isEmpty { Text("No Teensy connected").tag("") }
                        ForEach(model.devices) { device in Text(device.title).tag(device.path) }
                    }
                    .labelsHidden().frame(minWidth: 180, maxWidth: .infinity)
                    .disabled(model.isActive || model.devices.isEmpty)
                    Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh connected Teensy devices").accessibilityLabel("Refresh devices")
                        .disabled(model.isActive)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Input").font(.caption).foregroundStyle(.secondary)
                Picker("Input", selection: $model.selectedPin) {
                    ForEach(14...26, id: \.self) { pin in
                        Text("A\(pin - 14) · pin \(pin)\(pin == 21 ? " · mapped" : "")").tag(pin)
                    }
                }
                .labelsHidden().frame(width: 155).disabled(model.isActive)
                .help("A7 is the mapped input. Other jack assignments still need checking. Stop capture before changing inputs.")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Sample rate").font(.caption).foregroundStyle(.secondary)
                Picker("Sample rate", selection: $model.sampleRate) {
                    Text("16 kHz").tag(16_000)
                    Text("8 kHz").tag(8_000)
                }
                .labelsHidden().frame(width: 90).disabled(model.isActive)
            }
            Button(action: model.toggleCapture) {
                Label(model.isActive ? "Stop" : "Start", systemImage: model.isActive ? "stop.fill" : "play.fill")
                    .frame(width: 76)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled((!model.isActive && !model.canStart) || model.phase == .stopping)
            .keyboardShortcut(.return, modifiers: [])
            .help("Start or stop receiving this input. Return is the keyboard shortcut.")
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var listeningBar: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Listen", isOn: $model.listenEnabled).toggleStyle(.switch)
                    .help("Play through the Mac’s current sound output. The waveform keeps updating when listening is off.")
                Text("System sound output").font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 40)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Text("\(Int(model.volume * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }.font(.callout)
                Slider(value: $model.volume, in: 0...1) { Text("Listening volume") }
                    .labelsHidden().disabled(!model.listenEnabled)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Boost")
                    Spacer()
                    Text("+\(Int(model.boostDB)) dB").monospacedDigit().foregroundStyle(.secondary)
                }.font(.callout)
                Slider(value: $model.boostDB, in: 0...36, step: 1) { Text("Listening boost") }
                    .labelsHidden().disabled(!model.listenEnabled)
                    .help("Amplifies quiet audio for listening. It does not change the ADC or the input waveform display.")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            Circle().fill(model.phase == .live ? ScopeColors.signal : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(model.statusText).fontWeight(.medium)
            Text(model.message).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 12)
            if model.snapshot.received > 0 {
                Text("\(model.snapshot.received.formatted()) samples").monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
                Text("\(model.snapshot.missing) dropped")
                    .foregroundStyle(model.snapshot.missing > 0 ? Color.orange : Color.secondary)
                    .monospacedDigit()
            }
            if model.snapshot.timingIssues > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("The last capture reported timing overruns. Try 8 kHz.")
            }
        }
        .font(.caption).padding(.horizontal, 24).padding(.vertical, 11)
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
            label(String(format: "+%.3f", range), x: area.minX - 7, y: area.minY, anchor: .trailing)
            label("0", x: area.minX - 7, y: area.midY, anchor: .trailing)
            label(String(format: "−%.3f", range), x: area.minX - 7, y: area.maxY, anchor: .trailing)
            label(String(format: "−%.0f ms", windowMS), x: area.minX, y: size.height - 9, anchor: .leading)
            label("now", x: area.maxX, y: size.height - 9, anchor: .trailing)
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
