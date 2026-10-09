PIEZO BOX — TEENSY LC USB-SERIAL WAVEFORM EXPERIMENT

WHAT THIS DOES

The .ino captures continuously sampled ADC waveforms. It does not detect hits
or generate MIDI. A computer-side Python program receives the samples and
creates a PCM WAV file. For multiple selected inputs it also creates a separate
mono WAV per input, keeping their frame indices aligned. Channels are sampled
sequentially on the LC's shared ADC, not simultaneously.

This is USB SERIAL, not a class-compliant USB Audio device. The box will not
appear as a microphone/input device in a DAW. Import its WAVs into a DAW, or use
the optional computer-side live monitor. A future supported Teensy/USB-audio
implementation is a separate step.

KNOWN HARDWARE AND UNCERTAINTIES

The panel has one mono jack and three TRS jacks: seven piezo signal connections,
with seven corresponding pots. Traced pots appear to be roughly 100 kohm
variable shunts to ground, rather than seven separate ADC controls.

The tested cable tip has a reported approximately 1-ohm connection to pin 21
(A7). That is the ONLY default recording input. Pin 20/A6 was traced to dotted
pot A and a diode with its band toward the input and its other end grounded.
The complete jack/ring/pot-to-pin mapping is not established. Do not assume
pins 15..21 are the seven inputs just because they are a plausible group.

The original hardware was built for triggering. Its ground-referenced input
does not preserve negative-going audio in a unipolar ADC. The diode's type and
positive-clamp voltage are unknown. A successful recording does not establish
safe input voltages. Before exciting connected piezos, establish that their
conditioned signals stay within the LC's 0..3.3 V input range. The presence of
the diode or an old working MIDI sketch does not prove that. A scope or known
conditioning circuit is needed to validate fast transient peaks; a multimeter
cannot establish their maximum.

No input buffer, midpoint bias, or anti-alias filter has been verified. Expect
possible clipping, loading, aliasing, and ADC-channel crosstalk. The software
DC blocker removes an offset but cannot restore a clipped negative waveform.
This is a waveform/lo-fi experiment, not a clean contact-mic preamp design.

1. BUILD THE FIRMWARE (NO HARDWARE UPLOAD HAS BEEN PERFORMED FOR YOU)

Install Arduino IDE and PJRC's Teensy boards package using its official guide:
https://www.pjrc.com/teensy/td_download.html
Boards Manager URL:
https://www.pjrc.com/teensy/package_teensy_index.json

Open piezo_lc_capture/piezo_lc_capture.ino.
Select Board: Teensy LC; USB Type: Serial; CPU: 48 MHz.
Compile/Verify first. Uploading REPLACES the existing firmware; the old sketch
was not recovered or backed up. Keep piezos disconnected for initial startup.

The firmware waits idle until the receiver requests a capture. It does not
drive the jack pins as outputs. Close Arduino's Serial Monitor/Plotter before
opening the receiver, so only one program owns the port.

2. SET UP THE COMPUTER RECEIVER

In Terminal, change to this package directory:

  cd ~/code/piezo-box
  python3 -m venv .venv
  .venv/bin/python -m pip install -r requirements.txt
  .venv/bin/python capture.py ports

Identify the Teensy's /dev/cu.usbmodem... port. The receiver requires an explicit
port; it does not open every attached serial device or upload firmware.

3. FIRST CAPTURE: THE KNOWN A7 / PIN 21 INPUT

After the input-conditioning check above, replace PORT with the actual port:

  .venv/bin/python capture.py record --port PORT --pins 21 --rate 16000 --seconds 5 --out captures/a7-first

This requests 16,000 samples/s on ONE channel, at 12-bit ADC resolution. Whether
the hardware sustains it is checked during the take. Start with disconnected
inputs if you first want to verify USB transport alone; that does not test audio.

Outputs:
  captures/a7-first.wav   — 16-bit PCM, DC-blocked at 20 Hz by default
  captures/a7-first.pzlc  — original framed 12-bit ADC samples and timing stats
  captures/a7-first.json  — pin list, counters, sample ranges, and validation

To play the WAV on macOS:
  afplay captures/a7-first.wav

The 16-bit WAV container does not mean 16-bit ADC fidelity. The default PCM
gain is 8 per ADC count. Use --gain 4 if the host reports PCM clipping.

4. OPTIONAL LIVE LISTENING

  .venv/bin/python -m pip install sounddevice
  .venv/bin/python capture.py record --port PORT --pins 21 --rate 16000 --seconds 20 --monitor --out captures/a7-monitor

