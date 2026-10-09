# Product

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS. The user explicitly requested a native Swift app, not a web surface.

## Stack

Swift, SwiftUI, Foundation/IOKit serial discovery, and AVAudioEngine for local playback.
The existing Teensy LC firmware and PZLC1 USB-serial protocol remain the capture source.

## Users and purpose

Jordan is restoring a homemade piezo box and wants to hear and see its signal on
the Mac. For this first app, the user selected one selectable input at a time.

## Operating context

The box has one mono and three TRS jacks, seven piezo signal connections, and
seven physical loading controls. Pin 21/A7 has been mapped and its USB capture
verified at 16 kHz. Other jack-to-pin mappings and analog protection remain
incompletely verified.

## Capabilities and constraints

- Show a live waveform and play the selected input through the Mac.
- Use the current firmware; do not require Python for the native app.
- Keep connection, waveform viewing, and listening controls understandable.
- Virtual audio-device, DAW routing, and broader Core Audio integration are future work.
- An app cannot recover clipped waveforms or validate physical input protection.

## Product principles

- Let the user get from connected hardware to hearing and seeing the signal quickly.
- Show real received data and honest connection/error states.
- Follow familiar native Mac controls and system appearance.
- Keep the capture transport separate from playback and visualization.
