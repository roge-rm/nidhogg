# Playing nidhogg

nidhogg runs Chompi's own TAPE firmware on norns, with an OMX-27 as the panel. This guide covers the test build: TAPE only, OMX-27 in REMOTE mode.

TAPE is a sampler and a tape looper. You play samples from the card across the keys, record your own into a RAM slot, and loop everything on a varispeed tape with delay and reverb on top.

## Where everything is

### OMX-27

- **Bottom row, from the second key:** Chompi's 15 white keys, C to C over two octaves. The first bottom key does nothing.
- **Top row:** Chompi's 10 black keys.
- **AUX:** the CHOMPI key. Hold it for the shift menu in Play mode. In Record mode it records.
- **Pots, left to right:** Pitch, Start, End, Magic, then Volume past the encoder.
- **Encoder:** Transport, which is the looper's speed. Push it to go back to 1x.
- **Key lights:** the same colours Chompi's own keys would show.

A pot does nothing until you sweep it past the knob's current value, then it takes over. This stops the sound jumping when you first touch a pot.

### norns

- **E1:** the Play/Record switch. Turn left for Play, right for Record.
- **K2:** PLAY. **K3:** LOOP.
- **K1 held + move a pot:** pushes that knob.
- **E2:** Transport. **E3:** Volume.
- **Screen:** Chompi's 10 panel lights along the top, the 25 key lights below.

### Knob pages

Each knob has more than one job. Push it (K1 + pot) to step to its next page.

| Knob | Page 1 | Page 2 | Page 3 |
|---|---|---|---|
| Pitch | speed and direction: right of middle forward, left backwards, middle nearly stopped, about 5/6 up normal speed, fully right double | sample gain | |
| Start | where playback starts in the sample | attack | |
| End | where it ends | release | |
| Magic | reverb and delay together | lo-fi saturation | filter (middle is off, left low-pass, right high-pass) |
| Volume | main volume | input gain | |

## Playing samples

TAPE starts in **JAMMI** mode on slot 15, the RAM slot. Until you record something there it plays a built-in test tone.

- **JAMMI:** one sample across all the keys. The middle C (eighth white key) plays it at its own pitch, and up to 7 notes sound at once.
- **CUBBI:** each white key plays a different sample at its own pitch, with its own knob settings.

To choose a sample in JAMMI, hold AUX and press a white key. White keys 1-14 are the card's slots in the current bank, and key 15 is the RAM slot. Keys with a sample light up in the bank colour while you hold AUX.

### Shift menu (hold AUX)

| Top key | Does |
|---|---|
| 1 (C#) | JAMMI, or the next JAMMI bank if already in JAMMI |
| 2 (D#) | CUBBI, or the next CUBBI bank |
| 3 (F#) | input: mic (norns left input) |
| 4 (G#) | input: line (both norns inputs) |
| 5 (A#) | input: resample (what nidhogg itself is playing) |
| 6 (C#) | FX before the looper |
| 7 (D#) | FX after the looper |
| 8 (F#) | erase a slot |
| 9 (G#) | copy a slot |
| 10 (A#) | save the RAM sample to a slot |

There are five banks per mode (a-e), each with its own colour.

Pots and pushes do different things while AUX is held:

- Pitch: quantised pitch (steps of fifths and fourths); page 2 is pan.
- Start, End: move the whole start-to-end window; page 2 sets attack and release together.
- Magic: delay time (also reverb length), warble, filter resonance.
- Volume: output compressor.
- Push Start: auto-loop on or off. Push End: sustain on or off.
- Push Magic: reset all FX. Push Volume: cycle where the input is heard.
- K2/K3: overdub level down or up.

## Recording a sample

1. Turn E1 right for Record. The input is now heard.
2. Hold AUX to record into the RAM slot. Let go to stop.
3. Turn E1 left for Play, and play it on the keys (slot 15 if it isn't selected already).

To keep it, hold AUX, press top key 10 (save), press a white key 1-14 for where it goes, then press AUX to confirm. Copy (top key 9) and erase (top key 8) work the same way.

## The looper

- **LOOP (K3):** starts the first recording. Press again to close the loop, and it carries straight on overdubbing. Press again to stop overdubbing.
- **PLAY (K2):** pauses and plays, like stopping and starting a tape. Hold 2 seconds while paused to rewind.
- **PLAY + LOOP together** on an empty looper: recording starts with your next note.
- **Hold PLAY + LOOP 2 seconds:** clears the loop.
- **Transport (OMX encoder or E2):** while playing, sets the speed from -2x to 2x, so backwards and up to double speed. While paused, turning it scrubs the tape. Push the OMX encoder for normal speed.

## Not in this build yet

- The OMX-27 screen.
- A proper norns screen and settings.
- TEMPO and WAVE.
- Routing Chompi's MIDI out to your MIDI devices.
