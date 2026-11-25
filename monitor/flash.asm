;=============================================================================
; flash.asm - FL: program the flash (SST39SF020A) from RAM
;
; The monitor runs from the flash it programs. While the chip erases, programs
; or shows its ID, a read returns status bits instead of data, so no code may
; run from the flash then. The part that talks to the chip (the "engine",
; fe_start..fe_end) is position independent: fl_call copies it onto the
; monitor stack and runs it there with the interrupt mask at 7 and the NMI
; vector pointed at an RTE inside the copy. The engine does the whole job
; (erase, program, verify) without calling ROM code and prints its progress
; with polled output. When the job changes the monitor's own sectors, the
; engine does not return: it starts the new monitor through its reset vector,
; or after a failure waits for R to try again.
;
; Chip facts (SST39SF010A/020A/040 data sheet): 4K sectors, command
; addresses $5555/$2AAA on A14-A0, byte program 20 us max (DQ7 data
; polling), sector erase 25 ms max (DQ6 toggle bit), software ID $BF/$B6
; (020A) or $BF/$B7 (040) at offsets 0 and 1.
;=============================================================================

                include "flash_defs.inc"
MON_PROT_END    equ     (mon_code_end+FL_SECT-1)&~(FL_SECT-1)  ; first sector after the monitor

FLF_FORCE       equ     0                       ; fl_flags: ! given
FLF_SELF        equ     1                       ; the job changes the monitor's sectors

; FL working storage. v_recbuf is free while FL runs (only LO uses it).
fl_tab          equ     v_recbuf                ; 64 bytes: nonzero = erase sector n
fl_src          equ     v_recbuf+64             ; source in RAM
fl_dest         equ     v_recbuf+68             ; destination in the flash
fl_len          equ     v_recbuf+72             ; length in bytes
fl_nprog        equ     v_recbuf+76             ; bytes the job programs
fl_nerase       equ     v_recbuf+80             ; (word) sectors the job erases
fl_flags        equ     v_recbuf+82             ; (byte) FLF_ bits

;------------------------------------------------------------ FL
; FL                      show the flash ID and the protected monitor range
; FL start end dest [!]   write RAM start..end (inclusive) to the flash at dest
cmd_fl:
                bsr     at_end
                bne     .args
                bsr     fl_chip
                PRINT   "Monitor sectors (FL changes them only with !): $80000-$"
                move.l  #MON_PROT_END-1,d0
                bsr     puthex5
                bra     crlf
.args           bsr     get_range               ; D2/D3 = source range
                bsr     get_addr
                move.l  d0,d5                   ; D5 = destination
                clr.b   fl_flags
                bsr     skipsp
                cmpi.b  #'!',d0
                bne     .nf
                addq.l  #1,a0
                bset    #FLF_FORCE,fl_flags
.nf             bsr     end_args
                cmpi.l  #USER_RAM,d2
                blo     .src
                cmpi.l  #RAM_TOP-1,d3
                bhi     .src
                move.l  d3,d6
                sub.l   d2,d6                   ; length-1
                cmpi.l  #ROM_BASE,d5
                blo     .dst
                move.l  d5,d4
                add.l   d6,d4
                cmpi.l  #ROM_TOP-1,d4
                bhi     .dst
                move.l  d2,fl_src
                move.l  d5,fl_dest
                addq.l  #1,d6
                move.l  d6,fl_len
                bsr     fl_chip
                bne     .chip
                bsr     fl_plan
                PRINT   "Flash $"
                move.l  fl_dest,d0
                bsr     puthex5
                PRINT   "-$"
                add.l   fl_len,d0
                subq.l  #1,d0
                bsr     puthex5
                PRINT   " from RAM $"
                move.l  fl_src,d0
                bsr     puthex5
                PRINT   ": erase "
                moveq   #0,d0
                move.w  fl_nerase,d0
                bsr     putdec
                PRINT   " sector(s), program "
                move.l  fl_nprog,d0
                bsr     putdec
                PRINT   <" byte(s)",13,10>
                tst.w   fl_nerase
                bne     .work
                tst.l   fl_nprog
                bne     .work
                PRINT   <"The flash already holds this data.",13,10>
                rts
.work           btst    #FLF_SELF,fl_flags
                beq     .ask
                btst    #FLF_FORCE,fl_flags
                beq     .prot
                bsr     fl_chkvec
                PRINT   <"This rewrites the running monitor. Keep the power on and don't press reset",13,10>
                PRINT   <"until the new monitor starts. If a step fails, you can try it again.",13,10>
