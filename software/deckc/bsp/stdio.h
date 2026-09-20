#ifndef _DECKC_BSP_STDIO_H_
#define _DECKC_BSP_STDIO_H_

#include <stdint.h>

int  putchar(int c);
int  printf(const char* fmt, ...);
int  snprintf(char* buf, size_t n, const char* fmt, ...);

#endif