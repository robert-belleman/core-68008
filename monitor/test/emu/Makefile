# core68008 board emulator for MON68K (Musashi 68000 core, patched for the
# board's bus errors and interrupt acknowledge).
#
#   make                      build ./emu
#   ./emu -i                  interactive: your terminal is the serial console
#   ./emu -s ../fn/s1.txt     run a test script
#
# Interactive keys: Ctrl-] then  q quit, s send a file (e.g. S-records after LO),
# n NMI, b BREAK, r power-on reset, l show LEDs, f toggle 8 MHz / full speed.

CC     ?= cc
CFLAGS ?= -O2 -w
ROM    ?= ../../monitor.bin

emu: emu.c m68kcpu.c m68kops.c m68kdasm.c softfloat/softfloat.c *.h
	$(CC) $(CFLAGS) -o emu emu.c m68kcpu.c m68kops.c m68kdasm.c softfloat/softfloat.c -lm

# m68kops.c/h are included; regenerate them only if m68k_in.c changes
m68kops.c m68kops.h: m68k_in.c m68kmake.c
	$(CC) -w -o m68kmake m68kmake.c && ./m68kmake

run: emu
	./emu -r $(ROM) -i

clean:
	rm -f emu m68kmake

.PHONY: run clean
