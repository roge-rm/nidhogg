#include "vhw.h"

#include <pthread.h>
#include <sched.h>

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>

namespace vhw
{
namespace
{

Config cfg_;

// time and the firmware thread
std::mutex              m_;
std::condition_variable cv_;
std::atomic<uint64_t>   vtime_{0};
std::thread             fw_thread_;
std::thread::id         fw_id_;
bool                    fw_sleeping_ = false;
uint64_t                fw_wake_     = 0;
bool                    fw_done_     = false;
bool                    fw_may_run_  = false; // lockstep: interrupts for this block are done
std::atomic<bool>       quit_{false};

// irq lock
pthread_mutex_t     irq_mutex_;
thread_local bool   irq_masked_ = false;
std::once_flag      irq_once_;

void irq_init()
{
    pthread_mutexattr_t a;
    pthread_mutexattr_init(&a);
    pthread_mutexattr_setprotocol(&a, PTHREAD_PRIO_INHERIT);
    pthread_mutex_init(&irq_mutex_, &a);
    pthread_mutexattr_destroy(&a);
}

// pins
struct PinSlot
{
    PinDevice* dev   = nullptr;
    int        which = 0;
    bool       level = true; // last level written by the firmware
};
PinSlot pins_[11][16];

// audio
std::atomic<AudioCallback> audio_cb_{nullptr};
void (*pre_audio_)() = nullptr;

// timers
struct Timer
{
    const void*   id;
    double        period_us;
    double        next;
    TimerCallback cb;
    void*         data;
};
std::vector<Timer> timers_;
std::mutex         timers_m_;
using Posted = std::function<void()>;
std::deque<Posted> posted_;
std::thread        timer_thread_;
uint64_t           timer_next_ = 0;

// midi
struct MidiState
{
    std::mutex           m;
    MidiRxCallback       rx;
    std::vector<uint8_t> in, out;
};
MidiState midi_[2];

std::string card_root_ = ".";

void pin_to_cpu()
{
    if(cfg_.cpu < 0)
        return;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cfg_.cpu, &set);
    pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
}

// Runs due timers, posted irqs and midi input. Caller holds the irq lock.
void run_timers(uint64_t t)
{
    std::vector<Posted> posted;
    {
        std::lock_guard<std::mutex> l(timers_m_);
        posted.assign(posted_.begin(), posted_.end());
        posted_.clear();
    }
    for(auto& p : posted)
        p();

    for(auto& ms : midi_)
    {
        std::vector<uint8_t> in;
        MidiRxCallback       rx;
        {
            std::lock_guard<std::mutex> l(ms.m);
            in.swap(ms.in);
            rx = ms.rx;
        }
        if(rx && !in.empty())
            rx(in.data(), in.size());
    }

    for(size_t i = 0;; i++)
    {
        Timer tm;
        {
            std::lock_guard<std::mutex> l(timers_m_);
            if(i >= timers_.size())
                break;
            if(timers_[i].next > double(t))
                continue;
            tm = timers_[i];
            // Fire every period that has come due, as the hardware would have.
            while(timers_[i].next <= double(t))
                timers_[i].next += timers_[i].period_us;
        }
        for(double due = tm.next; due <= double(t); due += tm.period_us)
            tm.cb(tm.data);
    }
}

void timer_thread_main()
{
    pin_to_cpu();
    sched_param sp{};
    sp.sched_priority = 60;
    pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);
    uint64_t last = 0;
    while(!quit_)
    {
        {
            std::unique_lock<std::mutex> l(m_);
            cv_.wait(l, [&] { return quit_ || vtime_ > last; });
        }
        if(quit_)
            break;
        uint64_t t = vtime_;
        irq_disable();
        run_timers(t);
        irq_enable();
        last = t;
    }
}

} // namespace

// ---- time -------------------------------------------------------------------

uint64_t now_us()
{
    return vtime_;
}

void sleep_until_us(uint64_t t)
{
    if(std::this_thread::get_id() != fw_id_)
    {
        // A delay inside interrupt-context code. On the Daisy, SysTick keeps
        // time moving while an interrupt busy-waits, so let time pass here too:
        // in real time by sleeping, in lockstep by moving vtime on.
        if(t <= vtime_)
            return;
        if(cfg_.mode == Mode::Realtime)
            std::this_thread::sleep_for(std::chrono::microseconds(t - vtime_));
        else
        {
            std::lock_guard<std::mutex> l(m_);
            vtime_ = t;
        }
        return;
    }
    // A masked main loop that sleeps would block every interrupt context; the
    // firmware never does this on purpose, so let them in while it waits.
    bool masked = irq_masked_;
    if(masked)
        irq_enable();
    {
        std::unique_lock<std::mutex> l(m_);
        fw_sleeping_ = true;
        fw_wake_     = t;
        cv_.notify_all();
        cv_.wait(l, [&] {
            return quit_
                   || (vtime_ >= t
                       && (cfg_.mode == Mode::Realtime || fw_may_run_));
        });
        fw_sleeping_ = false;
    }
    if(masked)
        irq_disable();
}

// ---- irq --------------------------------------------------------------------

void irq_disable()
{
    std::call_once(irq_once_, irq_init);
    if(!irq_masked_)
    {
        pthread_mutex_lock(&irq_mutex_);
        irq_masked_ = true;
    }
}

void irq_enable()
{
    if(irq_masked_)
    {
        irq_masked_ = false;
        pthread_mutex_unlock(&irq_mutex_);
    }
}

bool irq_disabled_by_me()
{
    return irq_masked_;
}

// ---- pins -------------------------------------------------------------------

