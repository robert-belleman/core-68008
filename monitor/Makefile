# MON68K - ROM monitor for the core68008 board
#
#   make            assemble monitor.bin (256K flash image) and monitor.lst,
#                   with EhBASIC (basic/ehbasic.bin) at $A0000
#   make examples   assemble the example programs as S-record files (.s28)
#   make s28        monitor.s28: the image as S-records at $10000, to load with
#                   LO and program with FL (see MONITOR.md, "Programming the flash")
#   make flashupd   flashupd/flashupd.s28: FLASHUPD + this monitor, to put it into the flash from a monitor without FL (see MONITOR.md)
#   make flash      program the SST39SF020A with the T48 (minipro)
#   make clean
#
# vasm: http://sun.hasenbraten.de/vasm/ (vasmm68k_mot, Motorola syntax)

VASM    ?= /opt/homebrew/bin/vasmm68k_mot
MINIPRO ?= minipro
# check the exact name with:  minipro -L SST39SF020
DEVICE  ?= SST39SF020A@PLCC32

SRC = monitor.asm util.asm serial.asm except.asm cmds.asm srec.asm api.asm disasm.asm flash.asm flash_defs.inc flash_engine.asm
BASIC = basic/ehbasic.asm basic/ehbasic.inc

all: monitor.bin

monitor.bin: $(SRC) basic/ehbasic.bin
	$(VASM) -quiet -m68000 -Fbin -o monitor.bin -L monitor.lst monitor.asm
	@test `wc -c < monitor.bin` -eq 262144 || (echo "monitor.bin is not 256K"; rm -f monitor.bin; exit 1)

basic/ehbasic.bin: $(BASIC)
	cd basic && $(VASM) -quiet -nowarn=2028 -m68000 -Fbin -o ehbasic.bin -L ehbasic.lst ehbasic.asm

s28: monitor.s28

monitor.s28: monitor.bin bin2srec.py
	python3 bin2srec.py monitor.bin 10000 > monitor.s28

examples: examples/hello.s28 examples/apidemo.s28

examples/%.s28: examples/%.asm examples/mon68k.inc
	cd examples && $(VASM) -quiet -m68000 -Fsrec -s28 -exec=start -o $*.s28 -L $*.lst $*.asm

flashupd: flashupd/flashupd.s28

flashupd/flashupd.s28: flashupd/flashupd.asm flashupd/mkflashupd.py flash_defs.inc flash_engine.asm monitor.bin
	$(VASM) -quiet -m68000 -Fbin -I. -o flashupd/flashupd.bin -L flashupd/flashupd.lst flashupd/flashupd.asm
	python3 flashupd/mkflashupd.py flashupd/flashupd.bin monitor.bin > flashupd/flashupd.s28

flash: monitor.bin
	$(MINIPRO) -p "$(DEVICE)" -w monitor.bin

clean:
	rm -f monitor.bin monitor.lst monitor.s28 basic/ehbasic.bin basic/ehbasic.lst examples/*.s28 examples/*.lst flashupd/flashupd.s28 flashupd/flashupd.bin flashupd/flashupd.lst

.PHONY: all s28 examples flashupd flash clean
