# Piezo box

An experimental waveform recorder for an existing Teensy LC piezo-trigger box:
one mono jack, three TRS jacks, seven piezo signals, and seven analog loading controls.

The Teensy samples its ADC and streams framed samples over **USB serial**. The
Python receiver saves a multichannel WAV, separate mono WAVs for selected inputs,
the original ADC data, and a timing report. Optional live monitoring plays a mono
mix through the computer. The device does **not** appear as a USB audio input in a DAW.

Start with the known cable-tip connection to **pin 21 / A7**. The complete seven-input
mapping and sustainable multichannel sample rate still need hardware validation.

## Files

- [`piezo_lc_capture/piezo_lc_capture.ino`](piezo_lc_capture/piezo_lc_capture.ino): capture firmware, Teensy LC only.
- [`capture.py`](capture.py): serial recorder, pin-mapping mode, and offline decoder.
- [`README.txt`](README.txt): full setup, recording, mapping, and troubleshooting guide.
- [`BUILD-VALIDATION.txt`](BUILD-VALIDATION.txt): compiler results, checksums, test coverage, and untested hardware behavior.
- [`piezo_lc_capture.teensy-lc.hex`](piezo_lc_capture.teensy-lc.hex): initial compiled LC firmware snapshot.

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
python3 -B -m unittest -v test_capture.py
```

To compile with Arduino CLI after installing the Teensy boards package, without
launching Teensy Loader or uploading:

```sh
arduino-cli compile \
  --fqbn teensy:avr:teensyLC:usb=serial,speed=48,opt=osstd \
  --build-property 'recipe.hooks.postbuild.1.pattern=' \
  --build-path build/teensy-lc \
  piezo_lc_capture
```

The firmware compiles with Teensy boards package 1.62.0. Host tests and a
simulated serial capture pass. On 2026-10-09 it was flashed to the physical LC;
a five-second A7 capture at 16 kHz received all 80,000 frames with zero dropped
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
