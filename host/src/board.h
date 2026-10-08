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
Leds leds();

} // namespace board
