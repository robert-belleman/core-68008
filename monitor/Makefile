# MON68K - ROM monitor for the core68008 board
#
#   make            assemble monitor.bin (256K flash image) and monitor.lst
#   make examples   assemble the example programs as S-record files (.s28)
#   make flash      program the SST39SF020A with the T48 (minipro)
#   make clean
#
# vasm: http://sun.hasenbraten.de/vasm/ (vasmm68k_mot, Motorola syntax)

VASM    ?= /opt/homebrew/bin/vasmm68k_mot
MINIPRO ?= minipro
# check the exact name with:  minipro -L SST39SF020
DEVICE  ?= SST39SF020A@PLCC32

SRC = monitor.asm util.asm serial.asm except.asm cmds.asm srec.asm api.asm disasm.asm

all: monitor.bin

monitor.bin: $(SRC)
	$(VASM) -quiet -m68000 -Fbin -o monitor.bin -L monitor.lst monitor.asm
	@test `wc -c < monitor.bin` -eq 262144 || (echo "monitor.bin is not 256K"; rm -f monitor.bin; exit 1)

examples: examples/hello.s28 examples/apidemo.s28

examples/%.s28: examples/%.asm examples/mon68k.inc
	cd examples && $(VASM) -quiet -m68000 -Fsrec -s28 -exec=start -o $*.s28 -L $*.lst $*.asm

flash: monitor.bin
	$(MINIPRO) -p "$(DEVICE)" -w monitor.bin

clean:
	rm -f monitor.bin monitor.lst examples/*.s28 examples/*.lst

.PHONY: all examples flash clean
