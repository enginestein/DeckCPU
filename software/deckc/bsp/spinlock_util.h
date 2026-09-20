#ifndef _DECKC_BSP_SPINLOCK_UTIL_H_
#define _DECKC_BSP_SPINLOCK_UTIL_H_

/* Single-core DeckCPU: "spinlocks" collapse to IRQ disable/restore.
 * syslog_lock returns the saved interrupt state; syslog_unlock restores it. */

#include <stdint.h>

#define SCHED_SPINLOCK_ID   14
#define CONFIG_SPINLOCK_ID  15
#define SYSLOG_SPINLOCK_ID  13

uint32_t syslog_lock(void);
void     syslog_unlock(uint32_t saved);

#endif