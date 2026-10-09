# nidhogg

nidhogg is the CHOMPI [open source firmware](https://github.com/CHOMPI-Club/CHOMPI) adapted to norns and designed around the [OMX-27](https://github.com/okyeron/OMX-27).

Each of the three firmwares (TAPE, TEMPO, WAVE) is run using the actual code from the CHOMPI source, adapted to run under Linux. You can switch between them in the norns parameter edit screen - the state of each is saved when you switch away and resumed when you come back.

How to play it is in the [guide](docs/guide.html).

This has only been tested on my [shieldXL](https://github.com/okyeron/shieldXL) unit with a Pi4 2GB inside but it should run fine on a Pi3 unit - like an official norns. Only support for the OMX-27 has been added so far, if you'd like another controller supported please come chat with me in #nidhogg **[on my discord](https://discord.gg/9Wun47jGC6)** or open an issue here.

Thanks to the team at CHOMPI for open sourcing it, I hope this port does it justice.

Enjoy!
Dan

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
