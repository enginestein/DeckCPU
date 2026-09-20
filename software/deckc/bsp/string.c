/* deckc BSP string helpers (C; the compiler exercises full loops/pointers).
 * strncpy and memset live in software/deckc/rt/crt0.s (deckc_runtime). */

#include <stdint.h>

size_t strlen(const char* s)
{
    size_t n = 0;
    while (s[n] != 0)
        n++;
    return n;
}

int strcmp(const char* a, const char* b)
{
    while (*a != 0 && *a == *b) {
        a++;
        b++;
    }
    return (int)*a - (int)*b;
}

int strncmp(const char* a, const char* b, size_t n)
{
    while (n > 0 && *a != 0 && *a == *b) {
        a++;
        b++;
        n--;
    }
    if (n == 0)
        return 0;
    return (int)*a - (int)*b;
}

char* strcpy(char* dst, const char* src)
{
    char* d = dst;
    while (*src != 0) {
        *d = *src;
        d++;
        src++;
    }
    *d = 0;
    return dst;
}

void* memcpy(void* dst, const void* src, size_t n)
{
    char* d = (char*)dst;
    const char* s = (const char*)src;
    size_t i;
    for (i = 0; i < n; i++)
        d[i] = s[i];
    return dst;
}