; hello.asm - smallest MON68K program.  make examples, then LO and GO.
                include "mon68k.inc"
                org     $1000
start:          lea     msg(pc),a0
                MONCALL MON_PUTS
                moveq   #0,d1
                MONCALL MON_EXIT        ; back to the monitor (RTS works too when
                                        ; started with CALL)
msg:            dc.b    "Hello from the 68008!",13,10,0
