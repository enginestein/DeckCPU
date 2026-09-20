/* deckc interactive console: a shell compiled in C, running on the DeckCPU
 * netlist / interpreter. UART RX drives a line editor, then the line
 * dispatches to the command set below. Boot detail is logged through the
 * verbatim DeckOS syslog module (same BSP wiring as the CIOS image).
 *
 * Deterministic session, mirrored in test_deckc.py and cshell_tb.sv:
 *   help / echo / time / calc / poke / peek / gpio / clear / exit
 *   (full command list in deckos-port/README.md)
 */

#include <stdint.h>
#include <string.h>
#include "deckc_runtime.h"
#include "stdio.h"
#include "pico/stdlib.h"
#include "syslog.h"

#define GPIO_BASE    0x40002000
#define GPIO_REG_OUT 0x40002004
#define GPIO_REG_DIR 0x40002000

static char line[96];

static uint32_t mmio_read(uint32_t addr)
{
    return *((uint32_t*)addr);
}

static void mmio_write(uint32_t addr, uint32_t val)
{
    *((uint32_t*)addr) = val;
}

static const char* skip_spaces(const char* s)
{
    while (*s == ' ' || *s == '\t')
        s++;
    return s;
}

/* Copy the first whitespace-delimited token of s into out, then return a
 * pointer at the next token (or the terminating NUL). */
static const char* word_cpy(const char* s, char* out, int cap)
{
    int i = 0;
    s = skip_spaces(s);
    while (*s != 0 && *s != ' ' && *s != '\t' && i < cap - 1) {
        out[i] = *s;
        i++;
        s++;
    }
    out[i] = 0;
    return skip_spaces(s);
}

static void take_rest(const char* s, char* out, int cap)
{
    int i = 0;
    s = skip_spaces(s);
    while (*s != 0 && i < cap - 1) {
        out[i] = *s;
        i++;
        s++;
    }
    out[i] = 0;
}

static int parse_dec(const char* s, uint32_t* out)
{
    uint32_t v = 0;
    if (*s < '0' || *s > '9')
        return 0;
    while (*s >= '0' && *s <= '9') {
        v = v * 10 + (uint32_t)(*s - '0');
        s++;
    }
    *out = v;
    return 1;
}

static int parse_hex(const char* s, uint32_t* out)
{
    uint32_t v = 0;
    int any = 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
        s += 2;
    for (;;) {
        char c = *s;
        uint32_t d;
        if (c >= '0' && c <= '9')
            d = (uint32_t)(c - '0');
        else if (c >= 'a' && c <= 'f')
            d = (uint32_t)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F')
            d = (uint32_t)(c - 'A' + 10);
        else
            break;
        v = (v << 4) | d;
        any = 1;
        s++;
    }
    if (!any)
        return 0;
    *out = v;
    return 1;
}

/* Read and echo one line of UART input (CR or LF ends it). */
static int read_line(char* buf, int cap)
{
    int i = 0;
    for (;;) {
        int c = __decko_uart_getc();
        if (c == 13 || c == 10)
            break;
        if (c == 8 || c == 127) {
            if (i > 0) {
                i--;
                putchar(8);
            }
            continue;
        }
        if (i < cap - 1) {
            buf[i] = (char)c;
            i++;
        }
        putchar(c);
    }
    buf[i] = 0;
    return i;
}

static void do_help(void)
{
    printf("commands: help echo time gpio peek poke calc clear exit\r\n");
}

static void do_echo(const char* rest)
{
    char tmp[72];
    take_rest(rest, tmp, 72);
    printf("%s\r\n", tmp);
}

static void do_time(void)
{
    printf("t=%08x\r\n", get_absolute_time());
}

static void do_peek(const char* rest)
{
    uint32_t addr;
    if (!parse_hex(skip_spaces(rest), &addr)) {
        printf("bad address\r\n");
        return;
    }
    printf("%08x\r\n", mmio_read(addr));
}

static void do_poke(const char* rest)
{
    const char* p;
    uint32_t addr, val;
    p = skip_spaces(rest);
    if (!parse_hex(p, &addr)) {
        printf("bad address\r\n");
        return;
    }
    while (*p != 0 && *p != ' ' && *p != '\t')
        p++;
    if (!parse_hex(skip_spaces(p), &val)) {
        printf("bad value\r\n");
        return;
    }
    mmio_write(addr, val);
    printf("%08x\r\n", mmio_read(addr));
}

static void do_gpio(const char* rest)
{
    const char* p;
    uint32_t pin, val, bit;
    p = skip_spaces(rest);
    if (!parse_dec(p, &pin)) {
        printf("bad request\r\n");
        return;
    }
    while (*p >= '0' && *p <= '9')
        p++;
    p = skip_spaces(p);
    if (!parse_dec(p, &val) || pin > 31 || val > 1) {
        printf("bad request\r\n");
        return;
    }
    bit = ((uint32_t)1) << pin;
    mmio_write(GPIO_REG_DIR, mmio_read(GPIO_REG_DIR) | bit);
    if (val)
        mmio_write(GPIO_REG_OUT, mmio_read(GPIO_REG_OUT) | bit);
    else
        mmio_write(GPIO_REG_OUT, mmio_read(GPIO_REG_OUT) & ~bit);
    printf("gpio %d -> %d\r\n", pin, val);
}

static void do_calc(const char* rest)
{
    const char* p;
    uint32_t a, b, r;
    int op;
    p = skip_spaces(rest);
    if (!parse_dec(p, &a)) {
        printf("bad calc\r\n");
        return;
    }
    while (*p >= '0' && *p <= '9')
        p++;
    p = skip_spaces(p);
    op = (int)*p;
    if (op == 0) {
        printf("bad calc\r\n");
        return;
    }
    p++;
    if (!parse_dec(skip_spaces(p), &b)) {
        printf("bad calc\r\n");
        return;
    }
    if (op == '+')
        r = a + b;
    else if (op == '-')
        r = a - b;
    else if (op == '*')
        r = a * b;
    else if (op == '&')
        r = a & b;
    else if (op == '|')
        r = a | b;
    else if (op == '^')
        r = a ^ b;
    else {
        printf("bad calc\r\n");
        return;
    }
    printf("%08x\r\n", r);
}

static void do_clear(void)
{
    printf("syslog cleared (%d entries)\r\n", (int)syslog_total());
    syslog_clear();
}

int main(void)
{
    char cmd[16];
    const char* rest;

    __decko_uart_init();
    syslog_init();
    syslog_write(LOG_INFO, "deckc", "console up");
    printf("deckc/1.0 DeckCPU console\r\n");

    for (;;) {
        printf("deckc> ");
        read_line(line, 96);
        printf("\r\n");
        rest = word_cpy(line, cmd, 16);
        if (cmd[0] == 0)
            continue;
        if (strcmp(cmd, "help") == 0)
            do_help();
        else if (strcmp(cmd, "echo") == 0)
            do_echo(rest);
        else if (strcmp(cmd, "time") == 0)
            do_time();
        else if (strcmp(cmd, "gpio") == 0)
            do_gpio(rest);
        else if (strcmp(cmd, "peek") == 0)
            do_peek(rest);
        else if (strcmp(cmd, "poke") == 0)
            do_poke(rest);
        else if (strcmp(cmd, "calc") == 0)
            do_calc(rest);
        else if (strcmp(cmd, "clear") == 0)
            do_clear();
        else if (strcmp(cmd, "exit") == 0) {
            printf("bye\r\n");
            return 0;
        }
        else
            printf("Unknown command: %s\r\n", cmd);
    }
}