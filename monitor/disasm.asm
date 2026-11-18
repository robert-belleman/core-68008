;=============================================================================
; disasm.asm - MC68000 disassembler (68000/68008 instruction set only)
;
; dis_one   A0 = address (even), A1 = buffer (>= 64 bytes)
;           -> buffer holds "MNEMONIC operands" + NUL, D0.L = length (2-10)
;           Other registers preserved.
; dis_length A0 = address -> D0.L = instruction length
; dis_line  D0 = address: prints "AAAAA  hhhh hhhh ...  text", D0 = length
;
; Encodings follow the M68000 Programmer's Reference Manual. Effective
; address modes are checked against each instruction's allowed set; an
; encoding that is not a valid MC68000 instruction (including 68010+
; extensions, line A and line F) is shown as DC.W $xxxx with length 2.
; The output is valid vasm (Motorola) source when assembled at the same
; address: branch and PC-relative operands are shown as target addresses.
; Byte immediates show the low byte of their extension word (the 68000
; ignores the high byte).
;
; Registers inside: D7 opcode, D6 size (0 B, 1 W, 2 L), A1 output,
; A2 instruction address, A3 extension word pointer, A4 output start.
;=============================================================================

; effective address classes (bit n = EA index n, see d_eaidx)
EA_DN           equ     $001
EA_AN           equ     $002
EA_ALL          equ     $FFF
EA_DATA         equ     $FFD            ; all but An
EA_MEM          equ     $FFC
EA_CTRL         equ     $7E4            ; (An) d16(An) d8(An,Xn) abs.W abs.L d16(PC) d8(PC,Xn)
EA_ALT          equ     $1FF            ; Dn An (An) (An)+ -(An) d16 d8 abs.W abs.L
EA_DALT         equ     $1FD
EA_MALT         equ     $1FC
EA_CALT         equ     $1E4
EA_MOVEM_W      equ     $1F4            ; control alterable or -(An)
EA_MOVEM_R      equ     $7EC            ; control or (An)+
EA_DNOIMM       equ     $7FD            ; data, not immediate

; MN "text": append a mnemonic
MN              macro
                bsr     d_inl
                dc.b    \1,0
                even
                endm

dis_length:     movem.l a1,-(sp)
                lea     v_scratch,a1
                bsr    dis_one
                movem.l (sp)+,a1
                rts

; dis_line: D0 = address
dis_line:
                movem.l d1-d3/a0-a1,-(sp)
                movea.l d0,a0
                move.l  d0,d3
                lea     v_scratch,a1
                bsr    dis_one
                move.l  d0,d2                   ; length
                move.l  d3,d0
                bsr     puthex5
                bsr     putspace
                bsr     putspace
                movea.l d3,a0
                move.w  d2,d1
                lsr.w   #1,d1                   ; words
                moveq   #5,d3
                sub.w   d1,d3                   ; padding words
                subq.w  #1,d1
.w              move.w  (a0)+,d0
                bsr     puthex4
                bsr     putspace
                dbra    d1,.w
.p              subq.w  #1,d3
                bmi    .t
                PRINT   "     "
                bra    .p
.t              bsr     putspace
                lea     v_scratch,a0
                bsr     puts
                bsr     crlf
                move.l  d2,d0
                movem.l (sp)+,d1-d3/a0-a1
                rts

dis_one:
                movem.l d1-d7/a0-a6,-(sp)
                move.l  sp,v_dis_sp             ; for d_invalid
                movea.l a0,a2
                movea.l a0,a3
                movea.l a1,a4
                move.w  (a3)+,d7
                moveq   #-1,d6
                move.w  d7,d0
                rol.w   #4,d0
                andi.w  #$F,d0
                add.w   d0,d0
                move.w  dis_lines(pc,d0.w),d0
                jsr     dis_lines(pc,d0.w)
dis_done:       clr.b   (a1)
                move.l  a3,d0
                sub.l   a2,d0
                movem.l (sp)+,d1-d7/a0-a6
                rts
dis_lines          dc.w    d_line0-dis_lines,d_move-dis_lines,d_move-dis_lines,d_move-dis_lines
                dc.w    d_line4-dis_lines,d_line5-dis_lines,d_line6-dis_lines,d_line7-dis_lines
                dc.w    d_line8-dis_lines,d_line9d-dis_lines,d_invalid-dis_lines,d_lineb-dis_lines
                dc.w    d_linec-dis_lines,d_line9d-dis_lines,d_linee-dis_lines,d_invalid-dis_lines

; d_invalid: not an MC68000 instruction -> DC.W $xxxx, length 2
d_invalid:
                movea.l v_dis_sp,sp
                movea.l a4,a1
                lea     2(a2),a3
                MN      "DC.W"
                bsr     d_tab
                move.w  d7,d0
                moveq   #4,d1
                bsr     s_hexd
                bra     dis_done

;------------------------------------------------------------ output helpers
; d_inl: append the inline string (after the BSR) at A1
d_inl:          move.l  a0,-(sp)
                movea.l 4(sp),a0
