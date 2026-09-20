#ifndef _DECKC_BSP_RUNTIME_H_
#define _DECKC_BSP_RUNTIME_H_

/* deckc runtime (software/deckc/rt/crt0.s) entry points reachable from C. */

#include <stdint.h>

void     __decko_uart_init(void);
int      __decko_uart_getc(void);
uint32_t __decko_time_tick(void);
uint32_t __decko_irq_disable(void);
void     __decko_irq_restore(uint32_t saved);

#endif