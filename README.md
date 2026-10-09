# Piezo Box

Turn seven piezo pickups connected to a **Teensy LC** into USB audio and MIDI
drum triggers. The firmware samples A1–A7 (pins 15–21) at **32 kHz** and exposes
two standard USB audio inputs: **Piezo Box LC 7 Inputs** and **Piezo Box LC Mono**
(the average of all seven). Both carry 16-bit PCM from the LC's 12-bit ADC.

The native Mac app, **Piezo Scope**, shows input levels and a selected waveform,
plays the selected input, and generates drum MIDI with per-input thresholds,
notes, and fixed or hit-strength velocity. USB audio works even with the app
closed; MIDI requires the app to be running. No custom audio driver is needed.

## Build and run on a Mac

Requires **macOS 14+** and **Xcode 16+ or Command Line Tools with Swift 6+**.
Install Apple's developer tools with `xcode-select --install` if needed, then
check `swift --version`. The app has no third-party package dependencies.

From the repository root:

```sh
./macOS/build-app.sh
open "build/Piezo Scope.app"
```

1. Connect the box using a USB **data** cable. It must be running the firmware below.
2. Press **Start** and allow microphone access when macOS asks. Select an input
   to view its waveform; enable **Listen** to hear it.
3. For MIDI, select **MIDI** mode, set thresholds above the idle signal, and choose
   **Piezo Box Drums** as your DAW's MIDI input (channel 10 by default).
4. For audio recording, choose either **Piezo Box LC** input in your DAW. Use
   32 kHz or the DAW's sample-rate conversion. Listening volume affects only monitoring.

Build on each Mac for its native architecture. The script locally signs the app;
no Apple developer account is required. [More app details](macOS/README.md).

## Teensy firmware

- **Source:** [`piezo_lc_audio/piezo_lc_audio.ino`](piezo_lc_audio/piezo_lc_audio.ino)
  and the USB core additions in [`usb_audio/`](usb_audio/), for **Teensy LC only**.
- **Build and flash:** [firmware setup guide](docs/usb-audio.md), including pinned
  Teensy 1.62.0 toolchain setup and USB-only updates. A plain Arduino sketch build
  is insufficient: the helper applies the required USB core changes.
- **Build output:** `build/usb-audio/build/piezo_lc_audio.ino.hex`.
  Compiled firmware is generated locally and excluded from Git.

The existing box clips negative piezo signals; firmware removes DC but cannot
recover that lost audio. The complete physical jack-to-channel map is still
unverified. Mono and seven-channel transport passed a simultaneous two-minute
Mac test with zero sample/sequence errors; [details](docs/usb-audio.md#verification-evidence).

## Development

```sh
swift test --package-path macOS
python3 -B -m unittest -v test_capture.py test_streaming.py test_usb_audio.py
```

Python 3.9+ is needed only for firmware build tools and host tests. App code lives
in `macOS/Sources/`. Older serial firmware source and capture tools
are retained; see the [legacy guide](docs/legacy-serial.txt) and
[build history](validation/build-history.txt).
