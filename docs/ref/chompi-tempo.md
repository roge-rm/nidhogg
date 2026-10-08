# Chompi TEMPO v1.0: functional spec

Source: `nidhogg-ref/chompi/firmware/chompi-tempo/code/src` (paths below are relative to it). Card profile: `firmware/card-profiles/tempo-1.0`. Line refs are `file:line`.

TEMPO is a two-engine pattern generator. The chromatic engine plays one sample pitched across the keys. The slice engine cuts one sample into 16 equal slices, one per white key. Each engine has 8 voices, its own arpeggiator/sequencer, its own clock division and its own MIDI out channel. Both feed one shared FX chain (tempo-synced "granular" delay with freeze, a reverb, a ducking compressor, an output compressor/saturator).

Contents:
1. Hardware as the firmware sees it
2. Controls: normal page, shift menu, boot combos
3. Audio engines and DSP (formulas)
4. Signal flow
5. Files: options.json, presets.json, StateSaver
6. MIDI
7. SD card layout and sample format
8. LEDs
9. Hard to reproduce in SuperCollider
10. Shared with TAPE
11. OMX-27 notes
12. Bugs and dead code

---

## 1. Hardware as the firmware sees it

Daisy Seed (STM32H750), 64 MB SDRAM, SD card over SDMMC 4-bit, MP2722 battery charger on I2C (`hardware.h:98-177`).

### Audio
48 kHz, 24-sample blocks (0.5 ms) (`hardware.h:123-124`). Two codecs, 4 in and 4 out (`chompi_main.cpp:78-90`):

| Channel | In | Out |
|---|---|---|
| 0 | built-in microphone | headphones L |
| 1 | unused | headphones R |
| 2 | aux/line in L | main L |
| 3 | aux/line in R | main R |

Line-in jack has a detect pin (`hardware.h:143`). Plugging a cable selects LINE_IN, pulling it selects MIC (`chompi_main.cpp:129-136`).

### Controls
Read through 5 chained CD4021 shift registers plus GPIO (`hardware.h:46-94`, `153-168`).

| Firmware ID | buttonID | What it is |
|---|---|---|
| ENC_1_SW..ENC_4_SW | 0..3 | push switches of encoders 1-4 |
| ENC_5_SW | 4 | push of encoder 5 (on a GPIO, `hardware.h:6`, `150`) |
| KEY_26 | 5 | the CHOMPI key (record / shift) |
| SW_TOG | 6 | 2-position toggle switch |
| KEY_1..KEY_15 | see key table | 15 white keys |
| KEY_16..KEY_25 | see key table | 10 black keys |
| ENC_6_SW | 32 | push of encoder 6 |
| KEY_27 | 33 | PLAY key |
| KEY_28 | 34 | LOOP key |
| NC_1..NC_5 | 35..39 | not connected |

6 detented encoders. Encoders 1-4 are read from a 4021, 5-6 from GPIO (`hardware.h:146-151`, `382-397`). The UI renumbers them into logical knobs with `encoder_map = {1,2,3,0,4,5}` (`ui.h:36`, applied at `ui.h:242-254`). Logical knobs 1, 2, 3 and 5 send 3 steps per detent, knobs 0 and 4 send 1 (`ui.h:249-252`).

| Logical knob | Name used here | Hardware | Push switch buttonID |
|---|---|---|---|
| 0 | PITCH | encoder 4 | 3 (ENC_4_SW) |
| 1 | START | encoder 1 | 0 |
| 2 | END | encoder 2 | 1 |
| 3 | MAGIC (FX) | encoder 3 | 2 |
| 4 | TEMPO | encoder 5 | 4 |
| 5 | VOLUME | encoder 6 | 32 |

Toggle switch: `GetToggleState()` is true when the switch bit reads high for most of the last 200 scans (`hardware.h:364-380`). The firmware calls this `switch_state`. Here:
- SHIFT position = `switch_state` true. CHOMPI key opens the shift menu. Input monitoring off.
- REC position = `switch_state` false. CHOMPI key records. Input monitoring on (`NormalPage.h:491`).

The physical up/down orientation is not in the code.

### Key table
Note numbers from `key_map` (`NormalPage.h:20-61`), slices from `sliceMap` (`SliceEngine.h:14-15`), LED index from `led_map` (`NormalPage.h:63-104`), shift functions from `MenuPage.h:888-1121`.

| Key | buttonID | MIDI note | Slice | SMT LED | Shift menu function |
|---|---|---|---|---|---|
| KEY_1 (white) | 15 | 48 | 0 | 24 | sample slot 1 |
| KEY_16 (black) | 7 | 49 | none | 0 | select CHROMATIC engine |
| KEY_2 | 8 | 50 | 1 | 23 | slot 2 |
| KEY_17 | 12 | 51 | none | 1 | select SLICE engine |
| KEY_3 | 9 | 52 | 2 | 22 | slot 3 |
| KEY_4 | 10 | 53 | 3 | 21 | slot 4 |
| KEY_18 | 13 | 54 | none | 2 | input MIC |
| KEY_5 | 11 | 55 | 4 | 20 | slot 5 |
| KEY_19 | 14 | 56 | none | 3 | input LINE |
| KEY_6 | 16 | 57 | 5 | 19 | slot 6 |
| KEY_20 | 21 | 58 | none | 4 | input RESAMPLE |
| KEY_7 | 17 | 59 | 6 | 18 | slot 7 |
| KEY_8 | 18 | 60 | 7 | 17 | slot 8 |
| KEY_21 | 22 | 61 | none | 5 | state A |
| KEY_9 | 19 | 62 | 8 | 16 | slot 9 |
| KEY_22 | 23 | 63 | none | 6 | state B |
| KEY_10 | 20 | 64 | 9 | 15 | slot 10 |
| KEY_11 | 24 | 65 | 10 | 14 | slot 11 |
| KEY_23 | 29 | 66 | none | 7 | ERASE |
| KEY_12 | 25 | 67 | 11 | 13 | slot 12 |
| KEY_24 | 30 | 68 | none | 8 | COPY |
| KEY_13 | 26 | 69 | 12 | 12 | slot 13 |
| KEY_25 | 31 | 70 | none | 9 | SAVE |
| KEY_14 | 27 | 71 | 13 | 11 | slot 14 |
| KEY_15 | 28 | 72 | 14 or 15, alternating | 10 | slot 15 (record buffer) |

Chromatic transpose = note − 60 semitones (`NormalPage.h:688`), so the keyboard spans −12..+12.

### LEDs
- 10 "PTH" RGB LEDs (`temp_led_stuff.h:23`). Index: 0 CHOMPI key, 1 PITCH, 2 START, 3 END, 4 MAGIC, 9 VOLUME (8 mm); 5 and 6 a pair by TEMPO, 7 PLAY, 8 LOOP (5 mm) (`NormalPage.h:172-184`).
- 25 "SMT" RGB LEDs under the keys, index per key table (`temp_led_stuff.h:24`).
- Brightness scaled down: PTH value/11, SMT value/4 (`temp_led_stuff.h:175-185`).

### Other
- MIDI: serial UART in/out plus USB MIDI device (`MidiManager.h:30-40`).
- Battery: 15 s yellow flashing then shipping mode (power off) when unplugged with low battery; LEDs off and stop-mode sleep on a weak charger with low battery; battery level probed every 30 s (`hardware.h:198-298`).
- SD card checked every 1 s. If lost: all LEDs blink red for 3 s, then the shift menu shows red keys and save/copy/erase/slot/engine select are disabled until reboot (`chompi_main.cpp:215-243`, `MenuPage.h:455-456`, `905`, `1013`).

---

## 2. Controls