.l              move.b  (a0)+,(a1)+
                bne    .l
                subq.l  #1,a1
                move.l  a0,d0
                addq.l  #1,d0
                andi.w  #$FFFE,d0
                move.l  d0,4(sp)
                movea.l (sp)+,a0
                rts

; d_sz: append .B/.W/.L for D6 = 0/1/2
d_sz:           move.b  #'.',(a1)+
                move.b  .c(pc,d6.w),(a1)+
                rts
.c              dc.b    "BWL",0

; d_tab: pad the mnemonic to 8 columns
d_tab:          move.b  #' ',(a1)+
                move.l  a1,d0
                sub.l   a4,d0
                cmpi.w  #8,d0
                blo    d_tab
                rts

d_comma:        move.b  #',',(a1)+
                rts

; d_dn / d_an: register D0.W (0-7)
d_dn:           move.b  #'D',(a1)+
                bra    d_rn
d_an:           move.b  #'A',(a1)+
d_rn:           andi.b  #7,d0
                addi.b  #'0',d0
                move.b  d0,(a1)+
                rts

; d_reg9 / d_reg0: register number from opcode bits 11-9 / 2-0 -> D0
d_reg9:         move.w  d7,d0
                rol.w   #7,d0
                andi.w  #7,d0
                rts
d_reg0:         move.w  d7,d0
                andi.w  #7,d0
                rts

; d_size: D6 = size from opcode bits 7-6, invalid if 3
d_size:         move.w  d7,d6
                lsr.w   #6,d6
                andi.w  #3,d6
                cmpi.w  #3,d6
                beq     d_invalid
                rts

; d_word: next extension word -> D0.W (sign-extended to long)
d_word:         move.w  (a3)+,d0
                ext.l   d0
                rts

; d_shex: append D0.L as signed hex (-$10 / $10), minimal digits
d_shex:         tst.l   d0
                bpl    d_hex
                move.b  #'-',(a1)+
                neg.l   d0
; d_hex: append D0.L as $hex with 1-8 digits (no leading zeros)
d_hex:          movem.l d0-d2,-(sp)
                move.b  #'$',(a1)+
                moveq   #8,d1
                move.l  d0,d2
.z              cmpi.w  #1,d1
                beq    .o
                rol.l   #4,d2
                move.b  d2,d0
                ror.l   #4,d2
                andi.b  #$F,d0
                bne    .o
                lsl.l   #4,d2
                subq.w  #1,d1
                bra    .z
.o              move.l  (sp),d0
                bsr     s_hex
                movem.l (sp)+,d0-d2
                rts

; d_addr: append an address D0.L as $xxxxx (5 digits if <= $FFFFF)
d_addr:         movem.l d1,-(sp)
                move.b  #'$',(a1)+
                moveq   #5,d1
                cmpi.l  #ADDR_MAX,d0
                bls    .s
                moveq   #8,d1
.s              bsr     s_hex
                movem.l (sp)+,d1
                rts

; d_imm: immediate of size D6 -> "#$xx"
d_imm:          move.b  #'#',(a1)+
                moveq   #0,d0
                tst.w   d6
                bne    .wl
                move.w  (a3)+,d0
                andi.w  #$FF,d0                 ; byte: low byte of the word
                bra     d_hex
.wl             cmpi.w  #1,d6
                bne    .l
                move.w  (a3)+,d0
                bra     d_hex
.l              move.l  (a3)+,d0
                bra     d_hex

;------------------------------------------------------------ effective address
; d_eaidx: D0.W = 6-bit EA (mode<<3|reg) -> D1.W = index 0-11, invalid if none
d_eaidx:        move.w  d0,d1
                lsr.w   #3,d1
                andi.w  #7,d1
                cmpi.w  #7,d1
                bne    .x
                move.w  d0,d1
                andi.w  #7,d1
                cmpi.w  #4,d1
                bhi     d_invalid
                addq.w  #7,d1
.x              rts

; d_eachk: D0.W = EA, D2.W = allowed classes; invalid unless allowed
d_eachk:        movem.l d1,-(sp)
                bsr    d_eaidx
                btst    d1,d2
                movem.l (sp)+,d1
                beq     d_invalid
                rts

