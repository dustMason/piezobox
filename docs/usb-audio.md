# Teensy LC USB audio

The current `piezo_lc_audio` firmware is a capture-only USB Audio Class 1 device
at **32,000 samples/second per channel**, with two independent inputs:

- **Piezo Box LC 7 Inputs**: A1–A7 / pins 15–21, in that order.
- **Piezo Box LC Mono**: arithmetic mean of those seven channels.

Both can be open concurrently, and neither needs Piezo Scope or a custom Mac
audio driver. A serial interface remains for diagnostics and USB programming.
The complete jack-to-pin map remains provisional; pin 21/A7 was traced by
continuity. Software channel ordering is verified separately from that wiring.

## Audio and timing

The USB format is signed little-endian 16-bit PCM, sourced from the LC's 12-bit
ADC. The firmware removes DC with a fixed-point, approximately 20 Hz high-pass
filter. One ADC count corresponds to about eight PCM units. This does not add
ADC resolution or reconstruct the negative waveform clipped by the old trigger
circuit. Analog settling, input protection, crosstalk, and anti-aliasing remain
unqualified. The ADC multiplexes the seven inputs; they are not simultaneous.

A 32 kHz timer starts a linked-DMA ADC scan. The next tick publishes the finished
scan to a 128-frame PCM ring. Each USB input has its own reader, so mono and
seven-channel clients do not consume each other's samples. USB uses asynchronous
isochronous IN endpoints with mostly 32 frames per 1 ms packet, occasionally 31
or 33 to follow the ADC clock. Maximum packet sizes are 462 and 66 bytes.

At stream startup, firmware waits for a small reserve and aligns to recent data.
Startup silence/discards are counted separately from underruns or overruns
while streaming. Gaps during normal operation are not hidden by pretending the
sampling rate changed. The host may add its own buffers and format conversion.

32 kHz is the only advertised device sample rate. Set the recording software to
32 kHz, or use its supported sample-rate conversion. Compatibility has been
checked through macOS CoreAudio, not every DAW or other operating system.

## Build

