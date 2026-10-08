# Chompi WAVE firmware: functional spec

Reference for reimplementing Chase Bliss CHOMPI's WAVE v1.0 firmware on norns (Lua + SuperCollider) with an OMX-27 as the control surface.

Source: `nidhogg-ref/chompi/firmware/chompi-wave/code/src` (all files read). File:line refs below are relative to that folder unless a path is given. DaisySP/libDaisy refs are under `code/libs/`.

Conventions in this doc:

- "Knob 0..5" are the logical knob numbers the UI uses (after `encoder_map`, ui.h:43). Names: 0 pitch, 1 attack, 2 release, 3 FX ("magic"), 4 transport/tempo, 5 gain.
- Knob values are floats 0..1 unless stated. "Page 0/1" is the knob's alternate page, toggled by clicking it.
- `sr` = 48000. Audio block = 24 samples (hardware.h:130).
- `fonepole(x, target, k)` means `x += k*(target - x)` once per sample (DaisySP dsp.h:135). k = .001 is a ~20.8 ms time constant; k = .0002 is ~104 ms.
- The "CHOMPI key" is KEY_26, also called shift.

---

## 1. Hardware as the firmware sees it

Platform: Daisy Seed (STM32H750), 64 MB SDRAM, SD card over SDMMC 4-bit, MP2722 battery/charger IC on I2C (hardware.h:101-188).

### Audio (chompi_main.cpp:70-82, hardware.h:112-134)

| Channel | Use in WAVE |
|---|---|
| In 1 | built-in microphone (ignored) |
| In 2 | "X", unused |
| In 3/4 | aux/line in L/R (ignored) |
| Out 1/2 | headphone L/R |
| Out 3/4 | master (line) L/R, an exact copy of out 1/2 (subtractiveEngine.h:291-292) |

WAVE never reads any input. A jack-detect GPIO exists (hardware.h:150) but WAVE only prints it in a debug function.

### Switch shift register (hardware.h:49-97)

40 bits from 5 chained CD4021s, debounce 7 (hardware.h:167-172). Button IDs used everywhere are these enum indices.

| ID | Name | Role |
|---|---|---|
| 0 | ENC_1_SW | click of knob 1 (attack) |
| 1 | ENC_2_SW | click of knob 2 (release) |
| 2 | ENC_3_SW | click of knob 3 (FX) |
| 3 | ENC_4_SW | click of knob 0 (pitch) |
| 4 | NC_6 | unused; ID 4 is reused for ENC_5_SW (knob 4 click), which is on its own GPIO (hardware.h:9, ui.h:207, 243-246) |
| 5 | KEY_26 | CHOMPI key (shift / mute / rest) |
| 6 | SW_TOG | toggle switch |
| 7..31 | KEY_1..KEY_25 | 25 note keys (order scrambled, see table below) |
| 32 | ENC_6_SW | click of knob 5 (gain) |
| 33 | KEY_27 | play |
| 34 | KEY_28 | loop (record) |
| 35..39 | NC_1..NC_5 | unused |

Note keys (NormalPage.h:22-63 `key_map`, value = MIDI note number). KEY_1..KEY_15 are the 15 white keys, KEY_16..KEY_25 the 10 black keys. Two octaves C to C.

