# How nidhogg works

```
 OMX-27 (REMOTE) --USB MIDI sysex--> matron: nidhogg.lua --OSC--> scsynth: Nidhogg<Fw> UGen
        <--LED and OLED sysex--         |      <--LEDs, state, MIDI--   (Chompi firmware + virtual Daisy)
                                  norns screen, keys,                    in: engine send
                                  encoders, MIDI, params                 out: engine return
```

## The firmware

Each Chompi firmware (TAPE, TEMPO, WAVE) builds from its vendored source in `third_party/chompi/<fw>`, never edited. The build copies it into the build folder and applies the patches in `host/patches/<fw>/`:

- `0001-host-memory`: the Daisy's SDRAM and DTCM sections become plain arrays, and `ZeroSDRAM()` zeroes those arrays.
- knob access: a few functions the board code uses to read knob values and pages, post knob turns and read state for the screens.
- TEMPO only: its arpeggiator reads note lists without checking their size, which is harmless on the Daisy and faults on Linux, so the lists reserve room.

All patches are `#ifdef NIDHOGG_HOST`.

## The virtual Daisy (`host/shim`)

libDaisy's own headers are used as they are. `daisy_impl.cpp` implements their hardware classes on Linux:

- GPIO pins are virtual. The board code (`host/src/board_daisy.cpp`) emulates the 4021 shift registers the keys and switch sit on, and plays encoder detents as A/B pulses, so Chompi's own debouncing and decoding run unchanged.
- The MP2722 battery charger on I2C reports USB power and a full battery.
- Audio, timers and MIDI are driven by the host. Timers run at the rate libDaisy's timer maths gives (240 MHz through the prescaler and period).
- FatFs calls work on plain files under the card folder, matching names case-insensitively like FAT (`ff_posix.cpp`).
- Interrupt masking (`__disable_irq`, `ScopedIrqBlocker`) takes a priority-inheriting lock that the audio and timer contexts also hold.

`vhw.cpp` runs the firmware's three contexts:

- the audio interrupt: the host's audio callback, in 24-frame blocks (`blocks.h` adapts any host block size, adding 0.5 ms)
- the timer interrupts: a timer thread, woken every block
- the main loop: the firmware's own `main()` in its own thread

Firmware time counts audio blocks, 0.5 ms each, so `System::GetNow()`, delays and the control debouncers behave as on the Daisy whatever the host does. When nothing feeds audio, firmware time stops, so a firmware that isn't playing is paused.

Delays inside interrupt-context code move firmware time on, as SysTick does on the Daisy.

## Hosts

- `NidhoggTape`, `NidhoggTempo`, `NidhoggWave` (`host/src/ugen.cpp`): the firmware as a SuperCollider UGen. `/cmd Nidhogg<Fw>Start <card>` starts it on scsynth's non-real-time thread. scsynth loads all three plugins, so each one hides everything but its entry points.
- `nidhogg-<fw>` (`run.cpp`): a JACK client, for testing.
- `nidhogg-<fw>-render` (`render.cpp`): offline, in lockstep: each block the main loop runs until it sleeps, so a script of events gives the same result every time. Prints LEDs, MIDI out and CPU load.

All three share `bridge.cpp`, the OSC link to the norns script (port 57140 TAPE, 57141 TEMPO, 57142 WAVE; replies to matron on 10111).

## Pots

Chompi's knobs are endless encoders with pages. A pot posts turns to the firmware's own UI event queue, waits until they land, then corrects from the knob's real value. It takes over once it passes the knob's value, and lets go on a page change or when the firmware changes the value itself. Each firmware's board file gives the step per turn for each knob and page, and which knobs follow pot movement instead (quantised pitch, tempo).

## The norns script

- `nidhogg.lua`: start-up, params, inputs, the frame loop.
- `lib/install.lua`: downloads the factory cards (sparse clone of the Chompi repo), installs the plugins, restarts SuperCollider and reloads the script.
- `lib/omx.lua`: the OMX-27 REMOTE mode protocol (Quixotic7's `SYSEX_SPEC.md`).
- `lib/modes.lua`: what differs between firmwares: labels, pages, home screens.
- `lib/view.lua`: the OMX screen (large text) and the norns screen (details and Chompi's panel lights). Each frame the OMX picture is drawn, copied with `screen.peek`, then the norns picture is drawn over it.
- `lib/saver.lua`: the dragon screensaver.
- `lib/options.lua`: each firmware's `options.json` as params.
