#include "bridge.h"

#include "board.h"
#include "vhw.h"

#include <lo/lo.h>
#include <time.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <thread>

namespace bridge
{
namespace
{

lo_server_thread    osc;
lo_address          to;
std::thread         pump;
std::atomic<bool>   running{false};
std::atomic<bool>   quit{false};
std::atomic<double> last_ping{0};
std::atomic<float>  load_sum{0}, load_max{0};
std::atomic<int>    load_n{0};

double now_s()
{
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int on_key(const char*, const char*, lo_arg** a, int, lo_message, void*)
{
    board::key(a[0]->i, a[1]->i != 0);
    return 0;
}
int on_turn(const char*, const char*, lo_arg** a, int, lo_message, void*)
{
    board::turn(a[0]->i, a[1]->i);
    return 0;
}
int on_push(const char*, const char*, lo_arg** a, int, lo_message, void*)
{
    board::push(a[0]->i, a[1]->i != 0);
    return 0;
}
int on_switch(const char*, const char*, lo_arg** a, int, lo_message, void*)
{
    board::set_switch(a[0]->i != 0);
    return 0;
}
// /midi s:port then either one blob or the bytes as ints (Lua can't send blobs).
int on_midi(const char*, const char* types, lo_arg** a, int argc, lo_message, void*)
{
    if(argc < 2 || types[0] != 's')
        return 0;
    auto    port = std::strcmp(&a[0]->s, "trs") == 0 ? vhw::MidiPort::TRS : vhw::MidiPort::USB;
    uint8_t bytes[256];
    size_t  n = 0;
    if(types[1] == 'b')
    {
        auto b = reinterpret_cast<lo_blob>(a[1]);
        vhw::midi_in(port, static_cast<const uint8_t*>(lo_blob_dataptr(b)), lo_blob_datasize(b));
        return 0;
    }
    for(int i = 1; i < argc && n < sizeof(bytes); i++)
        if(types[i] == 'i')
            bytes[n++] = uint8_t(a[i]->i);
    vhw::midi_in(port, bytes, n);
    return 0;
}

int on_ping(const char*, const char*, lo_arg**, int, lo_message, void*)
{
    last_ping = now_s();
    return 0;
}
int on_quit(const char*, const char*, lo_arg**, int, lo_message, void*)
{
    quit = true;
    return 0;
}

// Sends LED changes and MIDI out every 10 ms, and the load once a second.
void pump_main()
{
    board::Leds last{};
    double      next_load = now_s() + 1;
    while(running)
    {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        board::Leds l = board::leds();
        if(std::memcmp(&l, &last, sizeof(l)) != 0)
        {
            last      = l;
            lo_blob b = lo_blob_new(sizeof(l), &l);
            lo_send(to, "/leds", "b", b);
            lo_blob_free(b);
        }
        for(auto p : {vhw::MidiPort::TRS, vhw::MidiPort::USB})
        {
            auto bytes = vhw::midi_out(p);
            if(bytes.empty())
                continue;
            lo_blob b = lo_blob_new(int(bytes.size()), bytes.data());
            lo_send(to, "/midi", "sb", p == vhw::MidiPort::TRS ? "trs" : "usb", b);
            lo_blob_free(b);
        }
        double t = now_s();
        if(t >= next_load)
        {
            next_load = t + 1;
            int   n   = load_n.exchange(0);
            float sum = load_sum.exchange(0), mx = load_max.exchange(0);
            lo_send(to, "/load", "ff", n ? sum / n : 0.f, mx);
        }
    }
}

} // namespace

bool start(const std::string& port, const std::string& reply)
{
    if(running)
        return true;
    osc = lo_server_thread_new(port.c_str(), nullptr);
    if(!osc)
        return false;
    lo_server_thread_add_method(osc, "/key", "ii", on_key, nullptr);
    lo_server_thread_add_method(osc, "/turn", "ii", on_turn, nullptr);
    lo_server_thread_add_method(osc, "/push", "ii", on_push, nullptr);
    lo_server_thread_add_method(osc, "/switch", "i", on_switch, nullptr);
    lo_server_thread_add_method(osc, "/midi", nullptr, on_midi, nullptr);
    lo_server_thread_add_method(osc, "/ping", "", on_ping, nullptr);
    lo_server_thread_add_method(osc, "/quit", "", on_quit, nullptr);
    lo_server_thread_start(osc);
    to        = lo_address_new("127.0.0.1", reply.c_str());
    last_ping = now_s();
    quit      = false;
    running   = true;
    pump      = std::thread(pump_main);
    return true;
}

void stop()
{
    if(!running)
        return;
    running = false;
    pump.join();
    lo_server_thread_free(osc);
    lo_address_free(to);
}

bool quit_requested()
{
    return quit;
}

double seconds_since_ping()
{
    return now_s() - last_ping;
}

void report_block_load(float percent)
{
    load_sum = load_sum + percent;
    load_n++;
    if(percent > load_max)
        load_max = percent;
}

} // namespace bridge
