;=============================================================================
; flashupd.asm - FLASHUPD: put a new MON68K into the flash, in circuit
;
; For a board whose monitor has no FL command yet. FLASHUPD runs from RAM
; under any MON68K 1.0, so the old monitor only has to load and start it:
;
;   MF 10000 4FFFF FF   records that hold only $FF are left out of the file
;   LO                  send flashupd.s28: FLASHUPD at $01000 and the new
;                       256K image at $10000-$4FFFF (make flashupd)
;   GO                  LO has set the PC to $01000
;
; It checks the image in RAM against the sum that make stored in it, checks
; the image's reset vector, reads the flash ID, works out which 4K sectors
; need an erase, and asks Y/N. Then it runs the same engine as FL
; (flash_engine.asm) straight from here: erase, program, verify, and start
; the new monitor through its reset vector. After a failure the engine waits
; for R to try again. Before the Y it uses the old monitor's TRAP #15
; services; after the Y it no longer touches the ROM.
;
; Assemble from monitor/:  vasmm68k_mot -m68000 -Fbin -I. flashupd/flashupd.asm
; flashupd/mkflashupd.py then stores the image sum at img_sum and writes
; flashupd.s28.
;=============================================================================

; hardware (the same values as in monitor.asm)
ROM_BASE        equ     $80000
ROM_SIZE        equ     $40000
ROM_TOP         equ     $C0000
DUART           equ     $F0000
D_SRA           equ     1
D_THRA          equ     3
D_RHRA          equ     3
SR_RXRDY        equ     0
SR_TXRDY        equ     2
SR_TXEMT        equ     3
VEC_TABLE       equ     $00000
V_NMI           equ     31
TX_TIMEOUT      equ     150000

; MON68K TRAP #15 services
API_EXIT        equ     0
API_PUTS        equ     3
API_GETLINE     equ     5
API_PUTHEX      equ     6
API_PUTDEC      equ     7
API_CRLF        equ     8

IMG_RAM         equ     $10000                  ; where LO puts the image
IMG_SIZE        equ     ROM_SIZE

                include "flash_defs.inc"

API             macro
                moveq   #\1,d0
                trap    #15
                endm

PUTS            macro                           ; PUTS label
                lea     \1(pc),a0
                API     API_PUTS
                endm

                org     $1000
start:          bra.w   main
img_sum:        dc.l    0                       ; offset 4: sum of the image bytes (mkflashupd.py)
                dc.b    "FLASHUPD"              ; offset 8: marker for mkflashupd.py

main:
                PUTS    s_banner
; ---- 1. the image in RAM must match the one make used
                lea     (IMG_RAM).l,a1
                move.l  #IMG_SIZE,d3
                moveq   #0,d2
                moveq   #0,d0
.sum            move.b  (a1)+,d0
                add.l   d0,d2
                subq.l  #1,d3
                bne     .sum
                cmp.l   img_sum(pc),d2
                beq     .sumok
                PUTS    s_badsum1
                move.l  d2,d1
                moveq   #8,d2
                API     API_PUTHEX
                PUTS    s_badsum2
                move.l  img_sum(pc),d1
                API     API_PUTHEX
                PUTS    s_badsum3
                bra     exit
.sumok          move.l  (IMG_RAM+4).l,d1           ; reset PC of the new image
                btst    #0,d1
                bne     .badvec
                cmpi.l  #ROM_BASE,d1
                blo     .badvec
                cmpi.l  #ROM_TOP,d1
                blo     .vecok
.badvec         PUTS    s_badvec
                bra     exit
; ---- 2. the flash must answer the ID command
.vecok          moveq   #0,d0
                bsr     fe_start
                move.w  d0,d7
                PUTS    s_id
                moveq   #0,d1
                move.w  d7,d1
                moveq   #4,d2
                API     API_PUTHEX
                cmpi.w  #$BFB6,d7
                beq     .idok
                cmpi.w  #$BFB7,d7
                beq     .idok
                PUTS    s_badid
                bra     exit
