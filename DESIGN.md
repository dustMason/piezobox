# Piezo Scope — native Mac utility

The user's brief is a small native app for one signal at a time. Use the macOS
design language directly; this is a focused operating surface, not a new brand
or promotional page.

- System fonts and semantic system foreground/background colors; follow light/dark appearance.
- One generous waveform canvas, with quieter time/scale labels and a clearly named view scale.
- Native device/input pickers, a Start/Stop action, a listening toggle, and gain/volume sliders.
- Teal for received waveform data, the system accent for native controls, and orange for degraded timing or clipping.
- Distinguish empty, connecting, live, stopped, missing-device, and error states in words.
- Waveform zoom affects the view only; input boost and listening volume affect playback only.
- A compact diagnostics footer reports actual frame delivery and timing, without overwhelming the waveform.
- Keyboard access, named accessibility elements, readable values, and a resizable window.

First viewport: device and input at the top, a dominant real waveform in the
center, listening controls below, and a quiet capture-status line at the bottom.
The waveform can be held for inspection while the input continues to play.
