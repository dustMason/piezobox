# Piezo box

An experimental waveform recorder for an existing Teensy LC piezo-trigger box:
one mono jack, three TRS jacks, seven piezo signals, and seven analog loading controls.

The Teensy samples its ADC and streams framed samples over **USB serial**.
Firmware v2 adds continuous seven-input streaming, packed 12-bit samples, DMA
acquisition, and live timing/drop counters. The Python receiver archives the
original ADC data; the offline decoder produces multichannel and separate mono
WAVs. The device does **not** appear as a USB audio input in a DAW.

Start with the known cable-tip connection to **pin 21 / A7**. The complete seven-input
mapping still needs hardware validation. Pins 15–21 are the provisional seven-input
set used for throughput tests.

## Continuous seven-input capture

Stop Piezo Scope first so only one program owns the serial port. With firmware v2
installed and the Python environment below prepared:

```sh
.venv/bin/python streaming.py --port /dev/cu.usbmodem12776501 \
  --pins 15,16,17,18,19,20,21 --rate 32000 --profile fast \
  --out captures/seven-inputs
```

This requests 32,000 samples/second **on each input** (224,000 total readings/s).
It runs until Ctrl-C, which sends `STOP`, drains pending data, and saves final
counters. Use `--seconds 60` for a timed host stop. The stream has no 600-second
limit; `--finite` is available for exact-frame-count benchmarks. Output names
must be new. The serial port name may change; use `capture.py ports` to find it.

The raw `.pzlc` preserves all 12 ADC bits. Decode after recording, using a new
output prefix:

```sh
.venv/bin/python capture.py decode captures/seven-inputs.pzlc \
  --out captures/seven-inputs-audio
```

The JSON report must have `timing_checks_passed: true` before treating a run as
loss-free. The firmware reports missing frames, late intervals and overruns.
At 32 kHz, seven packed inputs use about 368 kB/s including packet headers,
before USB transaction overhead.

For more analog settling time, use `--rate 12000 --profile settled`. This
discards a conversion after each channel switch and uses a longer sample
window. Neither profile repairs the existing circuit's clipped waveform or
establishes analog accuracy through its high-impedance inputs.

See [the wire protocol](docs/protocol-v2.md) for ADC profiles, counters, timing,
continuous capture semantics, and remaining physical limitations.
Hardware test details and rate limits are recorded in the
[v2 throughput report](validation/2026-10-09-v2-throughput.txt).

## Uploading with the enclosure closed

USB-only uploads work with the running USB Serial firmware. Stop any capture
client, select the Teensy LC and its USB port, then Upload from the Teensyduino
toolchain. It requests a software reboot into Teensy Loader. This path was used
successfully for the v2 updates without touching the physical Program button.
The button remains a recovery fallback if firmware stops servicing USB.

## Native Mac viewer

**Piezo Scope** is a small Swift app for hearing and seeing one input at a time.
It discovers the Teensy, shows a live waveform and level meter, and plays through
the Mac's current sound output using AVAudioEngine. It uses the existing firmware
and does not need Python. See the [Mac app guide](macOS/README.md).

```sh
./macOS/build-app.sh
open "build/Piezo Scope.app"
```

Select an input and press Start. Stop before changing inputs. Listen can be
muted independently of the waveform; Hold freezes only the view. Volume and
Boost affect listening, while View scale changes only the waveform display.
DAW/virtual-device integration is future work.

## Files

- [`piezo_lc_capture/piezo_lc_capture.ino`](piezo_lc_capture/piezo_lc_capture.ino): capture firmware, Teensy LC only.
- [`capture.py`](capture.py): serial recorder, pin-mapping mode, and offline decoder.
- [`streaming.py`](streaming.py): continuous PZLC2 raw receiver with live diagnostics.
- [`docs/protocol-v2.md`](docs/protocol-v2.md): ADC profiles and binary protocol.
- [`macOS/`](macOS/): native SwiftUI waveform viewer and AVAudioEngine monitor.
- [`README.txt`](README.txt): full setup, recording, mapping, and troubleshooting guide.
- [`BUILD-VALIDATION.txt`](BUILD-VALIDATION.txt): compiler results, checksums, test coverage, and untested hardware behavior.
- [`piezo_lc_capture.teensy-lc.hex`](piezo_lc_capture.teensy-lc.hex): initial compiled LC firmware snapshot.
- [`firmware/piezo-lc-v2.hex`](firmware/piezo-lc-v2.hex): current optimized LC firmware, with its [build manifest](validation/2026-10-09-v2-build.json).

## First recording

Read the hardware limits below and the [setup guide](README.txt) before connecting
piezo signals. Uploading the sketch replaces the old firmware; that firmware has
not been recovered or backed up.

Select **Teensy LC**, **USB Type: Serial**, and **CPU: 48 MHz** in Arduino IDE.
After uploading, close Serial Monitor and use:

```sh
cd ~/code/piezo-box
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python capture.py ports
```

Replace `PORT` with the Teensy's listed serial device:

```sh
.venv/bin/python capture.py record --port PORT --pins 21 --rate 16000 --seconds 5 --out captures/a7-first
```

The receiver does not upload firmware. It supports multiple selected inputs and
separate channel files; adding channels may require a lower sampling rate. The
guide includes software mapping and optional live-listening commands.

## Verification

```sh
python3 -B -m unittest -v test_capture.py test_streaming.py
```

To compile with Arduino CLI after installing the Teensy boards package, without
launching Teensy Loader or uploading:

```sh
arduino-cli compile \
  --fqbn teensy:avr:teensyLC:usb=serial,speed=48,opt=o3std \
  --build-property 'build.flags.optimize=-O3 --specs=nano.specs' \
  --build-property 'recipe.hooks.postbuild.1.pattern=' \
  --build-path build/teensy-lc \
  piezo_lc_capture
```

The firmware compiles with Teensy boards package 1.62.0. The optimized build uses
`-O3` and newlib-nano to leave RAM for the stack and USB handling. Host codec tests
cover both protocol versions. The original physical check on 2026-10-09,
a five-second A7 capture at 16 kHz, received all 80,000 frames with zero dropped
frames, slow callbacks, or late intervals. See the [hardware result](validation/2026-10-09-a7-flash-check.json).
This verifies ADC/USB transport for that run, not piezo audio quality, analog
protection, live monitoring, or multichannel performance.

## Hardware limits

The traced inputs are ground-referenced trigger circuits with adjustable loading
and diode clamping. They can clip the piezo waveform. Positive-voltage protection,
midpoint bias, input buffering, and anti-alias filtering have not been established.
Verify that conditioned inputs stay within the LC's permitted voltage range before
exciting connected piezos. Digital DC removal cannot recover a clipped waveform.
See the full guide for the measured wiring and remaining uncertainties.
