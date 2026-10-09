# OMX-27 as the nidhogg control surface

Update: nidhogg uses Quixotic7's fork (github.com/Quixotic7/OMX-27, v1.15.4 and later) in its REMOTE mode, which already gives the host the LEDs, the OLED and raw input on all three boards. The host-mode proposal below is not needed. The rest of this file describes okyeron's tree and still holds for the hardware.

Notes from reading the OMX-27 repo (firmware 1.15.0, `src/config.h:24-26`, EEPROM version 38, `src/config.cpp:5`).

Paths are relative to a clone of the OMX-27 firmware repo. `src/` means `OMX-27-firmware/src/`, `.ino` means `OMX-27-firmware/OMX-27-firmware.ino`.

## Short answer

- Stock firmware can't drive the surface from the host. There is no LED-colour message, no OLED text message and no way to read the AUX key or the encoder as plain events.
- The only stock LED feedback: in MI mode an incoming note flashes one key in a fixed colour picked by octave. It gets wiped by the next LED redraw (a few hundred ms) and can't reach keys 0, 11 or 26.
- The sysex in stock firmware only reads and writes the settings header (`F0 7D 00 00 1F/0D/0E`).
- Teensy builds of this source don't read incoming MIDI at all. `MM::begin()` only installs input handlers on the RP2040 build (`src/midi/midi.cpp:38-68`).
- A small new mode (about 250 lines plus a few hooks) gives a clean surface: raw key, encoder and pot events out, LED colours and OLED text in. See "Host mode" below.

## Hardware

### Board versions

| Version | MCU | PlatformIO env | Notes |
|---|---|---|---|
| v1 | Teensy 3.2/3.1 | `teensy31` (`platformio.ini:61-70`) | CV pitch from the Teensy's own DAC on A14 (`src/consts/consts.h:67-73`) |
| v2 | Teensy 4.0 | `teensy40` (`platformio.ini:48-58`) | MCP4725 I2C DAC at 0x60 for CV pitch (`src/config.cpp:47-49`) |
| v3 | RP2040 (Pico) | `pico`, the default (`platformio.ini:14,34-46`) | Pots through an analogue mux, TinyUSB, USB name "omx-27-v3" (`.ino:103-121`) |

The board type is picked at compile time from the Arduino board define (`src/consts/consts.h:12-25`). The README says v3 is the RP2040 version (`README.md:7-11`). Check which one you have: a Teensy is visible on the back of v1/v2.

### Keys

27 mechanical keys (Cherry MX or Kailh Choc V1, `build/BOM.md:9-10`), indexed 0-26 in firmware. Physical layout (from `notes[]`, `src/config.cpp:124-126`, and `Docs.md:69-95`):

```
[0 AUX]    [1] [2]     [3] [4] [5]     [6] [7]     [8] [9] [10]
       [11][12][13][14][15][16][17][18][19][20][21][22][23][24][25][26]
```

- Key 0: AUX, top left on its own (`Docs.md:49-51`, `Docs.md:150`).
- Keys 1-10: top row "black keys". Keys 1 and 2 are the function keys F1 and F2 in some modes (`Docs.md:79-89`).
- Keys 11-26: bottom row "white keys", B3 to C6 at octave 0.
- Scanned as a 5x6 matrix with Adafruit_Keypad. Matrix map in `src/config.cpp:109-114`, row/column pins at `src/config.cpp:115-121`.
- The keypad wrapper gives down, up, held (800 ms) and click-count events (`.ino:126-128`, `src/hardware/omx_keypad.cpp:40-108`).

### LEDs

- 27 WS2812-style RGB LEDs on one chain, one under each key, driven by Adafruit_NeoPixel as GRB at 800 kHz (`src/hardware/omx_leds.cpp:6`).
- LED index equals key index everywhere in the code (for example `strip.setPixelColor(notenum, MIDINOTEON)` in `src/utils/omx_util.cpp:360`). LED 0 is AUX.
- Data pin 14 on Teensy, 19 on RP2040 (`src/config.cpp:33-39`).
- Global brightness 50/255 on Teensy, 90/255 on RP2040 (`src/config.cpp:26-30`), set with `strip.setBrightness` (`src/hardware/omx_leds.cpp:16`).