.idok           API     API_CRLF
; ---- 3. plan: erase a sector only if some bit has to go from 0 to 1
                lea     (IMG_RAM).l,a0
                lea     (ROM_BASE).l,a1
                lea     tab(pc),a2
                moveq   #0,d3                   ; sector
                moveq   #0,d4                   ; sectors to erase
                moveq   #0,d5                   ; bytes to program
.sec            movem.l a0-a1,-(sp)
                moveq   #0,d7
                move.w  #FL_SECT-1,d6
.p1             move.b  (a0)+,d0
                move.b  (a1)+,d1
                and.b   d0,d1
                cmp.b   d0,d1
                beq     .p1n
                moveq   #1,d7
.p1n            dbra    d6,.p1
                movem.l (sp)+,a0-a1
                move.b  d7,0(a2,d3.w)
                add.l   d7,d4
                move.w  #FL_SECT-1,d6
.p2             move.b  (a0)+,d0
                tst.b   d7
                beq     .old
                cmpi.b  #$FF,d0                 ; erased: every non-$FF byte
                beq     .p2n
                bra     .cnt
.old            cmp.b   (a1),d0                 ; not erased: every byte that differs
                beq     .p2n
.cnt            addq.l  #1,d5
.p2n            addq.l  #1,a1
                dbra    d6,.p2
                addq.w  #1,d3
                cmpi.w  #FL_NSECT,d3
                blo     .sec
                PUTS    s_plan1
                move.l  d4,d1
                API     API_PUTDEC
                PUTS    s_plan2
                move.l  d5,d1
                API     API_PUTDEC
                PUTS    s_plan3
                move.l  d4,d0
                or.l    d5,d0
                bne     .ask
                PUTS    s_same
                bra     exit
; ---- 4. ask
.ask            PUTS    s_warn
                lea     line(pc),a0
                moveq   #16,d1
                API     API_GETLINE
                tst.l   d0
                bmi     .no
                lea     line(pc),a0
.sp             move.b  (a0)+,d0
                cmpi.b  #' ',d0
                beq     .sp
                andi.b  #$DF,d0
                cmpi.b  #'Y',d0
                beq     .go
.no             PUTS    s_cancel
                bra     exit
; ---- 5. erase, program, verify, start the new monitor (does not return)
.go             lea     (IMG_RAM).l,a0
                lea     (ROM_BASE).l,a1
                move.l  #IMG_SIZE,d1
                lea     tab(pc),a2
                moveq   #1,d2                   ; restart afterwards
                moveq   #1,d0
                bsr     fe_start
exit:           moveq   #0,d1
                API     API_EXIT

s_banner        dc.b    13,10,"FLASHUPD: put the MON68K image at RAM $10000-$4FFFF into the flash",13,10,0
s_badsum1       dc.b    "Error: the image in RAM has sum $",0
s_badsum2       dc.b    ", it should be $",0
s_badsum3       dc.b    ".",13,10,"Fill the RAM with MF 10000 4FFFF FF before LO, and check that LO",13,10
                dc.b    "reported no bad records. The flash is unchanged.",13,10,0
s_badvec        dc.b    "Error: the image's reset vector does not point into the flash.",13,10
                dc.b    "The flash is unchanged.",13,10,0
s_id            dc.b    "Flash ID $",0
s_badid         dc.b    ": not an SST39SF020A/040, or the flash ignores writes (/WE).",13,10
                dc.b    "The flash is unchanged.",13,10,0
s_plan1         dc.b    "Erase ",0
s_plan2         dc.b    " sector(s), program ",0
s_plan3         dc.b    " byte(s)",13,10,0
s_same          dc.b    "The flash already holds this image.",13,10,0
s_warn          dc.b    "This replaces the monitor. Keep the power on and don't press reset until",13,10
                dc.b    "the new monitor starts. If a step fails, you can try it again.",13,10
                dc.b    "Program the flash (Y/N)? ",0
s_cancel        dc.b    "Cancelled. The flash is unchanged.",13,10,0
                even

                include "flash_engine.asm"

line            ds.b    16                      ; Y/N answer
tab             ds.b    FL_NSECT                ; nonzero: erase this sector
                even
end:
