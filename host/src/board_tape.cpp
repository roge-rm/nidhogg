// TAPE's pots and status for the norns. The panel itself is in
// board_daisy.cpp.
#include "board.h"

#include "vhw.h"

#include <algorithm>
#include <atomic>
#include <cmath>

// ---- absolute pots ------------------------------------------------------------
//
// Chompi's knobs are endless encoders. A pot moves its knob by posting the
// turns needed to reach the pot's position to the firmware's own event queue,
// as a fast spin of the encoder would. A pot takes over once it passes the
// knob's current value, and lets go when the knob's page changes or the
// firmware changes the value itself (a preset load). While the shift menu is
// open the pots turn their knobs relative to how far they move.

float nidhogg_knob_value(int knob);
int   nidhogg_knob_page(int knob);
bool  nidhogg_menu_active();
bool  nidhogg_pitch_quantized();
void  nidhogg_turn(int knob, int turns);
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
bool  nidhogg_ready();

namespace
{

struct Pot
{
    std::atomic<float> target{-1.f};
    float              last     = -1.f;
    bool               picked   = false;
    int                page     = -1;
    float              seen     = 0.f; // knob value after the turns posted so far
    uint64_t           turned_at = 0;
    float              rel      = 0.f; // relative detents not yet posted
};
Pot pots[6];

// Turns one physical detent posts (UserInterface::GenerateEvents).
int detent_turns(int knob)
{
    return (knob == 0 || knob == 4) ? 1 : 3;
}

// Value change per turn (NormalPage::OnEncoderTurned).
float turn_step(int knob, int page, bool quantized)
{
    bool fine = (knob == 0 && page == 0 && !quantized) || ((knob == 1 || knob == 2) && page == 0)
                || (knob == 4 && !quantized);
    return fine ? 0.003f : 0.01f;
}

void post_relative(Pot& p, int knob, float delta, float detents_per_travel)
{
    p.rel += delta * detents_per_travel;
    int n = int(p.rel);
    if(n != 0)
    {
        p.rel -= n;
        nidhogg_turn(knob, n * detent_turns(knob));
    }
}

void pots_hook()
{
    const bool     menu = nidhogg_menu_active();
    const bool     quant = nidhogg_pitch_quantized();
    const uint64_t now  = vhw::now_us();
    for(int k = 0; k < 6; k++)
    {
        Pot&  p = pots[k];
        float t = p.target;
        if(t < 0.f)
            continue;
        if(p.last < 0.f)
        {
            p.last = t; // first reading: wait for the pot to reach the knob
            continue;
        }
        const float prev = p.last;
        p.last           = t;

        if(menu)
        {
            // Shift values live in the menu page; a full sweep is 33 detents,
            // the coarse knob's range.
            p.picked = false;
            if(t != prev)
                post_relative(p, k, t - prev, 1.f / (0.01f * detent_turns(k)));
            continue;
        }

        const int   page = nidhogg_knob_page(k);
        const float v    = nidhogg_knob_value(k);
        const float step = turn_step(k, page, quant) * detent_turns(k);
        if(page != p.page)
        {
            p.page   = page;
            p.picked = false;
        }
        // The firmware changed the value itself, once our turns have landed.
        if(p.picked && now - p.turned_at > 50000 && std::fabs(v - p.seen) > 1.5f * step)
            p.picked = false;

        if(k == 0 && page == 0 && quant)
        {
            // Quantised pitch steps by fifths and fourths, one step per 4
            // detents, so the pot steps too: 20 steps over a full sweep, about
            // 2x reverse to 2x forward.
            if(t != prev)
                post_relative(p, k, t - prev, 80.f);
            continue;
        }

        if(!p.picked)
        {
            if((prev - v) * (t - v) <= 0.f || std::fabs(t - v) < step)
            {
                p.picked = true;
                p.seen   = v;
            }
            else
                continue;
        }
        if(t == prev)
            continue;
        int n = int(std::lround((t - p.seen) / step));
        if(n != 0)
        {
            nidhogg_turn(k, n * detent_turns(k));
            p.seen      = std::min(1.f, std::max(0.f, p.seen + n * step));
            p.turned_at = now;
        }
    }
}

} // namespace

void board_firmware_attach()
{
    vhw::set_pre_audio_hook(pots_hook);
}

namespace board
{

void pot(int knob, float value)
{
    if(knob >= 0 && knob < 6)
        pots[knob].target = std::min(1.f, std::max(0.f, value));
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
        st.pot_picked[k] = pots[k].picked;
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