### Encoder

- One PEC11 encoder with push switch (VR5, `build/BOM.md:8`).
- Pins 12/11 with the button on 0 (Teensy), or 25/26 with the button on 20 (RP2040) (`.ino:90-100`).

### Pots

- 5 pots (VR1-VR4 and VR6, `build/BOM.md:7`; `NUM_CC_POTS 5`, `src/config.h:112-113`).
- Analogue pins `{23,22,21,20,16}` on T4, `{34,22,21,20,16}` on T3.2, mux channels on RP2040 (`src/config.cpp:41-56`).
- Read through ResponsiveAnalogRead and scaled to 14 bits (`hiResPotVal`), but only the 7-bit value is sent (`.ino:243-293`).

### OLED

- 128x32 SSD1306 on I2C at 0x3C (`build/BOM.md:15`, `src/ClearUI/ClearUI_Display.cpp:40-50`). Uses `Wire1` on RP2040 and `Wire` on Teensy.
- Drawn with Adafruit GFX plus U8g2 fonts (`FONT_LABELS` is 5x8, `src/consts/consts.h:90-96`).

### MIDI and CV

- USB MIDI in/out. Teensy builds use `USB_MIDI_SERIAL` (`platformio.ini:54,66`), RP2040 uses TinyUSB MIDI (`src/midi/midi.cpp:22-25`).
- One 3.5 mm TRS MIDI out with an A/B type switch (`Docs.md:27,33,1095-1097`). The docs mention no TRS MIDI in.
  - The RP2040 build reads `Serial1` with handlers (`src/midi/midi.cpp:57-64`), but sysex arriving there is only echoed back out, not parsed (`src/midi/midi.cpp:219-222`).
- Every `MM::send*` call goes to both USB and TRS (`src/midi/midi.cpp:224-268`).
- CV pitch out (about 4.3 octaves, `Docs.md:31`) and a gate out (`CVGATE_PIN`, `src/consts/consts.h:54-65`). Incoming MIDI notes drive CV by default (`midiInToCV = true`, `src/config.h:176`; `src/midi/midi.cpp:89-92`).

## Stock firmware, MI (MIDI keyboard) mode

MI is the default mode (`src/config.cpp:4`). On a fresh or reinitialised store the channel is 1 (`.ino:1093`) and velocity is 100 (`src/config.h:155`).

### Keys 1-26

Note on and note off on the MI channel at the default velocity.

- Note = `notes[key] + octave*12` (`src/utils/omx_util.cpp:297-299`).
- At octave 0: top 1-10 = 61 63 66 68 70 73 75 78 80 82, bottom 11-26 = 59 60 62 64 65 67 69 71 72 74 76 77 79 81 83 84 (`src/config.cpp:124-126`).
- The note can change with octave, scale lock, GROUP16 (`src/utils/omx_util.cpp:303-317`), round robin channel (`src/utils/omx_util.cpp:319-340`) and the selected MidiFX group (`src/modes/omx_mode_midi_keyboard.cpp:1431-1451`).
- MidiFX group 1 is selected by default (`src/modes/omx_mode_midi_keyboard.h:122`). It's empty unless you add effects, so notes pass straight through.
- The pressed key lights white (`MIDINOTEON`, `src/utils/omx_util.cpp:360`).

### AUX (key 0)

Sends nothing. Holding it turns the other keys into shortcuts and swallows their notes (`src/modes/omx_mode_midi_keyboard.cpp:676-726,795-829`, `Docs.md:162-193`):

- Top 1/2: previous/next parameter.
- Top 5-10: MidiFX off and groups 1-5.
- Bottom 1/2 (keys 11/12): octave down/up.
- Bottom 3/4 (keys 13/14): pot bank. These also send CC 90 = bank on the MI channel (`:701`).
- Keys 20, 22-26: arp shortcuts.

Double-clicking AUX enters or leaves the macro mode when `MCRO` isn't Off (`:581-633`).

### Pots

