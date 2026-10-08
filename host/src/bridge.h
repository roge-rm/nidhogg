// OSC link between the firmware and the norns script. Same messages whether
// the firmware runs as a JACK client or inside SuperCollider.
//
// In (UDP, `port`):
//   /key i:sw_id i:down        /turn i:encoder i:detents
//   /push i:encoder i:down     /switch i:record
//   /pot i:knob f:value        absolute pot, knob 0-5 as Chompi numbers them
//   /midi s:"trs"|"usb" then b:bytes or i:byte...
//   /hello                     send everything again, not just changes
//   /ping   /quit
// Out (to `reply` on localhost):
//   /leds b:105 bytes          10 panel then 25 key LEDs, RGB, on change
//   /midi s:port b:bytes       what the firmware sent
//   /load f:avg_percent f:max_percent   once a second
//   /knob i:knob i:page f:value         on change
//   /pickup i:knob i:picked             whether a pot has taken over its knob
//   /state i:menu i:state0..9           on change, see board::Status
//   /looper f:position f:dub_level      on change
#pragma once
#include <string>

namespace bridge
{

bool start(const std::string& port, const std::string& reply);
void stop();
bool quit_requested();
double seconds_since_ping();
// Audio-thread time per firmware block, as a percentage of the block's length.
void report_block_load(float percent);

} // namespace bridge
