; flash_defs.inc - SST39SF020A constants shared by flash.asm (FL) and flashupd/flashupd.asm. Needs ROM_BASE and ROM_SIZE.

FL_SECT         equ     $1000                   ; sector size
FL_NSECT        equ     ROM_SIZE/FL_SECT        ; 64 sectors in the 256K window
FL_CMD1         equ     ROM_BASE+$5555          ; command addresses
FL_CMD2         equ     ROM_BASE+$2AAA
FL_ERASE_TO     equ     400000                  ; DQ6 toggle polls, about 3 s
FL_PROG_TO      equ     2000                    ; DQ7 polls, about 10 ms