This plays through the computer's default output while recording. For multiple
inputs the monitor averages them into mono; the saved channel files remain
separate. Output-device sample-rate support and monitoring latency are untested.
If monitoring cannot open the output device, omit --monitor and play the WAV.

5. MAP THE REMAINING SIGNALS IN SOFTWARE

With input protection established, a low-rate scan can show which pin responds
to each piezo. This command inspects all thirteen LC analog-capable pins, rather
than presuming a seven-pin mapping:

  .venv/bin/python capture.py record --port PORT --pins 14,15,16,17,18,19,20,21,22,23,24,25,26 --rate 1000 --seconds 30 --map --out captures/pin-map

One line per second shows max-minus-min ADC values by pin. Exercise one piezo
at a time and associate its response with its pot and jack tip/ring. Floating
unused pins and high-impedance ADC crosstalk can also move; a response alone is
not proof of a wire connection. Confirm any ambiguous mapping by continuity.
Mapping mode saves raw samples and a report but no WAV files. A 1 kHz scan is
for mapping, not audio-quality recording. Full-scale ADC count is 4095.

6. RECORD SEPARATE CHANNELS

Supply ONLY verified pin numbers in the desired order. For example, IF pins
20 and 21 have both been confirmed as piezo channels:

  .venv/bin/python capture.py record --port PORT --pins 20,21 --rate 8000 --seconds 5 --out captures/pair

This produces pair.wav (two channels), pair.A6-pin20.wav, pair.A7-pin21.wav,
pair.pzlc, and pair.json. The input order is preserved in the combined file.
For seven verified channels, a reasonable initial EXPERIMENT is --rate 4000;
this rate is not hardware-validated. Pass the actual seven pin numbers to
--pins. Reducing the rate reduces available audio bandwidth: 4 kHz sampling
cannot faithfully represent frequencies at or above 2 kHz, and higher-frequency
content can alias without analog filtering.

The USB-serial protocol supports up to thirteen selected pins, so stereo is
not a protocol limit. ADC speed/settling and the analog circuit are the limits
to validate. Adding channels does not automatically divide the requested rate;
--rate is the frame rate PER CHANNEL. Reduce it explicitly. A discarded ADC
conversion after each channel switch helps settling but does not guarantee it.

7. INTERPRET THE CHECKS

Require "Timing checks passed" for a take whose nominal timebase you trust.
It requires: no device buffer drops, no ADC callbacks exceeding their budget,
no callback intervals >1.5 times the requested interval, normal completion,
and an effective frame rate within 2% of the requested rate.

Missed buffer frames are inserted as silence in all saved channels, and flagged.
Delayed sampling interrupts are flagged but cannot be precisely reconstructed;
do not treat such a recording as correctly timed. After eight consecutive
over-budget callbacks the firmware stops early to avoid starving the main loop.
Stop reasons: 0=normal, 1=host STOP, 2=timer setup failure, 3=sampling overload.
On failure, reduce --rate and/or channel count. Exit code 2 means the take was
saved but did not pass timing/completion checks. Exit code 1 indicates an error.

ADC zero readings are expected between hits in a ground-referenced trigger
circuit. The JSON zero/full-scale counts report rail occupancy, not a definitive
test for analog clipping or safety. No timing check proves audio fidelity.

8. REPROCESS ORIGINAL SAMPLES WITHOUT TOUCHING THE BOARD

  .venv/bin/python capture.py decode captures/a7-first.pzlc --out captures/a7-quieter --gain 4

Use --dc-block 0 to disable digital DC removal. With it disabled, unsigned ADC
samples are centered at 2048 before conversion to signed PCM. Existing output
files are never overwritten; use a new output prefix for another take.

VALIDATION

Host tests use synthetic data and do not require a board:
  python3 -m unittest -v test_capture.py

See BUILD-VALIDATION.txt for the actual compiler and test results. No physical
board, piezo capture, input voltage, or live playback has been validated here.

PRIMARY REFERENCES

LC analog pins, voltage limits, and USB serial:
https://www.pjrc.com/store/teensylc.html
LC pinout:
https://www.pjrc.com/teensy/card6a_rev4_web.pdf
https://www.pjrc.com/teensy/card6b_rev4_web.pdf
Teensy 4.0's supported USB Audio mode and experimental on-chip audio ADC:
https://www.pjrc.com/store/teensy40.html
Piezo signal conditioning:
https://www.ti.com/lit/an/sloa033a/sloa033a.pdf
