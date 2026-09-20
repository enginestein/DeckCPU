/* deckc BSP glue: single-core DeckCPU stand-ins for the API surface that the
 * DeckOS kernel syslog.c pulls in through its headers.  printf / snprintf /
 * memset / strncpy / putchar live in software/deckc/rt/crt0.s; only the
 * time + "spinlock" + BT mirror hooks are C code. */

#include <stdint.h>
#include <stdbool.h>
#include "deckc_runtime.h"
#include "pico/stdlib.h"
#include "spinlock_util.h"
#include "bt.h"

uint32_t syslog_lock(void)
{
    return __decko_irq_disable();
}

void syslog_unlock(uint32_t saved)
{
    __decko_irq_restore(saved);
}

uint32_t get_absolute_time(void)
{
    return __decko_time_tick();
}

uint32_t to_ms_since_boot(uint32_t t)
{
    return t;
}

bool bt_log_is_enabled(void)
{
    return false;
}

void bt_log_mirror(const char* level, const char* tag, const char* msg,
                   uint32_t ts_ms)
{
}