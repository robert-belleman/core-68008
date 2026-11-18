        org     $1000
; $1000: main loop with subroutine
main:   moveq   #0,d0
        moveq   #5,d7
.l      bsr     sub             ; $1004
        addq.l  #1,d0           ; $1008
        dbra    d7,.l           ; $100A
        moveq   #0,d0           ; exit
        trap    #15
sub:    addq.l  #1,d1           ; $1014
        rts
        org     $1100
buserr: move.b  $D0000,d0
        org     $1110
adrerr: move.w  $1001,d0
        org     $1120
divz:   moveq   #0,d1
        divu.w  d1,d0
        org     $1130
chk:    moveq   #-1,d0
        chk.w   #5,d0
        org     $1140
priv:   move.w  #$0000,sr       ; to user mode
        move.w  #$2700,sr       ; privilege violation
        org     $1150
linea:  dc.w    $A123
        org     $1160
linef:  dc.w    $F123
        org     $1170
trap3:  trap    #3
        org     $1180
illg:   illegal
        org     $1190
loop:   bra.s   loop
        org     $11A0
rst:    reset
        lea     msg(pc),a0
        moveq   #3,d0
        trap    #15
        moveq   #0,d0
        moveq   #42,d1
        trap    #15
msg:    dc.b    "after RESET ok",13,10,0
        even
        org     $1200
apit:   moveq   #2,d0           ; trace through TRAP #15
        moveq   #'X',d1
        trap    #15
        nop
        nop
        moveq   #0,d0
        trap    #15
        org     $1240
usr:    lea     $7E000,a0
        move.l  a0,usp
        andi.w  #$DFFF,sr       ; user mode
        moveq   #3,d0
        lea     umsg(pc),a0
        trap    #15
        moveq   #0,d0
        moveq   #7,d1
        trap    #15
umsg:   dc.b    "user mode ok",13,10,0
        even
        org     $1300
spur:   move.w  #$2000,sr
.w      bra.s   .w
        org     $1310
oddj:   jmp     $1001
        org     $1320
bigstk: lea     $1100,sp        ; SSP into user RAM below - legal
        moveq   #0,d0
        trap    #15
