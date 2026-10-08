// The few STM32 HAL names the firmware calls directly. None of them do
// anything on the host.
#pragma once
#include <stdint.h>
#include "cmsis_gcc.h"

#define PWR_LOWPOWERREGULATOR_ON 1u
#define PWR_STOPENTRY_WFI 1u
static inline void HAL_PWR_EnterSTOPMode(uint32_t, uint8_t) {}
