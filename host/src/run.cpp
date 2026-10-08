// Real-time runner: the firmware as a JACK client, controlled over OSC.
//
// nidhogg-<fw> --card DIR [--port 57140] [--reply 10111] [--cpu N] [--no-connect]
//
// Audio: two inputs, two outputs. By default they connect like a norns
// engine: crone:output_5/6 in, crone:input_5/6 out. The firmware sees the
// norns left input as its mic and both as its line in; Chompi's line out comes
// back.
//
// OSC in (UDP, --port):
//   /key i:sw_id i:down        /turn i:encoder i:detents
//   /push i:encoder i:down     /switch i:record
//   /midi s:"trs"|"usb" b:bytes
//   /ping                      keeps the program alive (see --watchdog)
//   /quit
// OSC out (to --reply on localhost):
//   /leds b:105 bytes          10 panel then 25 key LEDs, RGB, on change
//   /midi s:port b:bytes       what the firmware sent
//   /load f:dsp_percent f:max_percent   once a second
#include "board.h"
#include "vhw.h"

#include <jack/jack.h>
#include <lo/lo.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <time.h>

int chompi_firmware_main();

namespace
{

constexpr size_t kBlock = vhw::kBlockSize;
constexpr size_t kFifo  = 4096; // frames, power of two

jack_client_t* client;
jack_port_t*   in_port[2];
jack_port_t*   out_port[2];

// Input and output frames waiting to make up or hand back 24-frame blocks.
// Only touched by the JACK thread.
float  in_fifo[2][kFifo], out_fifo[2][kFifo];
size_t in_fill = 0, out_read = 0, out_fill = 0;

std::atomic<bool>  quit{false};
std::atomic<int>   cpu{-1};
bool               pinned = false;
std::atomic<float> load_sum{0}, load_max{0};
std::atomic<int>   load_n{0};

double now_s()
{
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int process(jack_nframes_t nframes, void*)
{
    if(!pinned && cpu >= 0)
    {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(cpu, &set);
        pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
        pinned = true;
    }
    double t0 = now_s();

    auto* inl  = static_cast<float*>(jack_port_get_buffer(in_port[0], nframes));
    auto* inr  = static_cast<float*>(jack_port_get_buffer(in_port[1], nframes));
    auto* outl = static_cast<float*>(jack_port_get_buffer(out_port[0], nframes));
    auto* outr = static_cast<float*>(jack_port_get_buffer(out_port[1], nframes));

    for(jack_nframes_t i = 0; i < nframes; i++)
    {
        in_fifo[0][in_fill] = inl[i];
        in_fifo[1][in_fill] = inr[i];
        in_fill++;
        if(in_fill == kBlock)
        {
            float  ib[4][kBlock], ob[4][kBlock];
            float* ins[4]  = {ib[0], ib[1], ib[2], ib[3]};
            float* outs[4] = {ob[0], ob[1], ob[2], ob[3]};
            for(size_t k = 0; k < kBlock; k++)
            {
                ib[0][k] = in_fifo[0][k]; // mic
                ib[1][k] = 0.f;
                ib[2][k] = in_fifo[0][k]; // line in
                ib[3][k] = in_fifo[1][k];
            }
            in_fill = 0;
            vhw::audio_block(ins, outs);
            for(size_t k = 0; k < kBlock; k++)
            {
                size_t w           = (out_read + out_fill) & (kFifo - 1);
                out_fifo[0][w]     = ob[2][k]; // line out
                out_fifo[1][w]     = ob[3][k];
                out_fill++;
            }
        }
    }

    // A block's output is ready one block after its input arrived.
    for(jack_nframes_t i = 0; i < nframes; i++)
    {
        if(out_fill > 0)
        {
            outl[i]  = out_fifo[0][out_read];
            outr[i]  = out_fifo[1][out_read];
            out_read = (out_read + 1) & (kFifo - 1);
            out_fill--;
        }
        else
            outl[i] = outr[i] = 0.f;
    }

    float pct = float((now_s() - t0) * jack_get_sample_rate(client) / nframes * 100.0);
    load_sum  = load_sum + pct;
    load_n++;
    if(pct > load_max)
        load_max = pct;
    return 0;
}

// Prime the output so a period never runs short: one block of latency.
void prime()
{
    out_fill = kBlock;
    for(size_t k = 0; k < kBlock; k++)
        out_fifo[0][k] = out_fifo[1][k] = 0.f;
}

std::atomic<double> last_ping{0};

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
int on_midi(const char*, const char*, lo_arg** a, int, lo_message, void*)
{
    auto        port = std::strcmp(&a[0]->s, "trs") == 0 ? vhw::MidiPort::TRS : vhw::MidiPort::USB;
    lo_blob     b    = reinterpret_cast<lo_blob>(a[1]);
    const auto* data = static_cast<const uint8_t*>(lo_blob_dataptr(b));
    vhw::midi_in(port, data, lo_blob_datasize(b));
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

void on_signal(int)
{
    quit = true;
}

} // namespace

int main(int argc, char** argv)
{
    std::string card = ".", port = "57140", reply = "10111";
    bool        connect  = true;
    double      watchdog = 0; // seconds without /ping before quitting; 0 is off
    for(int i = 1; i < argc; i++)
    {
        std::string a = argv[i];
        if(a == "--card" && i + 1 < argc)
            card = argv[++i];
        else if(a == "--port" && i + 1 < argc)
            port = argv[++i];
        else if(a == "--reply" && i + 1 < argc)
            reply = argv[++i];
        else if(a == "--cpu" && i + 1 < argc)
            cpu = std::atoi(argv[++i]);
        else if(a == "--watchdog" && i + 1 < argc)
            watchdog = std::atof(argv[++i]);
        else if(a == "--no-connect")
            connect = false;
        else
        {
            std::fprintf(stderr, "unknown option %s\n", a.c_str());
            return 1;
        }
    }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    vhw::set_card_root(card);
    board::attach();

    jack_status_t st;
    client = jack_client_open("nidhogg", JackNoStartServer, &st);
    if(!client)
    {
        std::fprintf(stderr, "can't connect to JACK (status 0x%x)\n", st);
        return 1;
    }
    if(jack_get_sample_rate(client) != vhw::kSampleRate)
    {
        std::fprintf(stderr, "JACK runs at %u Hz; Chompi needs 48000\n",
                     jack_get_sample_rate(client));
        return 1;
    }
    in_port[0]  = jack_port_register(client, "in_1", JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput, 0);
    in_port[1]  = jack_port_register(client, "in_2", JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput, 0);
    out_port[0] = jack_port_register(client, "out_1", JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput, 0);
    out_port[1] = jack_port_register(client, "out_2", JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput, 0);
    prime();
    jack_set_process_callback(client, process, nullptr);

    vhw::Config cfg;
    cfg.mode = vhw::Mode::Realtime;
    cfg.cpu  = cpu;
    vhw::start(cfg, chompi_firmware_main);

    if(jack_activate(client))
    {
        std::fprintf(stderr, "can't activate JACK client\n");
        return 1;
    }
    if(connect)
    {
        jack_connect(client, "crone:output_5", "nidhogg:in_1");
        jack_connect(client, "crone:output_6", "nidhogg:in_2");
        jack_connect(client, "nidhogg:out_1", "crone:input_5");
        jack_connect(client, "nidhogg:out_2", "crone:input_6");
    }

    lo_server_thread osc = lo_server_thread_new(port.c_str(), nullptr);
    if(!osc)
    {
        std::fprintf(stderr, "can't open OSC port %s\n", port.c_str());
        return 1;
    }
    lo_server_thread_add_method(osc, "/key", "ii", on_key, nullptr);
    lo_server_thread_add_method(osc, "/turn", "ii", on_turn, nullptr);
    lo_server_thread_add_method(osc, "/push", "ii", on_push, nullptr);
    lo_server_thread_add_method(osc, "/switch", "i", on_switch, nullptr);
    lo_server_thread_add_method(osc, "/midi", "sb", on_midi, nullptr);
    lo_server_thread_add_method(osc, "/ping", "", on_ping, nullptr);
    lo_server_thread_add_method(osc, "/quit", "", on_quit, nullptr);
    lo_server_thread_start(osc);
    lo_address to = lo_address_new("127.0.0.1", reply.c_str());

    std::fprintf(stderr, "nidhogg: running, OSC on %s, replies to %s\n", port.c_str(), reply.c_str());
    last_ping       = now_s();
    board::Leds last{};
    double      next_load = now_s() + 1;
    while(!quit)
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
            std::fprintf(stderr, "load avg %.1f%% max %.1f%% (jack dsp %.1f%%)\n", n ? sum / n : 0.f,
                         mx, jack_cpu_load(client));
        }
        if(watchdog > 0 && t - last_ping > watchdog)
        {
            std::fprintf(stderr, "nidhogg: no ping for %.0f s, quitting\n", watchdog);
            break;
        }
    }

    jack_deactivate(client);
    jack_client_close(client);
    lo_server_thread_free(osc);
    vhw::stop();
    std::_Exit(0);
}
