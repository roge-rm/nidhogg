// Offline harness: boots the firmware on a card folder, plays a timed script of
// panel events and writes the output to a WAV. Runs in lockstep, so the same
// script gives the same result every time.
//
// nidhogg-<fw>-render --card DIR --seconds S --out FILE.wav [--in FILE.wav] EVENT...
//   EVENT is TIME:WHAT:ARGS, TIME in seconds:
//     1.5:key:15:1      key (Hardware::SwId) down, :0 for up
//     2:turn:3:+10      encoder 0-5 (SW1-SW6) by detents
//     2:push:3:1        encoder push down/up
//     0:switch:rec      Play/Record switch (rec|play)
//     3:midi:usb:903c7f MIDI bytes in (trs|usb), hex
//     4:leds            print the LEDs
//   Output: 4 channels, 32-bit float: headphone L/R, line L/R.
#include "board.h"
#include "vhw.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

int chompi_firmware_main();

namespace
{

struct Event
{
    double      t;
    std::string what;
    std::string args;
};

void print_leds()
{
    board::Leds l = board::leds();
    std::printf("[%8.3f] panel:", vhw::now_us() / 1e6);
    for(auto& c : l.panel)
        std::printf(" %02x%02x%02x", c[0], c[1], c[2]);
    std::printf("\n           keys: ");
    for(auto& c : l.keys)
        std::printf(" %02x%02x%02x", c[0], c[1], c[2]);
    std::printf("\n");
}

std::vector<uint8_t> hex_bytes(const std::string& s)
{
    std::vector<uint8_t> out;
    for(size_t i = 0; i + 1 < s.size(); i += 2)
        out.push_back(uint8_t(std::strtoul(s.substr(i, 2).c_str(), nullptr, 16)));
    return out;
}

void apply(const Event& e)
{
    auto        colon = e.args.find(':');
    std::string a     = e.args.substr(0, colon);
    std::string b     = colon == std::string::npos ? "" : e.args.substr(colon + 1);
    if(e.what == "key")
        board::key(std::atoi(a.c_str()), std::atoi(b.c_str()) != 0);
    else if(e.what == "turn")
        board::turn(std::atoi(a.c_str()), std::atoi(b.c_str()));
    else if(e.what == "push")
        board::push(std::atoi(a.c_str()), std::atoi(b.c_str()) != 0);
    else if(e.what == "switch")
        board::set_switch(a == "rec");
    else if(e.what == "midi")
    {
        auto bytes = hex_bytes(b);
        vhw::midi_in(a == "trs" ? vhw::MidiPort::TRS : vhw::MidiPort::USB,
                     bytes.data(), bytes.size());
    }
    else if(e.what == "leds")
        print_leds();
    else
        std::fprintf(stderr, "unknown event %s\n", e.what.c_str());
}

// Reads a 16-bit or float WAV into stereo float. Good enough for test input.
bool read_wav(const char* path, std::vector<float>& lr)
{
    FILE* f = std::fopen(path, "rb");
    if(!f)
        return false;
    char     id[4];
    uint32_t sz;
    uint16_t fmt = 1, ch = 2, bits = 16;
    std::fseek(f, 12, SEEK_SET);
    while(std::fread(id, 1, 4, f) == 4 && std::fread(&sz, 4, 1, f) == 1)
    {
        if(!std::memcmp(id, "fmt ", 4))
        {
            std::fread(&fmt, 2, 1, f);
            std::fread(&ch, 2, 1, f);
            std::fseek(f, 10, SEEK_CUR);
            std::fread(&bits, 2, 1, f);
            std::fseek(f, sz - 16, SEEK_CUR);
        }
        else if(!std::memcmp(id, "data", 4))
        {
            size_t frames = sz / (ch * bits / 8);
            lr.resize(frames * 2);
            for(size_t i = 0; i < frames; i++)
                for(int c = 0; c < ch; c++)
                {
                    float v = 0;
                    if(bits == 16)
                    {
                        int16_t s;
                        std::fread(&s, 2, 1, f);
                        v = s / 32768.f;
                    }
                    else
                        std::fread(&v, 4, 1, f);
                    if(c < 2)
                        lr[i * 2 + c] = v;
                    if(ch == 1)
                        lr[i * 2 + 1] = v;
                }
            break;
        }
        else
            std::fseek(f, sz, SEEK_CUR);
    }
    std::fclose(f);
    return true;
}

void write_wav(const char* path, const std::vector<float>& data, int ch)
{
    FILE* f = std::fopen(path, "wb");
    if(!f)
        return;
    uint32_t bytes = uint32_t(data.size() * 4);
    uint32_t riff  = 36 + bytes;
    uint16_t fmt = 3, chans = uint16_t(ch), bits = 32, align = uint16_t(ch * 4);
    uint32_t rate = vhw::kSampleRate, brate = rate * align, fsz = 16;
    std::fwrite("RIFF", 1, 4, f);
    std::fwrite(&riff, 4, 1, f);
    std::fwrite("WAVEfmt ", 1, 8, f);
    std::fwrite(&fsz, 4, 1, f);
    std::fwrite(&fmt, 2, 1, f);
    std::fwrite(&chans, 2, 1, f);
    std::fwrite(&rate, 4, 1, f);
    std::fwrite(&brate, 4, 1, f);
    std::fwrite(&align, 2, 1, f);
    std::fwrite(&bits, 2, 1, f);
    std::fwrite("data", 1, 4, f);
    std::fwrite(&bytes, 4, 1, f);
    std::fwrite(data.data(), 4, data.size(), f);
    std::fclose(f);
}

} // namespace