Requires Python 3.9+ and [Arduino CLI](https://arduino.github.io/arduino-cli/latest/installation/)
on your PATH (`brew install arduino-cli` if you use Homebrew). These instructions
are for macOS and run from the repository root; other build hosts are untested.
The Mac app does not need this toolchain.

Install the pinned [PJRC Teensy boards package](https://www.pjrc.com/teensy/td_download.html)
into a repository-local, ignored directory. Run this setup once per clone:

```sh
mkdir -p .arduino
cat > .arduino/arduino-cli.yaml <<EOF
board_manager:
  additional_urls:
    - https://www.pjrc.com/teensy/package_teensy_index.json
directories:
  data: "$PWD/.arduino/data"
  downloads: "$PWD/.arduino/downloads"
  user: "$PWD/.arduino/user"
EOF
arduino-cli --config-file .arduino/arduino-cli.yaml core update-index
arduino-cli --config-file .arduino/arduino-cli.yaml core install teensy:avr@1.62.0
```

Then build:

```sh
python3 tools/build_usb_audio.py \
  --arduino-cli "$(command -v arduino-cli)" \
  --data-dir .arduino/data \
  --channels 7 --mono-companion
```

The default output is `build/usb-audio/build/piezo_lc_audio.ino.hex`. The build
copies the stock Teensy core into an isolated directory, applies guarded source
patches, and reuses the installed compiler tools. It neither edits the installed
core nor uploads. It disables `recipe.hooks.postbuild.1.pattern` so compilation
does not launch Teensy Loader. Build flags are LC / 48 MHz / `-O3 --specs=nano.specs`.
The generated `core.patch` and `core-provenance.json` record the core changes.
A plain compile against the unmodified core is not this firmware build.

Compiled HEX files are local build outputs and are not tracked in Git.
`validation/2026-10-09-usb-audio-build.json` records source and binary hashes from
the verified hardware release. Historical reports refer to the binary's former
repository path, `firmware/piezo-lc-usb-audio.hex`; build it from source using the
command above. Older serial firmware source remains in `piezo_lc_capture/`.

Development options:

- `--channels 1`: mono-only USB prototype, still sampling all seven ADC inputs.
- `--prototype`: return to the Teensy bootloader after 90 seconds unless the host
  sends `CONFIRM`. This is best-effort recovery while the sketch runs, not a
  guarantee against a hung USB interrupt or other firmware failure.
- `--prepare-only`: generate the patched core and descriptors without compiling.

## Upload and recovery

Build the firmware above first. For a first flash, download
[Teensy Loader](https://www.pjrc.com/teensy/loader_mac.html), open
`build/usb-audio/build/piezo_lc_audio.ino.hex`, connect the LC, and press its
Program button. Use Loader's Program and Reboot buttons, or enable Auto mode
before pressing Program.

For updates to a box already running this firmware, the retained CDC interface
supports the stock Teensy software-reboot request. After the firmware build
above, stop audio/serial clients and run:

```sh
.arduino/data/packages/teensy/tools/teensy-tools/1.62.0/teensy_post_compile \
  -file=piezo_lc_audio.ino \
  -path="$PWD/build/usb-audio/build" \
  -tools="$PWD/.arduino/data/packages/teensy/tools/teensy-tools/1.62.0" \
  -board=TEENSYLC -reboot
```

Connect only the target Teensy for this command. USB-only reprogramming was
exercised across mono, seven-channel, dual-input, and permanent builds.

The physical Program button remains the recovery path if firmware ceases to
service USB. The release has no automatic 90-second reboot and needs no host
confirmation. Disconnecting and reconnecting it does not need a serial client.

## Serial diagnostics

Open the Teensy's serial port and send newline-terminated commands:

| Command | Result |
|---|---|
| `INFO` | Identifies the `PZUA1` USB Audio firmware |
| `STATUS` | JSON with ADC timing, raw instantaneous readings, and per-stream packet/loss counters |
| `CONFIRM` | Disarms the prototype timeout for this boot; unnecessary on release firmware |
| `REBOOT` | Enters the Teensy programming bootloader |
| `TEST_ON` / `TEST_OFF` | Enable/disable a low-level digital PCM test pattern |

The test pattern replaces microphone samples on USB only; ADC sampling keeps
running. It is off at boot. Always restore `TEST_OFF` after verification.
`tools/qualify_usb_audio.py` does so in a `finally` block. Do not interpret test
pattern captures as physical piezo recordings.

Python serial helpers need `pyserial`; install them separately from the Mac app:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m serial.tools.list_ports -v
.venv/bin/python tools/confirm_usb_audio.py --serial YOUR_TEENSY_USB_SERIAL
```

Use the USB serial number reported by `list_ports`. The confirmation helper
also prints firmware status; it targets only the specified Teensy.

Counters are 32-bit and wrap; use unsigned differences for long-run diagnostics.
The PCM stream itself does not depend on a finite frame count. No claim of
indefinite reliability follows from the bounded test runs.

## Verification evidence

- Real mono and seven-channel ADC audio were read through the Mac's built-in USB
  audio driver.
- A 30-second seven-channel pattern run checked 954,368 frames after warm-up,
  with zero sample or sequence errors.
- Simultaneous mono and seven-channel captures ran for 120 seconds. Each checked
  3,834,368 frames, with zero sample/sequence errors, device underruns/overruns,
  ADC faults, or late sample ticks.
- The permanent, timeout-free build passed another 30-second seven-channel run.
- Descriptor tests check interface grouping, alternate settings, channel counts,
  fixed rate, packet sizes, and preservation of the CDC endpoints.

See the `validation/2026-10-09-usb-audio-*.json` reports. The receiver deliberately
skips its first eleven callbacks to exclude initialization buffers from pattern
comparison; device counters report startup separately.

## Primary references

- [USB Audio Class 1 specification](https://www.usb.org/sites/default/files/audio10.pdf)
- [USB 2.0 specification](https://www.pjrc.com/tmp/usb20.pdf)
- [KL26 reference manual](https://www.pjrc.com/teensy/KL26P121M48SF4RM.pdf)
- [PJRC Teensy core](https://github.com/PaulStoffregen/cores/tree/master/teensy3)
