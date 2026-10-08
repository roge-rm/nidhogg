// Chompi's panel wired to the virtual pins, as in hardware.h. All three
// firmwares run on the same board; each adds its own pots and status in
// board_<firmware>.cpp.
//
// Keys, encoder pushes and the Play/Record switch sit on a chain of five
// CD4021 shift registers (clock D8, latch D7, data D9). Encoders 1-4 have their
// A/B lines on a sixth 4021 (clock D22, latch D23, data D19). Encoder 5 is on
// GPIO (A D0, B D20, push D10), encoder 6 too (A D15, B D17, push on the chain).
// All inputs are active low with pull-ups.
#include "board.h"

#include "vhw.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cmath>
#include <cstring>
#include <mutex>

namespace chompi
{
// Defined in temp_led_stuff.h, compiled into the firmware's main file.
extern uint8_t led_pth_data[22][3];
extern uint8_t led_smt_data[37][3];
} // namespace chompi

namespace
{

// Pin numbers from daisy_seed.h: (port, pin), port A = 0.
constexpr int A = 0, B = 1, C = 2, D = 3, G = 6;

// A chain of CD4021 parallel-in shift registers. `level[i]` is the input bit
// that the firmware's ShiftRegister4021 stores at index i.
template <int kChips>
class Sr4021 : public vhw::PinDevice
{
  public:
    static constexpr int kBits = 8 * kChips;
    enum
    {
        kClk,
        kLatch,
        kData
    };
    std::atomic<bool> level[kBits];

    Sr4021()
    {
        for(auto& l : level)
            l = true;
    }
    bool read(int which) override
    {
        if(which != kData || count_ >= kBits)
            return true;
        return snap_[(kBits - 1) - count_];
    }
    void write(int which, bool v) override
    {
        if(which == kLatch && v)
        {
            for(int i = 0; i < kBits; i++)
                snap_[i] = level[i];
            count_ = 0;
        }
        else if(which == kClk)
        {
            // The firmware reads the data pin with the clock low, then raises
            // it to shift the next bit out.
            if(v && !clk_)
                count_++;
            clk_ = v;
        }
    }

  private:
    bool snap_[kBits] = {};
    int  count_       = 0;
    bool clk_         = false;
};

// A detented quadrature encoder. Queued detents are played out as A/B levels
// in firmware time, one phase per kPhaseUs, which both of Chompi's decoders
// read as one step each.
class Quadrature
{
  public:
    static constexpr uint64_t kPhaseUs = 2000;

    void turn(int detents)
    {
        std::lock_guard<std::mutex> l(m_);
        pending_ += detents;
    }

    // Levels at firmware time t; called from the audio context.
    void levels(uint64_t t, bool& a, bool& b)
    {
        std::lock_guard<std::mutex> l(m_);
        while(t >= next_)
        {
            if(phase_ == 0)
            {
                if(pending_ == 0)
                {
                    next_ = t + 1; // idle at rest
                    break;
                }
                dir_ = pending_ > 0 ? 1 : -1;
                pending_ -= dir_;
            }
            phase_ = (phase_ + 1) % 4;
            next_  = (next_ < t ? t : next_) + kPhaseUs;
        }
        // Clockwise: B falls, then A falls (counted), then B rises, then A.
        // Anticlockwise swaps A and B.
        static const bool seq_first[4]  = {true, false, false, true};
        static const bool seq_second[4] = {true, true, false, false};
        bool              lead = seq_first[phase_], lag = seq_second[phase_];
        if(dir_ > 0)
        {
            b = lead;
            a = lag;
        }
        else
        {
            a = lead;
            b = lag;
        }
    }