CC on the MI channel, 7-bit (`src/utils/omx_util.cpp:18-24`, `src/modes/omx_mode_midi_keyboard.cpp:166-189`). Five banks of five (`src/config.cpp:60-65`):

| Bank | CCs |
|---|---|
| A (default) | 21 22 23 24 7 |
| B | 29 30 31 32 33 |
| C | 34 35 36 37 38 |
| D | 39 40 41 42 43 |
| E | 91 93 103 104 7 |

- Bank changes with `PBNK` (sends CC 90 = bank, `:396-401`) or AUX + keys 13/14.
- An incoming CC 0 on any channel sets the pot bank (`src/midi/midi.cpp:121-125`). Watch for this if norns sends bank select.

### Encoder and push

Nothing is sent in MI.

- Turning selects or edits on-screen params (`src/modes/omx_mode_midi_keyboard.cpp:256-420`).
- A short press toggles select/edit (`:496-535`).
- A long press opens mode select (`.ino:776-791`). In mode select, AUX saves the state (`.ino:821-835`).
- `PGM`/`BNK` params send program change and CC 0/32 (`:368-392`).

### Screensaver

After 3 minutes (`src/modes/omx_screensaver.h:34`) the screen blanks and MI shows an LED animation. Pot moves aren't sent while it's on (`.ino:280-291`).

### OM mode (Organelle Mother)

- Same as MI except the encoder sends CC 28 (127 CW, 0 CCW). It only does this when not in select state and param 0 is selected (`src/modes/omx_mode_midi_keyboard.cpp:285-297`).
- `Docs.md:1077-1084` says AUX sends CC 25, but that code is commented out (`src/modes/omx_mode_midi_keyboard.cpp:799,823`).

### NRN (norns) macro mode

Enter it with `MCRO`=NRN, then double-click AUX. It targets the qremote mod and sends on `M-CH` (default 10, `src/config.h:196`). See `src/midimacro/midimacro_norns.h:34-54` and `.cpp:106-293`:

- Top 3 / bottom 4 / bottom 5 (keys 3, 14, 15): CC 85/87/88, 127 on press, 0 on release.
- Top 5 / bottom 6 / bottom 7 (keys 5, 16, 17) pick which norns encoder the OMX encoder drives. It then sends CC 58/62/63 as 65 (CW) or 63 (CCW).
- Keys 1, 11, 12, 13 send two ticks of CC 62/63 for up/left/down/right.
- Keys 6-10 and 19-26 still play notes. Pots send their bank CCs on `M-CH`.
- LEDs are fixed colours (`.cpp:212-265`) and the OLED shows "Enc 1/2/3".

This is one-way. It's handy for menu navigation but it isn't a raw surface.

### M8 and Deluge macros

Fixed note and CC maps for those devices (`src/midimacro/midimacro_m8.cpp`, `midimacro_deluge.cpp`), one-way. `MidiMacroDeluge::inMidiControlChange` exists but is never called, because `MM::handleControlChange` doesn't pass CCs to the mode (`src/midi/midi.cpp:114-133`).

## Configuration: sysex and webconfig

Spec: `OMX-27-firmware/SYSEX_SPEC.md`. Code: `src/midi/sysex.cpp`. It's only processed from USB MIDI (`src/midi/midi.cpp:55,215-218`).

- **Request:** `F0 7D 00 00 1F F7`.
- **Reply:** `F0 7D 00 00 0F 02 <maj> <min> <pt> <40 header bytes> F7`. Device id 2 = OMX-27. Any 0xFF byte is sent as 0x7F (`src/midi/sysex.cpp:109-157`).
- **Write device options:** `F0 7D 00 00 0D <32 bytes> F7` copies message bytes 5-36 straight into storage bytes 0-31. It then reloads mode, pattern, channel and pot CCs and refreshes the mode (`src/midi/sysex.cpp:66-107`).
  - Byte 0 must be the current EEPROM version (38), or the next boot wipes and reinitialises storage (`.ino:354-376`).
  - Header map: 0 version, 1 mode, 2 pattern, 3 MI channel-1, 4-28 pot CCs (5 banks x 5), 29 macro channel-1, 30 macro type (0 off, 1 M8, 2 NRN, 3 DEL), 31 scale root (`SYSEX_SPEC.md`, `.ino:299-348`).
  - Mode numbers: 0 MI, 1 DRUM, 2 CH, 3 S1, 4 S2, 5 GR, 6 EL, 7 OM (`src/config.h:38-50`).
