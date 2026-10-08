// The firmware inside SuperCollider, as one UGen per firmware: NidhoggTape,
// NidhoggTempo, NidhoggWave. Built once per firmware with NIDHOGG_UGEN set to
// the UGen name and NIDHOGG_OSC_PORT to its OSC port.
//
// Plugin command, sent before the first synth:
//   /cmd nidhogg<Fw>Start s:card_folder
// starts the firmware and its OSC bridge (bridge.h) on scsynth's non-real-time
// thread. The UGen then feeds it audio:
//   Nidhogg<Fw>.ar(in_l, in_r) -> [out_l, out_r]
// Only one instance runs the firmware; others output silence. Freeing the
// synth pauses the firmware, since its time only moves with audio, and a new
// synth carries on from there.
#include "SC_PlugIn.h"

#include "blocks.h"
#include "board.h"
#include "bridge.h"
#include "vhw.h"

#include <atomic>
#include <cstring>
#include <string>

int chompi_firmware_main();

#define CAT2(a, b) a##b
#define CAT(a, b) CAT2(a, b)
#define STR2(a) #a
#define STR(a) STR2(a)
#define UNIT NIDHOGG_UGEN
// SC's macros paste their argument, so expand UNIT first.
#define DEFINE_DTOR_UNIT(name) DefineDtorUnit(name)

static InterfaceTable* ft;

namespace
{

std::atomic<bool>  started{false};
std::atomic<Unit*> owner{nullptr};
Blocks             blocks; // only the owning unit's calc function touches it

struct StartCmd
{
    char card[512];
};

bool start_stage2(World*, void* data)
{
    auto* cmd = static_cast<StartCmd*>(data);
    if(started)
        return true;
    vhw::set_card_root(cmd->card);
    board::attach();
    vhw::Config cfg;
    cfg.mode = vhw::Mode::Realtime;
    vhw::start(cfg, chompi_firmware_main);
    bridge::start(STR(NIDHOGG_OSC_PORT), "10111");
    started = true;
    return true;
}

void start_cleanup(World* world, void* data)
{
    RTFree(world, data);
}

void start_cmd(World* world, void*, sc_msg_iter* args, void* reply_addr)
{
    const char* card = args->gets("");
    auto*       cmd  = static_cast<StartCmd*>(RTAlloc(world, sizeof(StartCmd)));
    if(!cmd)
        return;
    std::strncpy(cmd->card, card, sizeof(cmd->card) - 1);
    cmd->card[sizeof(cmd->card) - 1] = 0;
    DoAsynchronousCommand(world, reply_addr, STR(CAT(UNIT, Start)), cmd, start_stage2, nullptr,
                          nullptr, start_cleanup, 0, nullptr);
}

} // namespace

struct UNIT : public Unit
{
};

static void CAT(UNIT, _next)(UNIT* unit, int n)
{
    float* outl = OUT(0);
    float* outr = OUT(1);
    if(!started || owner.load() != unit)
    {
        std::memset(outl, 0, n * sizeof(float));
        std::memset(outr, 0, n * sizeof(float));
        return;
    }
    blocks.process(IN(0), IN(1), outl, outr, size_t(n));
}

static void CAT(UNIT, _Ctor)(UNIT* unit)
{
    Unit* none = nullptr;
    if(owner.compare_exchange_strong(none, unit))
        blocks.reset();
    SETCALC(CAT(UNIT, _next));
    OUT0(0) = 0.f;
    OUT0(1) = 0.f;
}

static void CAT(UNIT, _Dtor)(UNIT* unit)
{
    Unit* me = unit;
    owner.compare_exchange_strong(me, nullptr);
}

PluginLoad(UNIT)
{
    ft = inTable;
    DEFINE_DTOR_UNIT(UNIT);
    DefinePlugInCmd(STR(CAT(UNIT, Start)), start_cmd, nullptr);
}