.ask            PRINT   "Program the flash (Y/N)? "
                lea     v_linebuf,a0            ; answer as a line (Enter consumes the CR)
                moveq   #LINEMAX,d1
                bsr     getline
                tst.l   d0
                bmi     cmd_aborted
                lea     v_linebuf,a0
                bsr     skipsp
                bsr     toupper
                cmpi.b  #'Y',d0
                bne     .no
                movea.l fl_src,a0
                movea.l fl_dest,a1
                move.l  fl_len,d1
                lea     fl_tab,a2
                moveq   #0,d2
                btst    #FLF_SELF,fl_flags
                beq     .run
                moveq   #1,d2
.run            moveq   #1,d0
                bra     fl_call                 ; prints its own result
.no             PRINT   <"Cancelled. The flash is unchanged.",13,10>
                rts
.src            ERROR   "the source must be in user RAM ($01000-$7FFFF)"
.dst            ERROR   "the destination must be in the flash ($80000-$BFFFF)"
.chip           ERROR   "FL needs an SST39SF020A or SST39SF040 that answers the ID command"
.prot           bsr     crlf
                PRINT   "Error: this changes the monitor itself ($80000-$"
                move.l  #MON_PROT_END-1,d0
                bsr     puthex5
                PRINT   <").",13,10,"Add ! to do it anyway. The board then restarts with the new monitor.",13,10>
                bra     cmd_loop

; fl_chip: read the flash ID and print it. Z set if FL can use the chip.
fl_chip:
                movem.l d0-d1,-(sp)
                moveq   #0,d0
                bsr     fl_call
                move.w  d0,d1
                PRINT   "Flash ID $"
                bsr     puthex4
                cmpi.w  #$BFB6,d1
                beq     .020
                cmpi.w  #$BFB7,d1
                beq     .040
                PRINT   <": not an SST39SF020A/040, or the flash ignores writes (/WE)",13,10>
                moveq   #1,d0                   ; Z clear
                bra     .x
.020            PRINT   <": SST39SF020A",13,10>
                bra     .ok
.040            PRINT   <": SST39SF040 (256K of it mapped)",13,10>
.ok             moveq   #0,d0                   ; Z set
.x              movem.l (sp)+,d0-d1             ; (MOVEM keeps the flags)
                rts

; fl_plan: decide per sector what the job does, from fl_src/fl_dest/fl_len.
; A sector is erased when some byte in the range needs a 0 bit turned back
; into a 1. Then the bytes of that sector outside the range must be blank
; ($FF), because the erase would lose them; otherwise FL refuses. Fills
; fl_tab, fl_nerase, fl_nprog and FLF_SELF. Uses D0-D7, A0, A3, A4.
fl_plan:
                lea     fl_tab,a0
                moveq   #FL_NSECT/4-1,d0
.clr            clr.l   (a0)+
                dbra    d0,.clr
                clr.w   fl_nerase
                clr.l   fl_nprog
                bclr    #FLF_SELF,fl_flags
                move.l  fl_dest,d2              ; D2 = first address in this sector
                move.l  d2,d3
                add.l   fl_len,d3
                subq.l  #1,d3                   ; D3 = last address of the job
.sect           move.l  d2,d4
                andi.l  #~(FL_SECT-1),d4        ; D4 = sector start
                move.l  d4,d5
                addi.l  #FL_SECT-1,d5           ; D5 = sector end
                move.l  d5,d6
                cmp.l   d3,d6
                bls     .h
                move.l  d3,d6                   ; D6 = last address in this sector
.h              movea.l d2,a4                   ; A4 = flash
                movea.l fl_src,a3
                adda.l  d2,a3
                suba.l  fl_dest,a3              ; A3 = source for D2
                move.l  d6,d7
                sub.l   d2,d7                   ; D7 = count-1
                movem.l d7/a3-a4,-(sp)
.p1             move.b  (a3)+,d0                ; erase needed?
                move.b  (a4)+,d1
                and.b   d0,d1
                cmp.b   d0,d1
                bne     .need
                subq.l  #1,d7
                bcc     .p1
                movem.l (sp)+,d7/a3-a4
                moveq   #0,d1                   ; no erase: count the bytes that differ
.c1             move.b  (a3)+,d0
                cmp.b   (a4)+,d0
                beq     .c1n
                addq.l  #1,d1
.c1n            subq.l  #1,d7
                bcc     .c1
                moveq   #0,d0
                bra     .acc
.need           movem.l (sp)+,d7/a3-a4
                movea.l d4,a4                   ; the rest of the sector must be blank
.o1             cmpa.l  d2,a4
                bhs     .o2
                cmpi.b  #$FF,(a4)+
                beq     .o1
                bra     .keep
