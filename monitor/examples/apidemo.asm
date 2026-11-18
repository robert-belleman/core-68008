; apidemo.asm - reads a line, echoes it, counts down with the user LED
; blinking, and installs its own TRAP #0 handler.  Ctrl-C stops it at any
; time (the monitor shows where).
                include "mon68k.inc"
                org     $1000
start:          moveq   #32,d1                  ; TRAP #0 -> my handler
                lea     trap0(pc),a0
                MONCALL MON_SETVEC
                move.l  d0,oldvec

                lea     ask(pc),a0
                MONCALL MON_PUTS
                lea     line(pc),a0
                moveq   #40,d1
                MONCALL MON_GETLINE
                tst.l   d0
                bmi     .done                   ; Ctrl-C
                move.l  d0,d1
                lea     got(pc),a0
                MONCALL MON_PUTS
                MONCALL MON_PUTDEC
                lea     chars(pc),a0
                MONCALL MON_PUTS
                lea     line(pc),a0
                MONCALL MON_PUTS
                MONCALL MON_CRLF

                moveq   #9,d7
.count          move.l  d7,d1
                MONCALL MON_PUTDEC
                MONCALL MON_CRLF
                move.l  d7,d1                   ; LED on for odd numbers
                MONCALL MON_LED
                trap    #0                      ; my own handler: a delay
                dbra    d7,.count
                moveq   #0,d1
                MONCALL MON_LED

.done           moveq   #32,d1                  ; put the old TRAP #0 back
                movea.l oldvec(pc),a0
                MONCALL MON_SETVEC
                moveq   #0,d1
                MONCALL MON_EXIT

trap0:          move.l  d0,-(sp)                ; about 0.3 s at 8 MHz
                move.l  #60000,d0
.w              subq.l  #1,d0
                bne     .w
                move.l  (sp)+,d0
                rte

oldvec:         dc.l    0
ask:            dc.b    "Type something: ",0
got:            dc.b    "You typed ",0
chars:          dc.b    " characters: ",0
line:           ds.b    40
                even
