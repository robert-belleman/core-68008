; flash_engine.asm - the RAM-resident SST39SF020A engine of FL, also used by flashupd/flashupd.asm. Position independent; needs DUART, D_SRA, D_THRA, D_RHRA, SR_RXRDY/TXRDY/TXEMT, VEC_TABLE, V_NMI, TX_TIMEOUT, ROM_BASE and flash_defs.inc.

; Everything from fe_start to fe_end runs from the RAM copy: only
; PC-relative references inside it, absolute ones to hardware, no ROM calls.
; A4 = command address 1, A5 = command address 2, A6 = 68681.
; Absolute addresses inside the engine must be written (x).l: vasm otherwise
; turns references to $8xxxx into PC-relative ones, which point into RAM once
; the engine is copied.
fe_start:
                movem.l d1-d7/a0-a6,-(sp)
                move.w  sr,-(sp)
                move.w  #$2700,sr               ; the 68681 interrupt runs ROM code
                move.l  VEC_TABLE+V_NMI*4,-(sp) ; and so does the NMI handler
                lea     fe_rte(pc),a3
                move.l  a3,VEC_TABLE+V_NMI*4
                lea     DUART,a6
                lea     (FL_CMD1).l,a4
                lea     (FL_CMD2).l,a5
                tst.w   d0
                bne     fe_job
                move.b  #$AA,(a4)               ; software ID entry
                move.b  #$55,(a5)
                move.b  #$90,(a4)
                moveq   #0,d0
                move.b  (ROM_BASE).l,d0           ; maker
                lsl.w   #8,d0
                move.b  (ROM_BASE+1).l,d0           ; device
                move.b  #$AA,(a4)               ; software ID exit
                move.b  #$55,(a5)
                move.b  #$F0,(a4)
fe_ret:         move.l  (sp)+,VEC_TABLE+V_NMI*4
                move.w  (sp)+,sr
                movem.l (sp)+,d1-d7/a0-a6
                rts
fe_rte:         rte                             ; NMI while the engine runs: ignored

fe_job:
                movem.l d1/a0-a1,-(sp)          ; the job, kept for verify and retry
fe_again:
                ; ---- erase the marked sectors
                moveq   #0,d6                   ; heading printed?
                moveq   #0,d3                   ; sector number
.es             tst.b   0(a2,d3.w)
                beq     .en
                tst.b   d6
                bne     .eh
                lea     fs_erase(pc),a3
                bsr     fe_puts
                st      d6
.eh             move.l  d3,d4
                moveq   #12,d5
                lsl.l   d5,d4
                addi.l  #ROM_BASE,d4
                movea.l d4,a3                   ; A3 = sector
                move.b  #$AA,(a4)
                move.b  #$55,(a5)
                move.b  #$80,(a4)
                move.b  #$AA,(a4)
                move.b  #$55,(a5)
                move.b  #$30,(a3)               ; sector erase
                bsr     fe_toggle
                beq     fe_eto
                moveq   #'.',d0
                bsr     fe_putc
.en             addq.w  #1,d3
                cmpi.w  #FL_NSECT,d3
                blo     .es
                tst.b   d6
                beq     .prog
                bsr     fe_crlf
                ; ---- program every byte that differs
.prog           lea     fs_prog(pc),a3
                bsr     fe_puts
                movem.l (sp),d1/a0-a1
                move.l  d1,d5
.pl             move.b  (a0)+,d0
                cmp.b   (a1),d0
                beq     .pn
                move.b  #$AA,(a4)
                move.b  #$55,(a5)
                move.b  #$A0,(a4)
                move.b  d0,(a1)                 ; byte program
                move.l  #FL_PROG_TO,d4
.pp             cmp.b   (a1),d0                 ; DQ7 data polling: equal when done
                beq     .pn
                subq.l  #1,d4
                bne     .pp
                bra     fe_pto
.pn             addq.l  #1,a1
                move.w  a1,d4
                andi.w  #FL_SECT-1,d4
                bne     .pc
                moveq   #'.',d0                 ; a dot per 4K
                bsr     fe_putc
.pc             subq.l  #1,d5
                bne     .pl
                bsr     fe_crlf
                ; ---- verify the whole range
                lea     fs_verify(pc),a3
                bsr     fe_puts
                movem.l (sp),d1/a0-a1
                move.l  d1,d5
                moveq   #0,d6                   ; bytes that differ
.vl             move.b  (a0)+,d0
                cmp.b   (a1)+,d0
                beq     .vn
                tst.l   d6
                bne     .vc
                move.l  a1,d7                   ; first difference: D7 address,
                subq.l  #1,d7                   ; D3 = wrote << 8 | reads
                moveq   #0,d3
                move.b  d0,d3
                lsl.w   #8,d3
                move.b  -1(a1),d3
.vc             addq.l  #1,d6
.vn             subq.l  #1,d5
                bne     .vl
                tst.l   d6
                bne     fe_vfail
                lea     fs_ok(pc),a3
                bsr     fe_puts
                btst    #0,d2
                bne     fe_restart
                lea     12(sp),sp
                moveq   #0,d0
                bra     fe_ret

; the monitor was rewritten: start it the way a reset does
fe_restart:
                lea     fs_restart(pc),a3
                bsr     fe_puts
                move.l  #TX_TIMEOUT,d4
