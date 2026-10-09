# Product

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS. The user explicitly requested a native Swift app, not a web surface.

## Stack

Swift, SwiftUI, CoreAudio USB input, CoreMIDI virtual output, and AVAudioEngine
for local playback. The Teensy LC supplies standard USB audio at 32 kHz.

## Users and purpose

Jordan is restoring a homemade piezo box and wants to hear, see, record, and
trigger MIDI from its seven inputs. All inputs are captured together; one
selected input has the detailed waveform and local listening controls.

## Operating context

The box has one mono and three TRS jacks, seven piezo signal connections, and
seven physical loading controls. Pin 21/A7 has been mapped and its USB capture
verified initially at 16 kHz. The current firmware samples A1–A7 at 32 kHz and
exposes separate seven-channel and mono USB audio inputs. Other jack-to-pin
mappings and analog protection remain incompletely verified.

## Capabilities and constraints

- Show all input levels, a selected waveform, and local listening through the Mac.
- Read the current USB Audio firmware through CoreAudio; do not require Python or a custom Mac audio driver.
- Keep connection, waveform viewing, and listening controls understandable.
- The Teensy itself supplies the mono and seven-channel recording devices, even when the app is closed.
- MIDI mode provides per-input thresholds and notes, retrigger control, and selectable hit-strength or fixed velocity through the Piezo Box Drums virtual source.
- An app cannot recover clipped waveforms or validate physical input protection.

## Product principles

- Let the user get from connected hardware to hearing and seeing the signal quickly.
- Show real received data and honest connection/error states.
- Follow familiar native Mac controls and system appearance.
- Keep the capture transport separate from playback and visualization.
