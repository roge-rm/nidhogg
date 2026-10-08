// The panel of the Chompi firmware this program is built for.
#pragma once
#include <cstdint>

namespace board
{

// LED colours as the firmware meant them (0-255). panel: Chompi's 10 panel
// LEDs; keys: the 25 key LEDs in Chompi's own order.
struct Leds
{
    uint8_t panel[10][3];
    uint8_t keys[25][3];
};

void attach();
// sw_id is the firmware's Hardware::SwId index.
void key(int sw_id, bool down);
// encoder is the hardware encoder 0-5 (SW1-SW6).
void turn(int encoder, int detents);
void push(int encoder, bool down);
void set_switch(bool record);
// An absolute pot for logical knob 0-5 (Pitch, Start, End, Magic, Transport,
// Volume), value 0-1.
void pot(int knob, float value);
bool pot_picked(int knob);
void attach_pots();

// How a knob responds to turns, from each firmware's board file.
struct KnobFeel
{
    float step;           // value change per turn; a little high is fine
    bool  relative;       // follow pot movement instead of setting a value
    float relative_turns; // turns for a full sweep when relative
};
KnobFeel knob_feel(int knob, int page, bool menu);
Leds leds();

// Firmware state for the norns and OMX-27 screens.
struct Status
{
    bool  ready; // false until the firmware has booted; nothing else is valid
    int   knob_page[6];
    float knob_value[6];
    bool  pot_picked[6]; // the pot has taken over its knob
    bool  menu;          // the shift menu is open
    // Meaning set by each firmware; TAPE: voice mode (0 JAMMI, 1 CUBBI), bank
    // being browsed, bank of the loaded slot, loaded slot, input (0 mic,
    // 1 line, 2 resample), FX before the looper, monitor position, looper
    // state (0 empty, 1 armed, 2 first recording, 3 overdub, 4 play, 5 paused),
    // recording a sample.
    int   state[10];
    float looper_position;
    float dub_level;
    float meter_in, meter_out; // levels, 0-1
    uint32_t clock_ticks;      // MIDI clock ticks so far, 24 a beat; 0 for TAPE
};
Status status();

} // namespace board