| Key | ID | Note | Key | ID | Note |
|---|---|---|---|---|---|
| KEY_1 (C) | 15 | 48 | KEY_16 (C#) | 7 | 49 |
| KEY_2 (D) | 8 | 50 | KEY_17 (D#) | 12 | 51 |
| KEY_3 (E) | 9 | 52 | KEY_18 (F#) | 13 | 54 |
| KEY_4 (F) | 10 | 53 | KEY_19 (G#) | 14 | 56 |
| KEY_5 (G) | 11 | 55 | KEY_20 (A#) | 21 | 58 |
| KEY_6 (A) | 16 | 57 | KEY_21 (C#) | 22 | 61 |
| KEY_7 (B) | 17 | 59 | KEY_22 (D#) | 23 | 63 |
| KEY_8 (C) | 18 | 60 | KEY_23 (F#) | 29 | 66 |
| KEY_9 (D) | 19 | 62 | KEY_24 (G#) | 30 | 68 |
| KEY_10 (E) | 20 | 64 | KEY_25 (A#) | 31 | 70 |
| KEY_11 (F) | 24 | 65 | | | |
| KEY_12 (G) | 25 | 67 | | | |
| KEY_13 (A) | 26 | 69 | | | |
| KEY_14 (B) | 27 | 71 | | | |
| KEY_15 (C) | 28 | 72 | | | |

### Encoders (hardware.h:153-158, 395-423; encoder.cpp)

Six endless detented encoders with push switches. Physical encoders 1-4 are read through a second CD4021; 5 and 6 are on GPIO. Physical-to-logical map `encoder_map = {1,2,3,0,4,5}` (ui.h:43): physical SW1 = knob 1 (attack), SW2 = knob 2 (release), SW3 = knob 3 (FX), SW4 = knob 0 (pitch), SW5 = knob 4 (transport), SW6 = knob 5 (gain).

Each detent gives an increment of ±1 for knobs 0 and 4, and ±3 for the others (ui.h:252-264). All step sizes below are per detent.

### Toggle switch (hardware.h:388-405, ui.h:184, 209-216)

Debounced by a 0..200 counter; `toggle_state = counter < 100`. Code comments call `toggle_state == true` "DOWN" (ui.h:230, NormalPage.h:798). I use those names:

- DOWN (true): CHOMPI key opens the shift menu.
- UP (false): CHOMPI key is a performance key (sequencer mute / rest) and sends CC 14.

`engine.setSwitchState` is stored but unused (subtractiveEngine.h:571).

### LEDs (temp_led_stuff.h)

Two WS2812-style RGB chains driven by PWM+DMA.

- 10 "PTH" panel LEDs (temp_led_stuff.h:28). Index: 0 CHOMPI key, 1 pitch knob, 2 attack knob, 3 release knob, 4 FX knob, 5 and 6 the pair of 5 mm LEDs at the transport knob, 7 play key, 8 loop key, 9 gain knob (NormalPage.h:65-106, 259-427). Brightness scaled by 1/11 (temp_led_stuff.h:180).
- 25 "SMT" keybed LEDs, one under each note key. White keys KEY_1..KEY_15 = SMT 24 down to 10; black keys KEY_16..KEY_25 = SMT 0..9 (NormalPage.h `led_map`). Brightness scaled by 1/4.

### Other

- MIDI: TRS (UART, DMA) and USB device MIDI, both in and out (MidiManager.h:21-45).
- USB is also power/charging. Battery level states FULL, HIGH, MEDIUM, LOW (LOW unused) (hardware.h:190-318).
- SD card slot (FatFs).
- No display. All feedback is LED colour.

---

## 2. Runtime structure

- Audio ISR, once per 24-sample block (chompi_main.cpp:85-124): silent until boot/loading done; then MIDI in parse, scan controls, queue UI events, sequencer tick, process ONE queued key request, render audio.
- SD timer callback at 1 kHz (chompi_main.cpp:161-179, hardware.h:439-455): one file request per tick, SD-present check every 1 s, chunked preset writes every 50 ms.
- Main loop (chompi_main.cpp:223-311): MIDI out, UI event dispatch and LED draw every ~2 ms, wavetable load 1 s after boot, preset save check every 5 s, battery checks.
- UI is a libDaisy page stack. Events go to the top page first; a handler that returns false passes the event to the page below. Only the top page draws (libDaisy UI.h:86, UI.cpp:255-285). Pages: NormalPage (bottom, always open), MenuPage (shift), BootPage, RainbowPage, NoSDPage, TestPage.
- Key requests: `KeyRequest{type START/STOP, transpose_nn, key id, velocity, source USER/SEQUENCER}` go into a 64-entry FIFO (subtractiveEngine.h:27-74, 149). The engine pops one per audio block (0.5 ms), so a chord of N notes starts over N blocks (subtractiveEngine.h:501-513).

### Boot (chompi_main.cpp:313-421, 223-273)

1. Battery checks, mount SD, list wavetables, delete `.batt_log.txt` and `._.batt_log.txt`.
2. Read/rewrite `options.json`, read/rewrite `presets.json`.
3. 0.5 s control scan (5000 x 100 µs). If CHOMPI + play + loop are held >80% of it: shipping mode (power off). Else if the gain knob (ENC_6_SW) is held: hardware test mode (chompi_main.cpp:392-410).
4. BootPage: all LEDs pulse a random colour (BootPage.h). Audio output is zero.
5. 1 s after start, queue the wavetable loads. When the file queue drains and at least one `.wav` was found, select slot 15 (defaults) and release the loading screen 250 ms later (chompi_main.cpp:259-273, ui.h:377). With no `.wav` files the loading screen never ends (comment at chompi_main.cpp:257-258).
6. RainbowPage: one rainbow sweep across all LEDs, then closes (~1.5 s plus fades) (RainbowWavePage.h).
7. NormalPage ignores all input for 1.5 s after its Init (NormalPage.h:238-245).

---

## 3. Controls

### 3.1 Normal play (NormalPage.h)

#### Knobs

Steps are per detent. CC out is sent on every physical turn (section 7).

| Knob | Page | Function | Step | Default | Engine call |
|---|---|---|---|---|---|
| 0 pitch | 0 | fine tune, ±1 octave continuous | .003 | .5 | `setGlobalPitch` (NormalPage.h:722-729) |
| 0 pitch | 1 | wavetable frame ("cycle"), relative ±1 frame per detent, 0..32 | 1/33 shown on LED | 0 | `setCycle(turns, relative)` (NormalPage.h:730-738) |
| 1 attack | 0 | amp attack time | .009 | 0 | `setAttack` |
| 1 attack | 1 | pitch LFO depth | .03 | 0 | `setPitchLfoDepth` |
| 2 release | 0 | amp release time | .009 | 0 | `setRelease` |
| 2 release | 1 | filter LFO depth | .03 | 0 | `setLfoDepth` |
| 3 FX | 0 | delay/reverb, bipolar: left of centre delay, right reverb, .5 dry | .03 | .5 | `setDelayFeedback` |
| 3 FX | 1 | DJ filter cutoff: below .5 low-pass, above .5 high-pass | .03 | .5 | `setMasterCutoff` |
| 4 transport | (one page) | tempo: internal value T, ±1 per detent, 160..480 | value .003125 | T=320 (.5) | `changeTempo` (NormalPage.h:739-750) |
| 5 gain | 0 | output gain, linear 0..1 | .03 | .84 | `setGain` |
| 5 gain | 1 | pan | .03 | .5 | `setPan` |

Defaults: ui.h:26-30. Steps: NormalPage.h:109-115, 700-717. Pages per knob: `{2,2,2,2,1,2}` (NormalPage.h:132).

Knobs 1, 2, 3 and 5 are applied to the engine from `Draw()` every LED frame for the page currently shown (NormalPage.h:290-424). Knob 0 and 4 are applied in the turn handler.

#### Knob clicks (NormalPage.h:535-577)

| Control | Action |
|---|---|
| Click knob 0..3 | on release, toggle page 0/1 |
| Click knob 5 | on release, toggle page if held < 1.25 s. While held > 1.25 s the gain LED shows battery: white full, green high, yellow medium, red low (NormalPage.h:377-402, 550-563) |
| Click knob 4 | press: tap tempo (section 5.3). Release: send CC 24 with current tempo value |

#### Keys

| Control | Action |
|---|---|
| Note key press | START voice (velocity 1.0), MIDI note on (section 7) (NormalPage.h:642-657) |
| Note key release | STOP voice, MIDI note off; if recording, append a step with this note (NormalPage.h:659-676). Only if the press was handled here (`key_note_on_`), so presses eaten by the shift menu don't record or stop anything |
| Play | press toggles sequencer play/stop (Sequencer.h:106-116, 247-257) |
| Loop | on release toggles record arm, unless a long-press action fired (Sequencer.h:118-130). Press/release also send CC 15 127/0 (NormalPage.h:614-620) |
| Hold loop > 1.25 s (play not held, sequence not empty) | delete last step; repeats every 1.25 s while held (Sequencer.h:141-146) |
| Hold play + loop > 1.25 s (sequence not empty) | clear whole sequence, stop, record off, rainbow on play/loop LEDs for 1 s (Sequencer.h:134-140) |
| CHOMPI key, switch DOWN | opens shift menu (section 3.2) |
| CHOMPI key, switch UP | sends CC 14 127/0. Press while recording: append a rest step. Press while not recording: mute sequencer (new steps don't sound) until release (NormalPage.h:622-639) |
| Flip switch to DOWN | releases mute (NormalPage.h:794-800) |

The 1.25 s holds are checked from NormalPage `Draw()`, timed from the latest press of play or loop.

### 3.2 Shift menu (MenuPage.h)

Opens on the CHOMPI key's press edge when the switch is DOWN and no boot/rainbow/test page is open (ui.h:229-238). Closes automatically when `IsClosable()` (MenuPage.h:943-957): CHOMPI released and no preset operation pending, or 1.25 s after a save/copy/erase confirm (even if still held). The menu page consumes most events; play and loop presses do nothing while it is open (MenuPage.h:862-918 treat them as "slot 16").

On open: copies fine pitch into the semitone accumulator, clears reset flags, preset mode NONE (MenuPage.h:923-939).

#### Knobs while shift held (MenuPage.h:368-470)

The page of each knob is whatever it was set to in normal play. Turns here send no CC. Turns are ignored while a preset mode other than NONE is active.

| Knob | Page | Function | Step | Range / default |
|---|---|---|---|---|
| 0 | 0 | semitone pitch: accumulator += .01/detent, then `semis = round((acc-.5)*24)`, pitch = semis/24 + .5 | ~4 detents per semitone | ±12 semitones |
| 0 | 1 | wavetable (file) select, relative, 2 detents per table | | 0..(tables-1), clamped |
| 1 | 0 | coarse attack | .09 | 0..1 |
| 1 | 1 | pitch LFO rate | .03 | 0..1, default .58 |
| 2 | 0 | coarse release | .09 | 0..1 |
| 2 | 1 | filter LFO rate | .03 | 0..1, default .58 |
| 3 | 0 | delay time (also sets reverb time) | .03 | 0..1, default .4 |
| 3 | 1 | filter resonance | .03 | 0..1, default .63 |
| 4 | | sequencer clock division (section 5.3) | 1 count | default 12 |
| 5 | | output compression/saturation ("final comp") | .03 | 0..1, default 0 |

#### Knob clicks while shift held (reset to default, LED white while held) (MenuPage.h:588-698)

| Click | Page 0 | Page 1 |
|---|---|---|
| Knob 0 | pitch = .5 | frame = 0 |
| Knob 1 | attack = 0 | pitch LFO depth = 0, pitch LFO rate = .58 |
| Knob 2 | release = 0 | filter LFO depth = 0, filter LFO rate = .58 |
| Knob 3 | both pages: FX = .5, cutoff = .5, resonance = .63, delay time = .4 | same |
| Knob 4 | division = 12, T = 320 | |
| Knob 5 | gain = .84 (page 0) or pan = .5 (page 1); final comp = 0 | |

Knob clicks in the menu don't toggle pages (the release is consumed). The knob 3 case falls through into the SW_TOG case (missing `break`, MenuPage.h:681-701); harmless.

#### Keys while shift held

| Key | Action (on press) | Ref |
|---|---|---|
| KEY_16 (low C#) | octave −1 (offset clamped −1..+1) | MenuPage.h:747-761 |
| KEY_17 (low D#) | octave +1 | |
| KEY_18 (F#) | sequencer gate 10% | MenuPage.h:763-778 |
| KEY_19 (G#) | gate 50% (default) | |
| KEY_20 (A#) | gate 100% | |
| KEY_21 (high C#) | toggle pitch LFO on/off | MenuPage.h:781-787 |
| KEY_22 (high D#) | toggle filter LFO on/off | MenuPage.h:788-795 |
| KEY_23 (F#) | erase mode on/off | MenuPage.h:798-815 |
| KEY_24 (G#) | copy mode on/off | MenuPage.h:817-839 |
| KEY_25 (A#) | save mode on/off | MenuPage.h:841-859 |
| White KEY_n | preset slot n (1..15); slot 15 = defaults | MenuPage.h:961-979 |
| CHOMPI press | confirm pending save/copy/erase | MenuPage.h:703-745 |

With no SD card the octave and preset keys do nothing. Key releases in the menu pass through to NormalPage so held notes stop normally.

#### Presets (MenuPage.h:472-565, 703-918)

- Mode NONE: tap a white key whose slot is valid, or slot 15: load it now.
- Save: tap SAVE, tap a slot 1..14 (any, valid or empty), press CHOMPI (usually release and press again). Stops all voices, stores current values into the slot, marks it valid, loads it.
- Copy: tap COPY, tap a valid source slot, tap a destination 1..14 (not the source), press CHOMPI. Copies values and validity, loads the destination.
- Erase: tap ERASE, tap a valid slot 1..14, press CHOMPI. Marks it empty, loads slot 15.
- Tap the same mode key again to cancel.
- Copy to play/loop ("slot 16") is a TAPE leftover: it writes past the end of the slot array (PresetManager.h:248-273, `slotValues[15]` has 15 rows). Don't port.

What a slot stores (MenuPage.h:472-490): see section 6.2. Loading (MenuPage.h:492-565) sets all of those and pushes them to the engine. Loading slot 15 or an empty slot sets: pitch .5, attack 0, release 0, frame 0, table 0, pitch/filter LFO depth 0, FX .5, cutoff .5, resonance .63, delay time .4, both LFO rates .58, both LFOs ON. Loading never changes gain, pan, final comp, tempo, division, octave or gate.

Preset storage to SD happens later (section 6.2).

### 3.3 No SD card (chompi_main.cpp:140-179, NoSDPage.h, MenuPage.h)

Checked every 1 s after boot. If the card is gone: all LEDs blink red (400 ms) for 3 s, then normal play continues; in the shift menu the white keys show red and preset/octave keys do nothing. A reboot is needed to recover.

### 3.4 Test mode (TestPage.h)

Factory QC page (boot with gain knob held). Lights each control when touched, toggle switch outputs a 100 Hz sine at amp .2 to all outputs (chompi_main.cpp:112-117, 379-380). Not needed for the port.

### 3.5 Low battery (hardware.h:264-318)

Unplugged + low battery: 15 s of amber flashing on panel LEDs, then shipping mode. Low battery on a weak USB source: sleep loop. Not needed for the port.

---

## 4. Synth engine (subtractiveEngine.h, WavetableManager.h)

8 voices, each: wavetable oscillator → amp envelope and velocity → per-voice DJ filter. Voices summed, then a global FX chain. Everything is mono until the delay.

### 4.1 Pitch

`keyToFrequency(nn)` (subtractiveEngine.h:704-717):

```
freq = 440 * 2^((nn + 36 - 57 + 12*octave)/12) * 2^((pitch - .5)*2)
```

- `nn` = key's MIDI note − 60 (panel and MIDI in), integer, −12..+12 for panel keys, −24..+24 for MIDI in.
- So nn 0 (KEY_8, MIDI note 60) sounds C3 = 130.81 Hz at pitch .5 and octave 0. Sounding pitch is one octave below the MIDI note number it sends.
- `pitch` = knob 0 page 0 (0..1, ±1 octave, continuous; semitone steps when set from the shift menu).
- `octave` = −1, 0, +1 (shift + KEY_16/KEY_17).
- Changing pitch or octave retunes all voices immediately, including held and releasing notes (subtractiveEngine.h:346-366).
- No glide/portamento, no detune, no unison.

### 4.2 Wavetable oscillator (WavetableManager.h:22-138)

- Table memory: `float wavetableMemory[256][2048]` in SDRAM (chompi_main.cpp:57). Table t occupies rows t*33 .. t*33+32. Max 7 tables (WavetableManager.h:192).
- Each table = 33 frames ("cycles") of 2048 samples.
- Phase accumulator in samples: `inc = freq*2048/sr`, `phase += inc; if phase > 2048: phase -= 2048` (WavetableManager.h:64-67, 73-75). Phase is not reset on note start (free-running per voice).
- Read: linear interpolation between sample `idx` and `idx+1 mod 2048` of the current frame (WavetableManager.h:37-46). No band-limiting or mipmaps, so high notes alias.
- Frame and table changes are discrete. Each change starts a 960-sample (20 ms) linear crossfade from the old frame/table to the new one, both read at the same phase (WavetableManager.h:48-58, 137).
- Retarget rule: if a change arrives while a fade is under 50% done, the fade keeps its old source and position and only the destination changes; at 50% or more the fade restarts from 0 with the current frame as source (WavetableManager.h:77-125).
- Frame select (all voices together): relative ±1 clamped 0..32, or absolute (presets, CC; out-of-range absolute → 0) (WavetableManager.h:91-105).
- Table select: relative, ignored if it would go out of range; absolute out-of-range → table 0 (WavetableManager.h:223-241). The current frame number is kept when switching tables.
- With fewer than 7 files, unused table rows are zeros. A failed load is zeroed (silent) (WavetableManager.h:208-221).
- There is no continuous morph between frames and no wavetable position modulation.

### 4.3 Voice (subtractiveEngine.h:76-141)

Per sample:

```
wt.freq = voice.freq * pitch_lfo_mult
s  = wt.sample() * 0.2 * velocity * amp_env(gate)
filter control = cutoff + filter_lfo_val
(l, r) = DJFilter(s, s)      # same signal both sides
mix += (l, r)
```

After all 8 voices: `out = mix / 8` (subtractiveEngine.h:236-243). All 8 voices are always processed.

Velocity = `vel * 0.00787401` (= vel/127). Panel keys and the sequencer use 127 (1.0). MIDI in uses `data+1`, so 1..128 → .0079..1.0079 (MidiManager.h:74-75).

### 4.4 Amp envelope (DaisySP Adsr, Control/adsr.cpp)

Sustain fixed at 1 (subtractiveEngine.h:87), so it is attack + release. Decay is irrelevant.

- Attack: `setAttack(v)`: if v < .008 use .001; time = v*5 s (5 ms .. 5 s). Shape 1.0 (subtractiveEngine.h:372-382). Adsr shape 1 gives target `9*1^10 + .3 + 1.01 = 10.31`; per sample `x += d*(10.31 - x)`, `d = 1 - exp(ln(1 - 1/10.31)/(time*sr))`; stops at 1. Nearly linear rise reaching 1 at `time`.
- Release: `setRelease(v)`: if v < .008 use .005; time constant = v seconds (0.005 .. 1 s) (subtractiveEngine.h:384-392). Per sample `x += c*(−0.01 − x)`, `c = 1 − exp(−1/(time*sr))`; goes idle when x < 0, i.e. after time*ln(101) ≈ 4.6*time.
- Gate rise during release restarts the attack from the current level (no reset to 0).
- `IsRunning` (used for key LEDs) = not idle.

### 4.5 Voice allocation (subtractiveEngine.h:599-702)

Each voice has `key` (button ID or MIDI-derived ID), `prioroty` (0 = most recent), `activeFromUser`, `activeFromSequencer`, `gate`.

START(key):
1. If a voice already has this key: set gate, velocity, mark source active, make it most recent. Frequency is not recomputed.
2. Else pick the voice with gate off and the highest priority number (oldest). Its release tail may still be sounding; it is cut. If every gate is on, steal the voice whose priority == 8 (oldest). Assign freq, key, velocity, nn, gate on, priority 0; all other voices' priority +1.

STOP(key, source): clear that source's flag on the voice with this key; gate off only when neither user nor sequencer holds it.

Bug: priorities start 1..8 and in step 2 all others are incremented, so values can drift above 8; then "priority == 8" may match nothing and a note is dropped when all 8 gates are on. Reimplement as plain oldest-first stealing.

### 4.6 LFOs (subtractiveEngine.h:162-173, 231-234, 396-402, 520-527)

Two global free-running triangle LFOs (DaisySP Oscillator WAVE_TRI: +1 at phase 0, −1 at half cycle, linear between). Not retriggered by notes.

| | Filter LFO | Pitch LFO |
|---|---|---|
| Depth | knob 2 page 1 (0..1) = amplitude | knob 1 page 1 (0..1) = amplitude |
| Rate | shift + knob 2 page 1 | shift + knob 1 page 1 |
| Rate map | `Hz = .14 * (65.41/.14)^v` = .14 .. 65.41 Hz | same |
| Default rate | .58 → 4.95 Hz | .58 → 4.95 Hz |
| Destination | added to every voice's filter control | `mult = 2^(lfo*2/12)`, ±2 semitones at full depth, applied per sample |
| On/off | shift + KEY_22 | shift + KEY_21 |
| Start phase | 0 | +.25 cycle |

When an LFO is off its output is 0 (filter) or 1 (pitch) and its phase stops advancing. Both default on.

Because the DJ filter slews its control at k = .0002 (~104 ms), filter LFO rates above a couple of Hz are strongly smoothed in amplitude.

### 4.7 DJ filter (per voice) (DJFilter.h, BasicMMF.h)

One knob: low-pass below .5, high-pass above. Two cascaded 2-pole "BasicMMF" filters per channel: LP then HP.

BasicMMF (BasicMMF.h:34-45, 74), coefficient `f` 0..1 (not Hz), resonance `q`:

```
fb   = q + q/(1 - f)
b0  += f*(in - b0 + fb*(b0 - b1))
b1  += f*(b0 - b1)
LP = b1 ; HP = in - b0
```

Control mapping (DJFilter.h:66-74), c = cutoff + filter LFO:

```
lp_target = clamp(.01 + 2c, 0, .98)^3
hp_target = clamp(1.9c - 1, 0, .9)^3
```

Both slewed per sample with fonepole k = .0002 (DJFilter.h:40-41). Rough corner (one-pole estimate `-ln(1-f)*sr/2π`):

| c | LP f | ≈ LP Hz | HP f | ≈ HP Hz |
|---|---|---|---|---|
| 0 | 1e-6 | 0 (silent) | 0 | |
| .1 | .0093 | 71 | 0 | |
| .2 | .069 | 545 | 0 | |
| .3 | .227 | 1970 | 0 | |
| .4 | .531 | 5790 | 0 | |
| .5 | .941 | open | 0 | |
| .6 | .941 | open | .0027 | 21 |
| .7 | | | .036 | 280 |
| .8 | | | .141 | 1160 |
| .9 | | | .358 | 3380 |
| 1 | | | .729 | 9970 |

Resonance: `setMasterResonance(v)`: clamp 0..0.99, then `q = v*.95` on all four stages (subtractiveEngine.h:536-542, DJFilter.h:77-86). Default .63 → q .5985. There is a branch that rescales HP resonance when `hp > .8` (DJFilter.h:49-54); in WAVE hp tops out at .729 so it never runs (dead code; reachable in TAPE).

### 4.8 FX chain (subtractiveEngine.h:224-344)

Order: voice sum → DC block → delay → reverb → gain → compressor → saturation → makeup → (VU meter tap) → pan → outputs.

#### DC block (DaisySP dcblock.cpp)

`y = x − x1 + .99*y1`, per channel.

#### Delay (subtractiveEngine.h:306-333, 544-565, InterpolatedDelayLine.h)

Stereo line of 96256 frames of int16 pairs (~2.0 s) (subtractiveEngine.h:19). Values are clamped to ±1 when stored (f2s16) and scaled by 1/32767 when read.

Parameters from FX knob v (`setDelayFeedback`):

```
if v < .5: a = 1 - 2v       # 1 at full left, 0 at centre
           fb = .9a ; amount = 1.3*ln(a+1) ; reverb_amount = 0
else:      a = 2(v - .5)
           reverb_amount = 1.3*ln(a+1) ; fb = 0 ; amount = 0
```

Delay time from shift + knob 3 page 0, d (`setDelayTime`):

```
delay_samples = .99 * d^3 * 96256 + 450      # 9.4 ms .. 1995 ms, default .4 → 136 ms
reverb_time   = clamp(d, .05, .97)
```

All four (amount, fb, reverb amount, delay time) are slewed with fonepole k = .001 per sample. Slewing the delay time gives a pitch-bend on changes.

Per sample:

```
vol   = fb < .2 ? fb*5 : 1
tapL  = line.L[delay] * vol      # linear interpolation
tapR  = line.R[delay] * vol
write  line.L = (inL + inR)/2 + tapR * fb^0.7
write  line.R = tapL
wet = amount > .25 ? .5 : 2*amount
dry = amount > .83 ? .5 : 1 - .6*amount
outL = inL*dry + tapL*wet ; outR = inR*dry + tapR*wet
```

So it is a ping-pong: the left tap is at `delay`, the right tap at `2*delay`, feedback from the right tap back into the left line. At FX = .5 the delay keeps running but is silent (vol 0).

#### Reverb (reverb.h, fx_engine.h; identical to TAPE)

Mutable Instruments Rings/Clouds Griesinger reverb, 32768-word 16-bit delay memory. Per sample WAVE sets (subtractiveEngine.h:335-343), with ra = slewed reverb amount, rt = slewed reverb time:

```
amount    = ra^2 * .8          # 0 .. .65
time      = rt                 # loop gain
lowpass   = ra*.6 + .4
diffusion = ra*.6
input gain = .3 (fixed, subtractiveEngine.h:193)
```

Algorithm (reverb.h:49-133). Delay lengths: ap1 150, ap2 214, ap3 319, ap4 527, dap1a 2182, dap1b 2690, del1 4501, dap2a 2525, dap2b 2197, del2 6312. LFO1 0.5 Hz, LFO2 0.3 Hz (cosine). kap = diffusion, klp = lowpass, krt = time.

```
acc = (L + R) * .3
for ap in ap1..ap4:  t = ap.tail; acc += kap*t; ap.write(acc); acc = -kap*acc + t
apout = acc

acc = apout + krt * del2.read(6261 + 50*cos(LFO2))      # interpolated
lp1 += klp*(acc - lp1); acc = lp1
t = dap1a.tail; acc += -kap*t; dap1a.write(acc); acc = kap*acc + t
t = dap1b.tail; acc +=  kap*t; dap1b.write(acc); acc = -kap*acc + t
del1.write(acc); wetL = 2*acc
L += (wetL - L) * amount

acc = apout + krt * del1.read(4460 + 40*cos(LFO1))
lp2 += klp*(acc - lp2); acc = lp2
t = dap2a.tail; acc +=  kap*t; dap2a.write(acc); acc = -kap*acc + t
t = dap2b.tail; acc += -kap*t; dap2b.write(acc); acc = kap*acc + t
del2.write(acc); wetR = 2*acc
R += (wetR - R) * amount
```

Memory is stored as int16 (clips at ±1). The LFO phases also advance once per 32 samples in `Start()` (fx_engine.h:393-405), so actual rates are about 3% above the nominal 0.5/0.3 Hz.

#### Gain, compressor, saturation (subtractiveEngine.h:251-281, 430-486, limiter.h:73-81)

Gain: `out *= gain` (knob 5 page 0, linear 0..1, slewed k .001).

"Final comp" knob x (shift + knob 5), `setFinalComp`:

```
if x < .5:  L = 1.4x ; sat = 1 ; makeup = 1
else:       L = .7
            sat = 100*ln(3.4(x - .5) + 1) + 1     # 1 .. 100.3
            makeup = step table on sat:
              <5 .25, <15 .13, <24 .085, <30 .072, <40 .065, <52 .058,
              <60 .05, <70 .046, <80 .044, <85 .042, else .04
```

L, sat and makeup are slewed with k .001.

Compressor (`ProcessComp`, per channel, own state):

```
thresh  = 1/(10L + 4)       # .25 at L=0
ratio   = 1 + 7L^2
mk      = .9 + .6L
pregain = 7L + 1
pre  = in * pregain
peak: if |pre| > peak: peak += .05*(|pre| - peak) else peak += .0002*(|pre| - peak)
g    = peak <= thresh ? 1 : 1/(ratio*(1 + (peak - thresh)))
gs:  if g > gs: gs += .001*(g - gs) else gs += .005*(g - gs)
out  = SoftLimit(pre * gs * mk)
```

Then `out = SoftClip(sat*out) * makeup`.

`SoftLimit(x) = x(27 + x^2)/(27 + 9x^2)`; `SoftClip(x)` = −1 below −3, +1 above 3, else SoftLimit (DaisySP dsp.h:220-234).

The compressor and saturation also run on out[2]/out[3] (line outs) using stale data from the previous block, and the result is then overwritten by the copy below (subtractiveEngine.h:267-278, 291-292). Ignore.

#### VU meter (EnvFollower.h)

`e = |L+R|` clamped 0..1; `y = e > y ? .5y + .5e : .9993y + .0007e`; display `min(5y, 1)`. Drives the gain knob LED only.

#### Pan (subtractiveEngine.h:284-293)

```
L *= (1 - pan)*2 ; R *= pan*2        # pan slewed k .001
out3 = L ; out4 = R
```

At centre each side is unity; at the ends one side is ×2.

### 4.9 Gain staging summary

One full-scale voice reaches the FX at about `.9 (table peak) * .2 / 8 = .0225`. The compressor at final comp 0 still has threshold .25 and makeup .9, so normal levels pass nearly untouched. Expect the port to need its own output level trim; keep the formulas as given and add a fixed gain at the end if needed.

---

## 5. Sequencer and clock

### 5.1 Sequencer (Sequencer.h)

- Monophonic step list, max 32 steps (Sequencer.h:12). Each step is a note (key ID + nn) or a rest.
- Recording is armed with the loop key and works whether playing or stopped. Steps are appended at the end on note-key release (NormalPage.h:670-673). Rests with the CHOMPI key (switch UP). MIDI-in notes are not recorded.
- Full: further appends ignored, loop LED blinks red 4 times (125 ms) over 1 s (NormalPage.h:449-457).
- Delete last step (hold loop) and clear all (hold play + loop), see 3.1.
- Playback (checkAndPop, Sequencer.h:178-238), checked once per audio block with 1 ms timing:
  - On start: play step 0 now and start the step timer.
  - Each step interval: STOP the current step's note (unless it was muted at its start or already cut by gate), advance (wrap), START the next step's note unless muted or a rest. Alternate the transport LEDs.
  - Gate: if gate < 1, STOP the note once `elapsed > interval*gate`. Gate 10/50/100%, default 50% (Sequencer.h:170). At 100% the note is held until the next step (STOP then START one block apart, so it retriggers the attack from the current level).
  - Sequencer notes use velocity 1.0 and source SEQUENCER, so they don't cut a key the user is holding and vice versa.
  - Octave and pitch changes apply live to sequenced notes.
- Stop: MIDI Stop, STOP current step note, note-off for last sent note, index back to 0 (Sequencer.h:91-100).
- Mute (CHOMPI held, switch UP, not recording): steps that start while muted are silent and send no MIDI.
- No swing, no step editing, no per-step velocity, no external sync. Sequence is not saved.

### 5.2 Tempo

Internal tempo value T, 160..480, default 320 (clockManager.h:43-52). Step length:

```
step_ms = (60000 / T) * (div / 12)
```

MIDI clock out rate = `T*12/60` Hz (clockManager.h:77-88). The firmware comment calls this 12 PPQN (chompi_main.cpp:194-195). A normal 24 PPQN receiver therefore follows at BPM = T/2 (80..240, default 160), and step lengths in those terms are:

| div | knob position | step at BPM = T/2 | Transport LEDs in shift menu (5 / 6) |
|---|---|---|---|
| 24 | 0 | quarter | med blue / off |
| 18 | 1 | dotted eighth | green / off |
| 12 | 2 (default) | eighth | dim white / dim white |
| 8 | 3 | eighth triplet | off / yellow |
| 6 | 4 | sixteenth | off / red |

(clockManager.h:29-35.) A tempo change applies immediately, including to the step in progress.

### 5.3 Division knob and tap tempo

- Division (shift + knob 4, clockManager.h:95-121): a counter 0..60 starts at 30; each division owns a 12-count band. Crossing out of the band moves one division and recentres the counter in the new band, so about 7 detents per change. The change waits until the next step boundary (clockManager.h:54-64).
- Tap (press knob 4, clockManager.h:138-153): if the previous tap was ≤ 750 ms ago, `T = 120000/interval_ms` clamped 160..480 (one tap interval = one quarter at T/2 BPM). Slower taps only restart the timer.
- Shift + click knob 4: division 12 and T 320.

---

## 6. Files

### 6.1 options.json (OptionsManager.h)

Read at boot, then always rewritten in the normalised form below (OptionsManager.h:33-57, 62-110).

```json
{
	"chompi": [
		{ "name": "Midi In Channel",  "value": 1 },
		{ "name": "Midi Out Channel", "value": 1 },
		{ "name": "MIDI Clock Out",   "value": true },
		{ "name": "MIDI CC In",       "value": true },
		{ "name": "MIDI CC Out",      "value": true }
	]
}
```

| Name (exact string) | Type | Range | Default | Effect |
|---|---|---|---|---|
| Midi In Channel | int | 1..16 | 1 | channel for incoming notes and CCs; everything else on other channels is ignored |
| Midi Out Channel | int | 1..16 | 1 | channel for all notes and CCs sent |
| MIDI Clock Out | bool | | true | send 0xF8 while the sequencer plays |
| MIDI CC In | bool | | true | accept CCs |
| MIDI CC Out | bool | | true | send CCs |

Lookup is by `name`, up to 9 entries (OptionsManager.h:117-131). Booleans are only turned off by the literal `false`. Out-of-range channels are ignored. Buffer 4096 bytes.

### 6.2 presets.json (PresetManager.h)

A JSON array of 14 slot arrays followed by the version number 3 (PresetManager.h:62-107):

```
[[v0,v1,...,v13,valid], ... 14 times ..., 3]
```

Each slot (MenuPage.h:472-490):

| Index | Meaning | Stored as | Range | Slot-15 default |
|---|---|---|---|---|
| 0 | pitch (knob 0 p0) | int(x*1000) | 0..1000, 500 = no shift | 500 |
| 1 | wavetable frame | int | 0..32 | 0 |
| 2 | wavetable file index | int | 0..6 (sorted file order) | 0 |
| 3 | attack | x*1000 | 0..1000 | 0 |
| 4 | pitch LFO depth | x*1000 | 0..1000 | 0 |
| 5 | release | x*1000 | 0..1000 | 0 |
| 6 | filter LFO depth | x*1000 | 0..1000 | 0 |
| 7 | filter cutoff (knob 3 p1) | x*1000 | 0..1000 | 500 |
| 8 | pitch LFO rate | x*1000 | 0..1000 | 580 |
| 9 | delay/reverb knob (knob 3 p0) | x*1000 | 0..1000 | 500 |
| 10 | resonance | x*1000 | 0..1000 | 630 |
| 11 | filter LFO rate | x*1000 | 0..1000 | 580 |
| 12 | delay time | x*1000 | 0..1000 | 400 |
| 13 | LFO on bits | int | bit0 pitch, bit1 filter | 3 |
| 14 | valid | bool | | |

Notes:

- Slots are 1..14 on white keys KEY_1..KEY_14. Slot 15 (KEY_15) is built-in defaults, never stored.
- Floats are written truncated (`int(x*1000)`). Pitch is read back as `nextafterf(v*.001, -inf)`, a hair below, so semitone rounding stays stable (PresetManager.h:166-169).
- Empty slots are still written, with filler values `[500,0,0,0,0,1000,1000,0,500,0,0,0,0,0,false]` from ui.h:275-277. They are never loaded.
- Version check: it looks up `[2]` and falls back to a 7-control "V1" layout if missing (PresetManager.h:126-134). With 14 slots `[2]` always exists, so in practice 14 controls are always read.
- Presets remember the table by index, so renaming/reordering wav files changes presets (README).
- Not stored: gain, pan, final comp, tempo, division, octave, gate, sequence.
- Saving: an edit sets a dirty flag. Every 5 s the main loop serialises to a 4096-byte buffer; the SD callback then writes `presets_temp.json` in 1024-byte chunks every 50 ms, deletes `presets.json` and renames the temp file (ui.h:312-373).
- At boot the file is parsed and rewritten in normalised form. A missing or invalid file becomes 14 empty slots (ui.h:272-302).

Factory `presets.json` in card-profiles/wave-1.0 has all 14 slots valid, both LFOs on.

### 6.3 SD card layout

| File | Purpose |
|---|---|
| `CHOMPI.bin` (any one .bin) | firmware, flashed by the bootloader (firmware/README.md) |
| `*.wav` in root | wavetables, first 7 in sorted order |
| `options.json` | section 6.1 |
| `presets.json` | section 6.2 |
| `presets_temp.json` | transient during save |
| `.batt_log.txt`, `._.batt_log.txt` | deleted at boot |
| `test_file.txt` | transient, test mode only |

Wavetable rules (WavetableManager.h:155-190, FileStreamingManager.cpp:177-194):

- Files in the root whose name contains `.wav` (substring match) and doesn't start with `.`, sorted by `std::sort` on the name (byte order, case-sensitive). First 7 are loaded, into table index 0..6.
- The header is not parsed. The loader seeks to byte 136 and reads 270336 bytes = 33 × 2048 little-endian 32-bit floats, mono.
- Short files fail the read and the table is silent. Files with more frames load only the first 33. A WAV whose data doesn't start at byte 136 loads misaligned garbage.
- Factory files (wavetable01..07.wav, identical in card-profiles/wave-1.0 and chompi-wave/wavetables): 270472 bytes; chunks `JUNK` (28 bytes), `fmt ` (IEEE float, 1 ch, 44100 Hz, 32 bit), `clm ` (48 bytes, text `<!>2048 11000000 wavetable (CHOMPI WAVE)`, the Serum marker), `data` at offset 128 with samples from 136, 270336 bytes = 67584 floats = 33 frames of 2048. Peaks ±0.9. The 44100 Hz rate is irrelevant (single-cycle frames).
- At least one `.wav` is required or boot never finishes.

---

## 7. MIDI (MidiManager.h, hardware.h:459-490, NormalPage.h, Sequencer.h)

TRS and USB are merged on input and both get every output message (MidiManager.h:146-213, 291-307).

### In

Only messages on the input channel are handled (MidiManager.h:59-61). Incoming clock, start/stop, pitch bend, aftertouch, program change are ignored.

| Message | Effect |
|---|---|
| Note on 36..84 | START voice, nn = note − 60, velocity (v+1)/127, key ID from `midi2key` (ui.h:33-41): notes 48..72 share the panel key IDs (so their key LEDs light and a MIDI note and the same panel key share a voice), others get IDs 40..63 (MidiManager.h:68-78) |
| Note on velocity 0 | note off (libDaisy midi_parser.cpp:143-147) |
| Note off 36..84 | STOP (source USER) |
| Notes outside 36..84 | ignored |
| CC 20, 21, 22, 23, 25 | set knob 0, 1, 2, 3, 5 on its CURRENT page to value/127 (MidiManager.h:103-111). Knob 0 page 1: frame = floor(v*32) |
| CC 24 | ignored (tempo) |
| CC 14 | CHOMPI key press (>84) / release (<42), 42..84 dead zone; ignored when switch is DOWN (MidiManager.h:112-138) |
| CC 15 | loop key press/release, same thresholds |

CC in is ignored while the shift menu is open or when "MIDI CC In" is false. CCs received are not echoed. Note: CC out uses 26..30 for page 1, but CC in only listens to 20..25 and writes whichever page is showing.

MIDI-in notes don't send MIDI out and aren't recorded by the sequencer.

### Out (output channel)

| Message | When |
|---|---|
| Note on, vel 127 | panel key press: note = key's MIDI note + 12*octave (clamped 0..127) (NormalPage.h:652-655) |
| Note off (TRS vel 0, USB vel 127) | panel key release, same note |
| Note on / off | sequencer steps: note = nn + 60 + 12*octave (Sequencer.h:186-191) |
| CC 20..25 (page 0), 26, 27, 28, 29, 30 (page 1: knobs 0, 1, 2, 3, 5) | physical knob turn in normal play, value int(x*127) (NormalPage.h:17-20, 759-764) |
| CC 24 | knob 4 turn, and on release of knob 4 click |
| CC 14 127/0 | CHOMPI key press/release, switch UP only |
| CC 15 127/0 | loop key press/release (also when triggered by CC 15 in) |
| Start 0xFA | sequencer play |
| Stop 0xFC | sequencer stop or clear |
| Clock 0xF8 | while playing and "MIDI Clock Out" on, at T*12/60 Hz from a hardware timer (chompi_main.cpp:196-221). Free-running; not phase-locked to the ms step timer |

CC out is suppressed when "MIDI CC Out" is false. Shift-menu turns send nothing.

---

## 8. LEDs (brief)

Normal play (NormalPage.h:224-513):

| LED | Shows |
|---|---|
| Key LEDs | white while that key's voice envelope is running (panel, sequencer and MIDI 48..72) |
| Pitch knob | p0: blue → green → yellow → red by value. p1: blue → pink → red by frame |
| Attack knob | p0: yellow → orange. p1: dim → full purple by pitch LFO depth |
| Release knob | p0: orange → red. p1: dim → full purple by filter LFO depth |
| FX knob | p0: green → teal → blue. p1: purple → pink → white |
| Transport LEDs (5, 6) | colour by tempo (blue → green → yellow → red); while playing one of the pair goes dark, alternating each step |
| Gain knob | p0: VU meter colour (dim → green → yellow → pink) scaled by gain. p1: blue → red by pan. Battery colour when held |
| Play | teal playing, 10% teal if a sequence exists |
| Loop | red when recording; blink on full; 200 ms flash on delete-last-step; rainbow 1 s on clear-all |
| CHOMPI | white when held (switch UP), purple when held (switch DOWN) |

Shift menu (MenuPage.h:70-365): CHOMPI purple, blinking red when a slot is chosen for save/copy/erase, blinking white while confirming. Knob LEDs: FX shows delay time or resonance as white brightness, attack/release show the env colour (p0) or LFO rate as white brightness (p1), gain shows final comp as blue brightness, pitch shows pitch colour (p0) or table index teal → blue → green (p1). Transport pair shows division colour (table in 5.2), white while knob 4 clicked. Keys: slots purple if valid, KEY_15 pink, current slot white; in a select mode valid slots blink dim purple, empty slots dim white (save/copy dest), chosen slot blue/red/green. KEY_16 or KEY_17 orange for octave −1/+1. KEY_18/19/20 yellow for current gate. KEY_21/22 yellow when that LFO is on. KEY_23 red, KEY_24 green, KEY_25 blue when that mode is available.

---

## 9. Signal flow

```
 panel keys ─┐
 MIDI in  ───┼─> KeyRequest FIFO (1 per 0.5 ms) ─> voice allocator (8 voices)
 sequencer ──┘

 per voice:
   wavetable osc (2048-sample frame, linear interp, 20 ms frame/table xfade)
     freq = keyToFrequency(nn) * 2^(pitchLFO*2/12)
   * 0.2 * velocity * AR env (sustain 1)
   -> DJ filter: [2-pole LP] -> [2-pole HP], control = cutoff + filterLFO, slew .0002
   -> (same signal L and R)

 sum / 8  (stereo, but identical L/R)
   -> DC block (.99)
   -> ping-pong delay (int16, 9 ms..2 s, fb .9 max, wet/dry curve)
   -> Griesinger reverb (amount ra^2*.8, time = delay-time knob)
   -> * gain
   -> peak compressor (L from final comp) -> SoftLimit
   -> SoftClip(sat * x) * makeup
   -> [VU follower tap]
   -> pan (x2 law)
   -> headphone L/R  ==  master L/R
```

---

## 10. Hard to reproduce in SuperCollider

| Part | Issue | Suggestion |
|---|---|---|
| Wavetable oscillator | 33 discrete 2048-sample frames, linear interp, non-band-limited, frame changes crossfade 20 ms with a retarget rule | Load each wav as one buffer of 67584 floats (skip 136 bytes, or `Buffer.readChannel` after fixing the header). Read with `BufRd.ar(1, buf, Phasor.ar(0, freq*2048/sr, 0, 2048) + frame*2048, 0, 2)`; note BufRd interpolation 2 is linear but wraps across frame edges, so wrap the +1 sample yourself (`idx+1 mod 2048`) or add a guard sample. For the crossfade use two readers (old/new frame or buffer) and an `EnvGen`/`Line` 0→1 over 960 samples triggered on change. `VOsc` needs Wavetable-format buffers and morphs continuously between frames, which sounds different from WAVE's stepped frames; usable as an approximation with `Lag` on the index. `Osc` is also non-band-limited, so aliasing will be similar. |
| DJ filter | Kellett-style 2-pole with `fb = q + q/(1-f)`, cascaded LP→HP, cube mapping, per-sample slew | Linear, so it can be done exactly with `SOS.ar` (audio-rate coefficients). Derived from BasicMMF.h (verify by impulse test): with `c2 = (1-f)(1-f+f*fb)` and `b1 = 2 - 2f + f*fb*(1-f)`, LP: `a0 = f^2, a1 = 0, a2 = 0, b1, b2 = -c2`; HP: `a0 = 1-f, a1 = -(1-f)(2-f+f*fb), a2 = c2, b1, b2 = -c2`. Smooth `f` with `OnePole.ar(target, 1-.0002)`. Approximations: `RLPF`/`RHPF` driven by the Hz table in 4.7. |
| Per-voice filter control slew | k = .0002 per sample attenuates fast filter LFO | `OnePole.ar(ctl, 0.9998)` inside the voice SynthDef |
| Envelope | DaisySP Adsr curves | `Env.new([0,1,0],[atk, 4.615*rel],[-0.102, -4.615], releaseNode: 1)` with atk and rel from 4.4 (curve −0.102 matches the 10.31 overshoot target, −4.615 = ln(101) matches the −0.01 release target). EnvGen restarts from the current level like Adsr |
| Delay | int16 clipping in the loop, cross-fed ping-pong, slewed time | Two `DelayL` (or `BufDelayL`) with `LocalIn/LocalOut`; min delay 450 samples so block latency is fine at 64-sample blocks but subtract `ControlDur` for accuracy. `.clip2(1)` before writing. Slew time with `OnePole.ar(t, 0.999)` |
| Reverb | MI Rings/Clouds reverb with 16-bit memory | mi-UGens `MiVerb` is the same Clouds/Rings reverb family (check parameter mapping). Or build the topology from 4.8 with `LocalIn`, `DelayC`, and manual allpass blocks (loop delays ≥ 2182 samples, so block feedback is fine) |
| Compressor | peak follower with asymmetric per-sample slew, gain slew | `Amplitude.ar(x, attackTime, releaseTime)` approximates the peak follower (.05 → ~0.4 ms, .0002 → ~104 ms); gain slew with `LagUD.ar` (up ~20.8 ms, down ~4.2 ms). The gain formula is plain math on those signals |
| SoftLimit/SoftClip | specific rational curve | Write it as an expression: `x.clip2(3)` then `x*(27+x*x)/(27+9*x*x)` |
| Voice allocation, one request per block | engine-side | Do allocation in Lua; 8 persistent voices with `gate` args is closest. Fix the priority bug |
| Global LFOs added per sample | | One LFO synth writing to audio buses; voices read the bus. DaisySP's triangle starts at +1 going down, which is `LFTri.ar(freq, 1)`; the pitch LFO's +.25 cycle offset is `iphase 2` |

---

## 11. Shared with TAPE

Same-named files diffed against `chompi-tape/code/src`:

| File | Difference |
|---|---|
| fx_engine.h, reverb.h | identical |
| BasicMMF.h, encoder.cpp, encoder.h, EnvFollower.h, InterpolatedDelayLine.h, ui_utils.h, temp_led_stuff.h | comments only |
| DJFilter.h | WAVE clamps LP coef to .98 and HP to .9; TAPE uses .99 and 1.0, so TAPE can reach the `hp > .8` resonance branch |
| limiter.h | `Process()` in TAPE scales by .7 before SoftLimit, WAVE doesn't; `Process()` isn't used by WAVE. `ProcessComp` is identical |
| hardware.h | same pin map, switch enum, LED/battery code. TAPE does MIDI I/O inside Hardware; WAVE moved it to MidiManager.h with an output queue. Battery medium-check timing moved inside `BMCMediumBattCheck` |
| BootPage, NoSDPage, RainbowWavePage, TestPage | same behaviour; TAPE versions take an Engine pointer; TAPE TestPage sends test MIDI notes and checks the line-in jack |
| Makefile, chompi_sram.lds | WAVE names its own bootloader bin; slightly different SRAM split |
| NormalPage.h | identical `key_map` and `led_map`. `cc_map` page 1 differs (TAPE 28..32, page 2 CC 33 on knob 3; WAVE 26..30). TAPE knob 3 has 3 pages |
| ui.h, MenuPage.h, PresetManager.h, OptionsManager.h, FileStreamingManager.*, chompi_main.cpp | same structure (page stack, chunked preset write, JSON options by name), different content. TAPE presets use modes/banks; WAVE ignores them |

Shared behaviour worth keeping in one place in the port:

- Hardware layout: key/LED maps, `encoder_map`, 1x/3x detent scaling, CHOMPI key as shift, toggle switch, knob click page toggles, battery-hold on gain knob, boot combos.
- Delay ping-pong code (same formula in TAPE DSPEngine.h:317-333), reverb parameter mapping (amount², .6a+.4, .6a), reverb time clamp .05..0.97, compressor formula (thresh/ratio/makeup/pregain). WAVE adds the saturation + makeup table above final comp .5; TAPE's `SetFinalComp` sets L directly.
- LED colour helpers (`color_xfade`, triple, quad) and the colour palette.
- options.json format: same `{"chompi": [{name, value}]}` layout. Both have Midi In/Out Channel; WAVE adds MIDI Clock Out, MIDI CC In, MIDI CC Out; TAPE has Record Latch, Tape Slew On, Monitor Position, Pitch Quantize In Shift Menu, Split Delay instead.

WAVE-only: subtractiveEngine.h, WavetableManager.h, Sequencer.h, clockManager.h (ported from TEMPO), MidiManager.h.

---

## 12. OMX-27 mapping notes

- Endless relative encoders on CHOMPI become absolute pots on the OMX-27; the per-detent steps above only matter for "feel". Use pickup/soft-takeover when a pot controls a page that was changed elsewhere (page toggles, presets).
- CHOMPI's knob pages (click to toggle) need a page modifier on the OMX; the OMX AUX key is the obvious CHOMPI/shift key.
- The 25 note keys plus octave shift map directly to OMX note keys; keep sounding pitch = MIDI note − 12 if matching the original, or drop the offset.
- Play, loop and the shift-menu keys (gate, LFO toggles, save/copy/erase, slot keys) need assigned OMX keys or norns keys/encoders.

---

## 13. Dead code and oddities (don't port)

- `NormalPage::DumpValuePresets` writes to slot 0, which underflows and is rejected (NormalPage.h:775-790).
- `quantized_pitch_` branches in NormalPage (always false).
- `engine.setSwitchState`, `master_cutoff`, `master_resonance` fields unused.
- Copy to "slot 16" (play/loop keys) is out of bounds.
- DJ filter `hp > .8` branch unreachable.
- Line-out compressor on stale buffers.
- Large parts of FileStreamingManager (WAV writing, reverse read) are TAPE leftovers.
- `PresetManager::values`, `chompi_value` arrays unused.