- `0E` ("whole config") is in the switch but writes 80 bytes from offset 9. The spec marks it not implemented (`src/midi/sysex.cpp:34-38,61-64`).
- `webconfig/index.html` is a WebMIDI page that does the `1F` request and sends `0D` with the mode, pattern, channel and 25 pot CCs (`webconfig/index.html:114-190`).
  - It pads bytes 29-31 with zeros, which resets the macro channel to 1, macro off and scale root C.
  - Its mode list (MIDI, S1, S2, OM) is out of date.
- Every `0D` write goes to FRAM/EEPROM, so it's for setup, not live use.

## Can the host drive LEDs and OLED, and read raw keys, on stock firmware?

**LEDs:** effectively no.

- `inMidiNoteOn` in MI (`src/modes/omx_mode_midi_keyboard.cpp:1293-1347`) lights key `midiKeyMap[note % 24]`. The map is `src/config.cpp:132`: 0→12, 1→1, 2→13, 3→2, 4→14, 5→15, 6→3, 7→16, 8→4, 9→17, 10→5, 11→18, 12→19, 13→6, 14→20, 15→7, 16→21, 17→22, 18→8, 19→23, 20→9, 21→24, 22→10, 23→25.
- The colour comes from the octave (`note/12`): white, orange, yellow, green, magenta, cyan, lime, cyan, then white. It accepts any channel and ignores velocity.
- Note off turns the LED off (`:1349-1368`).
- `updateBlinkStates` marks the LEDs dirty every `step_delay*2` ms (`src/hardware/omx_leds.cpp:33-57`). The next `drawMidiLeds` then repaints every key that isn't held (`:143-160`), so the colour lasts a fraction of a second.
- Keys 0, 11 and 26 can't be reached. Only the RP2040 build gets this at all.

**OLED:** no. No incoming message writes to the display.

**Raw keys:**

- Keys 1-26: partly. In MI with octave 0, no scale lock, GROUP16 off, MidiFX off or empty and round robin off, each key maps to a fixed note (table above). AUX held swallows them.
- AUX: no.
- Encoder: no.
- Encoder push: no.
- Pots: yes, as 7-bit CCs.

## Host mode: a minimal firmware change

Add a new mode, `MODE_HOST`, that does no music logic and only bridges hardware and MIDI. Put it last in the enum so stored mode numbers keep their meaning. Unknown modes already fall back to MI (`.ino:226-229`).

### Changes

1. `src/config.h:38-50`: add `MODE_HOST` before `NUM_OMX_MODES`. Add `"HO"` to `modes[]` (`src/config.cpp:90`).

2. New `src/modes/omx_mode_host.{h,cpp}` implementing `OmxModeInterface` (`src/modes/omx_mode_interface.h:5-38`):
   - `onKeyUpdate(e)`: skip `e.held()` events. Send note on (vel 127) for down and note off for up, with note = key index 0-26, on the host channel. The main loop passes held events to `onKeyUpdate` too (`.ino:806-855`).
   - `onEncoderChanged(u)`: CC 16 as relative `64 + clamp(u.accel(1), -63, 63)`.
   - `onEncoderButtonDown`/`Up`: note 27 on/off.
   - `shouldBlockEncEdit()`: return true unless AUX is held (`midiSettings.keyState[0]`). A long press then stays a plain press for the host, and AUX + long press is the way back to mode select (`.ino:776-791`).
   - `onPotChanged(k,...)`: CC 17+k = `analogValues[k]`. Optionally CC 49+k with the low 7 bits of `hiResPotVal[k]` for 14-bit.
   - `loopUpdate`: call `omxScreensaver.resetCounter()`, so the screensaver never takes the LEDs or swallows pots (`.ino:689,280-291`).
   - `updateLEDs`/`onDisplayUpdate`: keep a 27-entry colour array and a 4x25 char text buffer. Redraw the text buffer every call, since the main loop clears the display buffer every pass (`.ino:684`). Use `FONT_LABELS` (5x8). Push the LEDs with `strip.setPixelColor` and `omxLeds.setDirty()`. `showLeds()` sends them at the end of the loop (`.ino:879-880`).
   - `inMidiNoteOn(ch, note, vel)` on the host channel: `led[note] = palette[vel]` (a 128-entry palette, Launchpad style). Note off sets it to black. This is the cheap path for norns.
   - Set `midiSettings.midiInToCV = false` on activate, so host LED notes don't move the CV out (`src/midi/midi.cpp:89-92,107-110`).