int main(int argc, char** argv)
{
    const char*        card = ".", *out = "out.wav", *in = nullptr;
    double             seconds = 5;
    std::vector<Event> events;
    for(int i = 1; i < argc; i++)
    {
        std::string a = argv[i];
        if(a == "--card" && i + 1 < argc)
            card = argv[++i];
        else if(a == "--out" && i + 1 < argc)
            out = argv[++i];
        else if(a == "--in" && i + 1 < argc)
            in = argv[++i];
        else if(a == "--seconds" && i + 1 < argc)
            seconds = std::atof(argv[++i]);
        else
        {
            auto c1 = a.find(':');
            auto c2 = a.find(':', c1 + 1);
            if(c1 == std::string::npos)
            {
                std::fprintf(stderr, "bad event %s\n", a.c_str());
                return 1;
            }
            events.push_back({std::atof(a.substr(0, c1).c_str()),
                              a.substr(c1 + 1, c2 == std::string::npos ? std::string::npos : c2 - c1 - 1),
                              c2 == std::string::npos ? "" : a.substr(c2 + 1)});
        }
    }

    std::vector<float> input;
    if(in && !read_wav(in, input))
    {
        std::fprintf(stderr, "can't read %s\n", in);
        return 1;
    }

    vhw::set_card_root(card);
    board::attach();
    vhw::Config cfg;
    cfg.mode = vhw::Mode::Lockstep;
    vhw::start(cfg, chompi_firmware_main);

    const size_t       blocks = size_t(seconds * vhw::kSampleRate / vhw::kBlockSize);
    std::vector<float> rec;
    rec.reserve(blocks * vhw::kBlockSize * 4);
    float  ibuf[4][vhw::kBlockSize] = {}, obuf[4][vhw::kBlockSize];
    float* ins[4]  = {ibuf[0], ibuf[1], ibuf[2], ibuf[3]};
    float* outs[4] = {obuf[0], obuf[1], obuf[2], obuf[3]};
    size_t next    = 0;
    std::stable_sort(events.begin(), events.end(),
                     [](const Event& a, const Event& b) { return a.t < b.t; });

    for(size_t blk = 0; blk < blocks; blk++)
    {
        double t = double(blk * vhw::kBlockSize) / vhw::kSampleRate;
        while(next < events.size() && events[next].t <= t)
            apply(events[next++]);
        for(size_t i = 0; i < vhw::kBlockSize; i++)
        {
            size_t f = blk * vhw::kBlockSize + i;
            float  l = 0, r = 0;
            if(f * 2 + 1 < input.size())
            {
                l = input[f * 2];
                r = input[f * 2 + 1];
            }
            ibuf[0][i] = l; // mic
            ibuf[2][i] = l; // line in
            ibuf[3][i] = r;
        }
        vhw::audio_block(ins, outs);
        for(size_t i = 0; i < vhw::kBlockSize; i++)
            for(int c = 0; c < 4; c++)
                rec.push_back(obuf[c][i]);
        for(auto port : {vhw::MidiPort::TRS, vhw::MidiPort::USB})
        {
            auto bytes = vhw::midi_out(port);
            if(bytes.empty())
                continue;
            std::printf("[%8.3f] midi %s:", vhw::now_us() / 1e6,
                        port == vhw::MidiPort::TRS ? "trs" : "usb");
            for(auto b : bytes)
                std::printf(" %02x", b);
            std::printf("\n");
        }
    }
    print_leds();
    write_wav(out, rec, 4);
    vhw::stop();
    std::fflush(stdout);
    std::_Exit(0);
}
