*PROCESS RENT,MACHINE(Z15)
         TITLE 'T24HGPR - HIGH HALF PRESERVE'
***********************************************************************
*  BITS 0-31 OF R2-R12 ARE X'DEADBEEF' ACROSS EACH CALL.
*  QINIT, QENQ, QDEQ, QSTATS, AND QCBSTOP MUST LEAVE THEM.
*  R15=0 PASS. R15=2..12 IS THE REGISTER THAT CHANGED.
*  R15=100+API RC WHEN A CALL FAILS. EMPTY DEQ IS RC 4.
***********************************************************************
         PRINT NOGEN
         MACRO
         SETGH
         IIHF  R2,X'DEADBEEF'
         IIHF  R3,X'DEADBEEF'
         IIHF  R4,X'DEADBEEF'
         IIHF  R5,X'DEADBEEF'
         IIHF  R6,X'DEADBEEF'
         IIHF  R7,X'DEADBEEF'
         IIHF  R8,X'DEADBEEF'
         IIHF  R9,X'DEADBEEF'
         IIHF  R10,X'DEADBEEF'
         IIHF  R11,X'DEADBEEF'
         IIHF  R12,X'DEADBEEF'
         MEND
         MACRO
         CHKREG &R,&N
         SRLG  R0,&R,32
         CLFI  R0,X'DEADBEEF'
         JE    C&SYSNDX
         LHI   R15,&N
         J     FAIL
C&SYSNDX DS    0H
         MEND
T24HGPR  CSECT
T24HGPR  AMODE 31
T24HGPR  RMODE ANY
         STM   R14,R12,12(R13)
         LR    R11,R13
         LARL  R12,T24HGPR
         USING T24HGPR,R12
         LA    R13,SAVE
         ST    R11,4(,R13)
         ST    R13,8(,R11)
         LHI   R0,4096
         GETMAIN R,LV=(0)
         LA    R2,255(,R1)
         NILF  R2,X'FFFFFF00'
         ST    R2,QCB
         MVC   SRC(8),=C'HGPRTEST'
         MVC   SLAB(16),=CL16'SLABSLABSLABSLAB'
         LHI   R0,65537
         GETMAIN R,LV=(0)
         ST    R1,BIGA
         MVC   0(8,R1),=C'IARV64..'
*  QINIT POOL 4, NO CALLBACK
         MVC   PL(24),=6F'0'
         MVC   PL(4),QCB
         LHI   R0,4
         ST    R0,PL+8
         SETGH
         LA    R1,PL
         L     R15,=V(QINIT)
         BALR  R14,R15
         LTR   R15,R15
         JNZ   FAILRC
         BAL   R14,CHKALL
*  INLINE
         MVC   PL(12),=3F'0'
         MVC   PL(4),QCB
         LA    R0,SRC
         ST    R0,PL+4
         LHI   R0,8
         ST    R0,PL+8
         SETGH
         LA    R1,PL
         L     R15,=V(QENQ)
         BALR  R14,R15
         LTR   R15,R15
         JNZ   FAILRC
         BAL   R14,CHKALL
         MVC   PL(16),=4F'0'
         MVC   PL(4),QCB
         LA    R0,DST
         ST    R0,PL+4
         LHI   R0,8
         ST    R0,PL+8
         LA    R0,OUTL
         ST    R0,PL+12
         SETGH
         LA    R1,PL
         L     R15,=V(QDEQ)
         BALR  R14,R15
         LTR   R15,R15
         JNZ   FAILRC
         BAL   R14,CHKALL
*  2K SLAB
         MVC   PL(12),=3F'0'
         MVC   PL(4),QCB
         LA    R0,SLAB
         ST    R0,PL+4
         LHI   R0,2048
         ST    R0,PL+8
         SETGH
         LA    R1,PL
         L     R15,=V(QENQ)
         BALR  R14,R15
         LTR   R15,R15
         JNZ   FAILRC
         BAL   R14,CHKALL
         MVC   PL(16),=4F'0'
         MVC   PL(4),QCB
         LA    R0,SLAB
         ST    R0,PL+4
         LHI   R0,2048
         ST    R0,PL+8
         LA    R0,OUTL
         ST    R0,PL+12
         SETGH
         LA    R1,PL
         L     R15,=V(QDEQ)
         BALR  R14,R15
         LTR   R15,R15
         JNZ   FAILRC
         BAL   R14,CHKALL
*  IARV64 65537
         MVC   PL(12),=3F'0'
         MVC   PL(4),QCB
         L     R0,BIGA
         ST    R0,PL+4
         L     R0,=F'65537'
         ST    R0,PL+8
         SETGH
         LA    R1,PL
         L     R15,=V(QENQ)
         BALR  R14,R15
         LTR   R15,R15
         JNZ   FAILRC
         BAL   R14,CHKALL
         MVC   PL(16),=4F'0'
         MVC   PL(4),QCB
         L     R0,BIGA
         ST    R0,PL+4
         L     R0,=F'65537'
         ST    R0,PL+8
         LA    R0,OUTL
         ST    R0,PL+12
         SETGH
         LA    R1,PL
         L     R15,=V(QDEQ)
         BALR  R14,R15
         LTR   R15,R15
         JNZ   FAILRC
         BAL   R14,CHKALL
*  EMPTY. RC 4 IS SUCCESS HERE.
         MVC   PL(16),=4F'0'
         MVC   PL(4),QCB
         LA    R0,DST
         ST    R0,PL+4
         LHI   R0,8
         ST    R0,PL+8
         LA    R0,OUTL
         ST    R0,PL+12
         SETGH
         LA    R1,PL
         L     R15,=V(QDEQ)
         BALR  R14,R15
         CHI   R15,4
         JNE   FAILRC
         BAL   R14,CHKALL
         MVC   PL(12),=3F'0'
         MVC   PL(4),QCB
         LA    R0,STATS
         ST    R0,PL+4
         LHI   R0,80
         ST    R0,PL+8
         SETGH
         LA    R1,PL
         L     R15,=V(QSTATS)
         BALR  R14,R15
         LTR   R15,R15
         JNZ   FAILRC
         BAL   R14,CHKALL
         MVC   PL(4),QCB
         SETGH
         LA    R1,PL
         L     R15,=V(QCBSTOP)
         BALR  R14,R15
         LTR   R15,R15
         JNZ   FAILRC
         BAL   R14,CHKALL
         WTO   'T24HGPR PASS'
         XR    R15,R15
         J     LEAVE
FAILRC   AHI   R15,100
         ST    R15,KEEPRC
         WTO   'T24HGPR FAIL RC'
         J     GOOUT
FAIL     ST    R15,KEEPRC
         WTO   'T24HGPR FAIL REG'
         J     GOOUT
LEAVE    ST    R15,KEEPRC
GOOUT    L     R1,4(,R13)
         L     R14,12(,R1)
         L     R15,KEEPRC
         LR    R13,R1
         LM    R2,R12,28(R13)
         BR    R14
CHKALL   CHKREG R2,2
         CHKREG R3,3
         CHKREG R4,4
         CHKREG R5,5
         CHKREG R6,6
         CHKREG R7,7
         CHKREG R8,8
         CHKREG R9,9
         CHKREG R10,10
         CHKREG R11,11
         CHKREG R12,12
         BR    R14
         LTORG
SAVE     DS    18F
KEEPRC   DS    F
PL       DS    6F
QCB      DS    F
OUTL     DS    F
SRC      DS    CL8
DST      DS    CL8
SLAB     DS    CL2048
BIGA     DS    F
STATS    DS    20F
         END   T24HGPR
