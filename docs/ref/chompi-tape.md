# CHOMPI TAPE 2.0: functional spec for the norns port

Reference for porting the CHOMPI TAPE firmware to norns (Lua script plus SuperCollider engine) with an OMX-27 as the control surface.

Sources:

- Firmware: `nidhogg-ref/chompi/firmware/chompi-tape/code/src` (all `file:line` refs below are relative to this folder unless a path is given).
- DaisySP and libDaisy code used by it: `chompi-tape/code/libs`.
- Factory card: `nidhogg-ref/chompi/firmware/card-profiles/tape-2.0`.
- Hardware: `nidhogg-ref/chompi/hardware/hardware-pcb` (BOM, schematic PDF).

Words used here:

- **Play mode** and **Record mode**: the two positions of the mode switch (`switch_state` true and false). The code comments call Record mode "switch up".
- **Shift**: the CHOMPI key held in Play mode. It opens the menu page (`MenuPage.h`).
- **JAMMI** and **CUBBI**: the two voice modes. JAMMI plays one sample chromatically, CUBBI plays one sample per key.
- **Slot 15**: the RAM sample buffer (what the CHOMPI key records). **Slot 16**: the looper buffer, used only in copy/save.
- Knob values are 0..1 floats stored in `enc_values[page][knob]`.

---

## 1. Hardware

From the BOM (`hardware-pcb/CHOMPI_Rev4_BOM.csv`) and `hardware.h`:

- Daisy Seed2 DFM (STM32H750, 64 MB SDRAM) plus a PCM3060 second codec.
- 28 key switches (Kailh hot-swap) read through 5 chained CD4021 shift registers (`hardware.h:46-94`, `hardware.h:156-161`).
- 6 push encoders (SW1..SW6). Four read through a sixth CD4021, encoder 5 and 6 on GPIO (`hardware.h:145-168`).
- One 2-position slide switch `SW_NORMAL` (the mode switch, `SW_TOG`).
- LEDs: 6 x 8 mm RGB and 4 x 5 mm RGB through-hole (the "PTH" chain, 10 LEDs) and 25 reverse-mount RGB LEDs under the keys (the "SMT" chain) (`temp_led_stuff.h:23-24`).
- MEMS mic (MP23ABS1), five 3.5 mm jacks: audio in (stereo aux), audio out (stereo line), headphones (TPA6110 amp), MIDI in and MIDI out (TRS, opto H11L1).
- USB-C (USB MIDI device, charging), microSD, LiPo with MP2722 charger.

### 1.1 Audio I/O channels

`chompi_main.cpp:46-58`, `hardware.h:103-127`:

| Channel | Input | Output |
|---|---|---|
| 0 | Mic (Seed codec) | Headphone L |
| 1 | unused | Headphone R |
| 2 | Aux in L (PCM3060) | Line out L |
| 3 | Aux in R (PCM3060) | Line out R |

- Sample rate 48 kHz, block size 24 frames (`hardware.h:123-124`).
- Plugging a cable into the input jack switches the input source to LINE_IN, unplugging switches it to MIC (`chompi_main.cpp:83-90`).

### 1.2 Key numbering

The UI uses the shift-register bit index as the button ID (`hardware.h:46-94`). MIDI note out comes from `key_map` (`NormalPage.h:15-56`). Slot comes from `KeyToSlot` (`DSPEngine.h:103-121`). Key LED index comes from `led_map` (`NormalPage.h:58-99`).

25-key keyboard, C3 to C5 (MIDI 48..72). White keys KEY_1..KEY_15, black keys KEY_16..KEY_25, then three function keys.

