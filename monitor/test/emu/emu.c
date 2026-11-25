/*
 * core68008 board model for testing the ROM monitor (Musashi 68000 core).
 *
 *  - 20-bit address bus: every address is masked to A0-A19.
 *  - GAL1 decode: RAM $00000-$7FFFF, flash $80000-$BFFFF, Junior window
 *    $C0000-$CFFFF (2K RAM at $C0000 models a memory card, rest reads $FF),
 *    $D0000-$EFFFF bus error, 68681 at $F0000-$FFFFF (RS1-4 = A0-A3).
 *  - Boot overlay: after reset, reads of $00000-$7FFFF come from flash until
 *    the first access in $80000-$BFFFF; writes always go to RAM.
 *  - 68008 timing estimate: Musashi 68000 cycles plus 4 clocks for every
 *    extra byte cycle a word/long access needs on the 8-bit bus.
 *  - 68681 channel A only (enough for the monitor): MR1/MR2 pointer, SR, CR
 *    commands, RHR 3-deep FIFO with overrun, THR to stdout, IMR/ISR, IVR,
 *    OPR set/reset, IP0 (CTS), RxRTS flow control on OP0.
 *  - IACK level 5 -> IVR (or spurious if the DUART is not requesting),
 *    levels 2 and 7 autovectored (VPA).
 *  - SST39SF020A command model: unlock cycles on $5555/$2AAA (A14-A0),
 *    byte program (bits only go 1 -> 0, 20 us busy, DQ7 data polling and DQ6
 *    toggle), sector erase (4K, 18 ms), chip erase, software ID (BF B6).
 *    Reads while busy or in ID mode return status/ID, not data; an
 *    instruction fetch from the flash then is reported. Bad sequences are
 *    reported too.
 *
 * Script (stdin of -s file): one line per entry.
 *   text            wait for the prompt, then send text + CR
 *   @wait STR       wait until output contains STR (since last send)
 *   @send TEXT      send TEXT + CR without waiting for the prompt
 *   @raw HEX..      send raw bytes (no CR)
 *   @file NAME      send a file's bytes (e.g. S-records), lines end in CR
 *   @nmi            pulse the level-7 NMI
 *   @break          send a BREAK condition
 *   @run N          run N clocks with no input
 *   @reset          hardware reset (PORST)
 *   @dump A N       print N bytes of memory at A (host side)
 *   @fast           feed characters as fast as the FIFO allows (no baud timing)
 *   @noflow         ignore RTS (sender does not honour flow control)
 *   @lag N          sender still sends N characters after RTS goes away and
 *                   ignores the FIFO (an FTDI-like sender; 0 = ideal, default)
 *   @track H T      track the max of byte (H) - byte (T) (ring fill); reported
 *                   by @track without arguments (which stops it) or at the end
 *   @load FILE A    copy a file into memory at A (host side)
 *   @save FILE      write the 256K flash contents to FILE
 *   @stuck A M      flash byte A keeps bits M at 1 (program fails); M=0 clears
 *   @flashlog       print every flash program/erase command
 *   # ...           comment
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <termios.h>
#include <unistd.h>
#include <sys/select.h>
#include <time.h>
#include "m68k.h"
#include "m68kcpu.h"

static uint8_t ram[0x80000], rom[0x40000], win[0x800];
static int overlay = 1;
static unsigned long long clocks68008 = 0, extra = 0;
int emu_berr_flag = 0;

/* ---- DUART channel A ---- */
static uint8_t mr1a, mr2a, mrptr, sra_err, imr, ivr = 0x0f, acr, csra, opr, opcr;
static int rx_en, tx_en;
static uint8_t fifo[3], fifo_brk[3]; static int fifo_n;
static int break_pending; static uint8_t isr_brk;
static int ip0_cts = 0;   /* CTS input low = asserted */
static char outbuf[1 << 20]; static size_t outlen, outmark;
static int noflow = 0, fast = 0;
static int lag = 0, lag_cnt = 0;          /* @lag: characters the sender still sends after RTS goes away */
static unsigned trk_h = 0, trk_t = 0; static int trk_max = -1;   /* @track: max ring fill */
static unsigned long long next_rx_clock;
static const unsigned CHAR_CLOCKS = 2083; /* 8 MHz / 3840 chars/s (38400 baud) */
static int verbose_led = 1;
static int halted = 0;
static unsigned long long overruns = 0;

