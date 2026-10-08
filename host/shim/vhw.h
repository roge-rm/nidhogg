// Virtual Daisy Seed hardware for running Chompi firmware on Linux.
//
// The firmware's three execution contexts map to threads:
//   audio interrupt   -> the host's audio thread, calls audio_block()
//   1 kHz SD timer    -> the timer thread (timer_thread_main)
//   main loop         -> the firmware thread, running the firmware's own main()
// Firmware time ("vtime") counts audio blocks: 24 frames at 48 kHz is 500 us.
// GetNow(), Delay() and the control debouncers all run on vtime, so they behave
// as on the Daisy whatever the host's period size is.
//
// Interrupt masking (ScopedIrqBlocker, __disable_irq) maps to irq_lock, a
// recursive priority-inheriting mutex that the audio and timer contexts also
// hold while they run.
#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace vhw
{

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kBlockSize  = 24;
constexpr uint64_t kBlockUs    = 1000000ull * kBlockSize / kSampleRate; // 500

// ---- time -------------------------------------------------------------------

uint64_t now_us();
// Firmware-side sleep: blocks the calling firmware thread until vtime >= t.
void sleep_until_us(uint64_t t);

// ---- interrupt masking ------------------------------------------------------

void irq_disable();
void irq_enable();
bool irq_disabled_by_me();

// ---- pins -------------------------------------------------------------------

// A pin is (port, index); port 0-10 are A-K.
struct PinDevice
{
    virtual ~PinDevice() = default;
    // Level the device drives onto pin `which` (an input to the firmware).
    virtual bool read(int which) { return true; }
    // Firmware drove pin `which` (an output).
    virtual void write(int which, bool level) {}
};

void attach_pin(int port, int pin, PinDevice* dev, int which);
bool pin_read(int port, int pin);
void pin_write(int port, int pin, bool level);

// ---- audio ------------------------------------------------------------------

using AudioCallback = void (*)(const float* const* in, float** out, size_t size);
void set_audio_callback(AudioCallback cb);
bool audio_running();

// ---- timers -----------------------------------------------------------------

using TimerCallback = void (*)(void* data);
// Periodic callback in the timer context. Only 1 kHz is used by the firmware.
void add_timer(uint32_t hz, TimerCallback cb, void* data);
// One-shot callback in the timer context on the next timer tick (DMA ends).
void post_irq(TimerCallback cb, void* data);

// ---- midi -------------------------------------------------------------------

enum class MidiPort
{
    TRS,
    USB
};
using MidiRxCallback = std::function<void(const uint8_t* data, size_t size)>;
void set_midi_rx(MidiPort port, MidiRxCallback cb);
void midi_tx(MidiPort port, const uint8_t* data, size_t size);
// Host side: bytes arriving from outside; delivered in the timer context.
void midi_in(MidiPort port, const uint8_t* data, size_t size);
// Host side: bytes the firmware sent since the last call.
std::vector<uint8_t> midi_out(MidiPort port);

// ---- sd card ----------------------------------------------------------------

void set_card_root(const std::string& path);
const std::string& card_root();

// ---- host driving -----------------------------------------------------------

enum class Mode
{
    Realtime, // threads run freely, audio comes from the sound card
    Lockstep  // offline: the firmware thread runs to its next sleep each block
};

struct Config
{
    Mode mode = Mode::Lockstep;
    int  cpu  = -1; // pin all firmware threads to this core (-1 leaves them)
};

// Start the firmware's main() in its own thread.
void start(const Config& cfg, int (*firmware_main)());
// Run one 24-frame block: advances vtime, runs due timers, the audio callback,
// and in lockstep mode lets the firmware thread run until it sleeps again.
// in/out are 4 channels each (Daisy: mic, unused, line L, line R in;
// headphone L/R, line L/R out).
void audio_block(const float* const* in, float** out);
// The audio callback must also hold the irq lock; the host calls these around it
// when it drives audio itself.
void stop();

} // namespace vhw
