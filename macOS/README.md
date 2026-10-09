# Piezo Scope

A native macOS app for the **Piezo Box LC 7 Inputs** USB audio device. It captures
all seven channels at 32 kHz using CoreAudio. No Python receiver or Mac audio
driver installation is needed. macOS may request microphone permission for
reading the USB audio input.

## Use

1. Connect the Teensy running the current `piezo_lc_audio` firmware.
2. Open `build/Piezo Scope.app` and press Start.
3. Select a row to inspect its waveform. Listen plays that selected input on
   the Mac's sound output. Listening volume/boost are local monitoring controls.
4. For recording, select **Piezo Box LC Mono** or **Piezo Box LC 7 Inputs** in
   the recording app. Both hardware inputs remain available when Piezo Scope is
   stopped or closed.

The waveform and trigger thresholds use equivalent ADC-count units after the
firmware's DC filter. The audio stream has already been centered; the app does
not apply a second DC filter. Input names and settings persist across launches.
The default drum names are assignments you can edit, not a verified jack map.

## MIDI mode

Select MIDI, enable the pads you want, and choose **Piezo Box Drums** as a MIDI
input in your instrument or DAW. Defaults use channel 10 and common drum notes.
Each row has a threshold and note number; the selected input also exposes its
retrigger delay and, for hit-strength velocity, the level that maps to velocity
127. A three-millisecond peak search measures strength, and hysteresis plus
retrigger holdoff suppress repeated notes from ringing. Tune thresholds above
the idle hum and adjust using real strikes. Fixed velocity is selectable and
adjustable from 1 to 127. Test sends a MIDI note without a physical strike.

Notes receive an 80 ms note-off. Stop, mode changes, errors, and shutdown release
active notes. MIDI mode still uses the same standard USB audio input; it does
not change the firmware or prevent another app from recording the box.

## Implementation

`CoreAudioInput.swift` opens only the named seven-input Piezo USB device.
`PiezoAudioBridge/Capture.c` copies input PCM into a bounded single-producer,
single-consumer ring without Swift allocation or UI work in the audio callback.
A worker drains that ring, runs triggering, and publishes waveform snapshots.
It requests a 128-frame device buffer for drum latency when supported. The
footer counts observed CoreAudio/app buffering gaps; it is not a USB CRC monitor.
Firmware diagnostics and the dedicated digital-pattern tests provide separate
USB transport evidence.

`AudioMonitor` uses AVAudioEngine for local playback. `MIDIOutput` exposes a
CoreMIDI virtual source with a stable unique ID. `PiezoCore` contains deterministic
triggering, waveform history, and the retained serial-protocol decoder tests.

## Build and test

From the repository root, on macOS 14+ with Swift 6+ (Xcode 16+ or compatible
Command Line Tools):

```sh
swift test --package-path macOS
./macOS/build-app.sh
open "build/Piezo Scope.app"
```

The app uses only Apple frameworks and builds for the current Mac's architecture.
The locally signed bundle is written to `build/Piezo Scope.app`; no Apple
developer account is required. Open this bundle so microphone permission uses
its identity and usage description. If access was denied, enable Piezo Scope
in System Settings → Privacy & Security → Microphone and start capture again.

`macOS/tools/check-midi.swift` is a separate CoreMIDI receiver for integration
checks. The root `tools/usb_audio_probe.c`, `tools/list_audio.swift`, and
`tools/native_capture_probe.c` inspect the hardware/audio path without changing
the system's default input or output device.