; d_ea: check EA D0.W against D2.W, then append it (D6 = size for #imm)
d_ea:           bsr    d_eachk
; d_eaout: append EA D0.W (already validated)
d_eaout:        movem.l d1-d3,-(sp)
                move.w  d0,d3
                bsr    d_eaidx
                add.w   d1,d1
                move.w  .t(pc,d1.w),d1
                jsr     .t(pc,d1.w)
                movem.l (sp)+,d1-d3
                rts
.t              dc.w    .dn-.t,.an-.t,.ind-.t,.inc-.t,.dec-.t,.d16-.t,.d8-.t
                dc.w    .absw-.t,.absl-.t,.pcd16-.t,.pcd8-.t,.imm-.t
.dn             move.w  d3,d0
                bra     d_dn
.an             move.w  d3,d0
                bra     d_an
.ind            move.b  #'(',(a1)+
                move.w  d3,d0
                bsr     d_an
                move.b  #')',(a1)+
                rts
.inc            bsr    .ind
                move.b  #'+',(a1)+
                rts
.dec            move.b  #'-',(a1)+
                bra    .ind
.d16            bsr     d_word
                bsr     d_shex
                bra    .ind
.d8             move.w  (a3)+,d2                ; brief extension word
                move.b  d2,d0
                ext.w   d0
                ext.l   d0
                bsr     d_shex
                move.b  #'(',(a1)+
                move.w  d3,d0
                bsr     d_an
                bra    .xn
.absw           bsr     d_word
                bsr     d_hexl
                move.b  #'.',(a1)+
                move.b  #'W',(a1)+
                rts
.absl           move.l  (a3)+,d0
                bsr     d_hexl
                move.b  #'.',(a1)+
                move.b  #'L',(a1)+
                rts
.pcd16          move.l  a3,d1                   ; PC = address of the extension word
                bsr     d_word
                add.l   d1,d0
                bsr     d_addr
                move.b  #'(',(a1)+
                move.b  #'P',(a1)+
                move.b  #'C',(a1)+
                move.b  #')',(a1)+
                rts
.pcd8           move.l  a3,d1
                move.w  (a3)+,d2
                move.b  d2,d0
                ext.w   d0
                ext.l   d0
                add.l   d1,d0
                bsr     d_addr
                move.b  #'(',(a1)+
                move.b  #'P',(a1)+
                move.b  #'C',(a1)+
.xn             move.b  #',',(a1)+              ; index register from D2
                move.w  d2,d0
                rol.w   #4,d0
                tst.w   d2
                bmi    .xa
                bsr     d_dn
                bra    .xs
.xa             bsr     d_an
.xs             move.b  #'.',(a1)+
                move.b  #'W',(a1)+
                btst    #11,d2
                beq    .xe
                move.b  #'L',-1(a1)
.xe             move.b  #')',(a1)+
                rts
.imm            bra     d_imm

; d_hexl: absolute address operand: $hex with at least 4 digits
d_hexl:         movem.l d1,-(sp)
                move.b  #'$',(a1)+
                moveq   #8,d1
                cmpi.l  #$FFFF,d0
                bhi    .a
                moveq   #4,d1
                bra    .s
.a              cmpi.l  #ADDR_MAX,d0
                bhi    .s
                moveq   #5,d1
.s              bsr     s_hex
                movem.l (sp)+,d1
                rts

; d_ea_src: source EA from bits 5-0 checked against D2
d_ea_src:       move.w  d7,d0
                andi.w  #$3F,d0
                bra     d_ea

; d_target: append branch target D0.L (already absolute)
d_target:       bra     d_addr

;------------------------------------------------------------ condition codes
d_cc:           move.w  d7,d0                   ; append cc from bits 11-8
                lsr.w   #7,d0
                andi.w  #$1E,d0
                move.b  .c(pc,d0.w),(a1)+
                move.b  .c+1(pc,d0.w),(a1)+
                rts
.c              dc.b    "T F HILSCCCSNEEQVCVSPLMIGELTGTLE"

;============================================================ line 0
d_line0:
                move.w  d7,d0
                cmpi.w  #$003C,d0
                beq     .oriccr
                cmpi.w  #$007C,d0
                beq     .orisr
                cmpi.w  #$023C,d0
                beq     .andiccr
                cmpi.w  #$027C,d0
                beq     .andisr
                cmpi.w  #$0A3C,d0
                beq     .eoriccr
                cmpi.w  #$0A7C,d0
                beq     .eorisr
                btst    #8,d7
                bne     .dyn
                move.w  d7,d0
                andi.w  #$0F00,d0
                cmpi.w  #$0800,d0
                beq     .static
                ; immediate group: ORI ANDI SUBI ADDI - EORI CMPI
                bsr     d_size
                move.w  d7,d0
                rol.w   #7,d0
                andi.w  #7,d0                   ; bits 11-9
                lea     .inames(pc),a0
                mulu.w  #5,d0
                adda.w  d0,a0
                tst.b   (a0)
                beq     d_invalid
.cp             move.b  (a0)+,(a1)+
                bne    .cp
                subq.l  #1,a1
                bsr     d_sz
                bsr     d_tab
                bsr     d_imm
                bsr     d_comma
                move.w  #EA_DALT,d2
                bra     d_ea_src
.inames         dc.b    "ORI",0,0,"ANDI",0,"SUBI",0,"ADDI",0,0,0,0,0,0,"EORI",0,"CMPI",0,0,0,0,0,0

.oriccr         MN      "ORI.B"
                bra    .ccr
.andiccr        MN      "ANDI.B"
                bra    .ccr
.eoriccr        MN      "EORI.B"
.ccr            bsr     d_tab
                moveq   #0,d6
                bsr     d_imm
                MN      ",CCR"
                rts
.orisr          MN      "ORI.W"
                bra    .sr
.andisr         MN      "ANDI.W"
                bra    .sr
.eorisr         MN      "EORI.W"
.sr             bsr     d_tab
                moveq   #1,d6
                bsr     d_imm
                MN      ",SR"
                rts

.bitname        move.w  d7,d0                   ; bits 7-6 -> BTST BCHG BCLR BSET
                lsr.w   #4,d0
                andi.w  #$C,d0
                lea     .bn(pc,d0.w),a0
                move.b  (a0)+,(a1)+
                move.b  (a0)+,(a1)+
                move.b  (a0)+,(a1)+
                move.b  (a0)+,(a1)+
                bra     d_tab
.bn             dc.b    "BTSTBCHGBCLRBSET"

.static         bsr    .bitname
                move.w  #EA_DALT,d2
                move.w  d7,d0
                andi.w  #$C0,d0
                bne    .s1
                move.w  #EA_DNOIMM,d2           ; BTST: any data mode except #
.s1             move.w  d7,d0
                andi.w  #$3F,d0
                bsr     d_eachk
                move.b  #'#',(a1)+
                move.w  (a3)+,d0
                andi.l  #$FF,d0
                bsr     d_hex
                bsr     d_comma
                bra     d_ea_src

.dyn            move.w  d7,d0                   ; dynamic bit op or MOVEP
                andi.w  #$38,d0
                cmpi.w  #$08,d0
                beq    .movep
                bsr    .bitname
                move.w  #EA_DALT,d2
                move.w  d7,d0
                andi.w  #$C0,d0
                bne    .d1
                move.w  #EA_DATA,d2             ; BTST Dn,<ea>: any data mode
                moveq   #0,d6                   ; (#imm is a byte)
.d1             move.w  d7,d0
                andi.w  #$3F,d0
                bsr     d_eachk
                bsr     d_reg9
                bsr     d_dn
                bsr     d_comma
                bra     d_ea_src

.movep          MN      "MOVEP"
                moveq   #1,d6
                btst    #6,d7
                beq    .m1
                moveq   #2,d6
.m1             bsr     d_sz
                bsr     d_tab
                btst    #7,d7
                bne    .mr2m
                bsr    .mpea                   ; d16(Ay),Dx
                bsr     d_comma
                bsr     d_reg9
                bra     d_dn
.mr2m           bsr     d_reg9                  ; Dx,d16(Ay)
                bsr     d_dn
                bsr     d_comma
.mpea           bsr     d_word
                bsr     d_shex
                move.b  #'(',(a1)+
                bsr     d_reg0
                bsr     d_an
                move.b  #')',(a1)+
                rts

;============================================================ MOVE / MOVEA
d_move:
                move.w  d7,d0
                rol.w   #4,d0
                andi.w  #3,d0                   ; 1 B, 2 L, 3 W
                lea     .sz(pc),a0
                move.b  0(a0,d0.w),d6
                ext.w   d6
                move.w  d7,d1                   ; destination EA: mode 8-6, reg 11-9
                lsr.w   #3,d1
                andi.w  #$38,d1
                move.w  d7,d0
                rol.w   #7,d0
                andi.w  #7,d0
                or.w    d0,d1                   ; d1 = dest EA
                move.w  d1,d5
                andi.w  #$38,d1
                cmpi.w  #$08,d1
                beq    .movea
                move.w  d5,d0
                move.w  #EA_DALT,d2
                bsr     d_eachk                 ; validate the destination first
                MN      "MOVE"
                bsr     d_sz
                bsr     d_tab
                move.w  #EA_ALL,d2
                tst.w   d6
                bne    .s
                move.w  #EA_DATA,d2             ; no byte access to An
.s              bsr     d_ea_src
                bsr     d_comma
                move.w  d5,d0
                bra     d_eaout
.movea          tst.w   d6
                beq     d_invalid
                MN      "MOVEA"
                bsr     d_sz
                bsr     d_tab
                move.w  #EA_ALL,d2
                bsr     d_ea_src
                bsr     d_comma
                bsr     d_reg9
                bra     d_an
.sz             dc.b    0,0,2,1

;============================================================ line 4
d_line4:
                move.w  d7,d0
                lea     .fixed(pc),a0           ; opcodes without operands
.f              move.w  (a0)+,d1
                beq    .nf
                cmp.w   d1,d0
                beq    .fixedhit
                addq.l  #8,a0
                bra    .f
.fixedhit       move.b  (a0)+,(a1)+
                bne    .fixedhit
                subq.l  #1,a1
                rts
.fixed          dc.w    $4AFC
                dc.b    "ILLEGAL",0
                dc.w    $4E70
                dc.b    "RESET",0,0,0
                dc.w    $4E71
                dc.b    "NOP",0,0,0,0,0
                dc.w    $4E73
                dc.b    "RTE",0,0,0,0,0
                dc.w    $4E75
                dc.b    "RTS",0,0,0,0,0
                dc.w    $4E76
                dc.b    "TRAPV",0,0,0
                dc.w    $4E77
                dc.b    "RTR",0,0,0,0,0
                dc.w    0
.nf             cmpi.w  #$4E72,d0
                beq     .stop
                move.w  d0,d1
                andi.w  #$FFF0,d1
                cmpi.w  #$4E40,d1
                beq     .trap
                move.w  d0,d1
                andi.w  #$FFF8,d1
                cmpi.w  #$4E50,d1
                beq     .link
                cmpi.w  #$4E58,d1
                beq     .unlk
                cmpi.w  #$4E60,d1
                beq     .tousp
                cmpi.w  #$4E68,d1
                beq     .fromusp
                cmpi.w  #$4840,d1
                beq     .swap
                cmpi.w  #$4880,d1
                beq     .extw
                cmpi.w  #$48C0,d1
                beq     .extl
                move.w  d0,d1
                andi.w  #$FFC0,d1
                cmpi.w  #$4E80,d1
                beq     .jsr
                cmpi.w  #$4EC0,d1
                beq     .jmp
                cmpi.w  #$40C0,d1
                beq     .frsr
                cmpi.w  #$44C0,d1
                beq     .toccr
                cmpi.w  #$46C0,d1
                beq     .tosr
                cmpi.w  #$4840,d1
                beq     .pea
                cmpi.w  #$4800,d1
                beq     .nbcd
                cmpi.w  #$4AC0,d1
                beq     .tas
                move.w  d0,d1
                andi.w  #$FF80,d1
                cmpi.w  #$4880,d1
                beq     .movemw
                cmpi.w  #$4C80,d1
                beq     .movemr
                move.w  d0,d1
                andi.w  #$F1C0,d1
                cmpi.w  #$41C0,d1
                beq     .lea
                cmpi.w  #$4180,d1
                beq     .chk
                move.w  d0,d1
                andi.w  #$FF00,d1
                lea     .one(pc),a0
                cmpi.w  #$4000,d1
                beq    .onehit
                addq.l  #6,a0
                cmpi.w  #$4200,d1
                beq    .onehit
                addq.l  #6,a0
                cmpi.w  #$4400,d1
                beq    .onehit
                addq.l  #6,a0
                cmpi.w  #$4600,d1
                beq    .onehit
                addq.l  #6,a0
                cmpi.w  #$4A00,d1
                beq    .onehit
                bra     d_invalid
.onehit         bsr     d_size                  ; NEGX CLR NEG NOT TST
.oc             move.b  (a0)+,(a1)+
                bne    .oc
                subq.l  #1,a1
                bsr     d_sz
                bsr     d_tab
                move.w  #EA_DALT,d2
                bra     d_ea_src
.one            dc.b    "NEGX",0,0,"CLR",0,0,0,"NEG",0,0,0,"NOT",0,0,0,"TST",0,0,0

.stop           MN      "STOP"
                bsr     d_tab
                moveq   #1,d6
                bra     d_imm
.trap           MN      "TRAP"
                bsr     d_tab
                move.b  #'#',(a1)+
                move.w  d7,d0
                andi.l  #$F,d0
                bra     s_dec
.link           MN      "LINK"
                bsr     d_tab
                bsr     d_reg0
                bsr     d_an
                MN      ",#"
                bsr     d_word
                bra     d_shex
.unlk           MN      "UNLK"
                bsr     d_tab
                bsr     d_reg0
                bra     d_an
.tousp          MN      "MOVE.L"
                bsr     d_tab
                bsr     d_reg0
                bsr     d_an
                MN      ",USP"
                rts
.fromusp        MN      "MOVE.L"
                bsr     d_tab
                MN      "USP,"
                bsr     d_reg0
                bra     d_an
.swap           MN      "SWAP"
                bsr     d_tab
                bsr     d_reg0
                bra     d_dn
.extw           MN      "EXT.W"
                bra    .ext
.extl           MN      "EXT.L"
.ext            bsr     d_tab
                bsr     d_reg0
                bra     d_dn
.jsr            MN      "JSR"
                bra    .ctl
.jmp            MN      "JMP"
                bra    .ctl
.pea            MN      "PEA"
.ctl            bsr     d_tab
                move.w  #EA_CTRL,d2
                bra     d_ea_src
.frsr           MN      "MOVE.W"
                bsr     d_tab
                MN      "SR,"
                move.w  #EA_DALT,d2
                bra     d_ea_src
.toccr          moveq   #1,d6
                move.w  #EA_DATA,d2
                move.w  d7,d0
                andi.w  #$3F,d0
                bsr     d_eachk
                MN      "MOVE.W"
                bsr     d_tab
                bsr     d_ea_src
                MN      ",CCR"
                rts
.tosr           moveq   #1,d6
                move.w  #EA_DATA,d2
                move.w  d7,d0
                andi.w  #$3F,d0
                bsr     d_eachk
                MN      "MOVE.W"
                bsr     d_tab
                bsr     d_ea_src
                MN      ",SR"
                rts
.nbcd           MN      "NBCD"
                bra    .da
.tas            MN      "TAS"
.da             bsr     d_tab
                move.w  #EA_DALT,d2
                bra     d_ea_src
.lea            MN      "LEA"
                bsr     d_tab
                move.w  #EA_CTRL,d2
                bsr     d_ea_src
                bsr     d_comma
                bsr     d_reg9
                bra     d_an
.chk            MN      "CHK.W"
                bsr     d_tab
                moveq   #1,d6
                move.w  #EA_DATA,d2
                bsr     d_ea_src
                bsr     d_comma
                bsr     d_reg9
                bra     d_dn
.movemw         move.w  d7,d0                   ; registers to memory
                andi.w  #$3F,d0
                move.w  #EA_MOVEM_W,d2
                bsr     d_eachk
                bsr    .mmname
                move.w  (a3)+,d4                ; register mask
                move.w  d7,d0
                andi.w  #$38,d0
                cmpi.w  #$20,d0                 ; -(An): mask is reversed
                bne    .mw1
                moveq   #16-1,d1
                moveq   #0,d3
.rev            lsr.w   #1,d4
                roxl.w  #1,d3
                dbra    d1,.rev
                move.w  d3,d4
.mw1            bsr     d_reglist
                bsr     d_comma
                move.w  d7,d0
                andi.w  #$3F,d0
                bra     d_eaout
.movemr         move.w  d7,d0                   ; memory to registers
                andi.w  #$3F,d0
                move.w  #EA_MOVEM_R,d2
                bsr     d_eachk
                bsr    .mmname
                move.w  (a3)+,d4
                move.w  d7,d0
                andi.w  #$3F,d0
                bsr     d_eaout
                bsr     d_comma
                bra     d_reglist
.mmname         MN      "MOVEM"
                moveq   #1,d6
                btst    #6,d7
                beq    .mm1
                moveq   #2,d6
.mm1            bsr     d_sz
                bra     d_tab

; d_reglist: D4.W = mask, bit 0 = D0 ... bit 15 = A7 -> "D0-D2/A0/A6"
d_reglist:
                movem.l d0-d3,-(sp)
                tst.w   d4
                bne    .go
                move.b  #'#',(a1)+              ; empty list (assembles as #0)
                move.b  #'0',(a1)+
                bra    .x
.go             moveq   #0,d1                   ; register index 0..15
                moveq   #0,d3                   ; "something printed" flag
.l              btst    d1,d4
                beq    .n
                tst.w   d3                      ; start of a run
                beq    .ns
                move.b  #'/',(a1)+
.ns             moveq   #1,d3
                move.w  d1,d0
                bsr    .name
                move.w  d1,d2                   ; find the end of the run
.r              addq.w  #1,d2
                cmpi.w  #16,d2
                beq    .re
                move.w  d2,d0
                andi.w  #7,d0
                beq    .re                     ; runs do not cross D7/A0
                btst    d2,d4
                bne    .r
.re             subq.w  #1,d2
                cmp.w   d1,d2
                beq    .single
                move.b  #'-',(a1)+
                move.w  d2,d0
                bsr    .name
.single         move.w  d2,d1
.n              addq.w  #1,d1
                cmpi.w  #16,d1
                blo    .l
.x              movem.l (sp)+,d0-d3
                rts
.name           cmpi.w  #8,d0
                bhs    .a
                bra     d_dn
.a              bra     d_an

;============================================================ line 5
d_line5:
                move.w  d7,d0
                andi.w  #$C0,d0
                cmpi.w  #$C0,d0
                beq    .sdb
                bsr     d_size                  ; ADDQ / SUBQ
                MN      "ADDQ"
                btst    #8,d7
                beq    .a
                move.b  #'S',-4(a1)
                move.b  #'U',-3(a1)
                move.b  #'B',-2(a1)
.a              bsr     d_sz
                bsr     d_tab
                move.w  #EA_ALT,d2
                tst.w   d6
                bne    .q
                move.w  #EA_DALT,d2             ; no byte access to An
.q              move.w  d7,d0
                andi.w  #$3F,d0
                bsr     d_eachk
                move.b  #'#',(a1)+
                bsr     d_reg9
                bne    .q8
                moveq   #8,d0
.q8             addi.b  #'0',d0
                move.b  d0,(a1)+
                bsr     d_comma
                bra     d_ea_src
.sdb            move.w  d7,d0
                andi.w  #$38,d0
                cmpi.w  #$08,d0
                beq    .db
                move.b  #'S',(a1)+              ; Scc
                bsr     d_cc
                bsr     d_trimcc
                bsr     d_tab
                move.w  #EA_DALT,d2
                bra     d_ea_src
.db             move.b  #'D',(a1)+
                move.b  #'B',(a1)+
                move.w  d7,d0
                andi.w  #$0F00,d0
                cmpi.w  #$0100,d0
                bne    .dbcc
                MN      "RA"                    ; DBF is written DBRA
                bra    .dbt
.dbcc           bsr     d_cc
                bsr     d_trimcc
.dbt            bsr     d_tab
                bsr     d_reg0
                bsr     d_dn
                bsr     d_comma
                move.l  a3,d1
                bsr     d_word
                add.l   d1,d0
                bra     d_target

; d_trimcc: remove the trailing blank of a one-letter condition (T, F)
d_trimcc:       cmpi.b  #' ',-1(a1)
                bne    .x
                subq.l  #1,a1
.x              rts

;============================================================ line 6
d_line6:
                move.w  d7,d0
                andi.w  #$0F00,d0
                bne    .n0
                MN      "BRA"
                bra    .d
.n0             cmpi.w  #$0100,d0
                bne    .n1
                MN      "BSR"
                bra    .d
.n1             move.b  #'B',(a1)+
                bsr     d_cc
.d              move.b  d7,d0
                bne    .short
                MN      ".W"
                bsr     d_tab
                move.l  a3,d1
                bsr     d_word
                add.l   d1,d0
                bra     d_target
.short          MN      ".S"
                bsr     d_tab
                move.b  d7,d0
                ext.w   d0
                ext.l   d0
                add.l   a3,d0
                bra     d_target

;============================================================ line 7
d_line7:
                btst    #8,d7
                bne     d_invalid
                MN      "MOVEQ"
                bsr     d_tab
                move.b  #'#',(a1)+
                move.b  d7,d0
                ext.w   d0
                ext.l   d0
                bsr     d_shex
                bsr     d_comma
                bsr     d_reg9
                bra     d_dn

;============================================================ line 8 (OR, DIV, SBCD)
d_line8:
                move.w  d7,d0
                andi.w  #$F1C0,d0
                cmpi.w  #$80C0,d0
                beq    .divu
                cmpi.w  #$81C0,d0
                beq    .divs
                move.w  d7,d0
                andi.w  #$F1F0,d0
                cmpi.w  #$8100,d0
                beq    .sbcd
                MN      "OR"
                bra     d_logic
.divu           MN      "DIVU.W"
                bra    .md
.divs           MN      "DIVS.W"
.md             bsr     d_tab
                moveq   #1,d6
                move.w  #EA_DATA,d2
                bsr     d_ea_src
                bsr     d_comma
                bsr     d_reg9
                bra     d_dn
.sbcd           MN      "SBCD"
                bra     d_bcdx

; d_logic: OR / AND body (mnemonic written)
d_logic:        bsr     d_size
                bsr     d_sz
                bsr     d_tab
                btst    #8,d7
                bne    .tomem
                move.w  #EA_DATA,d2             ; <ea>,Dn
                bsr     d_ea_src
                bsr     d_comma
                bsr     d_reg9
                bra     d_dn
.tomem          move.w  d7,d0                   ; Dn,<ea>
                andi.w  #$3F,d0
                move.w  #EA_MALT,d2
                bsr     d_eachk
                bsr     d_reg9
                bsr     d_dn
                bsr     d_comma
                bra     d_ea_src

; d_bcdx: ABCD/SBCD/ADDX/SUBX operands: Dy,Dx or -(Ay),-(Ax)
d_bcdx:         bsr     d_tab
                btst    #3,d7
                bne    .m
                bsr     d_reg0
                bsr     d_dn
                bsr     d_comma
                bsr     d_reg9
                bra     d_dn
.m              move.b  #'-',(a1)+
                move.b  #'(',(a1)+
                bsr     d_reg0
                bsr     d_an
                MN      "),-("
                bsr     d_reg9
                bsr     d_an
                move.b  #')',(a1)+
                rts

;============================================================ line 9 / D (SUB, ADD)
d_line9d:
                move.w  d7,d0
                andi.w  #$00C0,d0
                cmpi.w  #$00C0,d0
                beq    .adda
                btst    #8,d7
                beq    .norm
                move.w  d7,d0
                andi.w  #$0030,d0               ; mode 0 or 1 with bit 8: ADDX/SUBX
                bne    .norm
                bsr    .name
                move.b  #'X',(a1)+
                bsr     d_size
                bsr     d_sz
                bra     d_bcdx
.norm           bsr    .name
                bsr     d_size
                bsr     d_sz
                bsr     d_tab
                btst    #8,d7
                bne    .tomem
                move.w  #EA_ALL,d2              ; <ea>,Dn
                tst.w   d6
                bne    .s
                move.w  #EA_DATA,d2
.s              bsr     d_ea_src
                bsr     d_comma
                bsr     d_reg9
                bra     d_dn
.tomem          move.w  d7,d0
                andi.w  #$3F,d0
                move.w  #EA_MALT,d2
                bsr     d_eachk
                bsr     d_reg9
                bsr     d_dn
                bsr     d_comma
                bra     d_ea_src
.adda           bsr    .name
                move.b  #'A',(a1)+
                moveq   #1,d6
                btst    #8,d7
                beq    .aw
                moveq   #2,d6
.aw             bsr     d_sz
                bsr     d_tab
                move.w  #EA_ALL,d2
                bsr     d_ea_src
                bsr     d_comma
                bsr     d_reg9
                bra     d_an
.name           btst    #14,d7                  ; $9xxx SUB, $Dxxx ADD
                bne    .add
                MN      "SUB"
                rts
.add            MN      "ADD"
                rts

;============================================================ line B (CMP, EOR)
d_lineb:
                move.w  d7,d0
                andi.w  #$00C0,d0
                cmpi.w  #$00C0,d0
                beq    .cmpa
                btst    #8,d7
                bne    .b8
                MN      "CMP"
                bsr     d_size
                bsr     d_sz
                bsr     d_tab
                move.w  #EA_ALL,d2
                tst.w   d6
                bne    .s
                move.w  #EA_DATA,d2
.s              bsr     d_ea_src
                bsr     d_comma
                bsr     d_reg9
                bra     d_dn
.b8             move.w  d7,d0
                andi.w  #$38,d0
                cmpi.w  #$08,d0
                beq    .cmpm
                MN      "EOR"
                bsr     d_size
                bsr     d_sz
                bsr     d_tab
                move.w  d7,d0
                andi.w  #$3F,d0
                move.w  #EA_DALT,d2
                bsr     d_eachk
                bsr     d_reg9
                bsr     d_dn
                bsr     d_comma
                bra     d_ea_src
.cmpm           MN      "CMPM"
                bsr     d_size
                bsr     d_sz
                bsr     d_tab
                move.b  #'(',(a1)+
                bsr     d_reg0
                bsr     d_an
                MN      ")+,("
                bsr     d_reg9
                bsr     d_an
                MN      ")+"
                rts
.cmpa           MN      "CMPA"
                moveq   #1,d6
                btst    #8,d7
                beq    .aw
                moveq   #2,d6
.aw             bsr     d_sz
                bsr     d_tab
                move.w  #EA_ALL,d2
                bsr     d_ea_src
                bsr     d_comma
                bsr     d_reg9
                bra     d_an

;============================================================ line C (AND, MUL, ABCD, EXG)
d_linec:
                move.w  d7,d0
                andi.w  #$F1C0,d0
                cmpi.w  #$C0C0,d0
                beq    .mulu
                cmpi.w  #$C1C0,d0
                beq    .muls
                move.w  d7,d0
                andi.w  #$F1F0,d0
                cmpi.w  #$C100,d0
                beq    .abcd
                move.w  d7,d0
                andi.w  #$F1F8,d0
                cmpi.w  #$C140,d0
                beq    .exgd
                cmpi.w  #$C148,d0
                beq    .exga
                cmpi.w  #$C188,d0
                beq    .exgda
                MN      "AND"
                bra     d_logic
.mulu           MN      "MULU.W"
                bra    .mul
.muls           MN      "MULS.W"
.mul            bsr     d_tab
                moveq   #1,d6
                move.w  #EA_DATA,d2
                bsr     d_ea_src
                bsr     d_comma
                bsr     d_reg9
                bra     d_dn
.abcd           MN      "ABCD"
                bra     d_bcdx
.exgd           bsr    .exg
                bsr     d_reg9
                bsr     d_dn
                bsr     d_comma
                bsr     d_reg0
                bra     d_dn
.exga           bsr    .exg
                bsr     d_reg9
                bsr     d_an
                bsr     d_comma
                bsr     d_reg0
                bra     d_an
.exgda          bsr    .exg
                bsr     d_reg9
                bsr     d_dn
                bsr     d_comma
                bsr     d_reg0
                bra     d_an
.exg            MN      "EXG"
                bra     d_tab

;============================================================ line E (shifts)
d_linee:
                move.w  d7,d0
                andi.w  #$C0,d0
                cmpi.w  #$C0,d0
                beq    .mem
                bsr     d_size
                move.w  d7,d0                   ; type in bits 4-3
                lsr.w   #3,d0
                bsr    .name
                bsr     d_sz
                bsr     d_tab
                btst    #5,d7
                bne    .cr
                move.b  #'#',(a1)+              ; count 1-8
                bsr     d_reg9
                bne    .c8
                moveq   #8,d0
.c8             addi.b  #'0',d0
                move.b  d0,(a1)+
                bra    .dst
.cr             bsr     d_reg9                  ; count in Dn
                bsr     d_dn
.dst            bsr     d_comma
                bsr     d_reg0
                bra     d_dn
.mem            btst    #11,d7
                bne     d_invalid
                move.w  d7,d0                   ; type in bits 10-9
                lsr.w   #8,d0
                lsr.w   #1,d0
                bsr    .name
                moveq   #1,d6
                bsr     d_sz
                bsr     d_tab
                move.w  #EA_MALT,d2
                bra     d_ea_src
; .name: D0 bits 1-0 = type (AS LS ROX RO), bit 8 of opcode = direction
.name           andi.w  #3,d0
                mulu.w  #3,d0
                lea     .n(pc,d0.w),a0
                move.b  (a0)+,(a1)+
                move.b  (a0)+,(a1)+
                move.b  (a0)+,d0
                cmpi.b  #' ',d0
                beq    .dir
                move.b  d0,(a1)+
.dir            move.b  #'R',(a1)+
                btst    #8,d7
                beq    .r
                move.b  #'L',-1(a1)
.r              rts
.n              dc.b    "AS LS ROXRO "
                even