  private:
    std::mutex m_;
    int        pending_ = 0;
    int        dir_     = 1;
    int        phase_   = 0;
    uint64_t   next_    = 0;
};

Sr4021<5> buttons;
Sr4021<1> encoder_sr;
Quadrature quad[6];

// Encoders 1-4: drive the encoder 4021's inputs before each latch.
class EncoderSrFeeder : public vhw::PinDevice
{
  public:
    void write(int which, bool v) override
    {
        if(which == Sr4021<1>::kLatch && v)
        {
            uint64_t t = vhw::now_us();
            for(int i = 0; i < 4; i++)
            {
                bool a, b;
                quad[i].levels(t, a, b);
                encoder_sr.level[i * 2]     = a;
                encoder_sr.level[i * 2 + 1] = b;
            }
        }
        encoder_sr.write(which, v);
    }
    bool read(int which) override { return encoder_sr.read(which); }
};
EncoderSrFeeder encoder_feeder;

// Encoders 5 and 6: A/B straight on GPIO.
class GpioEncoder : public vhw::PinDevice
{
  public:
    explicit GpioEncoder(int idx) : idx_(idx) {}
    bool read(int which) override
    {
        bool a, b;
        quad[idx_].levels(vhw::now_us(), a, b);
        return which == 0 ? a : b;
    }

  private:
    int idx_;
};
GpioEncoder enc5(4), enc6(5);

// Encoder 5's push switch on D10.
class Button : public vhw::PinDevice
{
  public:
    std::atomic<bool> down{false};
    bool              read(int) override { return !down; }
};
Button enc5_push;

// Fixed inputs: line-in jack plugged (D21), no charger interrupt (D31).
class High : public vhw::PinDevice
{
  public:
    bool read(int) override { return true; }
};
High high;

// Switch ids from hardware.h (Hardware::SwId).
constexpr int kEncSw[6] = {0, 1, 2, 3, -1, 32};
constexpr int kSwTog    = 6;

} // namespace

// In board_<firmware>.cpp.
void board_firmware_attach();

// From each firmware's host patch (chompi_main.cpp). Knobs are Chompi's
// logical knobs 0-5: Pitch, Start, End, Magic, Transport/Tempo, Volume.
float nidhogg_knob_value(int knob);
int   nidhogg_knob_page(int knob);
bool  nidhogg_menu_active();
bool  nidhogg_ready();
void  nidhogg_turn(int knob, int turns);

namespace board
{

void attach()
{
    vhw::attach_pin(G, 11, &buttons, Sr4021<5>::kClk);   // D8
    vhw::attach_pin(G, 10, &buttons, Sr4021<5>::kLatch); // D7
    vhw::attach_pin(B, 4, &buttons, Sr4021<5>::kData);   // D9

    vhw::attach_pin(A, 5, &encoder_feeder, Sr4021<1>::kClk);   // D22
    vhw::attach_pin(A, 4, &encoder_feeder, Sr4021<1>::kLatch); // D23
    vhw::attach_pin(A, 6, &encoder_feeder, Sr4021<1>::kData);  // D19

    vhw::attach_pin(B, 12, &enc5, 0); // D0
    vhw::attach_pin(C, 1, &enc5, 1);  // D20
    vhw::attach_pin(B, 5, &enc5_push, 0); // D10
    vhw::attach_pin(C, 0, &enc6, 0);  // D15
    vhw::attach_pin(B, 1, &enc6, 1);  // D17

    vhw::attach_pin(C, 4, &high, 0); // D21 jack detect
    vhw::attach_pin(C, 2, &high, 0); // D31 MP2722 interrupt

    set_switch(false); // start in Play
    board_firmware_attach();
}

void key(int sw_id, bool down)
{
    if(sw_id >= 0 && sw_id < Sr4021<5>::kBits)
        buttons.level[sw_id] = !down;
}

void turn(int encoder, int detents)
{
    if(encoder >= 0 && encoder < 6)
        quad[encoder].turn(detents);
}

void push(int encoder, bool down)
{
    if(encoder == 4)
        enc5_push.down = down;
    else if(encoder >= 0 && encoder < 6)
        key(kEncSw[encoder], down);
}

void set_switch(bool record)
{
    // Hardware::GetToggleState() counts a high line as Record, low as Play.
    buttons.level[kSwTog] = record;
}

Leds leds()
{
    // SetPthLed stores r/11 and SetSmtLed r/4 for the hardware's brightness.
    Leds l;
    for(int i = 0; i < 10; i++)
        for(int c = 0; c < 3; c++)
            l.panel[i][c] = uint8_t(std::min(255, chompi::led_pth_data[i][c] * 11));
    for(int i = 0; i < 25; i++)
        for(int c = 0; c < 3; c++)
            l.keys[i][c] = uint8_t(std::min(255, chompi::led_smt_data[i][c] * 4));
    return l;
}

} // namespace board

