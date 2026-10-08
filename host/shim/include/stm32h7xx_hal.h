// The few STM32 HAL names the firmware calls directly. None of them do
// anything on the host.
#pragma once
#include <stdint.h>
#include "cmsis_gcc.h"

#define PWR_LOWPOWERREGULATOR_ON 1u
#define PWR_STOPENTRY_WFI 1u
static inline void HAL_PWR_EnterSTOPMode(uint32_t, uint8_t) {}

// Cortex-M7 data cache maintenance; there's no cache in the way on the host.
static inline void SCB_CleanDCache_by_Addr(uint32_t*, int32_t) {}
static inline void SCB_InvalidateDCache_by_Addr(uint32_t*, int32_t) {}
static inline void SCB_CleanInvalidateDCache_by_Addr(uint32_t*, int32_t) {}