static void duart_reset(void) {
    mr1a = mr2a = 0; mrptr = 0; sra_err = 0; imr = 0; ivr = 0x0f; acr = 0; csra = 0;
    opr = 0; opcr = 0; rx_en = tx_en = 0; fifo_n = 0; isr_brk = 0;
}
static uint8_t duart_isr(void) {
    uint8_t v = 0;
    if (tx_en) v |= 0x01;
    if (fifo_n > 0 && !(mr1a & 0x40)) v |= 0x02;
    if (fifo_n == 3 && (mr1a & 0x40)) v |= 0x02;
    if (isr_brk) v |= 0x04;
    return v;
}
static void update_irq(void) {
    int lvl = (duart_isr() & imr) ? 5 : 0;
    m68k_set_irq(lvl);
}
static int rts_asserted(void) { return (opr & 1) != 0; } /* OPR bit set -> OP0 low */

static void rx_push(uint8_t c, int brk) {
    if (fifo_n < 3) { fifo_brk[fifo_n] = brk; fifo[fifo_n++] = c; }
    else { sra_err |= 0x10; overruns++; }
    if (mr1a & 0x80 && fifo_n == 3) opr &= ~1; /* RxRTS: negate RTS when FIFO full */
    update_irq();
}
static uint8_t duart_read(unsigned r) {
    uint8_t v = 0xff;
    switch (r) {
    case 0: v = mrptr ? mr2a : mr1a; mrptr = 1; break;
    case 1: v = (fifo_n ? 1 : 0) | (fifo_n == 3 ? 2 : 0) | (tx_en ? 0x0c : 0) | sra_err | (fifo_n && fifo_brk[0] ? 0x80 : 0); break;
    case 3: if (fifo_n) { v = fifo[0]; memmove(fifo, fifo + 1, 2); memmove(fifo_brk, fifo_brk + 1, 2); fifo_n--; }
            else v = 0;
            if ((mr1a & 0x80) && fifo_n < 3) opr |= 1; /* RxRTS: reassert */
            break;
    case 4: v = 0; break;
    case 5: v = duart_isr(); break;
    case 12: v = ivr; break;
    case 13: v = (ip0_cts ? 0 : 1) | 0x3e; break;  /* IP0 = CTS input level */
    default: v = 0xff; break;
    }
    update_irq();
    return v;
}
static void duart_write(unsigned r, uint8_t v) {
    switch (r) {
    case 0: if (mrptr) mr2a = v; else mr1a = v; mrptr = 1; break;
    case 1: csra = v; break;
    case 2: {
        int misc = (v >> 4) & 7;
        if ((v & 3) == 1) rx_en = 1; else if ((v & 3) == 2) rx_en = 0;
        if (((v >> 2) & 3) == 1) tx_en = 1; else if (((v >> 2) & 3) == 2) tx_en = 0;
        switch (misc) {
        case 1: mrptr = 0; break;
        case 2: rx_en = 0; fifo_n = 0; break;
        case 3: tx_en = 0; break;
        case 4: sra_err = 0; break;
        case 5: isr_brk = 0; break;
        }
        break; }
    case 3: if (tx_en) { putchar(v); fflush(stdout); if (outlen < sizeof outbuf - 1) outbuf[outlen++] = v; } break;
    case 4: acr = v; break;
    case 5: imr = v; break;
    case 12: ivr = v; break;
    case 13: opcr = v; break;
    case 14: { uint8_t o = opr; opr |= v; if (verbose_led && ((o ^ opr) & 0xc0)) fprintf(stderr, "[LED OP6=%d OP7=%d]\n", !!(opr & 0x40), !!(opr & 0x80)); } break;
    case 15: { uint8_t o = opr; opr &= ~v; if (verbose_led && ((o ^ opr) & 0xc0)) fprintf(stderr, "[LED OP6=%d OP7=%d]\n", !!(opr & 0x40), !!(opr & 0x80)); } break;
    }
    update_irq();
}

