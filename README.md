# nidhogg

nidhogg runs the firmware of the CHOMPI sampler on a monome norns, with an OMX-27 as its panel. All three Chompi firmwares are here, and you can switch between them:

- TAPE, a sampler and varispeed tape looper
- TEMPO, a sample arpeggiator and slicer with a granular delay
- WAVE, a wavetable synth with a step sequencer

It's Chompi's own code, built for the norns, so it sounds and behaves like a Chompi.

How to play it: [docs/guide.html](docs/guide.html).

## What you need

- A norns, or a norns shield. Tested on a ShieldXL (Pi 4) with norns 2.9.1.
- An OMX-27 running Quixotic7's firmware, 1.15.4 or later: [github.com/Quixotic7/OMX-27/releases](https://github.com/Quixotic7/OMX-27/releases). Any of the three boards works. Connect it to the norns by USB.
- About 200 MB free for Chompi's factory samples, and wifi for the first run.

## Installing

1. In maiden, install nidhogg from this repo.
2. Load nidhogg from SELECT.
3. The first run downloads Chompi's factory samples, installs nidhogg's SuperCollider plugins and restarts SuperCollider. This takes a few minutes and then nidhogg loads by itself.

Later updates that change the plugins restart SuperCollider the same way.

The samples go in `dust/audio/nidhogg/tape`, `tempo` and `wave`, laid out like a Chompi SD card. Nothing there is overwritten after the first download, so you can add your own samples.

## If SuperCollider won't start

If you've logged in to the norns over ssh and then logged out, norns can lose the connection to its audio server until the next restart. This happens with any script that restarts SuperCollider. Restart the norns to fix it. To avoid it while you work over ssh, keep one ssh session open.

## How it works

Each firmware is Chompi's source, with a few small patches, built against a stand-in for the Daisy Seed board it normally runs on. The stand-in turns keys, knobs and LEDs into messages, the SD card into a folder, and the audio into a SuperCollider UGen. The norns script connects that to the OMX-27, the norns controls and the screens. More in [docs/design.md](docs/design.md).

## Building

The plugins in `bin/` are built for the norns (32-bit ARM). To build them yourself, see [docs/building.md](docs/building.md).

## Credits

CHOMPI is by CHOMPI Club, now part of Chase Bliss, with hardware and the original firmware platform by Electrosmith. Its firmware is released under the MIT licence: [github.com/CHOMPI-Club/CHOMPI](https://github.com/CHOMPI-Club/CHOMPI). The vendored copy in `third_party/chompi` keeps its licence and notices, including libDaisy, DaisySP and coreJSON. The CHOMPI name and marks belong to Chase Bliss and aren't covered by the licence.

The OMX-27 is by Denki Oto, with firmware by okyeron and Quixotic7.