UI pages (`ui.h`): Boot, Normal, Menu (shift), Test, NoSD, Rainbow. Events go to the top page first; a page returning false passes the event down (libDaisy `UI.cpp:165-195`, `340-360`). Release events carry `numberOfPresses = 0`.

Normal page ignores all input for the first 1500 ms (`NormalPage.h:223-230`).

### 2.1 Knob pages
Each knob has its own page index, cycled by clicking that knob (`knob_num_pages = {3,2,2,2,1,2}`, `NormalPage.h:130`). Page state is shared with the shift menu (`ui.h:389`). Values are 0..1.

Defaults (`ui.h:22-26`):

| Knob | Page 0 | Page 1 | Page 2 |
|---|---|---|---|
| 0 PITCH | pitch .83 | sample volume .6 | filter .5 |
| 1 START | sample start 0 | attack 0 | |
| 2 END | sample end 1 | release 0 | |
| 3 MAGIC | delay main .5 | delay mix .5 | |
| 4 TEMPO | tempo .5 (= 320) | | |
| 5 VOLUME | output gain .6 | input gain .75 | |

Pitch, start, end, attack, release, sample volume, filter (and shift's pan, redux, loop, sustain) apply to the currently selected engine only. Each engine keeps its own values (saved and recalled on engine switch).

### 2.2 Normal page: knob turns (`NormalPage.h:742-883`)
Per-detent step (after the ×3 multiplier in §1):

| Knob/page | Step per detent | Action |
|---|---|---|
| 0/0 pitch | .003 if free; quantised steps if `quantized_pitch_` | `setGlobalPitchFree` or `setGlobalPitchQuantized` (§3.3) |
| 0/1 sample volume | 1/33 | engine volume = value² (`:816`) |
| 0/2 filter | .01 | `setMasterCutoff` (§3.5) |
| 1/0 start | chromatic: .009 when end−start > .05, else `3 × max(.0001, (range/.05)^3.5 × .01)`; slice: .009 | clamped to ≤ end − .003 (`:826`) |
| 1/1 attack | .03 | `setAttack` |
| 2/0 end | as start | clamped to ≥ start + .003 (`:836`) |
| 2/1 release | .03 | `setRelease` |
| 3/0 delay main | .009 | `fx.setGranularMain` (§3.7) |
| 3/1 delay mix | .03 | `fx.setGranularMix` for the current engine |
| 4 tempo (FREE) | 1 tempo unit; value moves .003125 | `changeTempo(±1)`; while TEMPO is held: `changeDiv` for current engine |
| 4 (SYNC) | | always `changeDiv` |
| 5/0 output gain | .03 | `fx.setGain` |
| 5/1 input gain | .03 | `fx.setInputGain` |

`quantized_pitch_` on the normal page = NOT option "Pitch Quantize In Shift Menu" (`NormalPage.h:155`). With the default (true) the normal pitch knob is free and fine.

Every turn sends a MIDI CC (§6).

### 2.3 Normal page: buttons (`NormalPage.h:524-740`)

| Control | Action |
|---|---|
| Click knob 0, 1, 2 or 5 | next page for that knob, on release. Knob 5: only if released within 2 s |
| Knob 3 click under 750 ms | page 0: toggle delay freeze; page 1: go back to page 0 (`:549-561`) |
| Knob 3 hold 750 ms | next page (`:232-236`) |
| Knob 4 press | tap tempo (§3.9) and "held" state; while held, turning changes clock division. Release sends CC 24 |
| Knob 5 hold 2 s | VOLUME LED shows battery: white full, green high, yellow medium (`:395-420`) |
| CHOMPI key, REC position | sends CC 14 (127/0). Press starts recording. Release stops it, or with "Record Latch" true the next press stops it (`:648-684`) |
| CHOMPI key, SHIFT position | opens the shift menu while held (`ui.h:223-232`) |
| PLAY | `arpSeq.setPlay(press/release)` (§3.8) |
| LOOP | `arpSeq.setLatch(press/release)`, sends CC 15 (127/0) |
| Note keys | see below |

After a recording stops: current engine loads slot 15 (the buffer); if chromatic was recording and slice is also on slot 15, slice reloads too. Pitch, sample volume, start, end and filter go back to defaults, pan to .5 and redux to 0 (`NormalPage.h:658-679`, `ui.h:194-197`, `MenuPage.h:1298-1303`).

Note key press (`NormalPage.h:686-716`), "engine" = currently selected engine:
- Engine is playing (PLAY on): key goes to the arp/sequencer only. No direct sound, no direct MIDI note.
- Else LOOP latch on: key sounds directly (unless sustain mode and the key is already in the sequence) and is also sent to the sequencer.
- Else: key sounds directly.
- If engine not playing: MIDI note on, note = key note, on the engine's out channel.

Note key release (`NormalPage.h:718-735`):
- Stop the voice, unless sustain mode is on or the key is the sequencer's current step note.
- Send STOP to the sequencer if playing, or latch on and not sustain.
- MIDI note off if not playing and not sustain.

Chromatic keys transpose by note − 60. Slice keys send transpose 0 to the engine.

### 2.4 Shift menu (`MenuPage.h`)
Open: CHOMPI pressed with the toggle in SHIFT position, Normal page active. Closes when CHOMPI is released and no save/copy/erase is pending, or 1 s after a save/copy/erase finishes (`MenuPage.h:1141-1155`, `ui.h:176-180`).

Knob turns in the menu (`MenuPage.h:520-651`). These act on what the knob's current normal page is. Ignored while a save/copy/erase selection is active. No MIDI CC sent.

| Knob/page | Step per detent | Parameter | Range/curve | Default |
|---|---|---|---|---|
| 0/0 | quantised, or .003 if option false | pitch | §3.3 | .83 |
| 0/1 | .01 | pan (engine) | 0..1, §3.4 | .5 |
| 0/2 | .01 | sample-rate reduction (engine) | §3.6 | 0 |
| 1/0 | min(end−start, .01) × 3 | move start and end together | window kept inside 0..1 | |
| 1/1 | .03 | loop (engine) | on when > .5 | 1 (chromatic), 0 (slice, `StateSaver.h:46-47`) |
| 2/0 | every 3 detents | zoom window: down sets end = start + window/2, up sets end = start + 2×window (≤1) | counter `window_encoder_counter` beyond ±6 (`:589-605`) | |
| 2/1 | .03 | sustain (engine) | on when > .5 | 1 |
| 3/0 | .03 | delay randomness (`setGranularAlt`) | 0..1 | 0 |
| 3/1 | .03 | delay feedback (`setGranularFeedback`) | 0..1 | .3 |
| 4 | .01 | arp randomness, current engine | 0..1 | 0 |
| 5 | .03 | final comp/saturation (`setFinalComp`) | §3.11 | 0 |

Buttons in the menu:

| Control | Action |
|---|---|
| Knob 0 press | page 0: pitch to .83, reset quantiser. Page 1: sample volume .6 and pan .5. Page 2: filter .5 and redux 0. LED white while held (`:735-767`) |
| Knob 1 press (and release) | page 0: start to 0. Page 1: attack to 0 |
| Knob 2 press (and release) | page 0: end to 1. Page 1: release to 0 |
| Knob 3 press | page 0: delay main .5, randomness 0. Page 1: mix .5, feedback .3. Then unfreeze immediately (`:815-838`) |
| Knob 4 hold 1 s | toggle clock FREE/SYNC; the TEMPO pair blinks pink (free) or purple (sync) for 500 ms (`:94-100`, `158-167`) |
| Knob 5 press | next monitor mode 0→1→2→0 (§3.10) |
| PLAY | next pattern for current engine: SEQUENCE, UP, DOWN, PINGPONG, RANDOM |
| LOOP | next rest pattern for current engine (§3.8) |
| KEY_16 / KEY_17 | select chromatic / slice engine (§2.5) |
| KEY_18 / 19 / 20 | input MIC / LINE / RESAMPLE |
| KEY_21 / KEY_22 | recall state A / B; hold the already-active one 1 s to copy this state to the other (§5.3) |
| KEY_23 | ERASE mode on/off |
| KEY_24 | COPY mode on/off |
| KEY_25 | SAVE mode on/off |
| White key, no mode | if the slot has a sample: load it into the current engine with its preset values (§5.2). Slot 15 loads the record buffer with default values |
| CHOMPI press in a mode | confirm (below) |

Releases of white keys and of black keys 16-20, 23-25 pass to the Normal page so held notes stop.

Save / copy / erase (`MenuPage.h:843-886`, `1011-1116`):
- SAVE: pick slot 1-14, press CHOMPI. Writes the record buffer (slot 15) to `chroma_aN.wav` or `slice_aN.wav` for the current engine, stores current knob values as that slot's preset, then loads the slot.
- COPY: pick a source slot with a sample (1-15), then a destination (1-15), press CHOMPI. Current knob values are written as the destination preset and the sample is copied, see bug §12.
- ERASE: pick slot 1-14 with a sample, press CHOMPI. Deletes the file and loads slot 15.
- Pressing the mode key again cancels. Only one mode at a time.

### 2.5 Engine switching (`MenuPage.h:902-940`)
Selecting an engine: saves the other engine's knob values into the current state slot, loads this engine's knob values (without re-applying them to the DSP, the engine already has them), stops the left engine's voices (with MIDI note offs) unless it is playing or in sustain, and points the sequencer UI at the new engine. Both engines keep sounding and sequencing in the background.

### 2.6 Boot combos (`chompi_main.cpp:442-460`)
Checked over the first 0.5 s:
- CHOMPI + PLAY + LOOP held: shipping mode (power off).
- VOLUME knob held: hardware test page (`TestPage.h`).

Boot: LED animation, samples load starting 1 s after boot, audio is silent until loading finishes, then both engines select slot 15 (`buffer.wav`) and a rainbow animation plays (`chompi_main.cpp:295-319`).

---

## 3. Audio engines and DSP

Sample rate 48 kHz. Engine key requests are drained once per 24-sample block in `Prepare()`, so all note timing is quantised to 0.5 ms (`chompi_main.cpp:116-127`).

`fonepole(x, target, c)` is `x += c × (target − x)` per sample (DaisySP `dsp.h:135`). c = .001 is a 20.8 ms time constant, .0002 is 104 ms.

### 3.1 Sample player (`SampleManager.h:365-618`)
Shared by both engines. One per voice.
- Memory: raw interleaved int16 stereo frames.
- Rate (`tuningWord`) = keyFreq × global / 440, keyFreq = 440 × 2^(transpose/12). So rate = 2^(transpose/12) × |globalPitch|, negated when reversed (`:406-413`).
- Linear interpolation between frames; result is truncated back to int16 before scaling (`:495-505`).
- start_point = floor(frames × start); end_point = frames − floor(frames × (1 − end)), min 1 (`:381-394`).
- Forward: past end_point it wraps to start_point if loop, else outputs 0. Reverse mirrors this (`:459-490`).
- Loop crossfade: if loop on and window > 4800 frames, when the phase passes end − 256 (or start + 256 reversed) a second head starts at start_point and the two are crossfaded linearly over 256 frames of travel (counter advances by |rate|). At the end the main head jumps to the second head (`:507-549`, `569-586`).
- No-loop "click" fade: last 256 frames fade out linearly (`:513-517`, `550-556`).
- Retrigger while sounding: if looping, or not looping and before the fade zone, crossfade from the current position to start over 256 frames; else jump straight to start (end if reversed) (`:427-443`).

### 3.2 Voices and allocation
8 voices per engine (`EngineBase.h:10`). Each voice = sample player × ADSR (`SampleEngine.h:18-68`, `SliceEngine.h:17-67`).

Allocation (`SampleEngine.h:172-252`, same in `SliceEngine.h:173-268`). Voices are keyed by buttonID:
- Same key already on a voice: reuse it, gate on, retune, retrigger (with crossfade as above), priority 0.
- Else pick the gate-off voice with the highest priority number (longest since used); if all gates are on, steal the voice with priority 8. Others' priorities +1.
- A voice tracks user and sequencer holds separately; the gate closes only when both have released (`:254-269`).

ADSR (DaisySP `adsr.cpp`): sustain level 1. Attack is a one-pole toward `target = 9x^10 + 0.3x + 1.01` (x = shape) with coefficient `1 − exp(ln(1 − 1/target) / (t × sr))`, ending at 1. Decay and release are one-poles toward the sustain level / −0.01 with coefficient `1 − exp(−1/(t × sr))`. TEMPO calls attack with shape 1 (target 10.31, nearly linear).

Envelope settings:

| | Chromatic (`SampleEngine.h:413-432`) | Slice (`SliceEngine.h:436-453`) |
|---|---|---|
| attack a | t = 5 × (0.001 + 0.999 a³) s | t = 5a s, a < .008 gives 5 ms |
| release r | t = r s (time constant), r < .008 gives 5 ms | same |
| sustain off | gate drops when the envelope reaches its peak, so attack then release | same |

The slice voice calls `amp_env_.Process()` twice per sample (L then R), so slice envelopes run at double speed (`SliceEngine.h:48-49`). See §12.

Engine mix per sample (`SampleEngine.h:119-152`):
```
sum = Σ voices
L = sum_L × 0.125 × vol × (1 − pan) × 2
R = sum_R × 0.125 × vol × pan × 2
vol, pan smoothed with fonepole .001
→ sample-rate reducer (if on) → DJ filter
```
Initial vol .6, pan .5.

### 3.3 Global pitch (both engines)
Free (`SampleEngine.h:278-296`): knob v in 0..1, `x = 2v − 1`, s = sign(x):

| |x| | pitch |
|---|---|
| < .33 | x × 1.484848 + .01 s (.01..0.5) |
| .33..66 | (x − .33 s) × 1.515151 + .5 s (0.5..1) |
| ≥ .66 | (x − .66 s) × 2.941176 + 1 s (1..2) |

Rate multiplier = |pitch|. pitch < 0 (v < .5) plays reversed. Default v = .83 gives 1.0. v = 1 gives 2.0.

Quantised (`SampleEngine.h:298-374`): accumulates .25 per detent; every 4 detents it multiplies the current pitch alternately by a fifth (×1.49830707688, down ×.749153538438) and a fourth (×1.33483985417, down ×.667419927085) (the `fifth` flag toggles each step, reversed direction swaps them). Refuses steps beyond ±2. If a step would go below .0625 it flips direction (reverse playback) instead. Returns the matching knob position:
```
p < .5: k = (p − .01) × .673469
p < 1 : k = (p − .5) × .66 + .33
else  : k = (p − 1) × .34 + .66
knob = reverse ? (1 − k)/2 : k/2 + .5
```
Knob 0 press in the menu resets the step state.

### 3.4 Chromatic engine (`SampleEngine.h`)
- Plays the selected slot's whole sample, windowed by start/end.
- Loop default on, sustain default on (`:114`).
- Every key retunes by note − 60 semitones.

### 3.5 Slice engine (`SliceEngine.h`)
- Window = [start × frames, end × frames]; slice size = window / 16; slice i starts at window_start + i × size, length size (`:573-591`).
- White keys 1-14 play slices 0-13. Key 15 alternates slice 14 and 15 on each trigger (`:187-192`, `238-243`). In latch mode key 15 follows `slice_key_mode` instead (§3.8).
- Black keys and MIDI-only key IDs (> 31) are ignored (`:160-170`).
- Slices play at rate × |globalPitch| with transpose 0, except arp random octaves (§3.8).
- Loop default off, sustain on.

### 3.6 Per-engine filter, reducer, pan
DJ filter (`DJFilter.h`, `BasicMMF.h`), one stereo pair per engine.

Knob a → cutoff c and resonance (`SampleEngine.h:446-467`):
```
.45 < a < .55 : c = .5, res = 0
else          : c = clamp(a < .45 ? a × 1.1111 : (a − .1) × 1.1111, 0, 1)
                res = (.4<a<.45 or .55<a<.6) ? |.5 − a| × 9 − .45 : .45
res = clamp(res, 0, .99) × .95
```
c → coefficients (`DJFilter.h:65-73`):
```
lp = clamp(.01 + 2c, 0, .98)^3     (c=.5 → .941, c=0 → 1e-6)
hp = clamp(1.9c − 1, 0, .9)^3      (c≤.53 → 0, c=1 → .729)
lp, hp smoothed with fonepole .0002 per sample
```
Signal: lowpass BasicMMF then highpass BasicMMF, each 2-pole (`BasicMMF.h:34-46`):
```
fb   = q + q / (1 − f)
b0  += f × (in − b0 + fb × (b0 − b1))
b1  += f × (b0 − b1)
LP = b1, HP = in − b0
```
f is a one-pole coefficient. Approximate corner Hz ≈ −ln(1 − f) × 48000 / 2π (f = .941 ≈ 21.6 kHz, f = .729 ≈ 10 kHz). The `hp_ > .8` resonance branch never runs (`DJFilter.h:48`).

Sample-rate reducer (DaisySP `SampleRateReducer`, sample-and-hold with BLEP correction), per engine (`SampleEngine.h:473-484`):
```
a = 0: bypass
a > 0: hold rate = clamp((1 − a) × .45, .01, 1) × 48000 Hz  (21.6 kHz → 480 Hz)
```

Pan: linear, centre unity, hard side ×2 on one channel (§3.2).

### 3.7 FX: granular delay (`granularDelay.h`, the compiled one)
`granularDelay2.h` is not included anywhere and says so (`granularDelay2.h:13`). See §12.

Buffers: 480000 stereo float frames (10 s) for the delay line and the same for the freeze capture (`chompi_main.cpp:22`, `30-31`).

Main knob k (MAGIC page 0) (`granularDelay.h:622-650`, `FxEngine.h:297-314`):

| k | Mode | Wet target |
|---|---|---|
| < .4 | random-event delay | 1 |
| .4..45 | random-event delay | 9 − 20k (fade 0→1) |
| .45..55 | off | 0 (delay stops once wet < .01 at a knob change) |
| .55..6 | pitch-up delay + reverb | 20k − 11 |
| > .6 | pitch-up delay + reverb | 1 |

Wet smoothed fonepole .001.

Division index d (0..8) from distance to centre (`:419-428`):
```
k < .4 : d = round(k × 20)
k > .6 : d = round((1 − k) × 20)
else   : d = 8
delayDivs = {1/8, 1/6, 1/4, 1/3, 3/8, 1/2, 3/4, 1, 2}
delay_samples = interval_us × .192 × delayDivs[d]   (= 4 base steps × div)
```
interval_us is one base step (§3.9): 60e6/tempo in FREE, measured eighth note + `syncDelayBoost` in SYNC. With base step = eighth note: 1/8 = 16th, 1/6 = 8th triplet, 1/4 = 8th, 1/3 = quarter triplet, 3/8 = dotted 8th, 1/2 = quarter, 3/4 = dotted quarter, 1 = half, 2 = whole. delay_samples is smoothed fonepole .001. A division change crossfades each read voice to the new read position over 256 samples (`:160-175`, `242-293`).

Write (`:364-373`): `buf[w] = (in + fb_sig) × lockEnv`, skipped while frozen. Input = the wet bus (§4). `fb_sig = delay_out × feedback × .975` (`:602-603`, `618-620`).

Read voices (`delayVoice`, `:95-314`): two voices, crossfaded with a quarter-sine over 1024 samples (`:191-208`). Each reads stereo with fixed extra offsets, L 960 samples and R 480 samples behind its read head, linear interpolation (`:16-17`, `20-59`). Constant-power pan `sqrt(.5(1∓pan))`.

Per-voice read-head motion by event (`:210-231`):

| Event | Read head |
|---|---|
| NONE | write − delay (plain delay) |
| RETRIG | write − 1.125 × delay |
| REVERSE | moves −1 per sample (backwards) |
| PITCH_UP | +2 per sample (octave up). Starts at write − delay × (0.5 / div) when d < 5 |
| PITCH_DOWN | +0.5 per sample (octave down) |

Event scheduling (`:546-597`), on each chromatic-engine clock step (`chompi_main.cpp:116-119`), every step if the chromatic division position ≤ 2 else every second step:
- With probability 0.5 × randomness (shift MAGIC page 0): new event on the other voice, which fades in while the current fades out. k < .5: event = RETRIG/REVERSE/PITCH_UP/PITCH_DOWN at random, pan 0. k ≥ .5: PITCH_UP with random pan in ±(0.5 + 0.5 × randomness).
- Else NONE; if the previous step had an event, crossfade back to a plain voice.
- Randomness 0 gives a plain delay on both sides.

Freeze (`:375-545`, `656-677`):
- While not frozen, the delay output is also written to the freeze buffer.
- Toggle (MAGIC click): only if the delay is on, a 256-sample fade down; at zero the lock flips, then fade up. On lock: freeze read head = freeze write − delay_samples, all tick counters reset.
- Frozen: input is not written, no feedback. Plays the freeze buffer forward at rate 1. Loop restart: the clock timer ticks counters for every division (`frozenDelayIntervals = {6,8,12,16,18,24,36,48,96}` ticks at 24 PPQN, `chompi_main.cpp:180`); when the current division's counter wraps, a 256-sample fade down/up and the head jumps back to (freeze write − delay_samples). A division change while frozen crossfades (256 samples) to a read head with the same phase in the new division.
- Option "Delay Buffer Unfreeze Mute": when unfreezing, fade the delay output out over 256 samples, keep it silent for delay_samples, fade in over 256 (`:380-398`, `672-677`).
- Menu reset unfreezes instantly (no fade) (`:665-670`).

Mix (MAGIC page 1, per engine, `FxEngine.h:320-341`):
```
v ≥ .5 : dry = 2 − 2v, wet = 1
v < .5 : dry = 1,      wet = 2v
```
Smoothed fonepole .001.

### 3.8 Arpeggiator / sequencer (`ArpeggiatorSequencer.h`)
State per engine: note list (vector of {key, transpose, entry order, pitch rank}), play, latch, sustain, pattern, rest pattern, randomness, current index, rest index.

Pitch rank for sorting uses `keyMap` (`:21-22`): rank 0..24 by key pitch.

Patterns (`:748-823`), `pattern_` cycled in the shift menu:

| Pattern | Order | Next |
|---|---|---|
| SEQUENCE | entry order | +1, wrap |
| ARP_UP | sorted by pitch | +1, wrap |
| ARP_DOWN | sorted | −1, wrap |
| ARP_PP | sorted | ping-pong, ends not repeated |
| ARP_RANDOM | sorted | random index |

Rest patterns (20 steps, `:40-46`), T = play, F = rest:

| Mode | Pattern |
|---|---|
| NONE | all T |
| LAST | T T T F repeating |
| SECOND_LAST | T T F F repeating |
| MIDDLE_TWO | T F repeating |
| ONLY_FIRST | T F T T F repeating |

The names don't match the shapes; this is what the code plays.

Step (`checkAndPop`, `:83-117`), on each clock edge of that engine while it plays:
- Rest step T: stop current note (engine STOP + MIDI note off), drop it if flagged for removal, advance index and rest index, start the new note.
- Rest step F: stop current note, drop if flagged, advance rest index only.
- Notes are held for the whole step (full gate).
- Start (`:217-291`): pitch = stored transpose (0 for slice), plus with probability = arp randomness ±12 at random. MIDI note on = stored transpose + 60 (random octave not included).
- Single-note list: the retrigger is deferred 30 blocks (15 ms) with release forced to 5 ms, to avoid a click (`:119-142`, `242-247`).

PLAY key (`setPlay`, `:348-405`, `checkDecouplePlay` `:531-538`):
- Press with nothing playing: both engines start, clocks reset, first notes fire, MIDI Start sent (FREE mode, transport out enabled). Sustain mode on the current engine is cleared.
- Press with only one engine playing: both play.
- Release with both playing: both stop, MIDI Stop sent. Not on the release of the press that started them.
- Hold 1 s while the current engine plays: stops the current engine only.

LOOP key (`setLatch` `:456-501`, `checkSustain` `:540-567`):
- Press with latch off: latch on.
- Press-release with latch on: latch off, stop, clear the list.
- Hold 1 s with latch on and engine not playing: SUSTAIN mode. All notes in the list sound together and stay on; keys sounding at that moment join the list.
- Release from sustain: sustain off (latch stays), all list notes stop.

How keys feed the list (`ProcessKeyRequests`, `:119-215`):
- Arp (latch off, playing): key down adds, key up removes. Non-SEQUENCE patterns re-sort.
- Latch on: key down toggles the note in the list (if it is the playing note, removal waits until the step ends). Key up ignored.
- Slice engine, key 15 in latch: cycles `slice_key_mode` 0→1→2→3→0. 1 = in list, plays slice 14; 2 = plays slice 15; 3 = alternates; 0 = removed (`:577-589`, `257-274`).

Pattern change from SEQUENCE sorts by pitch; to SEQUENCE (from RANDOM) restores entry order (`:621-643`).

Randomness per engine (shift TEMPO knob), 0..1.

### 3.9 Clock (`clockManager.h`)
Internal tempo value `tempo` 160..480, default 320. MIDI clock rate = tempo × 12 / 60 Hz, so at 24 PPQN the musical BPM is tempo/2 (80..240, default 160) (`:166-194`). A hardware timer ISR (TIM16, 1 MHz tick, period `1e6/(tempo/5) − 1`) increments the step counters, ticks the freeze counters and sends MIDI clock (`chompi_main.cpp:173-203`).

Base step = 12 ticks = one eighth note; `intervalUsFree = 60e6 / tempo` µs (`:175`).

FREE mode divisions per engine (`:30-36`, `46`):

| Position | Ticks | Note | Multiplier | TEMPO LEDs |
|---|---|---|---|---|
| 0 | 24 | quarter | 2 | blue |
| 1 | 18 | dotted eighth | 1.5 | green |
| 2 (default) | 12 | eighth | 1 | dim white |
| 3 | 8 | eighth triplet | .66 | yellow (second LED) |
| 4 | 6 | sixteenth | .5 | red (second LED) |

Division is changed by turning TEMPO while held: a virtual counter 0..60, 12 detents per position, jumps to the middle of the new range (`:196-250`). In FREE mode the change waits for the next tick of a third counter (12 ticks), then applies and resets that engine's counter (`:75-89`).

SYNC mode divisions in MIDI clocks (`:22-28`): 48 half, 24 quarter, 12 eighth (default), 6 sixteenth, 3 thirty-second. Turning TEMPO changes the current engine's division directly. MIDI clocks are counted per audio block.

SYNC tempo estimate (`:281-302`), used only by the delay: over each 24 clocks, `interval = 0.9 interval + 0.1 × (µs per 24 clocks / 2)`; `syncDelayBoost = 138 d² / 1e9 + 194 d / 1e4 + 3900` µs with `d = max(0, interval − 151520)`, added to the interval. The boost looks like an empirical correction.

Tap tempo (`:304-320`): press TEMPO twice within 750 ms: tempo = 120000 / ms between taps (= 2 × BPM), capped at 480, floored at 160.

FREE/SYNC: hold TEMPO 1 s in the shift menu. No swing anywhere.

### 3.10 Inputs, monitoring and recording (`FxEngine.h`)
Input chains (`:230-295`):
```
MIC  = MicFilter(DcBlock(in0 × inGain × 5))
LINE = DcBlock(in2 × inGain × 8), DcBlock(in3 × inGain × 8)
```
DcBlock: `y = x − x1 + .99 y1` (about 76 Hz). inGain smoothed fonepole .001, default .75.

MicFilter (`MicFilter.h:17-58`): clamp ±.98, DaisySP Svf highpass 150 Hz (res .4), then Svf notches at 2 kHz (res .99, drive .6), 12 kHz, 8 kHz, 4 kHz (drive .6), 9 kHz (res .99). Svf is the double-sampled Chamberlin: `f = 2 sin(π fc / 2sr)`, `damp = min(2(1 − res^.25), 2, 2/f − f/2)`, drive term `band −= drive × band³` with `drive = .1 × setDrive × res`. Res .99 makes the notches very narrow.

Input monitor is on in the REC switch position. Monitor modes (`:85-146`):

| Mode | LED (shift, VOLUME) | Behaviour |
|---|---|---|
| 0 (default) | orange | when monitoring: MIC or LINE × .125 added to headphones only |
| 1 | blue | MIC or LINE × .125 added to the dry bus (× chroma dry) and the wet bus (× chroma wet), so it goes through the delay and to both outputs. Runs whatever the switch position |
| 2 | yellow | when monitoring and MIC: MIC × .125 into the wet bus only. LINE × .125 always added to headphones |

RESAMPLE (`:148-166`): after FX, `out_hp = out_hp × resampEnv`; resampEnv target = input gain while monitoring, else 1 (`:446-451`). In mode 1 main gets the same signal. Record source = that signal × 10.

Recording (`:170-180`, `SampleManager.h:238-266`):
- Source: the monitor signal (MIC/LINE chain above, before the ×.125), or RESAMPLE as above.
- Clipped to int16 stereo into the record buffer (slot 15). Max 1,920,000 bytes (10 s); stops by itself when full.
- Never written to SD by itself. SAVE writes it to a slot.

### 3.11 Output section
Order per sample in `fx.Process` (`FxEngine.h:102-131`):
```
wet  = chroma × chromaWet + slice × sliceWet (+ input in modes 1/2)
dry  = chroma × chromaDry + slice × sliceDry (+ input in mode 1)
delay.write(wet); d = delay.read()
d += wet × reverbBoost
reverb(d)
duck(d, keyed by dry)
out = d + dry
main = out (copied before headphone monitoring)
```

Reverb (`reverb.h`, Rings/Clouds Griesinger topology, 16-bit delay memory, 32768 samples):
- Input mono (L + R) × input gain .3. 4 input allpasses (150, 214, 319, 527 samples), coefficient = diffusion.
- Two loop halves: allpasses 2182, 2690 + delay 4501, and 2525, 2197 + delay 6312. Each reads the other half's long delay with LFO modulation (6261 ± 50 samples at 0.3 Hz; 4460 ± 40 at 0.5 Hz) × reverb time, then a one-pole lowpass (coefficient `lp`).
- Output: `x += (wet − x) × amount` per channel.
- Parameters from the delay knob (`FxEngine.h:297-314`, `118-121`):
```
k > .55: amt = .25 + .65 × sqrt((k − .55)/.45), else 0   (smoothed .001)
reverbBoost = .3 if k > .6 else 0                         (smoothed .001)
amount = amt² × .8, time = amt, lowpass = amt × .55 + .4, diffusion = amt × .6
```
- Freeze in `reverb.h` exists but is never called.

Ducking compressor (`SimpleCompressor.h`), active when feedback > .6, amount = (fb − .6)/.4 (`FxEngine.h:343-351`):
```
env  = a·|mean(dry) × 100| + (1−a) env, capped at 1      a = 1 − exp(−1/(.01 × 48000))
tgt  = env ≤ .1 ? 1 : 1 − min(1, (env − .1)/.9) × amount
gain = c·tgt + (1−c) gain, c = a when falling, else 1 − exp(−1/(.25 × 48000))
wet × gain
```

Output stage, applied to headphones and main pairs separately (`FxEngine.h:184-218`, `limiter.h:73-81`):
```
L = finalLim (smoothed .001)
pregain = 7L + 1, thresh = 1/(10L + 4), ratio = 1 + 7L², makeup = .9 + .6L
x    = in × pregain
peak: rises at .05/sample, falls at .0002/sample toward |x|
g    = peak ≤ thresh ? 1 : 1 / (ratio × (1 + peak − thresh))
gs   : moves toward g at .001 when rising, .005 when falling
y    = SoftLimit(x × gs × makeup)
y    = SoftClip(sat × y) × satMakeup × gain × 2
SoftLimit(x) = x(27 + x²)/(27 + 9x²); SoftClip clamps to ±1 beyond ±3
```
Final comp knob a (`FxEngine.h:376-432`):
```
a < .5 : sat = 1, satMakeup = 1, L = 1.4a
a ≥ .5 : sat = 100 ln(3.4(a − .5) + 1) + 1 (1..~102), L = .7
         satMakeup by sat: <5 .25, <15 .13, <24 .085, <30 .072, <40 .065,
                           <52 .058, <60 .05, <70 .046, <80 .044, <85 .042, else .04
```
gain = output gain knob, linear, default .6.

Meters: `EnvFollower` attack coefficient .5, release .9993 per sample; display value ×5 clipped to 1 (`EnvFollower.h`). Output meter on L + R after the output stage; input meter on the monitor signal × .8.

---

## 4. Signal flow

```
 keys / MIDI in / sequencer
        |                         |
  CHROMATIC engine           SLICE engine
  8 voices: player x ADSR    8 voices: player x ADSR (16 slices of window)
  sum x .125 x vol x pan     same
  SampleRateReducer          SampleRateReducer
  DJ filter (LP->HP)         DJ filter
        |                         |
        +---x chromaDry ----+-----x sliceDry---> DRY bus ----------------+
        +---x chromaWet ----+-----x sliceWet---> WET bus --+              |
                                                           |              |
  mic/line (monitor mode 1) --x.125--> dry + wet           |              |
  mic (monitor mode 2)      --x.125--> wet                 |              |
                                                           v              |
              +--------- granular delay (write wet + fb; freeze) ---+     |
              |                         delay out                   |     |
              |            + wet x reverbBoost                      |     |
              |            reverb (amount crossfade)               |     |
              |            duck by DRY (SimpleCompressor)          |     |
              |                                                    v     v
              |                                         out = wet path + dry
              |                                           |          |
              |                                 MAIN (copy)     HEADPHONES
              |                                           |          + monitor modes 0/2
              |                                           |          x resampEnv (RESAMPLE)
              |                                  comp -> softclip -> x gain x 2 (each pair)
  record tap: monitor signal, or RESAMPLE headphone mix x 10  -> int16 buffer (slot 15)
```

---

## 5. Files and state

### 5.1 options.json (`OptionsManager.h`)
Read at boot, then rewritten with current values every boot (`:30-60`). Format: `{"chompi":[{"name": ..., "value": ...}, ...]}`. Matched by name in any order, up to 11 entries.

| name | Type | File range | Default | Controls |
|---|---|---|---|---|
| Record Latch | bool | | false | CHOMPI toggles recording instead of hold |
| Midi In Channel | int | 1..16 | 1 | note/CC in channel |
| Midi Out Channel Chromatic | int | 1..16 | 1 | chromatic notes/CCs out |
| Midi Out Channel Slice | int | 1..16 | 2 | slice notes/CCs out |
| MIDI Clock Out | bool | | true | send F8 in FREE mode while chromatic plays |
| Monitor Position | int | 1..3 | 1 | intended start monitor mode. Never applied, see §12 |
| Pitch Quantize In Shift Menu | bool | | true | true: shift pitch quantised, normal free. false: the other way |
| MIDI CC In | bool | | true | accept CC 14, 15, 20-25 |
| MIDI CC Out | bool | | true | send knob CCs and CC 14/15 |
| Midi Start-Stop Message Behavior | int | 1..4 | 1 | 1 send+receive, 2 send only, 3 receive only, 4 neither (`ArpeggiatorSequencer.h:80`, `MidiManager.h:245`) |
| Delay Buffer Unfreeze Mute | bool | | false | mute delay for one delay time after unfreeze |

Bool parsing only changes a value away from its default (`:215-226`). Channels are stored 0-based. Card profile `options.json` has the defaults.

### 5.2 presets.json (`PresetManager.h`, `ui.h:262-339`)
JSON array `[mode][slot][ctrl]`: mode 0 chromatic, 1 slice; slots 0..13 = keys 1..14; 11 ints = value × 1000. Slot 15 (buffer) has no stored preset and always uses the defaults.

| ctrl | Meaning | Default |
|---|---|---|
| 0 | pitch knob | 830 |
| 1 | sample volume | 600 |
| 2 | filter | 500 |
| 3 | sample start | 0 |
| 4 | attack | 0 |
| 5 | sample end | 1000 |
| 6 | release | 0 |
| 7 | pan | 500 |
| 8 | sample-rate reduction | 0 |
| 9 | loop (> 500 on) | 1000 |
| 10 | sustain (> 500 on) | 1000 |

- Pitch is parsed as the next float below value/1000 (`PresetManager.h:144`).
- Read at boot (file buffer 4096 bytes). Rewritten in place right after parsing (`ui.h:280-286`).
- After SAVE or COPY a flag is set; every 5 s the main loop renders the file and the 1 kHz SD callback writes it in 1 KB chunks every 50 ms to `presets_temp.json`, then deletes `presets.json` and renames (`ui.h:299-339`, `chompi_main.cpp:249-253`, `321-325`).
- Loading a slot applies all 11 values to the current engine (`MenuPage.h:669-713`). Volume is applied linear here; turning the knob applies value² (§12).
- Card profile: chromatic slots all default; slice slots have loop 280..460 (off) for slots 1-11.

### 5.3 StateSaver (RAM only, `StateSaver.h`, `MenuPage.h:1177-1296`)
Four snapshots: ChromaticA, ChromaticB, SliceA, SliceB. Lost at power off.

| Field | From |
|---|---|
| enc_values[2][4] | knob pages 0-1 of knobs 0-3 (pitch, start, end, delay main; sample vol, attack, release, delay mix) |
| filter, redux, pan, loop, sustain | engine params |
| randomness, feedback | delay |
| out_gain, comp, in_gain | output gain, final comp, input gain |
| sample_slot | 1..15 |
| monitor_mode | 0..2 |
| pattern, rest_pattern | arp |
| clock_div | division position 0..4 |
| play | engine playing |
| latch_state | bit1 latch, bit0 sustain |
| arp_randomness | |
| sequence | the note list |

Behaviour:
- Saving a slot also copies delay main, randomness, feedback, out gain, comp, in gain and monitor mode into the other engine's slot with the same letter (`StateSaver.h:93-100`).
- All four start from the boot defaults with slot 15; slice slots start with loop 0.
- A/B recall: snapshot the current engine into the current letter, store the other engine's play flag, then apply the target letter to both engines (params, sample slot, sequence, pattern, play, latch, division) and the shared FX. The playing note is stopped at the next step (`setTempNote`).
- Hold the active letter key 1 s: copy both engines' current-letter snapshots to the other letter; the other letter's LED blinks green for 1 s.

---

## 6. MIDI (`MidiManager.h`)
Ports: UART and USB, merged on input, both sent on output (`:44-47`, `173-240`, `272-288`).

### In
| Message | Condition | Action |
|---|---|---|
| Clock F8 | SYNC mode | advance both engines' step counters, tempo estimate |
| Start FA | SYNC and transport in | both engines play from the start, counters reset |
| Stop FC | SYNC and transport in | both stop |
| Note on, notes 24..72 | in channel | like a key press on the current engine. Transpose = note − 60. Notes 48..72 map to the panel key IDs; 24..47 get virtual IDs 32..55 (chromatic only, `ui.h:28-34`). Velocity ignored. Velocity 0 counts as note off |
| Note off | in channel | like a key release |
| CC 20..25 | in channel, CC in on, menu closed | sets knob (CC − 20) on its current page to value/127. CC 24 sets tempo = 160 + v × 320 (`NormalPage.h:752-761`) |
| CC 14 | as above, REC position | > 84 presses CHOMPI, < 42 releases (record) |
| CC 15 | as above | same thresholds for LOOP |

CC 26-31 are sent but not received.

### Out
Sent on the current engine's channel unless noted.

| Message | When |
|---|---|
| Note on (vel 127) / off (vel 0 on UART, 127 on USB) | key pressed/released while that engine is not playing; each sequencer step (note = stored transpose + 60); engine switch chokes; sustain on/off |
| CC 20-25 | knob turns on page 0: pitch, start, end, delay main, tempo, output gain |
| CC 26-30 | page 1: sample volume, attack, release, delay mix, input gain |
| CC 31 | filter (knob 0 page 2) |
| CC 24 | also on TEMPO release (tap) |
| CC 14 | CHOMPI press/release in REC position |
| CC 15 | LOOP press/release |
| Clock F8 | FREE mode, MIDI Clock Out on, chromatic engine playing; tempo × 12 / 60 per second (24 PPQN) |
| Start / Stop | PLAY start/stop in FREE mode with transport out enabled |

Value = knob × 127. Shift-menu params send nothing. With CC out off, no CCs at all.

---

## 7. SD card layout and samples
```
/CHOMPI_TEMPOv1_0.bin   firmware (loaded by the bootloader)
/options.json
/presets.json           (presets_temp.json during writes)
/Chromatic/chroma_a1.wav .. chroma_a14.wav
/Slice/slice_a1.wav .. slice_a14.wav
/Buffer/buffer.wav      start-up content of slot 15, read only
```
- File names must start with `chroma_a` / `slice_a`, contain `.wav`, and the number after the prefix (1..14) is the slot (`SampleManager.h:41-101`). FAT is case-insensitive (card uses lowercase folders).
- `buffer.wav` is shared by both engines as slot 15. It is never written by the firmware.
- Format: 48 kHz, 16-bit, stereo PCM, little-endian. The header is not checked. The loader reads the first 116 bytes and looks for `data` within them, takes its size, then reads raw bytes (`FileStreamingManager.cpp:68-125`). The `data` chunk must start within byte 116 and the file must be at least 116 bytes. Other formats play wrong. No resampling.
- Max 1,920,000 data bytes per file (10 s stereo); longer files are cut (`FileStreamingManager.cpp:90`).
- RAM: delay buffers 7.68 MB, record buffer 1.92 MB, 28 slots × 1.92 MB (`SampleManager.h:14-21`, `117-118`).
- Saved WAVs: 44-byte PCM header, stereo 16-bit 48 kHz (`FileStreamingManager.h:103-118`).
- Card profile: 14 chromatic samples (1.25-5.5 s), 14 slice samples (6-9.9 s), `buffer.wav` 1.33 s. All 48 kHz 16-bit stereo PCM; most have a 28- or 64-byte JUNK chunk before `fmt` (data at byte 80 or 116).

---

## 8. LEDs

Normal page (`NormalPage.h:219-522`):

| LED | Shows |
|---|---|
| Key LEDs | white while that key's voice sounds (the next sequencer note goes dark near the end of a step); in latch: list members red (chromatic) or yellow (slice); slice key 15 in latch shows its mode: red, yellow, orange |
| PITCH | p0: blue at the ends (v 0 or 1) → green → yellow → red at the centre (v .5); p1: blue → pink → red; p2: purple → white |
| START | p0: yellow → orange; p1: dim → full purple |
| END | p0: orange → red; p1: dim → full purple |
| MAGIC | p0: delay colour from `delayLeftColors`/`delayRightColors` by division, centre teal; frozen: brightness ramps with loop position. p1: yellow → orange → red |
| TEMPO pair | FREE: colour by tempo value blue → green → yellow → red; while playing the two LEDs alternate each step; held or SYNC: division colours (§3.9) |
| PLAY | teal = current engine playing, dim teal = other engine only |
| LOOP | orange sustain, red latch (chromatic), yellow latch (slice) |
| CHOMPI | REC position: red while recording, else input meter (dim → green → yellow → pink). SHIFT position: purple while pressed |
| VOLUME | p0: output meter × knob value; p1: blue → red by input gain; battery when held 2 s |

Shift menu (`MenuPage.h:73-517`):

| LED | Shows |
|---|---|
| White keys | slot has sample: purple (chromatic), green (slice), pink (slot 15); current slot white; in save/copy/erase modes they blink and selections show blue (target), green (copy source), red (erase) |
| KEY_16/17 | orange on current engine |
| KEY_18/19/20 | pink on current input |
| KEY_21/22 | yellow on current state |
| KEY_23/24/25 | erase red, copy green, save blue (only in their own mode or none) |
| PLAY | pattern: teal SEQ, green UP, yellow DOWN, orange PINGPONG, red RANDOM |
| LOOP | rest pattern: teal, green, yellow, orange, red in order |
| TEMPO pair | white at arp-randomness brightness |
| Knob LEDs | shift values: MAGIC randomness or feedback (white → purple above .4); VOLUME monitor mode colour after a press, else blue by comp amount; PITCH p1 pan teal/blue/green, p2 redux purple; START p1 / END p1 blue when loop / sustain on |

Boot: key LEDs show each slot's load status (white loaded, red failed).

---

## 9. Hard to reproduce in SuperCollider

| Item | Why | Suggestion |
|---|---|---|
| Step timing | firmware clock is a hardware timer; steps are applied at 0.5 ms block edges; division changes wait for the next eighth | run the sequencer in Lua with `clock.sync` at 24 PPQN (or use `clock.get_beat_sec`) and accept a few ms jitter, or schedule note bundles with timestamps |
| Sequencer logic | lots of edge cases (decouple, sustain, deferred retrigger, removal at step end, slice key 15 modes) | port `ArpeggiatorSequencer.h` to Lua line by line; it is pure state |
| Voice allocation by key ID | per-key voices with user/sequencer hold flags and priority stealing | keep allocation in Lua, 8 SC synths per engine addressed by index |
| Sample player | int16 linear interpolation, 256-frame loop crossfade measured in source frames, retrigger crossfade, reverse windows | a voice SynthDef with two `BufRd` heads and a `Phasor` each, crossfade on triggers; `BufRateScale` for non-48k files; or `PlayBuf` × 2 with `XFade2` |
| Slice env bug | slice ADSR runs at double speed | halve slice attack/release times to match |
| ADSR | DaisySP one-pole segments with shape 1 attack | `EnvGen` with `curve` approximations, or a custom `Env` with exponential release to −0.01 |
| DJ filter | BasicMMF uses a raw coefficient with resonance feedback; 104 ms smoothing | `RLPF`/`RHPF` (or `DFM1`/`MoogFF` from sc3-plugins) with Hz from −ln(1 − f) × sr/2π, Lag 0.1 |
| Sample-rate reducer | BLEP-corrected sample and hold | `Latch.ar(sig, Impulse.ar(rate))` or `Decimator` (sc3-plugins); aliasing differs slightly |
| Granular delay | read heads moving at −1, 0.5, 2 per sample with 1024-sample sine crossfades; fixed L/R offsets 960/480; events chosen per clock step | buffer + `BufWr`, two read voices using `Phasor`-driven `BufRd`, events and pans sent from Lua on each step; crossfade with `Line`/`EnvGen` |
| Freeze | separate capture buffer of delay output, loop restarts on clock tick multiples with 256-sample through-zero fades | second buffer written by `BufWr` while unfrozen; when frozen, a `Phasor` reset by a trigger from Lua (or an SC clock divider) |
| Feedback loop | sample-accurate feedback inside the delay | SC `LocalIn`/`LocalOut` adds one block of delay (64 samples on norns); negligible for delays ≥ 32nd note, or do it inside the buffer write |
| Reverb | Clouds/Rings topology with 16-bit storage and LFO-modulated taps | rebuild with `AllpassN`/`DelayC` and the given sample lengths, feedback via `LocalIn`; or use `JPverb` as a stand-in |
| Ducking and output comp | custom per-sample peak followers with fixed coefficients | `Amplitude.ar` / `LagUD` with times: .05/sample ≈ 0.4 ms attack, .0002/sample ≈ 104 ms release; gain slew .001/.005 ≈ 21/4 ms |
| Mic filter | very narrow Svf notches (res .99) tuned to Chompi's mic noise | `BRF` with small rq, or skip on norns (different mic) |
| Smoothing | fonepole .001 on most params | `Lag.kr(0.02)` |
| Recording | int16 clip, 10 s cap, monitor-mode-dependent source | `RecordBuf` into a 10 s stereo buffer with `clip2(1)` |
| Memory | 29 × 10 s stereo slots | about 111 MB as float buffers in SC, fine on norns but load lazily |
| MIDI clock out | only while chromatic plays | norns clock can output MIDI clock; gate it the same way if exactness matters |

---

## 10. Shared with TAPE
TAPE source: `firmware/chompi-tape/code/src`.

Identical files: `BasicMMF.h`, `encoder.cpp`, `encoder.h`, `EnvFollower.h`, `fx_engine.h`, `MicFilter.h`, `temp_led_stuff.h`, `ui_utils.h`.

Nearly identical:
- `DJFilter.h`: TEMPO clamps lp to .98 and hp to .9 (`DJFilter.h:68`, `71`); TAPE .99 and 1.0.
- `limiter.h`: TAPE `Process()` scales by 0.7 before SoftLimit. TEMPO only uses `ProcessComp`, so no effect here.
- `reverb.h`: TEMPO adds an unused `SetFreeze`/`freeze_` path; otherwise the same.
- `NoSDPage.h`, `RainbowWavePage.h`: include line only.
- `TestPage.h`: TAPE sends test MIDI notes and checks the line-in jack; TEMPO has these commented out.
- `chompi_sram.lds`: different SRAM split. `Makefile`: one comment.

Same UI conventions (same tables): `key_map`, `led_map`, `midi2key`, `encoder_map`, colour constants, `kEncoderFineStep` .003 and `kEncoderCoarseStep` .01, ×3 on knobs 1/2/3/5, CHOMPI + toggle for shift/record, CC 20-25 on page 0, CC 14/15 for CHOMPI/LOOP, `options.json` `"chompi"` name/value format, boot combos, battery handling, SD-lost handling.

Different: TAPE `cc_map` pages 1-2 are {28..31, 32} and {33 on knob 3}; TEMPO {26..29, 30} and {31 on knob 0}. TAPE `knob_num_pages` = {2,2,2,3,1,2}, TEMPO {3,2,2,2,1,2}. TEMPO's `hardware.h` queues MIDI out through `MidiManager` (DMA UART) instead of sending directly. Everything in §3 (engines, clock, arp, delay, FX chain), `PresetManager`, `OptionsManager` fields and `StateSaver` is TEMPO's own.

---

## 11. OMX-27 notes
- The 25 Chompi keys are notes 48..72; the firmware's own MIDI-in path (note − 60 transpose) is a good model for OMX note keys.
- Chompi encoders are relative with page-dependent step sizes (§2.2). OMX pots are absolute, which matches the firmware's CC-in path (value/127 on the knob's current page). Pages then need pickup or jump handling.
- Needs dedicated controls or combos for: CHOMPI (shift/record), the toggle position, PLAY, LOOP, and the six knob clicks (page cycle, freeze, tap tempo/division hold).