.w              btst    #SR_TXEMT,D_SRA(a6)     ; let the text go out
                bne     .r
                subq.l  #1,d4
                bne     .w
.r              reset                           ; 68681 and Junior bus (H3)
                movea.l (ROM_BASE).l,sp
                movea.l (ROM_BASE+4).l,a0
                jmp     (a0)

fe_eto:         move.b  #$F0,(a4)               ; A3 = sector; back to reading
                move.l  a3,d3
                lea     fs_eto(pc),a3
                bsr     fe_puts
                moveq   #5,d6
                bsr     fe_hexn
                bra     fe_fail

fe_pto:         move.b  #$F0,(a4)               ; A1 = address, D0 = data
                move.l  a1,d7
                moveq   #0,d3
                move.b  d0,d3
                lsl.w   #8,d3
                move.b  (a1),d3
                lea     fs_pto(pc),a3
                bsr     fe_puts
                bra     fe_where

fe_vfail:       lea     fs_vfail(pc),a3         ; D6 = count, D7/D3 = first
                bsr     fe_puts
                move.l  d3,-(sp)
                move.l  d6,d3
                moveq   #5,d6
                bsr     fe_hexn
                move.l  (sp)+,d3
                lea     fs_vfail2(pc),a3
                bsr     fe_puts
fe_where:       move.l  d3,-(sp)                ; " at $D7: wrote $xx, reads $yy"
                lea     fs_at(pc),a3
                bsr     fe_puts
                move.l  d7,d3
                moveq   #5,d6
                bsr     fe_hexn
                lea     fs_wrote(pc),a3
                bsr     fe_puts
                move.l  (sp),d3
                lsr.w   #8,d3
                moveq   #2,d6
                bsr     fe_hexn
                lea     fs_reads(pc),a3
                bsr     fe_puts
                move.l  (sp)+,d3
                moveq   #2,d6
                bsr     fe_hexn
fe_fail:        bsr     fe_crlf
                btst    #0,d2
                bne     .self
                lea     12(sp),sp
                moveq   #1,d0
                bra     fe_ret
.self           lea     fs_retry(pc),a3         ; no monitor to go back to
                bsr     fe_puts
.w              btst    #SR_RXRDY,D_SRA(a6)
                beq     .w
                move.b  D_RHRA(a6),d0
                andi.b  #$DF,d0
                cmpi.b  #'R',d0
                bne     .w
                bsr     fe_crlf
                movem.l (sp),d1/a0-a1
                bra     fe_again

; fe_toggle: wait until DQ6 at (A3) stops toggling. Z set on time-out.
; Uses D0, D4, D7.
fe_toggle:
                move.l  #FL_ERASE_TO,d4
.l              move.b  (a3),d0
                move.b  (a3),d7
                eor.b   d7,d0
                btst    #6,d0
                beq     .x
                subq.l  #1,d4
                bne     .l
.x              tst.l   d4
                rts

; fe_putc: send D0.B (polled; gives up after about 1 s). Preserves all.
fe_putc:
                move.l  d4,-(sp)
                move.l  #TX_TIMEOUT,d4
.w              btst    #SR_TXRDY,D_SRA(a6)
                bne     .r
                subq.l  #1,d4
                bne     .w
                bra     .x
.r              move.b  d0,D_THRA(a6)
.x              move.l  (sp)+,d4
                rts

; fe_puts: send the string at A3. Uses D0, A3.
fe_puts:
.l              move.b  (a3)+,d0
                beq     .x
                bsr     fe_putc
                bra     .l
.x              rts

fe_crlf:        lea     fs_crlf(pc),a3
                bra     fe_puts

; fe_hexn: print the low D6.W (1-8) hex digits of D3. Uses D0.
fe_hexn:
                movem.l d3/d6,-(sp)
                moveq   #8,d0
                sub.w   d6,d0
                lsl.w   #2,d0
                lsl.l   d0,d3                   ; first digit to the top
                subq.w  #1,d6
.l              rol.l   #4,d3
                move.b  d3,d0
                andi.b  #$0F,d0
                addi.b  #'0',d0
                cmpi.b  #'9',d0
                bls     .p
                addq.b  #7,d0
.p              bsr     fe_putc
                dbra    d6,.l
                movem.l (sp)+,d3/d6
                rts

fs_erase        dc.b    "Erasing     ",0
fs_prog         dc.b    "Programming ",0
fs_verify       dc.b    "Verifying   ",0
fs_ok           dc.b    "OK",13,10,0
fs_restart      dc.b    "Starting the new monitor.",13,10,0
fs_eto          dc.b    13,10,"Error: sector erase timed out at $",0
fs_pto          dc.b    13,10,"Error: byte program failed",0
fs_vfail        dc.b    13,10,"Error: verify found $",0
fs_vfail2       dc.b    " byte(s) different, the first",0
fs_at           dc.b    " at $",0
fs_wrote        dc.b    ": wrote $",0
fs_reads        dc.b    ", reads $",0
fs_retry        dc.b    "The monitor in the flash is incomplete. Keep the power on and press R to",13,10
                dc.b    "try again. (If it keeps failing, reprogram with FLASHBOOT or the T48.)",13,10,0
fs_crlf         dc.b    13,10,0
                even
fe_end:
FE_SIZE         equ     fe_end-fe_start
