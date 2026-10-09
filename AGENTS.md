# Project instructions

- Author and commit all changes as `dustMason <369105+dustMason@users.noreply.github.com>`. Keep this identity repository-local; do not change global Git configuration.
- This repository is a personal project. The user manages creation of the GitHub repository and the initial push unless they request otherwise.
- The current `piezo_lc_audio` firmware targets Teensy LC at 48 MHz and exposes UAC1 mono and seven-channel USB inputs at 32 kHz, plus CDC diagnostics/reboot. Build it with `tools/build_usb_audio.py`, which patches an isolated Teensy 1.62.0 core. Do not replace the installed core. `piezo_lc_capture` and PZLC1/PZLC2 are retained legacy serial workflows.
- Run host tests with `python3 -B -m unittest -v test_capture.py test_streaming.py test_usb_audio.py`.
- Native Mac app: `swift test --package-path macOS`; build its local app bundle with `./macOS/build-app.sh`. Preserve the user's live capture and listening controls when they are trying the app; do not restart it just for optional polish.
- Keep measured wiring, inferred connections, software validation, and physical hardware validation distinct. A7 / pin 21 is the default tested-by-continuity input; the complete seven-input map is not established.
- Compiling alone must not upload firmware or launch Teensy Loader. With Arduino CLI, disable `recipe.hooks.postbuild.1.pattern` as documented in docs/usb-audio.md. Upload only when the user requests or authorizes it.
- USB test patterns must be disabled after checks. Release firmware must not contain the prototype's automatic 90-second programming-mode timeout. Keep the original and v2 serial HEX files as rollback snapshots.
- Keep local recordings, virtual environments, and build directories out of Git. The root `.hex` file is the intentionally retained initial compiled prototype; its checksum and validation scope are recorded in validation/build-history.txt.
