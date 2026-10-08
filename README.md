# nidhogg

nidhogg runs the firmware from the CHOMPI sampler on a monome norns, with an OMX-27 as the keys and knobs.

CHOMPI went open source when it was discontinued, so nidhogg runs its actual firmware: TAPE (the sampler and tape looper it shipped with), TEMPO (a sample arpeggiator and slicer) and WAVE (a wavetable synth). You can switch between them any time and each one picks up where you left it.

How to play it is in the [guide](docs/guide.html).

Please try it and let me know what works and what doesn't by opening an issue here.

Enjoy,<br>
Dan (rm)

---

## What you need

- A norns or norns shield. I've tested it on a ShieldXL (Pi 4) with norns 2.9.1.
- An OMX-27 with Quixotic7's firmware, version 1.15.4 or newer ([releases](https://github.com/Quixotic7/OMX-27/releases)), plugged into the norns by USB. Any of the three OMX-27 boards works.
- About 200 MB free, and wifi the first time.

## Installing

1. Install nidhogg from maiden.
2. Load it from **SELECT**.
3. The first time, it downloads CHOMPI's factory samples, installs its SuperCollider plugins and restarts SuperCollider. This takes a few minutes, then nidhogg loads by itself.

The samples are in `dust/audio/nidhogg`, one folder per firmware, laid out like a CHOMPI SD card. You can add your own there through maiden.

If SuperCollider won't start after you've been logged in over ssh, restart the norns.

## Credits

CHOMPI is by CHOMPI Club, now part of Chase Bliss, with hardware and the original firmware by Electrosmith. The firmware is MIT licensed ([github.com/CHOMPI-Club/CHOMPI](https://github.com/CHOMPI-Club/CHOMPI)) and the copy in `third_party/chompi` keeps its licences. The CHOMPI name belongs to Chase Bliss.

The OMX-27 is by Denki Oto, with firmware by okyeron and Quixotic7.

How it works is in [docs/design.md](docs/design.md), and building the plugins in [docs/building.md](docs/building.md).
