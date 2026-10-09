# Piezo Scope

A native SwiftUI Mac app that receives the existing LC's PZLC1 serial stream,
shows its waveform, and plays one selected input through AVAudioEngine.
No Python, firmware change, microphone access, or App Store setup is required.

## Build and launch

Requires macOS 14 or later and Xcode with Swift 6 or newer to build. The script
builds for the host architecture and applies a local ad-hoc signature.

```sh
cd ~/code/piezo-box
./macOS/build-app.sh
open "build/Piezo Scope.app"
```

The current bundle was built for Apple Silicon. Open `macOS/Package.swift` in
Xcode to work on the source there instead. Build products are ignored by Git.

## Try it

1. Connect the Teensy running the capture sketch. Close Python recording or
   Arduino Serial Monitor so the app can exclusively own its serial port.
2. Choose the device and input. A7 / pin 21 is the mapped starting input.
3. Press **Start**. The waveform and level meter show received ADC data with DC
   removed. The app initially listens at 20% volume with +12 dB boost.
4. **Listen** mutes playback without stopping the incoming waveform.
5. **Hold** freezes the view while reception and listening continue.
6. Stop before changing input or sample rate. The physical box's knob controls
   analog loading; the app's Boost and Volume controls only affect playback.

Time Window and View Scale only change the display. Auto scale can magnify
small signals; the vertical axis states the displayed full-scale range.
The meter shows the input before listening boost/volume. A clipping message
reports that clipping occurred during the current capture; lowering boost does
not erase that historical count. Start a new capture to reset the counters.

Playback follows the Mac's default sound output. The app detects output-engine
configuration changes and rebuilds playback if needed. If output is unavailable,
the waveform continues; select a working output in macOS and toggle Listen.

The device's finite capture command allows up to ten minutes. The app starts
another capture when that completes; the boundary can introduce a short gap.
This is a live viewer/listener, not a gapless recorder or a DAW input device.
Use the existing Python recorder for WAV files. Core Audio virtual-device or
audio-plugin integration remains future work.

## Implementation boundaries

- `PiezoCore`: incremental framed-protocol decoder, DC blocker, and bounded
  waveform history with transient-preserving min/max downsampling.
- `SerialTransport`: IOKit device discovery, exclusive POSIX serial access,
  firmware handshake, capture lifecycle, cancellation, and disconnect handling.
- `CaptureSession`: raw-input processing, gap accounting, waveform snapshots,
  and delivery to the playback sink.
- `AudioMonitor`: mono AVAudioEngine/AVAudioPlayerNode playback. It groups small
  packets into buffers, keeps the queue bounded, and reports render/clipping data.
- `ScopeModel` / `ContentView`: native controls and a data-driven SwiftUI Canvas.

The transport and audio sink are separate so future audio routing does not need
to be coupled to the view or the serial parser. This implementation does not
install a Core Audio driver or expose a virtual microphone to other apps.

## Checks and limits

```sh
swift test --package-path macOS
```

Nine core tests pass: byte-by-byte fragmented streams, channel ordering, gap
counters, malformed packets/headers, duplicate sequences, truncated packets,
DC behavior, bounded history, and preservation of short waveform transients.
The release app builds and its local code signature verifies successfully.

On 2026-10-09 the running app discovered the physical LC, received live samples,
rendered a waveform, and scheduled/rendered audio through AVAudioEngine. The
live verification snapshot is in `validation/2026-10-09-native-live-check.json`
at the repository root. It records zero transport gaps at that point, plus
playback rebuffer and clipping counters; it does not claim uninterrupted or
undistorted physical sound. End-of-session timing counters are not available
until the LC sends its final statistics.

Analog input protection, waveform fidelity, the remaining jack mapping, actual
speaker/headphone audibility, output-route changes, unplug recovery, and the
ten-minute restart boundary have not all been physically exercised. The app
does not change the input circuit or restore clipped negative waveforms.

For local debugging, launching with `--diagnostics /absolute/path/report.json`
writes a small live status report about twice per second. This is off by default
and contains counters/settings, not the waveform. The serial device is never
opened merely for discovery, and only a selected Teensy is opened for capture.
