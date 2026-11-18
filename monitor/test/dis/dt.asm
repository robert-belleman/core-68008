; disassemble COUNT 10-byte slots at $10000 through TRAP #15 DISASM
        org     $1000
start:  lea     $10000,a2
        move.l  #32768,d5
.loop   movea.l a2,a0
        lea     buf(pc),a1
        moveq   #13,d0
        trap    #15
        move.l  d0,d6
        move.l  a2,d1
        moveq   #5,d2
        moveq   #6,d0
        trap    #15
        moveq   #2,d0
        moveq   #' ',d1
        trap    #15
        move.l  d6,d1
        moveq   #7,d0
        trap    #15
        moveq   #2,d0
        moveq   #' ',d1
        trap    #15
        lea     buf(pc),a0
        moveq   #3,d0
        trap    #15
        moveq   #8,d0
        trap    #15
        lea     10(a2),a2
        subq.l  #1,d5
        bne     .loop
        moveq   #0,d0
        trap    #15
buf     ds.b    80
