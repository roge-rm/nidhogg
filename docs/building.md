# Building

The plugins must be built for 32-bit ARM, so build on a norns (or another 32-bit Raspberry Pi OS with SuperCollider's headers). A Pi 4 builds all three in a few minutes.

You need cmake, the SuperCollider plugin headers (on norns in `/usr/local/include/SuperCollider`) and liblo. JACK is only needed for the test runner. All are on a stock norns.

```
cd host
mkdir -p build && cd build
cmake ..
make -j3
```

This gives, for each firmware:

- `Nidhogg<Fw>.so`: the SuperCollider plugin
- `nidhogg-<fw>-render`: the offline harness
- `nidhogg-<fw>`: the JACK runner, if JACK's headers are there

On ARM the build targets the Cortex-A53, which covers the Pi 3 and Pi 4. Chompi's code builds at `-O3`, gnu++14, without exceptions or RTTI, as on the Daisy.

To use a new plugin, strip it and put it in `bin/`:

```
strip --strip-unneeded -o ../../bin/NidhoggTape.so NidhoggTape.so
```

The script installs changed plugins on its next start.

## Updating Chompi's source

```
tools/vendor-chompi.sh PATH_TO_A_CHOMPI_CLONE
```

copies the firmware sources and licences into `third_party/chompi`. If a patch in `host/patches` no longer applies, cmake stops with the patch's name.

## Testing offline

```
host/build/nidhogg-tape-render --card ~/dust/audio/nidhogg/tape --seconds 14 --out test.wav \
    9:key:18:1 11:key:18:0 12:leds 13.9:load
```

Events are `time:what:args`: `key`, `turn`, `push`, `pot`, `switch`, `midi`, `leds` and `load`. See the top of `host/src/render.cpp`. Keys use Chompi's switch ids from its `hardware.h`; middle C is 18 and the CHOMPI key is 5. The firmware takes about 8 seconds to boot before keys do anything.

## Tools

- `tools/repl.py`: send Lua to matron's REPL (or SuperCollider's with `-p 5556`).
- `tools/screenshot.py`: save the norns screen as a PNG.
- `tools/osc.py`: send an OSC message, for poking a running firmware.