| Key | Button ID | Note out | Slot | Key LED | Shift function |
|---|---|---|---|---|---|
| KEY_1 (C) | 15 | 48 | 1 | SMT 24 | select slot 1 |
| KEY_16 (C#) | 7 | 49 | none | SMT 0 | JAMMI mode / next JAMMI bank |
| KEY_2 (D) | 8 | 50 | 2 | SMT 23 | select slot 2 |
| KEY_17 (D#) | 12 | 51 | none | SMT 1 | CUBBI mode / next CUBBI bank |
| KEY_3 (E) | 9 | 52 | 3 | SMT 22 | slot 3 |
| KEY_4 (F) | 10 | 53 | 4 | SMT 21 | slot 4 |
| KEY_18 (F#) | 13 | 54 | none | SMT 2 | input: mic |
| KEY_5 (G) | 11 | 55 | 5 | SMT 20 | slot 5 |
| KEY_19 (G#) | 14 | 56 | none | SMT 3 | input: aux (line in) |
| KEY_6 (A) | 16 | 57 | 6 | SMT 19 | slot 6 |
| KEY_20 (A#) | 21 | 58 | none | SMT 4 | input: resample |
| KEY_7 (B) | 17 | 59 | 7 | SMT 18 | slot 7 |
| KEY_8 (C, middle) | 18 | 60 | 8 | SMT 17 | slot 8 |
| KEY_21 (C#) | 22 | 61 | none | SMT 5 | FX pre-looper |
| KEY_9 (D) | 19 | 62 | 9 | SMT 16 | slot 9 |
| KEY_22 (D#) | 23 | 63 | none | SMT 6 | FX post-looper |
| KEY_10 (E) | 20 | 64 | 10 | SMT 15 | slot 10 |
| KEY_11 (F) | 24 | 65 | 11 | SMT 14 | slot 11 |
| KEY_23 (F#) | 29 | 66 | none | SMT 7 | erase |
| KEY_12 (G) | 25 | 67 | 12 | SMT 13 | slot 12 |
| KEY_24 (G#) | 30 | 68 | none | SMT 8 | copy |
| KEY_13 (A) | 26 | 69 | 13 | SMT 12 | slot 13 |
| KEY_25 (A#) | 31 | 70 | none | SMT 9 | save |
| KEY_14 (B) | 27 | 71 | 14 | SMT 11 | slot 14 |
| KEY_15 (C) | 28 | 72 | 15 (RAM) | SMT 10 | slot 15 (RAM sample) |
| KEY_26 CHOMPI | 5 | (CC 21) | | PTH 0 | shift / confirm |
| KEY_27 PLAY | 33 | (CC 26) | 16 in menu | PTH 7 | overdub level down |
| KEY_28 LOOP | 34 | (CC 27) | 16 in menu | PTH 8 | overdub level up |

White key n is slot n. Black keys have no slot.

### 1.3 Encoders

Hardware encoder index maps to a logical knob through `encoder_map = {1,2,3,0,4,5}` (`ui.h:30`).

| Logical knob | HW encoder | Name used here | Push switch | Pages |
|---|---|---|---|---|
| 0 | SW4 | Pitch | ENC_4_SW | 2 |
| 1 | SW1 | Start | ENC_1_SW | 2 |
| 2 | SW2 | End | ENC_2_SW | 2 |
| 3 | SW3 | Magic (FX) | ENC_3_SW | 3 |
| 4 | SW5 | Transport (looper) | ENC_5_SW (GPIO) | 1 |
| 5 | SW6 | Volume | ENC_6_SW | 2 |

Pages per knob: `knob_num_pages = {2,2,2,3,1,2}` (`NormalPage.h:122`). Each knob has its own current page (`knob_page[6]`, `ui.h:476`).

Detent sizes (`ui.h:328-341`, `NormalPage.h:101-103`, `NormalPage.h:929-947`):

- Knobs 0 and 4 send +-1 per detent, the others +-3.
- Normal page step: coarse 0.01 x turns, fine 0.003 x turns.
- Fine is used for pitch page 0 (free mode), start, end and looper pitch (free mode). So pitch moves 0.003 per detent, start/end 0.009, looper pitch 0.003, everything else 0.03.
- Menu page step is 0.01 x turns (0.03 per detent on knobs 1,2,3,5; 0.01 on knob 0 page 1 for pan), with free-mode pitch at 0.003 (`MenuPage.h:414`, `MenuPage.h:431`, `MenuPage.h:523`).

### 1.4 LEDs

PTH chain (`NormalPage.h:169-181`): 0 CHOMPI key, 1 Pitch knob, 2 Start knob, 3 End knob, 4 Magic knob, 5 and 6 the two transport LEDs (5 = reverse side, 6 = forward side), 7 PLAY key, 8 LOOP key, 9 Volume knob. 0..4 and 9 are 8 mm, 5..8 are 5 mm.

SMT chain: 25 key LEDs, index per key in the table above.

Colours are defined at `NormalPage.h:109-120`. Bank colours: a purple, b orange, c teal, d dark orange, e yellow-green (`NormalPage.h:242-254`, `MenuPage.h:381-397`).

---

## 2. Pages and modes

Page stack (`ui.h` with libDaisy `UI`): events go to the top page first and fall through to lower pages when a page returns false (`libDaisy/src/ui/UI.cpp:178-234`). NormalPage is always at the bottom. MenuPage sits on top while shift is active.

Boot order (`ui.h:47-97`, `chompi_main.cpp:179-226`, `chompi_main.cpp:383-397`):

1. BootPage animation while every sample file is checked (see 6.4).
2. RainbowWave animation, ignores all input until done.
3. NormalPage. Input is ignored for the first 1500 ms (`NormalPage.h:229-236`).

Boot combos, read for 0.5 s at power-up (`chompi_main.cpp:383-397`):

- Hold CHOMPI + PLAY + LOOP: battery shipping mode (power off).
- Hold the Volume knob push: test mode (TestPage, hardware test, not needed for the port).

No SD card: voices fall back to JAMMI slot 15, menu shows red keys and file functions (mode/bank, save, copy, erase) are disabled (`chompi_main.cpp:115-138`, `MenuPage.h:326-329`).

### 2.1 Mode switch

`SetSwitchState` (`NormalPage.h:1035-1043`), `Draw` (`NormalPage.h:616`):

- Play mode: input monitoring off (except in BOTH and SEND_RET monitor positions, see 4.9). CHOMPI key is shift.
- Record mode: input monitoring on. CHOMPI key records into the RAM sample (slot 15). Knob LEDs 1..4 go dark, looper LEDs dim to 70% (`kRecDim`). Keys, knobs and looper still work.
- Moving the switch to Play mode while a sample recording is running stops the recording.

### 2.2 Normal page: keys

`NormalPage::OnButton` (`NormalPage.h:673-856`). Everything is ignored while a file copy runs (`NormalPage.h:677`).

White and black keys (`NormalPage.h:817-852`):

- Press: in CUBBI mode, first load that slot's settings (`OpenCubbiSlot`, `NormalPage.h:858-910`). Then queue a START request with transpose `note - 60`, key ID and velocity 127. Then if the looper is record-armed, start looper recording. Then send MIDI note on (velocity 127).
- Release: queue STOP and send MIDI note off.
- In CUBBI mode black keys queue START but nothing plays (no slot).

CHOMPI key (`NormalPage.h:783-814`):

- Record mode: sends CC 21 (127 press, 0 release). Starts sample recording on press. With Record Latch off it stops on release; with latch on a second press stops it.
- Play mode: opens the menu (`ui.h:309-319`). Also sets the MIDI out channel index to 1 while held and 0 on release (`NormalPage.h:790-793`). See 7.3.

PLAY key: `LooperPlayButton(rising)`, sends CC 26 127/0 (`NormalPage.h:767-773`).

LOOP key: `LooperRecordButton(rising)` unless a sample recording is running, sends CC 27 127/0 (`NormalPage.h:774-781`). Looper button logic is in 4.7.

### 2.3 Normal page: knobs

`NormalPage::OnEncoderTurned` (`NormalPage.h:912-1014`) and the continuous parameter push in `Draw` (`NormalPage.h:274-527`).

| Knob | Page 0 | Page 1 | Page 2 |
|---|---|---|---|
| 0 Pitch | Sample pitch/direction (default 0.83 = 1x) | Sample gain (default 0.704 = unity) | |
| 1 Start | Window start (default 0) | Attack (default 0) | |
| 2 End | Window end (default 1) | Release (default 0) | |
| 3 Magic | Reverb + delay amount (default 0) | Lo-fi saturation (default 0) | Filter, centre is off (default 0.5) |
| 4 Transport | Looper speed when playing, scrub when paused (default 0.75 = 1x) | | |
| 5 Volume | Main volume (default 0.84) | Input gain (default 0.75) | |

Defaults: `enc_defaults` (`ui.h:16-20`). Knob 4 page 1 and 2 entries and knob 0..2 page 2 entries are unused.

Push actions (release edge):

- Pitch, Start, End, Magic: next page (`NormalPage.h:693-705`).
- Volume: short click (under 2 s) next page. Holding it 2 s shows battery level on LED 9: white full, green high, yellow medium, red low (`NormalPage.h:477-502`, `NormalPage.h:707-720`).
- Transport: resets looper speed to 1x and the knob to 0.75, sends CC 24 = 95 (`NormalPage.h:723-734`). Press also sets speed 1x.

Knob details:

- Pitch page 0: free or quantised depending on the "Pitch Quantize In Shift Menu" option (normal page is free when the option is true, the default) (`NormalPage.h:143`, `NormalPage.h:952-958`). Mapping in 4.2.
- Start/End page 0: end must stay at least 0.01 above start. The voice also refuses a window shorter than 4096 frames (about 85 ms), and in streaming mode refuses to move the boundary into the region the play head has already buffered. A refused move in the shrinking direction is reverted (`NormalPage.h:975-1001`, `SampleReader.h:86-136`, `SampleReader.h:154-203`).
- Transport: only changes looper speed while the looper is playing. When paused, turns are fed to the scrub and the knob value does not change (`NormalPage.h:959-973`).
- Changes on knobs 0, 1, 2 save the current slot preset (`NormalPage.h:1008-1011`, `DumpValuePresets` `NormalPage.h:1016-1033`).
- Every physical turn sends a CC (see 7.2). Turns that arrive as incoming CC do not.

### 2.4 Normal page LEDs

`NormalPage::Draw` (`NormalPage.h:219-671`):

- Key LEDs: white while that key's voice is playing. In CUBBI: slots with a file show the bank colour at 25% (slot 15 in pink). In JAMMI: C3, C4 and C5 (button IDs 15, 18, 28) show the bank colour at 25% as landmarks. These idle LEDs are hidden in Record mode while monitoring the mic. Bank colour is pink when JAMMI slot 15 is active.
- LED 1 (Pitch), page 0: blue, green, yellow, red as the knob moves away from centre (`color_quad_xfade` on distance from 0.5). Page 1: blue, pink, red with gain.
- LED 2 (Start): yellow to orange; page 1 dim to bright purple for attack.
- LED 3 (End): orange to red; page 1 purple for release.
- LED 4 (Magic): page 0 teal, mid blue, blue (split delay: green to blue); page 1 yellow, orange, red; page 2 purple, pink, white.
- LEDs 5/6 (Transport): off when the looper is empty. Playing: the side for the current direction lights blue, green, yellow, red by distance from centre, the other side fades in red above 80%. Paused: the side matching the scrub direction lights white with scrub speed.
- LED 7 (PLAY): off when empty, white when armed, teal during the first recording, teal x (1 - position) when playing, white x (1 - position) when paused.
- LED 8 (LOOP): blinking red (300 ms) when armed, red during first recording, yellow x position when overdubbing, white x position otherwise.
- LED 9 (Volume): page 0 the output level meter (dim, green, yellow, pink) x volume; page 1 blue to red with input gain.
- LED 0 (CHOMPI): Record mode shows the input meter, solid red while recording, pink blink while copying files. Play mode shows purple while held.

### 2.5 Shift menu (MenuPage)

Opened by pressing CHOMPI in Play mode (`ui.h:309-319`). `OnFocusGained` resets the quantised pitch step state if quantising in shift, and preselects the current slot (`MenuPage.h:1040-1058`).

Closing rule `IsClosable` (`MenuPage.h:1062-1100`), checked every audio block (`ui.h:267-271`). The menu closes when at least 1 s has passed since the last save/copy/erase confirm and one of:

- a save or copy finished, or an erase finished;
- nothing is pending and CHOMPI is released;
- nothing is running and the switch moved to Record mode.

So a plain shift is momentary, while an erase/copy/save selection keeps the menu open after CHOMPI is released.

On close: after saving or copying into slot 16, the looper is reloaded from its buffer (`LooperOpenFile`, stopped, speed 1x). After saving or copying into a JAMMI slot, that slot is selected. After erasing the selected JAMMI slot, slot 15 is selected.

#### Shift knobs

`MenuPage::OnEncoderTurned` (`MenuPage.h:409-546`). Only active when no save/copy/erase is pending. Incoming CCs fall through to the normal page.

| Knob | Shift + turn |
|---|---|
| 0 Pitch, page 0 | Pitch, quantised by default (free if the option is false) |
| 0 Pitch, page 1 | Pan, 0.01 per detent (stored only in the preset) |
| 1/2 Start/End, page 0 | Move the whole window (start and end together), stops at 0 and 1 |
| 1/2 Attack/Release, page 1 | Set attack and release to the same value |
| 3 Magic, page 0 | Delay time, which also sets reverb decay (default 0.5) |
| 3 Magic, page 1 | Warble (wow and flutter) (default 0) |
| 3 Magic, page 2 | Filter resonance (default 0) |
| 4 Transport | Looper speed, quantised by default |
| 5 Volume | Output compressor amount (default 0) |

Shift + knob 0, 1, 2 changes save the slot preset.

#### Shift pushes

`MenuPage.h:625-733`:

- Pitch push: page 0 resets pitch to 1x forward. Page 1 resets gain to 0.704 and pan to centre. LED 1 white while held.
- Start push: toggle auto-loop (all voices). LED 2 white for on, off for off.
- End push: toggle sustain (all voices). LED 3 white for on.
- Magic push: reset all FX: reverb/delay 0 (0.5 with split delay), lo-fi 0, filter 0.5, delay time 0.5, resonance 0, warble 0. LED 4 white while held.
- Volume push: cycle monitor position HP, BOTH, SEND_RET (4.9). LED 9 shows blue for BOTH, orange for HP, yellow for SEND_RET until the knob is turned again.
- Transport push: falls through to the normal page (looper speed reset).

#### Shift keys

`MenuPage.h:735-1035`:

- KEY_16 (JAMMI): if already JAMMI, next JAMMI bank page (a to e, wrapping). The playing slot does not change until a slot is chosen; `voice_bank_` keeps the bank of the loaded slot. If in CUBBI, switch to JAMMI, return to the voice bank and reload that slot with its settings.
- KEY_17 (CUBBI): if already CUBBI, next CUBBI bank and stop voices. Else switch to CUBBI and stop voices.
- KEY_18/19/20: input source mic, line in, resample.
- KEY_21/22: FX before or after the looper (crossfaded switch, 4.8).
- KEY_23 erase, KEY_24 copy, KEY_25 save: see 2.6.
- White keys, JAMMI, nothing pending: select that slot if its file exists (loads its preset, `SetVoiceSlot` `MenuPage.h:566-623`). Slot 15 always exists. Nothing happens in CUBBI.
- PLAY/LOOP with nothing pending: overdub level -0.1/+0.1, applied on both press and release, so one tap moves 0.2 (`MenuPage.h:952-956`). Range 0..1, default 1. LEDs 7/8 show the level as white brightness.
- Key releases of white keys fall through so notes still stop. Note-ons are swallowed by the menu.

Menu LEDs (`MenuPage.h:62-406`): key LEDs show which slots have files in the bank colour (slot 15 pink), the selected JAMMI slot white, mode LED (SMT 0 or 1) in the bank colour, input source LED (SMT 2..4) pink, FX pre/post LED (SMT 5/6) yellow, erase red, copy green, save blue (dim grey when nothing to save). While holding shift: LED 1 shows the pitch colour or pan (purple left, yellow right), LED 4 shows the shift value of the magic page as white brightness, LED 9 shows compressor amount in blue.

### 2.6 Save, copy, erase

All three are file operations on the card. Selections can cross banks and modes (you can change bank/mode between choosing source and destination).

Save (KEY_25) (`MenuPage.h:925-947`, `MenuPage.h:741-759`):

1. Press Save: SAVE_SEL. All slot LEDs blink; empty ones show dim grey. Slot 15 shows pink.
2. Press a white key 1..14 (destination), or PLAY/LOOP for the looper (slot 16).
3. Press CHOMPI to confirm. The RAM sample is written to `<mode>_<bank><slot>.wav` and its `_double` file. The RAM slot preset (pitch, start, end, etc.) is copied to that slot. Saving to slot 16 copies the RAM sample into the looper.
4. Press Save again to cancel.

Copy (KEY_24) (`MenuPage.h:899-923`, `MenuPage.h:760-788`, `MenuPage.h:958-1029`):

1. Press Copy: COPY_SRC. Choose a source: a white key with a file, or PLAY/LOOP if the looper is not empty. State moves to COPY_DEST.
2. Choose a destination: any white key 1..15, or PLAY/LOOP (if the source is not the looper). Destination may not equal the source.
3. CHOMPI confirms. Supported: file to file, file to RAM (15), file to looper (16), RAM to file, RAM to looper, looper to file, looper to RAM. The preset is copied along.
4. Copy again cancels.

Erase (KEY_23) (`MenuPage.h:878-897`, `MenuPage.h:789-800`):

1. Press Erase: ERASE_SEL.
2. Choose a white key 1..14 with a file.
3. CHOMPI deletes the wav and `_double` and invalidates the preset.

During the operation the CHOMPI LED blinks white (250 ms), with a selection made it blinks red.

---

## 3. Voice modes

### 3.1 JAMMI

- One sample (the selected slot of the JAMMI voice bank) loaded on all 7 voices (`DSPEngine.h:1449-1475`).
- Each key plays it at `2^((note - 60) / 12)` times the global pitch (`DSPEngine.h:761-762`, `DSPEngine.h:1530`). Middle C (KEY_8) is unity, the keyboard spans -12..+12 semitones, MIDI notes extend this to -36..+12.
- All knobs act on all voices. One preset per slot.
- Startup state: JAMMI, bank a, slot 15 with the built-in test tone (`DSPEngine.h:212-214`, see 4.6).

### 3.2 CUBBI

- Each white key plays its own slot of the CUBBI bank at its stored pitch (no transposition, varispeed 1) (`DSPEngine.h:711-751`, `DSPEngine.h:763-764`).
- Pressing a key loads that slot's 9 preset values into the knob values and into `cubbi_*` fields; the voice gets them when it starts (`NormalPage.h:858-910`, `DSPEngine.h:1436-1447`).
- Knob changes act only on the most recently started voice (`latest_voice`), and save into that slot's preset.
- Slot 15 (top C) plays the RAM sample.
- Black keys do nothing.

### 3.3 Voice allocation

`StartPlayback` (`DSPEngine.h:652-768`), 7 voices (`kMaxPoly`, `DSPEngine.h:28`):

1. A voice already assigned to this key.
2. Else a voice that is idle and has no key.
3. Else any idle voice.
4. Else the voice started longest ago.

Key requests go through a 32-entry FIFO and only one is handled per audio block (24 frames, 0.5 ms) (`DSPEngine.h:782-793`, `DSPEngine.h:804-807`). `StopPlayback` releases every voice holding that key.

---

## 4. Audio engine

### 4.1 Signal flow

`Engine::Process` (`DSPEngine.h:407-567`), per block:

1. Sum all 7 voices into the working buffer (L/R) (`DSPEngine.h:418-438`).
2. `SoftClip` each sample of the voice sum (`DSPEngine.h:440-444`). SoftClip is `x(27+x^2)/(27+9x^2)` for |x| <= 3, else +-1 (`DaisySP/Source/Utility/dsp.h:220-234`).
3. Pre-FX input monitor, depending on monitor position (4.9) (`DSPEngine.h:447-460`).
4. Looper state updates (`DSPEngine.h:464-466`).
5. If FX pre-looper: FX chain, then looper. Else looper, then FX chain (`DSPEngine.h:469-481`).
6. Copy working buffer to line out (`DSPEngine.h:484-485`).
7. Post-looper monitor into headphones only (HP and SEND_RET positions) (`DSPEngine.h:488-498`).
8. Resample handling and input level meter (`DSPEngine.h:501-522`).
9. Record into the RAM sample if recording (`DSPEngine.h:526-538`).
10. Output gain and compressor per output pair, output meter (`DSPEngine.h:541-566`).

The looper adds its playback to the live signal (the live signal always passes).

### 4.2 Pitch mapping

Free mode, knob value v (`DSPEngine.h:1023-1038`, also `NormalPage.h:895-905`, `MenuPage.h:600-613`):

```
x = 2v - 1                      (-1..1)
s = sign(x), with x = 0 treated as +1
|x| < 0.33:  p = x * 1.484848 + 0.01 s      (0.01x .. 0.5x)
|x| < 0.66:  p = (x - 0.33 s) * 1.515151 + 0.5 s   (0.5x .. 1x)
else:        p = (x - 0.66 s) * 2.941176 + 1.0 s   (1x .. 2x)
speed = |p|, reverse = p < 0
```

Knob 0.83 is 1x forward, 0.17 is 1x reverse, 0.5 is 0.01x forward.

Quantised mode (`DSPEngine.h:946-1015`):

- Detents accumulate 0.25 each; every 4 detents makes one step (`encoder_chunk`).
- Steps alternate between a fifth and a fourth so two steps make an octave: up multiplies by 1.49830707688 (+7 semitones) then 1.33483985417 (+5); down multiplies by 0.749153538438 (-5) then 0.667419927085 (-7). A `fifth` flag tracks the parity. In reverse the multipliers swap so clockwise always means "towards faster forward".
- A step that would go past 2x is ignored.
- Below 0.0625x the direction flips: the speed stays at the previous magnitude and reverse toggles. So the knob runs continuously from 2x reverse through slow to 2x forward.
- From 1x the grid is 2, 1.5, 1, 0.749, 0.5, 0.375, 0.25, 0.187, 0.125, 0.094, 0.0625.
- The knob value is recomputed from the new speed for the LED: speed < 0.5: (p - 0.01) x 0.673469; < 1: (p - 0.5) x 0.66 + 0.33; else (p - 1) x 0.34 + 0.66; then forward 0.5 + y/2, reverse (1 - y)/2.
- Step parity resets on pitch reset, menu open (when shift quantises) or menu close (when normal quantises) (`MenuPage.h:1046-1050`, `MenuPage.h:1090-1094`).

### 4.3 Sample voice (FileSampleReader)

`SampleReader.h`. One per voice. Streams 16-bit stereo from the card, or reads the RAM sample for slot 15.

Parameters and curves:

| Parameter | Engine curve | Voice curve | Result | Refs |
|---|---|---|---|---|
| Gain (knob 0 p1) | | `2 v^2 + 0.01` | 0.01..2.01, default 0.704 = 1.0 | `SampleReader.h:256-262` |
| Pan (shift knob 0 p1) | | R = min(2p, 1), L = min(2 - 2p, 1) | linear balance, centre = both 1 | `SampleReader.h:265-276` |
| Attack (knob 1 p1) | `v^3 + 0.01` | `x * 20 + 0.001` s | 0.201 .. 20.2 s | `DSPEngine.h:822-835`, `SampleReader.h:280-284` |
| Release (knob 2 p1) | `v^3 + 0.01` | `x * 4 + 0.001` s | 0.041 .. 4.04 s time constant | `DSPEngine.h:837-850`, `SampleReader.h:286-290` |
| Velocity | | `vel / 127` | keys 127 = 1.0, MIDI (vel+1)/127 | `SampleReader.h:51` |
| Start/End | | fraction of the data length | min window 4096 frames | `SampleReader.h:86-217` |

Gain and pan are smoothed with a one-pole, coefficient 0.001 per sample (`SampleReader.h:419-427`). They jump when the voice is idle.

Envelope: DaisySP `Adsr` with sustain level 1 (`SampleReader.h:43-44`, `DaisySP/Source/Control/adsr.cpp`):

- Attack: shape 0, which targets 1.01 with a one-pole so the level reaches 1.0 exactly at the attack time. The curve is `1.01 (1 - e^(-4.615 t / T))`, fast at first: about 60% at T/5. Even at knob 0 the full rise takes 0.2 s.
- Decay stage holds at 1 (sustain 1).
- Release: one-pole towards -0.01 with time constant T (reaches 0 after about 4.6 T).
- Retrigger is soft (continues from the current level).

Gate behaviour (`SampleReader.h:400-411`, `SampleReader.h:570-574`, `SampleReader.h:595-691`):

| Auto-loop | Sustain | Behaviour |
|---|---|---|
| on (default) | on (default) | Loops the start..end window while the key is held, releases on key up |
| off | on | Plays once to the end, or until key up (release). The loop fade (see click and loop envelopes) takes the output down near the end, then the envelope resets |
| on | off | Attack, then release starts at once (one-shot swell). Loops during the release tail |
| off | off | Attack then release, stops at the end of the window |

`OTE()` (end reached) uses the read position; non-looping voices stop instantly when the end is reached (`SampleReader.h:571-574`, `SampleReader.h:695-719`).

Reverse: reads from end to start. Changing direction while playing fades the output out over the buffered samples (`rev_env`) and back in (`SampleReader.h:849-862`, `SampleReader.h:522-528`).

Varispeed: linear interpolation between two frames, position accumulator `rpos_frac_` advanced by `varispeed_factor x global_pitch` per output frame (`SampleReader.h:439-561`). A new key speed set while playing waits until the buffered audio drains (`varispeed_counter`) (`SampleReader.h:819-837`).

Click and loop envelopes:

- Retrigger of a playing voice: `click_env` ramps down over the buffered samples (at most 300 frames, `kMaxClickSamps`, `-2/300` per frame so about 150 frames), then the voice jumps to start and the envelope retriggers, and `click_env` ramps back up at 0.004 per frame (250 frames) (`SampleReader.h:889-910`, `SampleReader.h:465-494`).
- Fresh start of an idle voice: `click_env` from 0 up at 0.01 per frame (100 frames) (`SampleReader.h:931-949`).
- Loop wrap (streaming): `loop_env` fades out over the last up to 480 frames before the end point and back in after the jump (`SampleReader.h:666-680`, `SampleReader.h:504-520`). If the buffer was empty it fades at -0.0042 per frame. RAM voices fade over the last 300 frames (`-2/300`) and jump when the fade hits 0 (`SampleReader.h:575-582`).
- Choke (mode/bank change, save/copy/erase): release time constant set to 0.041 s and a click fade (`SampleReader.h:961-967`).

Output per frame: `sample * env * click_env * loop_env * rev_env * velocity * gain * pan` (`SampleReader.h:557-558`).

`RestoreDefaults` (after a sample recording): loop on, sustain on, pitch 1, forward, window 0..1, attack/decay 0.01 raw (0.201 s / 0.041 s), gain 0.704, pan centre (`SampleReader.h:233-253`).

### 4.4 Streaming and `_double` files

- Each voice has an 8192-sample FIFO (4096 stereo frames, about 85 ms) (`FileStreamingManager.h:13`, `SampleReader.h:1022`). When under 1/4 full it asks the SD task (1 kHz timer, `chompi_main.cpp:140-164`, `chompi_main.cpp:352`) to read the missing amount, forwards or backwards (`SampleReader.h:584-692`).
- While idle, a voice pre-reads the first 8192 samples from the start point (end point when reversed) every 2 s so a key press sounds at once (`SampleReader.h:978-1017`).
- If `varispeed x global_pitch > 1.5` the voice switches to `<name>_double.wav` and reads it at half speed. The double file is the original with every second frame dropped (no filtering) (`FileCopier.h:110-128`, `SampleReader.h:723-796`, `SampleReader.h:332-350`). Its purpose is halving SD bandwidth. Switching mid-note converts the read position and spends a few samples blending speeds (`double_speed_ctr`).
- Data is read as raw 16-bit interleaved stereo after a 44-byte header (`sizeof(WAV_FormatTypeDef)`). Header fields (rate, channels, bit depth) are never checked.

For the port, samples can live in RAM (norns has the memory), so `_double` handling is not needed. If exact sound matters, note that above 1.5x the original plays a decimated copy, so it aliases more than straight interpolation would.

### 4.5 RAM buffers

`RamBuffer.h`, `chompi_main.cpp:30-34`:

- Two SDRAM buffers: looper and RAM sample (slot 15). Each `kMaxRamBuffSize = 31694848 / 2 = 15,847,424` int16 values, so 7,923,712 stereo frames, 165.08 s at 48 kHz (`RamBuffer.h:8`).
- Stored as int16, so anything written clips at +-1.
- The RAM sample stops recording automatically when full (`DSPEngine.h:537-538`).
- Neither buffer is saved on power-off. Use Save/Copy to keep them.

### 4.6 RAM sample recording (CHOMPI key)

`StartNewRecording` / `StopRecording` (`DSPEngine.h:592-632`):

- Start: if the looper is recording (first pass or overdub) it is stopped first. The buffer write head resets and every block's monitor signal (4.9) is written as int16.
- The recorded signal is whatever went into the `monitor` buffer: mic or line in after input gain, DC block and (for mic) the mic filter, or the resampled output. What lands there depends on the monitor position, see 4.9.
- Stop: all voices get default settings and stop, mode switches to JAMMI, slot 15 is selected (`SetVoiceSlot(15, false)`). The UI resets the pitch/start/end/gain/attack/release knob values to defaults (`NormalPage.h:1045-1055`).
- The RAM slot preset lives only in memory (`PresetManager.h:546-547`).

Built-in test tone filling slot 15 at power-up (`DSPEngine.h:227-268`): 3 s of triangle waves at amplitude 0.4, left 264.2 Hz (261.63 x 1.01), right 261.63 Hz, 2000-sample fade-in, exponential decay after sample 24000 with rate 7.1956e-5 per sample.

### 4.7 Looper

`LooperEngine.h` (logic) and `Sampler.h` (`FileSampler`, the tape engine). Stereo, int16, up to 165 s.

#### Buttons

Debounce window `kButtonTimeout = 10` ms, hold time `kRecordClearTimeout = 2000` ms (`LooperEngine.h:9-10`). Evaluated every block in `CheckReset` (`LooperEngine.h:89-118`).

- LOOP pressed alone (after 10 ms): `ToggleRecord`.
  - Empty: start the first recording.
  - First recording: end it, jump to start and go straight into overdub (record stays on).
  - Overdubbing: stop overdub, keep playing.
  - Playing or paused, not recording: start overdub (and play).
- PLAY pressed alone (after 10 ms) while recording or playing: `TogglePlaying`. While recording this ends recording and plays (`ToggleRecord(true)`). While playing it pauses.
- PLAY released while paused (and not used for anything else): play (`LooperEngine.h:163-167`).
- PLAY held 2 s while paused: rewind to the start, no play on release.
- PLAY + LOOP pressed together while empty: record arm. The next key press (physical or MIDI note) starts the first recording (`NormalPage.h:836-837`, `ui.h:168-169`).
- PLAY + LOOP held 2 s: clear the looper (`Reset`). The normal page also resets the transport knob (`NormalPage.h:223-227`).
- A full buffer ends the first recording and starts playback (`LooperEngine.h:75-79`).

#### Tape engine

`FileSampler::PopStereoSamps` (`Sampler.h:74-259`):

- One read/write head pair. The write head follows the read head: on record start the write head is set to the read head (`Sampler.h:76-83`).
- Speed: `scrub_` is a one-pole towards the target with coefficient 0.0001 per sample when Tape Slew is on (time constant about 0.21 s) or 0.01 (about 2 ms) when off (`Sampler.h:92-98`). Clamped to +-2.
- Target when playing: looper speed (`varispeed_factor`, -2..2). When paused: the scrub target, which is 0 unless the transport knob is turned. So pause is a tape stop and play is a tape start, with the slew time.
- Negative speed plays in reverse. A direction change clears the write history and moves the write head to the read head (`Sampler.h:282-297`).
- Reading: linear interpolation between two frames, advanced by |speed| per output frame. At the buffer end it wraps to the start (or end when reversed) (`Sampler.h:166-204`, `Sampler.h:247-248`).
- Loop fade: `loop_env` falls at 0.00464 per frame (about 215 frames) when 480 frames remain, and rises again after the wrap (`Sampler.h:183-203`, `Sampler.h:356`).
- Overdub write (`Sampler.h:206-238`): each frame the read head passes is written back as `old * dub_gain + input * input_env`, where the input is linearly interpolated between the previous and current input sample across the frames crossed in this output sample. So the record head moves at the same varispeed as the play head and the input is resampled onto the tape. The sum goes through a peak limiter (`Limiter::ProcessHard`: peak follower attack 0.05, release 0.0004, gain 1/peak above 1, then clamp) before writing (`limiter.h:84-90`).
- `input_env` fades the input in and out at 0.001 per written frame on record start/stop (`Sampler.h:76-87`). `dub_gain` is smoothed at 0.0001 and only applied while writing. When not recording the write head just advances.
- First recording: written straight with no varispeed, length grows (`Sampler.h:262`, `LooperEngine.h:70-73`). The live signal passes unchanged.
- Scrub when paused (`Sampler.h:147-164`, `Sampler.h:302`): transport detents add to `turn_count_`. Every 6000 samples (1/8 s) the target becomes `turn_count x 0.2` (Tape Slew on) or `+-varispeed x 0.2 x 5 = +-varispeed` (Tape Slew off, any turn means full speed in that direction), then the count resets. So with slew on, 5 detents per 1/8 s scrub at 1x.
- Clear (`Sampler.h:116-145`): target speed 0; once |speed| < 0.05 the output fades at 0.0001 per sample (about 0.2 s), then the buffer empties and speed resets to 1.
- Looper pitch knob: free mode `speed = 4v - 2` (0.5 = stopped, 0.75 = 1x) (`DSPEngine.h:1248-1251`). Quantised mode uses the same fifth/fourth steps as 4.2 over -2..2 with a flip at |speed| < 0.0625, knob value `speed x 0.25 + 0.5` (`DSPEngine.h:1180-1246`).
- Overdub level: 0..1, default 1, set from the shift menu (2.5). On an empty looper it applies immediately (`Sampler.h:310-317`).
- FX envelope: when FX pre/post is switched the looper's input and output fade to 0 and back at 0.001 per sample (`LooperEngine.h:38-81`).
- Looper output = `interp * loop_env * rev_env * reset_env` added to the live signal (`LooperEngine.h:65-68`, `Sampler.h:254-257`).

### 4.8 FX chain

`Engine::ApplyFx` (`DSPEngine.h:270-349`). Order per sample:

1. `fx_env` (crossfade for pre/post switching, one-pole 0.001).
2. DC blocker L/R (`out = in - in[-1] + 0.99 out[-1]`, `DaisySP/Source/Utility/dcblock.cpp`).
3. DJ filter.
4. Saturation: `SoftClip(sat x)`, then gain `1 - SoftClip(0.4 (sat - 1)) x 0.7`.
5. Warble.
6. Delay (separate loop).
7. Reverb (separate loop).

Filter cutoff, resonance and saturation are smoothed with a one-pole 0.001 per sample (`DSPEngine.h:275-277`).

Pre/post looper switch: setting a different position starts the fade (`fx_env_target = 0`, looper fades too). When `fx_env < 0.01` the position flips and the fade returns to 1 (`DSPEngine.h:477-481`, `DSPEngine.h:1497-1504`). Default: FX pre-looper (the looper records wet sound) (`DSPEngine.h:197`).

#### DJ filter (Magic page 2 + shift resonance)

`DJFilter.h`, `BasicMMF.h`:

- Two cascaded `BasicMMF` per channel: a lowpass then a highpass.
- BasicMMF is the two-pole feedback filter `b0 += f (in - b0 + fb (b0 - b1)); b1 += f (b0 - b1)`, with `fb = r + r / (1 - f)`. Lowpass output `b1`, highpass output `in - b0` (`BasicMMF.h:34-45`, `BasicMMF.h:74`). `f` is a 0..1 coefficient (about `2 pi fc / fs` for small f).
- Control c (knob, default 0.5): `lp = clamp(0.01 + 2c, 0, 0.99)^3`, `hp = clamp(1.9c - 1, 0, 1)^3` (`DJFilter.h:65-73`). c = 0.5 gives lp 0.97, hp 0 (open). Below 0.5 the lowpass closes (c = 0 gives 1e-6, silent). Above 0.5 the highpass opens up to 0.729.
- `lp` and `hp` are smoothed again with one-pole 0.0002 (`DJFilter.h:39-40`).
- Resonance r = shift knob x 0.95 on both filters (`DJFilter.h:76-85`). The `hp > 0.8` branch that scales highpass resonance never runs because hp tops out at 0.729.

#### Saturation (Magic page 1)

`SetSaturate` (`DSPEngine.h:1154-1160`): `sat = 13 ln(1.7 v + 1) + 1`, so 1 at v = 0 (SoftClip at unity, mild) up to 13.9 at v = 1. Gain compensation drops to 0.3 at full.

#### Warble (shift Magic page 1)

`Warble.h`:

- A modulated delay line per channel (1024 samples, linear interpolation, `DaisySP DelayLine`), both channels share the same delay time.
- Per sample, with probability `(v x 30 + 0.1) / 48013` (so about `30v + 0.1` events per second) a new target delay is picked uniformly in 100..980 samples and a new glide coefficient uniformly in 0..0.0001 (`Warble.h:36-42`). The delay time follows with `fonepole(l, target, coeff)`.
- Mix = v (smoothed 0.001): `out = in + mix (delayed - in)`. At v = 1 it is fully wet, in between it also combs with the dry signal.
- The random generator is an LCG `(1103515245 x + 12345) mod 2^31` seeded at 1.

#### Delay (Magic page 0)

`DSPEngine.h:306-334`, `InterpolatedDelayLine.h`:

- Stereo line of `kMaxDelayTime = 96256` frames (2.005 s), stored as int16 pairs (clips at +-1) (`DSPEngine.h:22`).
- Time (shift Magic page 0, t): `0.99 t^3 x 96256 + 450` samples: 9.4 ms to 1.995 s, default t = 0.5 gives 12,362 samples (0.258 s) (`DSPEngine.h:1143-1148`). Smoothed one-pole 0.001 per sample, read with linear interpolation, so time changes pitch-bend like tape.
- Feedback fb = amount x 0.9 (`DSPEngine.h:1142`), smoothed 0.001.
- Ping-pong: input is the mono sum `(L + R)/2`. Written frame = `{ mono + readR x fb^0.7 , readL }`. So a repeat enters on the left, moves to the right, and only the right channel feeds back into the left.
- Read level `del_vol = fb < 0.2 ? 5 fb : 1` applied to both read channels before feedback and output.
- Mix: `wet = fb > 0.25 ? 0.5 : 2 fb`, `dry = fb > 0.83 ? 0.5 : 1 - 0.6 fb`.

#### Reverb (Magic page 0)

`reverb.h` (Mutable Instruments Rings reverb, Griesinger/Dattorro topology) on `fx_engine.h`:

- 32768-sample delay memory stored 16-bit (`FORMAT_16_BIT`: value x 32768, clipped) (`reverb.h:161-173`, `fx_engine.h:123-136`).
- Input `(L + R) x 0.3` through 4 allpasses (lengths 150, 214, 319, 527, coefficient `kap`).
- Two loop halves. Half 1: read `del2` at 6261 + 50 cos(LFO2), x krt, one-pole lowpass `klp`, allpass 2182 (-kap), allpass 2690 (kap), write `del1` (4501) and double the accumulator, output left (wet = 2x the loop signal). Half 2: read `del1` at 4460 + 40 cos(LFO1), x krt, lowpass, allpass 2525 (kap), allpass 2197 (-kap), write `del2` (6312), doubled, output right (`reverb.h:50-134`).
- LFO1 0.5 Hz, LFO2 0.3 Hz (cosine, phase advanced per sample by the interpolate calls plus every 32 samples in `Start`, so slightly faster) (`reverb.h:44-45`, `fx_engine.h:335-405`).
- Output: `out += (wet - out) x amount` per channel, so it crossfades towards wet.
- Control mapping (`DSPEngine.h:337-348`, `DSPEngine.h:1141`):
  - `r = 1.3 ln(v + 1)` (0..0.90), smoothed 0.001.
  - amount = `r^2 x 0.8` (max 0.65).
  - lowpass `klp = r x 0.6 + 0.4`.
  - diffusion `kap = r x 0.6`.
  - time `krt` = shift delay time t clamped to 0.05..0.97, smoothed 0.001.

#### Magic knob page 0 split

Default: one knob drives both reverb `v` and delay feedback `v x 0.9` (`NormalPage.h:381-388`).

Split Delay option (`NormalPage.h:367-380`): below 0.5 delay feedback = `(0.5 - v) x 2` (x 0.9) with reverb 0, above 0.5 reverb = `(v - 0.5) x 2` with no delay. Knob default becomes 0.5.

### 4.9 Inputs, monitoring and resampling

Input paths (`DSPEngine.h:361-392`):

- Mic: `in0 x input_gain x 5`, DC block, then the mic filter: clamp +-0.98, SVF highpass 150 Hz res 0.4, then SVF notches at 2 kHz (drive 0.6), 12 kHz, 8 kHz, 4 kHz (drive 0.6), 9 kHz, all res 0.99 (`MicFilter.h`). Mono to both sides.
- Line: `in2/in3 x input_gain x 3`, DC block per side.
- Input gain is linear 0..1, default 0.75, smoothed 0.001 (`DSPEngine.h:1129-1135`, `DSPEngine.h:544`).

Monitor positions (option "Monitor Position" and shift + Volume push) (`DSPEngine.h:47-53`, `DSPEngine.h:450-498`):

| Position | JSON value | Where the input goes |
|---|---|---|
| HP | 1 (default) | In Record mode only: current source (mic or line) added after the looper and FX to headphones only. Line out and looper never get it |
| BOTH | 2 | Always (both switch positions): current source added before FX and looper, so it reaches both outputs, the FX and the looper |
| SEND_RET | 3 | Mic (in Record mode, mic source only) added before FX. Line in is always added to the headphones after the looper and FX. Line out carries the instrument without the line input (a send/return loop) |

The same signals are written to the `monitor` buffer, which is what the CHOMPI key records and what drives the input meter.

Resample source (`DSPEngine.h:501-518`, `DSPEngine.h:569-575`): the working (headphone) buffer after looper and FX, before volume, scaled by `resamp_env`, becomes both the headphone signal and the recording source. `resamp_env` follows input gain in Record mode and 1 in Play mode (one-pole 0.001). In BOTH position line out gets the same scaled signal.

### 4.10 Output stage and gain staging

`DSPEngine.h:541-566`, `limiter.h:73-81`:

- Headphones: `x x 0.2 x volume`. Line out: `x x 0.3 x volume` (`kHpGain`, `kLineOutGain`, `DSPEngine.h:24-25`). Volume is linear, default 0.84, smoothed 0.001.
- Then a compressor per channel (four instances) with amount c (shift Volume, default 0, smoothed 0.001):
  - pregain `7c + 1`, threshold `1 / (10c + 4)` (0.25 to 0.071), ratio `1 + 7c^2`, makeup `0.9 + 0.6c`.
  - Peak follower on `|pre|`: attack 0.05, release 0.0002 (per-sample slope).
  - Gain = 1 below threshold, else `1 / (ratio x (1 + peak - thresh))`. Note at c = 0 this still pulls down peaks above 0.25.
  - Gain smoothing: falling 0.005, rising 0.001 per sample.
  - Output `SoftLimit(pre x gain x makeup)`.
- Level meters (`EnvFollower.h`): rectify, clamp 0..1, one-pole with up coefficient 0.5 and down 0.9993, display value x 5 clipped to 1. Input meter is fed `(L + R) x 0.8` (x 0.2 when resampling), output meter `L + R` of the headphone signal.

Gain summary from sample to output: `sample x env x fades x velocity x (2v^2+0.01) x pan` per voice, SoftClip of the 7-voice sum, plus monitored input (mic x 5, line x 3, x input gain), FX (unity at defaults apart from saturation's mild SoftClip and the DC blocker), looper (int16 buffer, adds), then x 0.2 or x 0.3 x volume, then the compressor and SoftLimit.

---

## 5. Settings and presets

### 5.1 options.json

`OptionsManager.h`. Read at boot, then rewritten with the parsed values (`OptionsManager.h:30-56`). Format (`OptionsManager.h:61-125`):

```json
{ "chompi": [ { "name": "<name>", "value": <value> }, ... ] }
```

| Name | Type | Default | Meaning | Refs |
|---|---|---|---|---|
| Record Latch | bool | false | CHOMPI key: false = hold to record, true = press to start and press to stop | `NormalPage.h:796-811` |
| Midi In Channel | 1..16 | 1 | Only this channel is accepted (all message types) | `ui.h:143-144` |
| Midi Out Channel | 1..16 | 1 | Channel for notes and CCs sent (but see 7.3) | `NormalPage.h:141` |
| Tape Slew On | bool | true | Looper speed slew 0.21 s on, 2 ms off; also changes scrub behaviour | `Sampler.h:97`, `Sampler.h:151-157` |
| Monitor Position | 1..3 | 1 | 1 HP, 2 BOTH, 3 SEND_RET; only 2 and 3 are accepted when parsing, anything else gives 1 | `OptionsManager.h:207-211` |
| Pitch Quantize In Shift Menu | bool | true | true: normal page pitch and looper speed are free, shift page is quantised. false: the reverse | `OptionsManager.h:226-230` |
| Split Delay | bool | false | Splits Magic page 0 into delay (left half) and reverb (right half) | `NormalPage.h:367-388` |

Parsing searches names by index `chompi[i]` for i < 7. Only a value of `true` turns Record Latch and Split Delay on, only `false` turns Tape Slew and Pitch Quantize off.

### 5.2 presets.json

`PresetManager.h`. Per-slot sound settings.

- Shape: `[ modes[2] , version ]` where each mode is `banks[5]`, each bank is `slots[14]`, each slot is `[p0, p1, ..., p8, valid]` (`PresetManager.h:64-124`).
- Values are stored as `int(value x 1000)`. Version is `2` (9 controls). A file without the version entry is version 1 with 7 controls (`PresetManager.h:143-149`).
- Mode 0 JAMMI, 1 CUBBI. Bank 0..4 = a..e. Slot index 0..13 = slots 1..14.
- Slot 15 (RAM) settings are kept in memory only (`chompi_value`) (`PresetManager.h:546-547`).

Control order (`PresetManager.h:42`, `NormalPage.h:1016-1033`):

| Index | Field | Stored value | Default (x1000) |
|---|---|---|---|
| 0 | Pitch knob (page 0) | knob value | 830 |
| 1 | Start | 0..1 | 0 |
| 2 | End | 0..1 | 1000 |
| 3 | Attack knob | 0..1 | 0 |
| 4 | Release knob | 0..1 | 0 |
| 5 | Auto-loop | 0/1 | 1000 |
| 6 | Sustain | 0/1 | 1000 |
| 7 | Gain knob | 0..1 | 704 |
| 8 | Pan | 0..1 | 500 |
| 9 | valid | true/false | false |

Behaviour:

- A slot with `valid = false` uses the defaults (`MenuPage.h:573-584`, `NormalPage.h:870-878`).
- Turning knobs 0..2 or the shift toggles writes the current slot and marks it valid.
- Save copies the RAM settings into the target slot, Copy copies settings with the file, Erase marks the slot invalid (`PresetManager.h:250-301`).
- The file is regenerated every 5 s if anything changed, written in 1 KB chunks to `presets_temp.json` only while no voice plays, then renamed over `presets.json` (`ui.h:386-445`, `chompi_main.cpp:159-163`, `chompi_main.cpp:239-243`).
- The factory file has every slot invalid with default values.

### 5.3 Card layout

`DSPEngine.h:1313-1351`, card profile folder:

- `CHOMPI_TAPEv2_0.bin` firmware, `options.json`, `presets.json`, sample files, all in the card root.
- Sample name: `<mode>_<bank><slot>.wav` with mode `jammi` or `cubbi`, bank letter `a`..`e`, slot 1..14 without zero padding (`%1d`). Example `jammi_a1.wav`, `cubbi_c12.wav`.
- Each sample has `<mode>_<bank><slot>_double.wav`.
- Format: 48 kHz, 16-bit PCM, stereo, 44-byte header. The factory card has banks a, b, c for both modes, 14 slots each (84 samples plus 84 doubles, 161 MB). Banks d and e are empty.
- Boot check (`chompi_main.cpp:179-217`, `FileCopier.h:148-188`, `FileCopier.h:356-401`): for every mode/bank/slot, a file whose `data` chunk does not start at byte 44, has trailing chunks, is missing its double, or whose double has the wrong size, is rewritten in place (header normalised, double regenerated). The `data` chunk is searched in the first 2048 bytes. Files with an odd header length are shifted to 4-byte alignment.
- `file_exists[mode][bank][slot]` is built at boot; slot 15 always exists (`DSPEngine.h:1385-1405`).
- Saved files get a standard header: PCM, 2 channels, 48 kHz, 16 bit (`FileCopier.h:20-31`).
- Temporary files: `presets_temp.json`. `.batt_log.txt` and `._.batt_log.txt` are deleted at boot (`chompi_main.cpp:337-343`).

---

## 6. Other behaviour worth keeping

- Changing mode or bank in CUBBI, or switching modes, resets the key-to-voice table and chokes voices (`DSPEngine.h:640-646`, `DSPEngine.h:1288-1301`, `DSPEngine.h:1479-1485`).
- In JAMMI, choosing a bank page does not change the loaded sample until a slot key is pressed; landmark key LEDs use the bank of the loaded slot (`DSPEngine.h:1281-1287`).
- Copy/save/erase stop all voices first.
- While a copy runs, the normal page ignores keys and knobs (`NormalPage.h:677`, `NormalPage.h:916`).
- The first 1.5 s after boot ignore input.
- After a save/copy into a CUBBI slot, voices reload the file the next time that key is played (`SetAllCopyOccurred`, `SampleReader.h:1067-1079`).

---

## 7. MIDI

USB (device) and TRS (UART) in parallel. Input is read from UART first then USB, at about 1 kHz from the main loop (`hardware.h:445-461`, `chompi_main.cpp:232-237`). Output goes to both (`hardware.h:487-522`).

No MIDI clock, transport, program change or pitch bend is handled in or out.

### 7.1 MIDI in

`UserInterface::ProcessMidi` (`ui.h:137-234`). Only the "Midi In Channel" is accepted.

Notes (velocity 0 note-on is a note-off, libDaisy `midi_parser.cpp:143-147`):

- Accepted range MIDI 24..72 (`key = note - 24`, 0..48). Others ignored.
- Transpose `note - 60` (JAMMI). Velocity scales the voice by `(vel + 1) / 127`.
- Notes 48..72 map to the physical keys (same voice key IDs, so they light the key LEDs and CUBBI slots work). Notes 24..47 use virtual key IDs 32..55 (`midi2key`, `ui.h:22-28`), so they play in JAMMI only.
- A note-on also starts an armed looper recording.
- Notes are not echoed to MIDI out.

CCs (ignored while the shift menu is open):

| CC | Action |
|---|---|
| 20..25 | Set logical knob 0..5 to `value / 127` on that knob's current page. CC 24 (transport) only while the looper plays |
| 26 | PLAY key: > 84 press, < 42 release, 42..84 no change (hysteresis) |
| 27 | LOOP key, same thresholds |

CC-set knob values go through the same handler as turns (`NormalPage.h:925-928`) but do not send CC out. With quantised normal-page pitch (option false) the CC value is passed as a turn count to the quantiser, which jumps oddly (`NormalPage.h:954-955`).

### 7.2 MIDI out

- Physical key press/release: note on/off, velocity 127, note number from `key_map` (48..72) (`NormalPage.h:841`, `NormalPage.h:849`). Sent in both voice modes.
- Physical knob turn on the normal page: CC with `value x 127` (`NormalPage.h:1003-1005`), map `cc_map` (`NormalPage.h:10-13`):

| Knob | Page 0 | Page 1 | Page 2 |
|---|---|---|---|
| 0 Pitch | 20 | 28 (gain) | |
| 1 Start | 21 | 29 (attack) | |
| 2 End | 22 | 30 (release) | |
| 3 Magic | 23 | 31 (lo-fi) | 33 (filter) |
| 4 Transport | 24 | (0) | |
| 5 Volume | 25 | 32 (input gain) | |

- PLAY: CC 26 127/0. LOOP: CC 27 127/0. These are also sent when the press came in over MIDI CC 26/27, so a device that echoes can loop.
- CHOMPI in Record mode: CC 21 127/0 (`key_map[5] = 0x15`), which collides with the Start knob CC.
- Transport push release: CC 24 = 95.
- Shift-page turns send nothing.

### 7.3 MIDI out channel quirk

`NormalPage.h:790-793`: pressing CHOMPI in Play mode sets the out channel index to 1 (MIDI channel 2) while held and 0 (channel 1) on release, overwriting the option. The firmware comment at `NormalPage.h:742-745` shows this "channel 2 while holding CHOMPI" is intended. In practice the menu swallows note-ons while shift is held, and after the first shift the configured out channel is lost. Decide whether to keep this.

---

## 8. Hard parts for SuperCollider and norns

1. **Varispeed overdub looper.** The record head moves with the play head at any speed (-2..2), resampling the input onto the tape with linear interpolation, and writes `old x dub + input` through a hard limiter (4.7). `BufWr` writes one index per sample, so at speeds other than 1 it skips or repeats indices. Options: a custom UGen; running the loop in a fixed-rate domain is not equivalent. norns softcut does exactly this kind of resampled write with pre/rec levels and rate slew, but softcut sits after the SC engine in crone's mix and cannot feed back into it, so "FX post-looper" (and the looper going into the FX chain) would not be possible with it. Pick one: custom UGen in the engine, or softcut with FX pre-looper only.
2. **Tape slew transport.** Pause/play as tape stop/start, the 1/8 s scrub window with turn counting, and the clear sequence (slow down, fade, empty). Doable with `Lag`/`OnePole` on the rate, but the scrub accumulation runs in Lua or as a control-rate process.
3. **Voice envelope and gate semantics.** DaisySP `Adsr` curves (exponential attack to 1.01, release as a time constant to -0.01), the four loop/sustain combinations, soft retrigger with a 300-frame click fade and jump, loop-point fades (up to 480 frames, fade to zero and back, not a crossfade), reverse with fade. `EnvGen` can approximate the curves; the loop and retrigger fades need a custom Phasor/BufRd voice with `SetResetFF`/trigger logic.
4. **Rings reverb.** Exact topology with 16-bit memory, modulated taps and a single feedback loop. In SC, a `LocalIn`/`LocalOut` build adds one block (64 samples on norns) of extra loop delay; the long delays (4501/6312) can absorb that. Or write a UGen. Greyhole/JPverb will not sound the same.
5. **DJ filter.** Per-sample feedback two-pole (Paul Kellett style) with the cubic cutoff map. Needs a custom UGen or `Fb1`-style single-sample feedback for an exact match; `RLPF`/`RHPF` or `MoogFF` are approximations.
6. **Ping-pong delay.** Asymmetric feedback (only R feeds back into L), int16 clipping in the line, the `fb^0.7` feedback curve and the dry/wet and read-level curves. Fine with `LocalIn` (feedback delay is at least 450 samples, above the block size) and `DelayL` with a lagged time for the pitch-bend on time changes.
7. **Warble.** Random targets at a Poisson rate with random glide speeds. Easy with `Dust` driving `TRand`/`Latch` and a one-pole with a variable coefficient, or `Lag` with a random lag time; an exact match of the per-sample LCG is not needed.
8. **Output compressor.** Custom peak follower and gain law; `Compander`/`Limiter` will behave differently, notably at amount 0 where the firmware already limits above 0.25 before SoftLimit.
9. **Mic filter and monitor routing.** The mic notch filter only makes sense for CHOMPI's MEMS mic; on norns the inputs are line level. The three monitor positions and resample path have to be rebuilt in the engine's bus routing, including the HP-only post-looper monitor (norns has one stereo output, so HP and line out collapse; decide what HP-only means).
10. **Quantised pitch stepping.** Fifth/fourth alternation, turn-around below 0.0625x and the knob-value back-mapping. Pure Lua, but easy to get subtly wrong.
11. **Per-voice parameters in CUBBI.** Knobs edit only the last-started voice while other voices keep their own pitch, window, envelope, gain and pan. The engine needs per-voice parameter sets, and JAMMI needs "set all voices".
12. **Two RAM buffers of 165 s stereo.** About 63 MB each as 32-bit float in scsynth; fine on norns but allocate once. Sample banks in RAM: 14 CUBBI slots plus one JAMMI slot at a time.
13. **`_double` files.** Not needed when playing from RAM. Above 1.5x the original plays a decimated copy, so for a faithful sound at high pitch you could play the double buffer at half rate.
14. **Mode switch and encoders on the OMX-27.** The port needs 25 note keys, 3 function keys (CHOMPI, PLAY, LOOP), 6 endless encoders with push (including press-and-hold for battery and the 2 s holds on PLAY/LOOP) and a 2-position switch. The firmware uses relative encoder steps with different sizes per knob and absolute values only from CC. Plan the OMX-27 mapping (keys, pots as absolute values, norns encoders and keys) against this list.
