#ifndef _DECKC_BSP_PICO_STDLIB_H_
#define _DECKC_BSP_PICO_STDLIB_H_

/* Minimal "pico/stdlib.h" stand-in for the DeckCPU target.
 * get_absolute_time()/to_ms_since_boot() fudge the Pico time API onto the
 * deckc free-running millisecond counter (see also __decko_time_tick). */

#include <stdint.h>

uint32_t get_absolute_time(void);
uint32_t to_ms_since_boot(uint32_t t);

#endif