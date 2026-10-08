// TAPE's pots and status for the norns. The panel itself is in
// board_daisy.cpp.
#include "board.h"

#include "vhw.h"

#include <algorithm>
#include <atomic>
#include <cmath>

float nidhogg_knob_value(int knob);
int   nidhogg_knob_page(int knob);
bool  nidhogg_menu_active();
bool  nidhogg_pitch_quantized();
bool  nidhogg_ready();
int   nidhogg_voice_mode();
int   nidhogg_bank();
int   nidhogg_voice_bank();
int   nidhogg_voice_slot();
int   nidhogg_input_source();
bool  nidhogg_fx_pre_looper();
int   nidhogg_monitor_mode();
int   nidhogg_looper_state();
float nidhogg_looper_position();
float nidhogg_dub_level();
bool  nidhogg_sample_recording();

void board_firmware_attach()
{
    board::attach_pots();
}

namespace board
{

// Value change per turn on TAPE's normal page (NormalPage::OnEncoderTurned).
// Quantised pitch steps by fifths and fourths, 4 detents a step, so its pot
// is relative: 80 turns, 20 steps, from about 2x reverse to 2x forward.
KnobFeel knob_feel(int knob, int page, bool menu)
{
    const bool quant = nidhogg_pitch_quantized();
    if(menu)
        return {0.01f, true, 100.f};
    if(knob == 0 && page == 0 && quant)
        return {0.01f, true, 80.f};
    bool fine = (knob == 0 && page == 0) || ((knob == 1 || knob == 2) && page == 0)
                || (knob == 4 && !quant);
    return {fine ? 0.003f : 0.01f, false, 0.f};
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
    st.menu            = nidhogg_menu_active();
    st.state[0]        = nidhogg_voice_mode();
    st.state[1]        = nidhogg_bank();
    st.state[2]        = nidhogg_voice_bank();
    st.state[3]        = nidhogg_voice_slot();
    st.state[4]        = nidhogg_input_source();
    st.state[5]        = nidhogg_fx_pre_looper();
    st.state[6]        = nidhogg_monitor_mode();
    st.state[7]        = nidhogg_looper_state();
    st.state[8]        = nidhogg_sample_recording();
    st.looper_position = nidhogg_looper_position();
    st.dub_level       = nidhogg_dub_level();
    return st;
}

} // namespace board