3. `.ino:185-235` `changeOmxMode`: add `case MODE_HOST: activeOmxMode = &omxModeHost;`. Optionally make it the default with `DEFAULT_MODE` (`src/config.cpp:4`) under a build flag.

4. `src/midi/midi.cpp:114-133`: call `activeOmxMode->inMidiControlChange(channel, control, value)`. Skip the CC 0 pot-bank grab when host mode is active.

5. `src/midi/midi.cpp:65-67`, Teensy only: install the USB handlers the RP2040 branch has. Without this a Teensy build hears nothing.
   ```cpp
   usbMIDI.setHandleNoteOn(handleNoteOn);
   usbMIDI.setHandleNoteOff(handleNoteOff);
   usbMIDI.setHandleControlChange(handleControlChange);
   usbMIDI.setHandleSystemExclusive(OnSysEx);
   // plus clock/start/stop/continue as on RP2040
   ```

6. `src/midi/sysex.cpp:27-58`: add commands after the `7D 00 00` header. Keep them clear of 0D/0E/0F/1F. All values are 7-bit, and the firmware doubles colours to 8-bit.

### Sysex commands

| Cmd | Bytes after `F0 7D 00 00` | Effect |
|---|---|---|
| 20 | `20 k r g b F7` | set LED k (0-26) |
| 21 | `21 r0 g0 b0 ... r26 g26 b26 F7` | set all 27 (87 bytes total) |
| 22 | `22 line col <ascii...> F7` | write text at line 0-3, column 0-24 |
| 23 | `23 F7` | clear text |
| 24 | `24 page x0 <7-bit packed bytes> F7` | raw bitmap chunk, page 0-3 (8 px rows), up to 64 columns per message |
| 25 | `25 b F7` | LED brightness, `strip.setBrightness(b*2)` |

- Keep each sysex at 128 bytes or less. The FortySevenEffects MIDI library default `SysExMaxSize` is 128 (used for USB on RP2040 and for TRS). Teensy's native `usbMIDI` buffer is larger (about 290). Check both if you change the limits.
- A full 128x32 frame is 512 bytes, so it needs at least 8 chunks. Text lines are the cheap path.

### Output summary (host channel, say 16)

| Source | Message |
|---|---|
| Keys 0-26 | note 0-26 on/off |
| Encoder push | note 27 |
| Encoder turn | CC 16 relative (65 CW, 63 CCW, more with acceleration) |
| Pots 1-5 | CC 17-21, optional LSB on CC 49-53 |

In: note on with velocity = palette index, or sysex 20-25.

### Build and flash

Install PlatformIO Core (`pipx install platformio`). The README's macOS steps are at `README.md:54-87`. Run from the repo root:

```sh
pio run -e teensy31 -t upload   # v1, Teensy 3.2; press the Teensy button if asked
pio run -e teensy40 -t upload   # v2, Teensy 4.0
pio run -e pico -t upload       # v3, RP2040; hold BOOT, tap RESET, release BOOT
```

- Teensy uploads use `teensy-cli` (`platformio.ini:51,64`) and need the Teensy udev rules on Linux.
- On this machine run the build through `heavy build pio run ...`.
- If storage gets confused, flash `clear_storage/clear_storage.T32.hex` or `.T4.hex`, then reflash the main firmware (`README.md:98-111`).
- Keep the storage layout unchanged (no `EEPROM_VERSION` bump) so the user's saved patterns survive.
