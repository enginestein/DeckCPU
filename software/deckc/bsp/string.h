#ifndef _DECKC_BSP_STRING_H_
#define _DECKC_BSP_STRING_H_

#include <stdint.h>

void*  memset(void* dst, int val, size_t n);
char*  strncpy(char* dst, const char* src, size_t n);

size_t strlen(const char* s);
int    strcmp(const char* a, const char* b);
int    strncmp(const char* a, const char* b, size_t n);
char*  strcpy(char* dst, const char* src);
void*  memcpy(void* dst, const void* src, size_t n);

#endif