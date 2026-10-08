# nidhogg plan

nidhogg runs the Chompi firmwares (TAPE, TEMPO and WAVE) on norns, with an OMX-27 as the panel. The aim is that it sounds and behaves like a real Chompi, so the Chompi code itself runs, not a copy built from SuperCollider UGens.

Reference specs: [chompi-tape](ref/chompi-tape.md), [chompi-tempo](ref/chompi-tempo.md), [chompi-wave](ref/chompi-wave.md), [omx27](ref/omx27.md).

## How it fits together

```
 OMX-27 (REMOTE)    --USB MIDI--> matron (nidhogg.lua) --OSC--> nidhogg-tape / -tempo / -wave
        <--LEDs, OLED sysex--           |    <--LEDs, MIDI out--        (Chompi firmware + Daisy shim)
                                        |                                       |
                               norns screen, keys,                     JACK client, 48 kHz
                               encoders, MIDI, params            in: crone:output_5/6 (engine send)
                                                                 out: crone:input_5/6 (engine return)
```

### 1. Chompi firmware on Linux

Each firmware builds as its own program from Chompi's source, with as few changes as possible. Only one runs at a time, so switching modes is like flashing a different firmware.

- A shim stands in for the Daisy Seed and the parts of libDaisy the firmware uses. That covers `Hardware` (keys, encoders, switch and LEDs from OSC), `System::GetNow`, MIDI, the audio callback and FatFS. DaisySP builds unchanged.
- **Audio:** it's a JACK client wired to crone's engine send and return, next to SuperCollider. It gets the norns inputs and goes through the norns engine level, monitoring and tape like any engine. JACK runs 128-sample periods and Chompi 24-sample blocks, so a small FIFO runs the firmware's callback in exact 24-sample blocks, adding 0.5 ms.
- **Outputs:** Chompi has headphone and line pairs with different gains. The line pair goes to norns. The mic is the norns left input in mono.
- **SD card:** FatFS calls map to plain files under `~/dust/audio/nidhogg/<mode>/`, laid out like a Chompi card. The streaming code runs as it is.
- **Threads:** the firmware's three contexts (audio interrupt, 1 kHz SD callback, main loop) become the JACK callback, a timer thread and the main thread. On the Daisy the audio interrupt always pre-empts the main loop. On Linux they can run at the same time, so shared state needs checking. This is the main technical risk and the first spike tests it.
- Each firmware's own libDaisy copy is the reference for the shim, since Chompi changed it (MIDI helpers, timers and UART timing).
- Credits and licence notices from Chompi's `THIRD_PARTY.md` come along with the code.
- Builds on x86 for an offline harness (scripted key events in, wav out) and natively on the norns for real use. One armv7 binary covers Pi 3 and Pi 4 (`-mcpu=cortex-a53`).

### 2. OMX-27 in REMOTE mode

No OMX-27 firmware work of our own. Quixotic7's fork (github.com/Quixotic7/OMX-27) has a REMOTE mode from v1.15.4: the norns owns all 27 key LEDs and the 128x32 OLED, and gets every key (down, up, hold, quick), the encoder, its button and the 5 pots at 14 bits. Release builds exist for all three boards (RP2040 `.uf2`, Teensy 4.0 and 3.2 `.hex`). The protocol is in that repo's `SYSEX_SPEC.md`, "REMOTE mode".

nidhogg talks to it with its own small Lua client written from that spec, since neither OMX-27 repo has a licence file. Exit REMOTE mode on the OMX-27 with AUX + hold the encoder button.

### 3. nidhogg.lua

- Starts the program for the chosen mode and stops it on exit. The program also quits by itself if matron goes quiet, so a crashed script doesn't leave it running.
- Maps the OMX-27, norns keys and encoders to Chompi controls, and draws Chompi's panel LEDs (10 panel and 25 key LEDs) on the norns screen and the OMX-27 key LEDs.
- Bridges MIDI: Chompi's TRS and USB MIDI go to norns MIDI devices, including the ShieldXL TRS port.
- Edits options.json through norns params.

## Control mapping (draft)

| Chompi | OMX-27 / norns |
|---|---|
| 15 white keys C3-C5 | OMX white keys 12-26 (C4-C6 on the panel) |
| 10 black keys | OMX top keys 1-10 |
| CHOMPI key | OMX AUX |
| PLAY, LOOP | open, see questions |
| Pitch, Start, End, Magic, Volume knobs | OMX pots 1-5 |
| Transport knob and push | OMX encoder and push |
| Knob pushes (page change, shift pushes) | open, see questions |
| Play/Record switch | norns E1: left Play, right Record |
| spare | OMX key 11 (B3, unused: easy to hit by accident), norns E2 |

Chompi's knobs are endless encoders with up to 3 pages each, and the pots are absolute, so each pot picks up its page's value when it passes it (soft takeover).

## Milestones

1. **Spike:** TAPE builds on Linux with the shim and renders a note from a factory sample offline. Check the threading risk.
2. **TAPE on norns:** runs as a JACK client, played from the norns and a plain MIDI keyboard. Measure CPU on the Pi 4, and with headroom for a Pi 3.
3. **OMX-27 client:** Lua client for REMOTE mode, tested on Dan's RP2040 unit with Quixotic7 v1.15.7.
4. **TAPE complete:** full OMX-27 mapping, screen, MIDI and options.
5. **TEMPO**, then **WAVE**, and switching between modes.
6. **Packaging:** prebuilt binaries in the repo, install and the factory card contents.

## Open questions

1. PLAY on K2, LOOP on K3 and the knob pushes as K1 held + move a pot are still to be confirmed. TEMPO and WAVE use the same panel, so one mapping serves all three.
2. Do you have a real Chompi to compare against? That would make "sounds just like one" testable.
3. The factory samples fall under Chompi's MIT licence, so nidhogg can ship them. They're 190 MB, so I'd rather fetch them from the Chompi repo on first run than keep them in our git. Is that OK?