/* ---- SST39SF020A ---- */
static int fl_cyc, fl_id, fl_prog, fl_erase_arm, fl_busy, fl_toggle, fl_log, fl_warned;
static unsigned long long fl_busy_until;
static uint8_t fl_busy_data;
static unsigned fl_stuck_addr = 0xffffffff; static uint8_t fl_stuck_mask;
static unsigned long long fl_nprog, fl_nsect, fl_nchip;
static unsigned long long now_exact(void) { return clocks68008 + m68k_cycles_run() + extra; }
static void flash_reset(void) { fl_cyc = fl_id = fl_prog = fl_erase_arm = fl_busy = 0; }
static int flash_unreadable(void) {
    if (fl_busy && now_exact() >= fl_busy_until) fl_busy = 0;
    return fl_busy || fl_id;
}
static uint8_t flash_read(unsigned ca) {
    if (fl_busy && now_exact() >= fl_busy_until) fl_busy = 0;
    if (fl_busy) {
        fl_toggle ^= 0x40;
        if (fl_busy == 1) return (~fl_busy_data & 0x80) | fl_toggle | 0x15;  /* program: DQ7# */
        return fl_toggle | 0x08;                                           /* erase: DQ7 = 0 */
    }
    if (fl_id) return (ca & 1) ? 0xb6 : 0xbf;
    return rom[ca];
}
static void flash_bad(unsigned ca, uint8_t v) {
    fprintf(stderr, "[flash: unexpected write %05X=%02X (cycle %d)]\n", ca + 0x80000, v, fl_cyc);
    fl_cyc = 0; fl_erase_arm = 0;
}
static void flash_write(unsigned ca, uint8_t v) {
    unsigned c15 = ca & 0x7fff;
    if (fl_busy && now_exact() >= fl_busy_until) fl_busy = 0;
    if (fl_busy) { fprintf(stderr, "[flash: write %05X=%02X while busy]\n", ca + 0x80000, v); return; }
    if (fl_prog) {
        fl_prog = 0;
        uint8_t nv = rom[ca] & v;
        if (ca == fl_stuck_addr) nv |= fl_stuck_mask;
        rom[ca] = nv; fl_nprog++;
        fl_busy = 1; fl_busy_data = v; fl_busy_until = now_exact() + 160;  /* 20 us */
        if (fl_log) fprintf(stderr, "[flash: program %05X=%02X]\n", ca + 0x80000, v);
        return;
    }
    if (fl_cyc == 0 && v == 0xf0) { fl_id = 0; fl_erase_arm = 0; return; }  /* one-cycle exit */
    switch (fl_cyc) {
    case 0: if (c15 == 0x5555 && v == 0xaa) fl_cyc = 1; else flash_bad(ca, v); break;
    case 1: if (c15 == 0x2aaa && v == 0x55) fl_cyc = 2; else flash_bad(ca, v); break;
    case 2:
        fl_cyc = 0;
        if (fl_erase_arm) {
            fl_erase_arm = 0;
            if (v == 0x30) {
                memset(rom + (ca & ~0xfffu), 0xff, 0x1000); fl_nsect++;
                fl_busy = 2; fl_busy_until = now_exact() + 144000;          /* 18 ms */
                if (fl_log) fprintf(stderr, "[flash: sector erase %05X]\n", (ca & ~0xfffu) + 0x80000);
            } else if (v == 0x10 && c15 == 0x5555) {
                memset(rom, 0xff, sizeof rom); fl_nchip++;
                fl_busy = 2; fl_busy_until = now_exact() + 560000;          /* 70 ms */
                if (fl_log) fprintf(stderr, "[flash: chip erase]\n");
            } else flash_bad(ca, v);
            break;
        }
        if (c15 != 0x5555) { flash_bad(ca, v); break; }
        if (v == 0xa0) fl_prog = 1;
        else if (v == 0x80) fl_erase_arm = 1;
        else if (v == 0x90) fl_id = 1;
        else if (v == 0xf0) fl_id = 0;
        else flash_bad(ca, v);
        break;
    }
}