---

## 12. Bugs, oddities and dead code
Reproduce these only if matching behaviour exactly matters.

1. MIDI note velocity is never stored; output is always 127 / 0 (`hardware.h:437-443`, `MidiManager.h:186`).
2. Slice voices run their envelope twice per sample, so slice attack/release are half as long and R is one envelope step ahead of L (`SliceEngine.h:48-49`).
3. "Monitor Position" option is checked under `field == 4`, so it is never applied; monitor mode always starts at 0 (`OptionsManager.h:250`).
4. COPY always writes to the chromatic bank (`dst_engine` fixed 0), even in slice mode (`MenuPage.h:869`).
5. `copyRamToRam` copies 4× the sample's byte count, overrunning into the next slots' RAM (`SampleManager.h:340`, `343`).
6. In SYNC mode, recalling an A/B state sets the MIDI clock division to the position index 0..4 instead of a clock count (`clockManager.h:257`, `MenuPage.h:1295`).
7. When recording fills the 10 s buffer it stops, but the engine is not reloaded with the new length (`FxEngine.h:176-178`).
8. Sample volume: knob applies value², preset/state recall applies value linear (`NormalPage.h:816`, `MenuPage.h:703`, `1286`).
9. MIDI notes below 48 use key IDs 32..55, past the end of `keyMap` (32 entries) used for arp sorting (`ArpeggiatorSequencer.h:21`, `887`).
10. `updateSlices` indexes `sliceMap[-1]` for unused voices (`SliceEngine.h:588`).
11. ARP_PP direction is a function-static flag shared by both engines (`ArpeggiatorSequencer.h:799`, `850`).
12. Monitor mode 2 always adds line-in to headphones, and recording from MIC in mode 2 also records line-in (`FxEngine.h:144-146`).
13. MIDI clock out only runs while the chromatic engine plays (`chompi_main.cpp:176`).
14. In the shift menu, PLAY/LOOP as "slot 16" in copy mode is unreachable (`MenuPage.h:1077-1090`). The MAGIC-press case falls through into the toggle case (harmless, `MenuPage.h:838-841`).
15. CC 20 with quantised normal pitch passes the CC value as detent count (`NormalPage.h:807-809`).
16. Black keys in slice latch/arp mode join the list but make no sound (silent steps).
17. Dead: `granularDelay2.h` (grain-cloud variant with 12 grains: delay below .45, random grains above .55, probabilities and sizes from the knob; never compiled); `ArpeggiatorSequencer::REST` random event; per-voice `filter_`/`filt_env` in `sampleVoice`; `lim_l_`/`lim_r_` in engines; slice `osc`; `Reverb::SetFreeze`; `DJFilter` `hp_ > .8` branch; `fillDefaultSample`; `reverse`/`saturate_amt_` fields in engines; `clockManager` `processMidiClock` alpha and `noteTime`.
18. Engine switch re-runs even if that engine is already selected (comment `MenuPage.h:907`).
