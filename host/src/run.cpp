// Real-time runner: the firmware as a JACK client, controlled over OSC.
//
// nidhogg-<fw> --card DIR [--port 57140] [--reply 10111] [--cpu N]
//              [--watchdog SECONDS] [--no-connect]
//
// Audio: two inputs, two outputs. By default they connect like a norns
// engine: crone:output_5/6 in, crone:input_5/6 out. OSC messages are in
// bridge.h. Mainly for testing; on norns the firmware runs inside
// SuperCollider (ugen.cpp).
#include "blocks.h"
#include "board.h"
#include "bridge.h"
#include "vhw.h"

#include <jack/jack.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>

int chompi_firmware_main();

namespace
{

jack_client_t*    client;
jack_port_t*      in_port[2];
jack_port_t*      out_port[2];
Blocks            blocks;
std::atomic<bool> quit{false};
int               cpu    = -1;
bool              pinned = false;

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
    blocks.process(static_cast<float*>(jack_port_get_buffer(in_port[0], nframes)),
                   static_cast<float*>(jack_port_get_buffer(in_port[1], nframes)),
                   static_cast<float*>(jack_port_get_buffer(out_port[0], nframes)),
                   static_cast<float*>(jack_port_get_buffer(out_port[1], nframes)),
                   nframes);
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
    if(!bridge::start(port, reply))
    {
        std::fprintf(stderr, "can't open OSC port %s\n", port.c_str());
        return 1;
    }
    std::fprintf(stderr, "nidhogg: running, OSC on %s, replies to %s\n", port.c_str(), reply.c_str());

    while(!quit && !bridge::quit_requested())
    {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if(watchdog > 0 && bridge::seconds_since_ping() > watchdog)
        {
            std::fprintf(stderr, "nidhogg: no ping for %.0f s, quitting\n", watchdog);
            break;
        }
    }

    jack_deactivate(client);
    jack_client_close(client);
    bridge::stop();
    vhw::stop();
    std::_Exit(0);
}