.o2             movea.l d6,a4
                addq.l  #1,a4
.o3             cmpa.l  d5,a4
                bhi     .oend
                cmpi.b  #$FF,(a4)+
                beq     .o3
                bra     .keep
.oend           move.l  d4,d0
                subi.l  #ROM_BASE,d0
                moveq   #12,d1
                lsr.l   d1,d0
                lea     fl_tab,a0
                st      0(a0,d0.w)
                addq.w  #1,fl_nerase
                moveq   #0,d1                   ; after the erase: count the non-$FF bytes
.c2             cmpi.b  #$FF,(a3)+
                beq     .c2n
                addq.l  #1,d1
.c2n            subq.l  #1,d7
                bcc     .c2
                moveq   #1,d0
.acc            add.l   d1,fl_nprog
                or.l    d1,d0                   ; does this sector change?
                beq     .adv
                cmpi.l  #MON_PROT_END,d4
                bhs     .adv
                bset    #FLF_SELF,fl_flags
.adv            move.l  d5,d2
                addq.l  #1,d2                   ; next sector
                cmp.l   d3,d2
                bls     .sect
                rts
.keep           subq.l  #1,a4
                bsr     crlf
                PRINT   "Error: sector $"
                move.l  d4,d0
                bsr     puthex5
                PRINT   "-$"
                move.l  d5,d0
                bsr     puthex5
                PRINT   <" has to be erased, but it holds data outside the range",13,10,"(at $">
                move.l  a4,d0
                bsr     puthex5
                PRINT   <"). Copy that data into your RAM image too and flash whole sectors.",13,10>
                bra     cmd_loop

; fl_final: D0 = flash address -> D0.B = the byte it holds after the job
; (from the source, $FF in an erased sector, or the byte it holds now).
fl_final:
                movem.l d1/a0,-(sp)
                move.l  d0,d1
                sub.l   fl_dest,d1
                bcs     .old
                cmp.l   fl_len,d1
                bhs     .old
                movea.l fl_src,a0
                move.b  0(a0,d1.l),d0
                bra     .x
.old            move.l  d0,d1
                subi.l  #ROM_BASE,d1
                lsr.l   #8,d1
                lsr.l   #4,d1
                lea     fl_tab,a0
                tst.b   0(a0,d1.w)
                bne     .ff
                movea.l d0,a0
                move.b  (a0),d0
                bra     .x
.ff             st      d0
.x              movem.l (sp)+,d1/a0
                rts

; fl_chkvec: error unless the reset PC in the flash after the job is even
; and points into the flash; otherwise the board could not start again.
fl_chkvec:
                moveq   #0,d2
                moveq   #4,d3
.l              lsl.l   #8,d2
                move.l  #ROM_BASE,d0
                add.l   d3,d0
                bsr     fl_final
                move.b  d0,d2
                addq.l  #1,d3
                cmpi.l  #8,d3
                blo     .l
                btst    #0,d2
                bne     .bad
                cmpi.l  #ROM_BASE,d2
                blo     .bad
                cmpi.l  #ROM_TOP,d2
                bhs     .bad
                rts
.bad            bsr     crlf
                PRINT   "Error: the new reset vector (flash offset 4) would be $"
                move.l  d2,d0
                bsr     puthex8
                PRINT   <",",13,10,"not an even address in the flash, so the board could not start.",13,10>
                PRINT   <"Check the image and the FL addresses.",13,10>
                bra     cmd_loop

;------------------------------------------------------------ engine
; fl_call: run the engine from a copy on the monitor stack.
; In:  D0.W = 0  read the ID: D0.W = maker << 8 | device
;      D0.W = 1  job: A0 = source, A1 = flash destination, D1.L = length,
;                A2 = 64-byte sector table (nonzero = erase), D2.L bit 0 set
;                if the job changes the monitor (restart afterwards)
; Out: job: D0.L = 0 verified, 1 failed (the engine printed why).
;      All other registers preserved.
fl_call:
                movem.l d1-d7/a0-a6,-(sp)
                lea     -FE_SIZE(sp),sp
                lea     fe_start(pc),a3
                movea.l sp,a4
                move.w  #FE_SIZE/2-1,d7
.cp             move.w  (a3)+,(a4)+
                dbra    d7,.cp
                jsr     (sp)
                lea     FE_SIZE(sp),sp
                movem.l (sp)+,d1-d7/a0-a6
                rts

                include "flash_engine.asm"

                if      MON_DATA_END+FE_SIZE+512>MON_STACK_TOP
                fail    "the FL engine does not fit on the monitor stack"
                endif
