// TEMPO's pots and status for the norns. The panel itself is in
// board_daisy.cpp. Pots and status come later; for now the firmware runs
// from keys and encoder turns.
#include "board.h"

void board_firmware_attach() {}

namespace board
{

void pot(int, float) {}

Status status()
{
    Status st{};
    return st;
}

} // namespace board
