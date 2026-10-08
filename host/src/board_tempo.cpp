// TEMPO's pots and status for the norns. The panel itself is in
// board_daisy.cpp.
#include "board.h"

#include <cstdint>

float nidhogg_knob_value(int knob);
int   nidhogg_knob_page(int knob);
bool  nidhogg_menu_active();
bool  nidhogg_pitch_quantized();
bool  nidhogg_ready();
void  nidhogg_meters(float* in, float* out);
uint32_t nidhogg_clock_ticks();
void  nidhogg_state(int* s);

void board_firmware_attach()
{
    board::attach_pots();
}

namespace board
{

// Value change per turn on TEMPO's normal page (NormalPage.h:742-883).
// Sample volume moves 1/33 a detent; start and end move .003 a turn and less
// on short windows, which the pot's correction takes care of. Quantised pitch
// and the tempo knob step, so their pots are relative.
KnobFeel knob_feel(int knob, int page, bool menu)
{
    if(menu)
        return {0.01f, true, 100.f};
    if(knob == 0 && page == 0)
        return nidhogg_pitch_quantized() ? KnobFeel{0.01f, true, 80.f} : KnobFeel{0.003f, false, 0.f};
    if(knob == 0 && page == 1)
        return {1.f / 33.f, false, 0.f};
    if((knob == 1 || knob == 2 || knob == 3) && page == 0)
        return {0.003f, false, 0.f};
    if(knob == 4)
        return {0.003125f, true, 320.f};
    return {0.01f, false, 0.f};
}

Status status()
{
    Status st{};
    st.ready = nidhogg_ready();
    if(!st.ready)
        return st;
    for(int k = 0; k < 6; k++)
    {
        st.knob_page[k]  = nidhogg_knob_page(k);
        st.knob_value[k] = nidhogg_knob_value(k);
        st.pot_picked[k] = pot_picked(k);
    }
    nidhogg_meters(&st.meter_in, &st.meter_out);
    st.clock_ticks = nidhogg_clock_ticks();
    st.menu = nidhogg_menu_active();
    nidhogg_state(st.state);
    return st;
}

} // namespace board
