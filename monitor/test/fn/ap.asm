        org     $4000
        lea     prompt(pc),a0
        moveq   #3,d0
        trap    #15
        lea     buf(pc),a0
        moveq   #20,d1
        moveq   #5,d0           ; GETLINE
        trap    #15
        move.l  d0,d7           ; length
        moveq   #8,d0
        trap    #15
        lea     buf(pc),a0
        moveq   #3,d0
        trap    #15
        moveq   #8,d0
        trap    #15
        move.l  d7,d1
        moveq   #7,d0           ; PUTDEC
        trap    #15
        moveq   #8,d0
        trap    #15
        moveq   #14,d0          ; INFO
        trap    #15
        move.l  (a0),d1
        moveq   #8,d2
        moveq   #6,d0
        trap    #15
        moveq   #8,d0
        trap    #15
        moveq   #35,d1          ; SETVEC TRAP #3
        lea     t3(pc),a0
        moveq   #9,d0
        trap    #15
        move.l  a0,d1           ; old vector
        moveq   #8,d2
        moveq   #6,d0
        trap    #15
        moveq   #8,d0
        trap    #15
        trap    #3              ; user handler
        moveq   #1,d1           ; SETVEC 1 -> refused
        moveq   #9,d0
        trap    #15
        move.l  d0,d1
        moveq   #8,d2
        moveq   #6,d0
        trap    #15
        moveq   #8,d0
        trap    #15
        moveq   #99,d0          ; unknown
        trap    #15
        move.l  d0,d1
        moveq   #8,d2
        moveq   #6,d0
        trap    #15
        moveq   #8,d0
        trap    #15
.k      moveq   #15,d0          ; GETCNB until a key
        trap    #15
        tst.l   d0
        bmi     .k
        move.l  d0,d1
        moveq   #2,d0
        trap    #15
        moveq   #0,d0
        moveq   #0,d1
        trap    #15
t3:     move.l  d0,-(sp)
        lea     t3m(pc),a0
        moveq   #3,d0
        trap    #15
        move.l  (sp)+,d0
        rte
t3m     dc.b    "in TRAP #3 handler",13,10,0
prompt  dc.b    "name? ",0
        even
buf     ds.b    22
