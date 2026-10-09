# Piezo box

A restored Teensy LC piezo box that now appears directly as **USB audio inputs**.
The hardware has one mono jack, three TRS jacks, seven piezo signals, and seven
analog loading controls.

| macOS input | Channels | Format |
|---|---:|---|
| **Piezo Box LC 7 Inputs** | 7 separate inputs | 32 kHz, 16-bit PCM |
| **Piezo Box LC Mono** | Mean of all seven inputs | 32 kHz, 16-bit PCM |

Both inputs work simultaneously, without Piezo Scope, Python, or a custom Mac
audio driver. The samples come from the LC's 12-bit ADC. Firmware removes DC
with an approximately 20 Hz high-pass filter; it cannot restore the negative
waveform clipped by the existing trigger circuitry.

Choose either input in recording software. Use a 32 kHz project/device rate or
the application's supported sample-rate conversion. Other operating systems
and individual DAWs have not all been qualified.

## Piezo Scope

The native Swift app reads all seven inputs through CoreAudio, displays their
levels and a selected waveform, and can play the selected input locally.
In **MIDI mode**, each input has an adjustable threshold, MIDI note, enable
control, retrigger delay, and hit-strength sensitivity. Velocity can follow hit
strength or use a fixed value. Other apps receive the virtual **Piezo Box Drums**
MIDI source while Piezo Scope runs.

```sh
./macOS/build-app.sh
```

Open `build/Piezo Scope.app`, allow macOS audio-input/microphone permission when
requested, and press Start. See [the app guide](macOS/README.md). The app's
listening controls do not change the USB audio other programs receive. Audio
mode explains direct routing; no desktop audio-forwarding driver is involved.

## Firmware

The current source is [`piezo_lc_audio/`](piezo_lc_audio/), with USB core additions
in [`usb_audio/`](usb_audio/). The build helper creates an isolated copy of the
Teensy 1.62.0 core; it does not modify the installed core or upload automatically.
See [USB Audio build, protocol, and verification details](docs/usb-audio.md).

The deployed binary is [`firmware/piezo-lc-usb-audio.hex`](firmware/piezo-lc-usb-audio.hex),
for **Teensy LC only**. [Its manifest](validation/2026-10-09-usb-audio-build.json)
records build flags, memory use, and source/binary hashes. CPU remains 48 MHz.
The serial interface is retained for diagnostics and USB-only programming.

The firmware uses pins 15–21 / A1–A7. Pin 21/A7 was traced to a cable tip, and
pin 20/A6 to the dotted pot's signal connection. The complete physical
jack/piezo map remains unverified; the app's drum names are editable defaults.

## Validation

```sh
python3 -B -m unittest -v test_capture.py test_streaming.py test_usb_audio.py
swift test --package-path macOS
```

Physical CoreAudio recording succeeded for mono and all seven channels. In a
120-second simultaneous transport test, each input checked 3,834,368 frames
with zero sample/sequence errors and zero device ADC faults, late ticks,
underruns, or overruns. The timeout-free release passed a further 30-second
seven-channel pattern check. These are bounded transport tests, not proof of
analog fidelity or indefinite reliability. See [the USB Audio guide](docs/usb-audio.md)
and `validation/2026-10-09-usb-audio-*.json`.

## Earlier serial experiment

The former raw-ADC workflow is retained for reference and rollback:

- `piezo_lc_capture/` and `firmware/piezo-lc-v2.hex`: continuous packed PZLC2
  streaming over USB serial, verified at seven × 32 kHz.
- `streaming.py`: raw PZLC2 receiver; `capture.py`: legacy recorder and offline
  PZLC1/PZLC2-to-WAV decoder.
- [PZLC2 protocol](docs/protocol-v2.md) and [serial throughput report](validation/2026-10-09-v2-throughput.txt).
- Root `piezo_lc_capture.teensy-lc.hex`: intentionally preserved first prototype.
- `README.txt` and `BUILD-VALIDATION.txt`: historical setup and validation.

Those serial recording commands require the older firmware. The current USB
Audio firmware supplies standard audio and a small diagnostic command set.

## Hardware limits

The traced inputs are ground-referenced trigger circuits with adjustable
loading and diode clamping. Positive-voltage protection, midpoint bias,
buffering, and anti-alias filtering have not been established. ADC clock speed
and digital transport tests do not establish safe peak input voltage, channel
isolation, or accurate settling through the high-impedance piezo/pot network.
