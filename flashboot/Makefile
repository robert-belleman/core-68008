# FLASHBOOT: program the SST39SF020A in circuit from a 27128 EPROM
#
#   make                 assemble eprom.bin: SERTEST at reset, FLASHBOOT at $2000
#                        (also flashboot.bin, FLASHBOOT on its own)
#   make blank           blank check the EPROM with the T48
#   make eprom           program eprom.bin into the EPROM with the T48
#   make verify          compare the EPROM with eprom.bin
#   make send PORT=/dev/cu.usbserial-XXXX   program ../monitor/monitor.bin
#
# See README.md for the wiring and the GAL1 swap.

VASM    ?= /opt/homebrew/bin/vasmm68k_mot
MINIPRO ?= minipro
# AMD AM27128A-2DC; check with:  minipro -L 27128
EPROM   ?= AM27128A@DIP28
IMAGE   ?= ../monitor/monitor.bin
PORT    ?=

all: eprom.bin

eprom.bin: sertest.asm flashboot.bin
	$(VASM) -quiet -m68000 -Fbin -o eprom.bin -L sertest.lst sertest.asm
	@test `wc -c < eprom.bin` -eq 16384 || (echo "eprom.bin is not 16K"; rm -f eprom.bin; exit 1)

flashboot.bin: flashboot.asm
	$(VASM) -quiet -m68000 -Fbin -o flashboot.bin -L flashboot.lst flashboot.asm
	@test `wc -c < flashboot.bin` -eq 16384 || (echo "flashboot.bin is not 16K"; rm -f flashboot.bin; exit 1)

blank:
	$(MINIPRO) -p "$(EPROM)" -b

eprom: eprom.bin
	$(MINIPRO) -p "$(EPROM)" -w eprom.bin

verify: eprom.bin
	$(MINIPRO) -p "$(EPROM)" -m eprom.bin

send:
	@test -n "$(PORT)" || (echo "usage: make send PORT=/dev/cu.usbserial-XXXX"; exit 1)
	python3 flashboot.py $(PORT) $(IMAGE)

clean:
	rm -f eprom.bin flashboot.bin flashboot.lst sertest.lst

.PHONY: all blank eprom verify send clean