void attach_pin(int port, int pin, PinDevice* dev, int which)
{
    if(port < 0 || port > 10 || pin < 0 || pin > 15)
        return;
    pins_[port][pin].dev   = dev;
    pins_[port][pin].which = which;
}

bool pin_read(int port, int pin)
{
    if(port < 0 || port > 10 || pin < 0 || pin > 15)
        return true;
    auto& s = pins_[port][pin];
    return s.dev ? s.dev->read(s.which) : s.level;
}

void pin_write(int port, int pin, bool level)
{
    if(port < 0 || port > 10 || pin < 0 || pin > 15)
        return;
    auto& s = pins_[port][pin];
    s.level = level;
    if(s.dev)
        s.dev->write(s.which, level);
}

// ---- audio ------------------------------------------------------------------

void set_audio_callback(AudioCallback cb)
{
    audio_cb_ = cb;
}

void set_pre_audio_hook(void (*hook)())
{
    pre_audio_ = hook;
}

bool audio_running()
{
    return audio_cb_ != nullptr;
}

// ---- timers -----------------------------------------------------------------

void set_timer(const void* id, double hz, TimerCallback cb, void* data)
{
    std::lock_guard<std::mutex> l(timers_m_);
    double                      p = 1e6 / hz;
    for(auto& tm : timers_)
        if(tm.id == id)
        {
            // keep the phase: the next tick comes one new period after the last
            tm.next      = tm.next - tm.period_us + p;
            tm.period_us = p;
            tm.cb        = cb;
            tm.data      = data;
            return;
        }
    timers_.push_back({id, p, double(vtime_) + p, cb, data});
}

void stop_timer(const void* id)
{
    std::lock_guard<std::mutex> l(timers_m_);
    for(size_t i = 0; i < timers_.size(); i++)
        if(timers_[i].id == id)
        {
            timers_.erase(timers_.begin() + long(i));
            return;
        }
}

void post_irq(TimerCallback cb, void* data)
{
    post_irq([cb, data] { cb(data); });
}

void post_irq(std::function<void()> fn)
{
    std::lock_guard<std::mutex> l(timers_m_);
    posted_.push_back(std::move(fn));
}

// ---- midi -------------------------------------------------------------------

void set_midi_rx(MidiPort port, MidiRxCallback cb)
{
    auto&                       ms = midi_[int(port)];
    std::lock_guard<std::mutex> l(ms.m);
    ms.rx = cb;
}

void midi_tx(MidiPort port, const uint8_t* data, size_t size)
{
    auto&                       ms = midi_[int(port)];
    std::lock_guard<std::mutex> l(ms.m);
    ms.out.insert(ms.out.end(), data, data + size);
}

void midi_in(MidiPort port, const uint8_t* data, size_t size)
{
    auto&                       ms = midi_[int(port)];
    std::lock_guard<std::mutex> l(ms.m);
    ms.in.insert(ms.in.end(), data, data + size);
}

std::vector<uint8_t> midi_out(MidiPort port)
{
    auto&                       ms = midi_[int(port)];
    std::lock_guard<std::mutex> l(ms.m);
    std::vector<uint8_t>        out;
    out.swap(ms.out);
    return out;
}

// ---- sd card ----------------------------------------------------------------

void set_card_root(const std::string& path)
{
    card_root_ = path;
}

const std::string& card_root()
{
    return card_root_;
}

// ---- host driving -----------------------------------------------------------

void start(const Config& cfg, int (*firmware_main)())
{
    cfg_ = cfg;
    std::call_once(irq_once_, irq_init);
    std::unique_lock<std::mutex> l(m_);
    fw_may_run_ = true;
    fw_thread_  = std::thread([firmware_main] {
        pin_to_cpu();
        firmware_main();
        std::lock_guard<std::mutex> l2(m_);
        fw_done_ = true;
        cv_.notify_all();
    });
    fw_id_ = fw_thread_.get_id();
    if(cfg_.mode == Mode::Realtime)
        timer_thread_ = std::thread(timer_thread_main);
    // Let the firmware run its start-up until it first sleeps.
    if(cfg_.mode == Mode::Lockstep)
        cv_.wait(l, [] { return fw_done_ || (fw_sleeping_ && fw_wake_ > vtime_); });
}

void audio_block(const float* const* in, float** out)
{
    uint64_t t;
    {
        std::lock_guard<std::mutex> l(m_);
        fw_may_run_ = false;
        t           = vtime_ + kBlockUs;
        vtime_      = t;
    }
    if(cfg_.mode == Mode::Realtime)
        cv_.notify_all();

    irq_disable();
    if(cfg_.mode == Mode::Lockstep)
        run_timers(t);
    AudioCallback cb = audio_cb_;
    if(cb && pre_audio_)
        pre_audio_();
    if(cb)
        cb(in, out, kBlockSize);
    else
        for(int c = 0; c < 4; c++)
            std::memset(out[c], 0, sizeof(float) * kBlockSize);
    irq_enable();

    if(cfg_.mode == Mode::Lockstep)
    {
        std::unique_lock<std::mutex> l(m_);
        fw_may_run_ = true;
        cv_.notify_all();
        cv_.wait(l, [&] { return fw_done_ || (fw_sleeping_ && fw_wake_ > vtime_); });
    }
}

void stop()
{
    quit_ = true;
    cv_.notify_all();
    if(timer_thread_.joinable())
        timer_thread_.join();
    // The firmware's main() never returns; leave its thread to die with the process.
    if(fw_thread_.joinable())
        fw_thread_.detach();
}

} // namespace vhw
