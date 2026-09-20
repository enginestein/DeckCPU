#ifndef _DECKC_BSP_BT_H_
#define _DECKC_BSP_BT_H_

/* Stand-in for pico-sdk DeckOS include/bt.h: only the two symbols the syslog
 * module touches are declared; the Bluetooth port is disabled on DeckCPU. */

#include <stdint.h>
#include <stdbool.h>

bool bt_log_is_enabled(void);
void bt_log_mirror(const char* level, const char* tag, const char* msg,
                   uint32_t ts_ms);

#endif