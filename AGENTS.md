# Project instructions

- Author and commit all changes as `dustMason <369105+dustMason@users.noreply.github.com>`. Keep this identity repository-local; do not change global Git configuration.
- This repository is a personal project. The user manages creation of the GitHub repository and the initial push unless they request otherwise.
- The current firmware targets Teensy LC, CPU 48 MHz, USB Type Serial. It streams ADC waveforms to the Python receiver; it is not a class-compliant USB Audio device.
- Run host tests with `python3 -B -m unittest -v test_capture.py`.
- Keep measured wiring, inferred connections, software validation, and physical hardware validation distinct. A7 / pin 21 is the default tested-by-continuity input; the complete seven-input map is not established.
- Compiling alone must not upload firmware or launch Teensy Loader. With Arduino CLI, disable `recipe.hooks.postbuild.1.pattern` as documented in README.md. Upload only when the user requests or authorizes it.
- Keep local recordings, virtual environments, and build directories out of Git. The root `.hex` file is the intentionally retained initial compiled prototype; its checksum and validation scope are recorded in BUILD-VALIDATION.txt.