/* ---- bus ---- */
static void raise_berr(unsigned a, int write) {
    emu_berr_flag = 1;
    m68ki_aerr_address = a;
    m68ki_aerr_write_mode = write ? MODE_WRITE : MODE_READ;
    m68ki_aerr_fc = FLAG_S ? 5 : 1;
    siglongjmp(m68ki_aerr_trap, 1);
}
static unsigned rd8(unsigned a) {
    a &= 0xfffff;
    if (a < 0x80000) return overlay ? rom[a & 0x3ffff] : ram[a];
    if (a < 0xc0000) { overlay = 0; return flash_read(a & 0x3ffff); }
    if (a < 0xd0000) return (a - 0xc0000) < 0x800 ? win[a - 0xc0000] : 0xff;
    if (a < 0xf0000) raise_berr(a, 0);
    return duart_read(a & 15);
}
static void wr8(unsigned a, unsigned v) {
    a &= 0xfffff; v &= 0xff;
    if (a < 0x80000) { ram[a] = v; if (trk_max >= 0 && (a == trk_h || a == trk_t)) { int f = (uint8_t)(ram[trk_h] - ram[trk_t]); if (f > trk_max) trk_max = f; } return; }
    if (a < 0xc0000) { overlay = 0; flash_write(a & 0x3ffff, v); return; }
    if (a < 0xd0000) { if ((a - 0xc0000) < 0x800) win[a - 0xc0000] = v; return; }
    if (a < 0xf0000) raise_berr(a, 1);
    duart_write(a & 15, v);
}
unsigned int m68k_read_memory_8(unsigned int a) { return rd8(a); }
unsigned int m68k_read_memory_16(unsigned int a) { extra += 4; unsigned h = rd8(a); return (h << 8) | rd8(a + 1); }
unsigned int m68k_read_memory_32(unsigned int a) { extra += 12; unsigned v = 0; for (int i = 0; i < 4; i++) v = (v << 8) | rd8(a + i); return v; }
static unsigned peek8(unsigned a) { a &= 0xfffff; if (a < 0x80000) return ram[a]; if (a < 0xc0000) return rom[a & 0x3ffff]; return 0; }
unsigned int m68k_read_disassembler_8(unsigned int a) { return peek8(a); }
unsigned int m68k_read_disassembler_16(unsigned int a) { return (peek8(a) << 8) | peek8(a + 1); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return (m68k_read_disassembler_16(a) << 16) | m68k_read_disassembler_16(a + 2); }
void m68k_write_memory_8(unsigned int a, unsigned int v) { wr8(a, v); }
void m68k_write_memory_16(unsigned int a, unsigned int v) { extra += 4; wr8(a, v >> 8); wr8(a + 1, v); }
void m68k_write_memory_32(unsigned int a, unsigned int v) { extra += 12; wr8(a, v >> 24); wr8(a + 1, v >> 16); wr8(a + 2, v >> 8); wr8(a + 3, v); }

int emu_int_ack(int level) {
    if (level == 5) { if (duart_isr() & imr) return ivr; return M68K_INT_ACK_SPURIOUS; }
    return M68K_INT_ACK_AUTOVECTOR;
}
void emu_reset_instr(void) { duart_reset(); update_irq(); fprintf(stderr, "[RESET instruction: 68681 reset]\n"); }

static unsigned long long instr_count;
static int trace_pc = 0;
void emu_instr_hook(unsigned int pc) {
    instr_count++; if (trace_pc) fprintf(stderr, "PC=%06X\n", pc);
    pc &= 0xfffff;
    if (pc >= 0x80000 && pc < 0xc0000 && flash_unreadable() && fl_warned++ < 5)
        fprintf(stderr, "[flash: instruction fetch at %05X while the flash is %s]\n", pc, fl_busy ? "busy" : "in ID mode");
}

/* ---- input feed ---- */
static uint8_t *feed; static size_t feed_len, feed_pos;
static void feed_add(const void *p, size_t n) { feed = realloc(feed, feed_len + n); memcpy(feed + feed_len, p, n); feed_len += n; }

