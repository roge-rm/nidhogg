// CMSIS intrinsics for the host build. Masking interrupts takes the virtual
// hardware's irq lock, so masked sections exclude the audio and timer contexts.
#pragma once
#include <stdint.h>

namespace vhw
{
void irq_disable();
void irq_enable();
bool irq_disabled_by_me();
} // namespace vhw

static inline uint32_t __get_PRIMASK(void)
{
    return vhw::irq_disabled_by_me() ? 1u : 0u;
}
static inline void __disable_irq(void)
{
    vhw::irq_disable();
}
static inline void __enable_irq(void)
{
    vhw::irq_enable();
}
static inline void __DSB(void) { __sync_synchronize(); }
static inline void __DMB(void) { __sync_synchronize(); }
static inline void __ISB(void) { __sync_synchronize(); }