// ---- absolute pots ------------------------------------------------------------
//
// Chompi's knobs are endless encoders. A pot moves its knob by posting turns
// to the firmware's own event queue, as a fast spin of the encoder would. It
// posts, waits until the firmware has applied the turns, then corrects from
// the knob's real value, so knobs whose step changes as they move still land
// where the pot is. A pot takes over once it passes the knob's value, and lets
// go when the knob's page changes or the firmware changes the value itself
// (a preset load). Knobs marked relative, and every knob while the shift menu
// is open, follow how far the pot moves instead.

namespace
{

struct Pot
{
    std::atomic<float> target{-1.f};
    float              last     = -1.f;
    bool               picked   = false;
    int                page     = -1;
    float              rel      = 0.f;   // relative turns not yet posted
    bool               waiting  = false; // turns posted, not yet applied
    float              posted_from = 0.f;
    uint64_t           posted_at = 0;
    float              settled  = 0.f;   // value after our last turns landed
};
Pot pots[6];

// Turns one physical detent posts (UserInterface::GenerateEvents).
int detent_turns(int knob)
{
    return (knob == 0 || knob == 4) ? 1 : 3;
}

void post_relative(Pot& p, int knob, float delta, float turns_per_sweep)
{
    p.rel += delta * turns_per_sweep;
    int n = int(p.rel);
    if(n != 0)
    {
        p.rel -= n;
        nidhogg_turn(knob, n);
    }
}

void pots_hook()
{
    if(!nidhogg_ready())
        return;
    const bool     menu = nidhogg_menu_active();
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
        const int   page = nidhogg_knob_page(k);
        const float v    = nidhogg_knob_value(k);
        const board::KnobFeel feel = board::knob_feel(k, page, menu);

        if(menu || feel.relative)
        {
            p.picked  = false;
            p.waiting = false;
            if(t != prev)
                post_relative(p, k, t - prev, feel.relative_turns);
            continue;
        }
        if(page != p.page)
        {
            p.page    = page;
            p.picked  = false;
            p.waiting = false;
        }
        if(p.waiting)
        {
            // landed once the value moves, or give up after 40 ms
            if(v == p.posted_from && now - p.posted_at < 40000)
                continue;
            p.waiting = false;
            p.settled = v;
        }
        else if(p.picked && std::fabs(v - p.settled) > 0.02f)
            p.picked = false; // the firmware changed it itself

        if(!p.picked)
        {
            if((prev - v) * (t - v) <= 0.f || std::fabs(t - v) < feel.step)
            {
                p.picked  = true;
                p.settled = v;
            }
            else
                continue;
        }
        float gap = t - v;
        if(std::fabs(gap) < feel.step * 0.5f)
            continue;
        int n = int(std::lround(gap / feel.step));
        if(n == 0)
            continue;
        nidhogg_turn(k, n);
        p.waiting     = true;
        p.posted_from = v;
        p.posted_at   = now;
    }
}

} // namespace

namespace board
{

void pot(int knob, float value)
{
    if(knob >= 0 && knob < 6)
        pots[knob].target = std::min(1.f, std::max(0.f, value));
}

bool pot_picked(int knob)
{
    return knob >= 0 && knob < 6 && pots[knob].picked;
}

void attach_pots()
{
    vhw::set_pre_audio_hook(pots_hook);
}

} // namespace board