static unsigned long long now(void) { return clocks68008; }
static void run(unsigned clk) {
    unsigned long long end = clocks68008 + clk;
    while (clocks68008 < end) {
        extra = 0;
        int c = m68k_execute(64);
        clocks68008 += c + extra;
        if (CPU_STOPPED & STOP_LEVEL_HALT) { if (!halted) fprintf(stderr, "[CPU HALTED (double bus fault)]\n"); halted = 1; clocks68008 = end; }
        if (feed_pos < feed_len && clocks68008 >= next_rx_clock && rx_en) {
            /* The sender watches its CTS = OP0 (RTSN), whoever drives it: the
               68681's RxRTS logic or the program through the OPR. With
               @lag 0 it is ideal (stops at once and never overruns the
               FIFO); with @lag N it is like an FTDI: it ignores the FIFO
               and still sends up to N characters after RTS goes away. */
            int can;
            if (noflow) can = 1;
            else if (rts_asserted()) { lag_cnt = 0; can = lag || fifo_n < 3; }
            else if (lag_cnt < lag) { lag_cnt++; can = 1; }
            else can = 0;
            if (can) {
                rx_push(feed[feed_pos++], 0);
                next_rx_clock = clocks68008 + (fast ? 400 : CHAR_CLOCKS);
            }
        }
    }
}
static int out_has(const char *s) { outbuf[outlen] = 0; return strstr(outbuf + outmark, s) != NULL; }
static int wait_for(const char *s, unsigned long long maxclk) {
    unsigned long long t0 = now();
    while (!out_has(s)) { run(2000); if (now() - t0 > maxclk || halted) return 0; }
    return 1;
}
static void drain_feed(void) { while (feed_pos < feed_len && !halted) run(2000); feed_len = feed_pos = 0; }

static void hw_reset(void) { overlay = 1; duart_reset(); flash_reset(); halted = 0; m68k_pulse_reset(); }


/* ---- interactive terminal mode (-i) ---- */
static struct termios tio_saved; static int tio_ok = 0;
static void term_raw(void) {
    if (!isatty(0)) return;
    struct termios t; tcgetattr(0, &tio_saved); tio_ok = 1; t = tio_saved;
    t.c_lflag &= ~(ICANON | ECHO | ISIG | IEXTEN); t.c_iflag &= ~(IXON | ICRNL | INLCR | ISTRIP);
    t.c_cc[VMIN] = 1; t.c_cc[VTIME] = 0; tcsetattr(0, TCSANOW, &t);
}
static void term_restore(void) { if (tio_ok) tcsetattr(0, TCSANOW, &tio_saved); }
static int key_ready(void) { fd_set f; FD_ZERO(&f); FD_SET(0, &f); struct timeval tv = {0, 0}; return select(1, &f, 0, 0, &tv) > 0; }
static double wall(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec * 1e-9; }
static void send_file(const char *fn) {
    FILE *x = fopen(fn, "rb");
    if (!x) { fprintf(stderr, "\r\n[cannot open %s]\r\n", fn); return; }
    int ch; while ((ch = fgetc(x)) != EOF) { if (ch == '\n') ch = '\r'; uint8_t b = ch; feed_add(&b, 1); }
    fclose(x);
}
static int interactive(int fullspeed) {
    verbose_led = 0;
    fprintf(stderr, "[core68008 emulator: Ctrl-] then q quit, s send file, n NMI, b BREAK, r reset, l LEDs, f speed]\r\n");
    term_raw();
    double t0 = wall(); unsigned long long c0 = clocks68008;
    int esc = 0;
    for (;;) {
        run(8000);                                   /* 1 ms of 8 MHz */
        if (feed_pos >= feed_len) feed_len = feed_pos = 0;
        while (key_ready()) {
            unsigned char c; if (read(0, &c, 1) != 1) { term_restore(); return 0; }
            if (esc) {
                esc = 0;
                switch (c) {
                case 'q': case 'Q': term_restore(); fprintf(stderr, "\n"); return 0;
                case 'n': m68k_set_irq(7); run(200); update_irq(); break;
                case 'b': isr_brk = 1; rx_push(0, 1); update_irq(); break;
                case 'r': hw_reset(); feed_len = feed_pos = 0; break;
                case 'l': fprintf(stderr, "\r\n[LEDs: D5 user %s, D6 monitor %s]\r\n", (opr & 0x40) ? "on" : "off", (opr & 0x80) ? "on" : "off"); break;
                case 'f': fullspeed = !fullspeed; t0 = wall(); c0 = clocks68008; fprintf(stderr, "\r\n[%s speed]\r\n", fullspeed ? "full" : "8 MHz"); break;
                case 's': {
                    char fn[512]; term_restore(); fprintf(stderr, "\r\nfile to send: "); fflush(stderr);
                    if (fgets(fn, sizeof fn, stdin)) { fn[strcspn(fn, "\r\n")] = 0; if (fn[0]) send_file(fn); }
                    term_raw(); break; }
                case 0x1d: { uint8_t b = c; feed_add(&b, 1); break; }
                }
            } else if (c == 0x1d) esc = 1;
            else { uint8_t b = (c == '\n') ? '\r' : c; feed_add(&b, 1); }
        }
        if (halted) { fprintf(stderr, "\r\n[CPU halted: Ctrl-] r resets, Ctrl-] q quits]\r\n"); while (halted) { unsigned char c; if (read(0, &c, 1) != 1) break; if (c == 0x1d) { if (read(0, &c, 1) == 1) { if (c == 'r') hw_reset(); else if (c == 'q') { term_restore(); return 0; } } } } }
        if (!fullspeed) {
            double ahead = (clocks68008 - c0) / 8e6 - (wall() - t0);
            if (ahead > 0.002) { struct timespec ts = {0, (long)(ahead * 1e9)}; nanosleep(&ts, 0); }
            else if (ahead < -0.5) { t0 = wall(); c0 = clocks68008; }   /* host too slow: resync */
        }
    }
}

