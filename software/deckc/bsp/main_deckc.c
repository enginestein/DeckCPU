/* deckc syslog smoke: boots the DeckOS syslog module on the DeckCPU.

 * Expected transcript:
 *   ring log ready (64 slots)
 *   ...5 entries, then "syslog cleared  (5 total entries discarded)",
 *   then "(log empty)".
 * And main() returns (int)syslog_total() == 5 -> stamped into the mailbox at
 * 0xDF00 by crt0.
 */

#include <stdint.h>
#include "deckc_runtime.h"
#include "syslog.h"

int main(void)
{
    __decko_uart_init();

    syslog_init();

    syslog_write(LOG_DEBUG, "deckc", "boot complete");
    syslog_write(LOG_WARN,  "deckc", "brownout detected");
    syslog_write(LOG_ERR,   "deckc", "allocation failed");
    syslog_write(LOG_INFO,  "deckc", "scan started");

    syslog_dump(LOG_DEBUG, 0);

    syslog_clear();
    syslog_dump(LOG_DEBUG, 0);

    return (int)syslog_total();
}