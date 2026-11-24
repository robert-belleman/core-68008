# GAL22V10 sources for the core68008 board (assembled with GALasm 2.1)
#
#   make                build decode.jed, bridge.jed and busdbg.jed
#   make decode.jed     build one GAL
#   make prog-decode    program GAL1 with the T48 (minipro)
#   make prog-bridge    program GAL2
#   make prog-busdbg    program GAL3
#   make verify-decode  read GAL1 back and compare with decode.jed (also -bridge, -busdbg)
#   make clean          remove the generated .jed/.chp/.fus/.pin files
#
# GAL1 decode.pld  map, boot overlay, DTACK, BERR, chip selects
# GAL2 bridge.pld  Junior bus bridge (PHI2 = CLK/8, DTACK state machine)
# GAL3 busdbg.pld  bus PHI1/PHI2/R/W, RAM.RW, BERR latch, debug outputs
# decode_boot.pld  TEMPORARY GAL1 for flashboot/ (27128 EPROM in the SRAM
#                   socket): make prog-decode_boot, later make prog-decode
#
# Override the tools on the command line, e.g.  make GALASM=galasm DEVICE=ATF22V10C

GALASM  ?= /Users/robbel/projects/GALasm/src/galasm
MINIPRO ?= minipro
# check the exact name with:  minipro -L ATF22V10
DEVICE  ?= ATF22V10CQZ

GALS = decode bridge busdbg decode_boot
JED  = $(GALS:=.jed)

all: $(JED)

# galasm writes <name>.jed, .chp, .fus and .pin next to the source
%.jed: %.pld
	$(GALASM) $<

$(addprefix prog-,$(GALS)): prog-%: %.jed
	$(MINIPRO) -p "$(DEVICE)" -u -w $<

$(addprefix verify-,$(GALS)): verify-%: %.jed
	$(MINIPRO) -p "$(DEVICE)" -m $<

clean:
	$(RM) $(GALS:=.jed) $(GALS:=.chp) $(GALS:=.fus) $(GALS:=.pin)

.PHONY: all clean $(addprefix prog-,$(GALS)) $(addprefix verify-,$(GALS))