int main(int argc, char **argv) {
    int inter_mode = 0, inter_full = 0;
    const char *romf = "monitor.bin", *script = NULL; const char *prompt = "\n> ";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-r")) romf = argv[++i];
        else if (!strcmp(argv[i], "-s")) script = argv[++i];
        else if (!strcmp(argv[i], "-p")) prompt = argv[++i];
        else if (!strcmp(argv[i], "-t")) trace_pc = 1;
        else if (!strcmp(argv[i], "-i")) inter_mode = 1;
        else if (!strcmp(argv[i], "-F")) inter_full = 1;
        else if (argv[i][0] != '-') romf = argv[i];          /* bare name = ROM image */
        else if (!strcmp(argv[i], "-h")) { fprintf(stderr, "usage: emu [[-r] monitor.bin] [-i [-F]] [-s script] [-t]\n  -i  interactive terminal (-F: run at full host speed)\n  -s  run a test script (see the top of emu.c)\n"); return 0; }
    }
    FILE *f = fopen(romf, "rb"); if (!f) { perror(romf); return 1; }
    memset(rom, 0xff, sizeof rom); fread(rom, 1, sizeof rom, f); fclose(f);
    for (size_t i = 0; i < sizeof ram; i++) ram[i] = (uint8_t)(i * 7 + 0x5a); /* garbage at power-up */
    m68k_init(); m68k_set_cpu_type(M68K_CPU_TYPE_68000);
    hw_reset();
    if (inter_mode) return interactive(inter_full);
    FILE *sf = script ? fopen(script, "r") : stdin;
    if (!sf) { perror(script); return 1; }
    char line[4096];
    static unsigned long long LIMIT; LIMIT = 400000000ULL; /* 50 s of 8 MHz per wait */
    if (!wait_for(prompt, LIMIT)) { fprintf(stderr, "\n[no initial prompt]\n"); }
    while (fgets(line, sizeof line, sf)) {
        line[strcspn(line, "\r\n")] = 0;
        if (line[0] == '#') continue;
        if (line[0] == '@') {
            char *arg = strchr(line, ' '); if (arg) *arg++ = 0; else arg = "";
            if (!strcmp(line, "@wait")) { if (!wait_for(arg, LIMIT)) fprintf(stderr, "\n[timeout waiting for '%s']\n", arg); outmark = outlen; }
            else if (!strcmp(line, "@send")) { outmark = outlen; feed_add(arg, strlen(arg)); feed_add("\r", 1); drain_feed(); }
            else if (!strcmp(line, "@raw")) { outmark = outlen; char *p = arg; while (*p) { unsigned v; int n; if (sscanf(p, "%x%n", &v, &n) != 1) break; uint8_t b = v; feed_add(&b, 1); p += n; } drain_feed(); }
            else if (!strcmp(line, "@file")) { FILE *x = fopen(arg, "rb"); if (!x) { perror(arg); continue; } outmark = outlen; int ch; while ((ch = fgetc(x)) != EOF) { if (ch == '\n') ch = '\r'; uint8_t b = ch; feed_add(&b, 1); } fclose(x); drain_feed(); }
            else if (!strcmp(line, "@nmi")) { outmark = outlen; m68k_set_irq(7); run(200); update_irq(); }
            else if (!strcmp(line, "@break")) { outmark = outlen; isr_brk = 1; rx_push(0, 1); update_irq(); run(20000); }
            else if (!strcmp(line, "@run")) { run(strtoul(arg, 0, 0)); }
            else if (!strcmp(line, "@reset")) { outmark = outlen; hw_reset(); wait_for(prompt, LIMIT); }
            else if (!strcmp(line, "@fast")) fast = 1;
            else if (!strcmp(line, "@slow")) fast = 0;
            else if (!strcmp(line, "@noflow")) noflow = 1;
            else if (!strcmp(line, "@flow")) noflow = 0;
            else if (!strcmp(line, "@lag")) lag = atoi(arg);
            else if (!strcmp(line, "@track")) {
                if (sscanf(arg, "%x %x", &trk_h, &trk_t) == 2) trk_max = 0;
                else if (trk_max >= 0) { fprintf(stderr, "[track: max fill of (%05X)-(%05X) = %d]\n", trk_h, trk_t, trk_max); trk_max = -1; }
            }
            else if (!strcmp(line, "@load")) { char fn[512]; unsigned a; if (sscanf(arg, "%511s %x", fn, &a) == 2) { FILE *x = fopen(fn, "rb"); if (!x) { perror(fn); continue; } int ch; while ((ch = fgetc(x)) != EOF) { wr8(a++, ch); } fclose(x); } }
            else if (!strcmp(line, "@limit")) { LIMIT = strtoull(arg, 0, 0); }
            else if (!strcmp(line, "@save")) { FILE *x = fopen(arg, "wb"); if (!x) { perror(arg); continue; } fwrite(rom, 1, sizeof rom, x); fclose(x); }
            else if (!strcmp(line, "@stuck")) { unsigned a, m; if (sscanf(arg, "%x %x", &a, &m) == 2) { fl_stuck_addr = m ? (a & 0x3ffff) : 0xffffffff; fl_stuck_mask = m; } }
            else if (!strcmp(line, "@flashlog")) fl_log = 1;
            else if (!strcmp(line, "@dump")) { unsigned a, n; sscanf(arg, "%x %x", &a, &n); fprintf(stderr, "[dump %05X:", a); for (unsigned i = 0; i < n; i++) fprintf(stderr, " %02X", peek8(a + i)); fprintf(stderr, "]\n"); }
            continue;
        }
        outmark = outlen;
        feed_add(line, strlen(line)); feed_add("\r", 1);
        drain_feed();
        if (!wait_for(prompt, LIMIT)) fprintf(stderr, "\n[timeout after '%s']\n", line);
    }
    fprintf(stderr, "\n[end: %llu clocks (%.3f s at 8 MHz), %llu instructions, %llu overruns]\n",
            clocks68008, clocks68008 / 8e6, instr_count, overruns);
    if (trk_max >= 0) fprintf(stderr, "[track: max fill of (%05X)-(%05X) = %d]\n", trk_h, trk_t, trk_max);
    if (fl_nprog || fl_nsect || fl_nchip)
        fprintf(stderr, "[flash: %llu bytes programmed, %llu sector erases, %llu chip erases]\n", fl_nprog, fl_nsect, fl_nchip);
    return 0;
}
