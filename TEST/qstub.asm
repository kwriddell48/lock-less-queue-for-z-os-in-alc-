*PROCESS RENT,MACHINE(Z15)
         TITLE 'QSTUB - OS LIST TO QUEUE VALUES'
***********************************************************************
*  QSTUB. C BUILDS AN OS LIST OF ADDRESSES. THE QUEUE READS VALUES.
*  THE LAST OS WORD POINTS AT A 128-BYTE WORK BUFFER. THAT BUFFER
*  IS THE SAVE AREA (SO THE CALLEE CAN STM) AND THE VALUE LIST AT
*  OFFSET 96. TSTCB IS THE NOTIFIER EXIT AND DOES NOT STM.
*  CTX+0 CALLS, CTX+4 LAST PENDING, CTX+8 ECB.
***********************************************************************
         PRINT GEN
         COPY  REGS
QSTUB    CSECT
QSTUB    AMODE 31
QSTUB    RMODE ANY
         USING QSTUB,R12
         ENTRY QINITC
         ENTRY QENQC
         ENTRY QDEQC
         ENTRY QSTATC
         ENTRY QSTOPC
         ENTRY WAITECB
         ENTRY TSTCB
         ENTRY SLOWCB
QINITC   DS    0H
         STM   R14,R12,12(R13)
         LARL  R12,QSTUB
         LHI   R8,6
         L     R9,VINIT
         J     CALLV
QENQC    DS    0H
         STM   R14,R12,12(R13)
         LARL  R12,QSTUB
         LHI   R8,3
         L     R9,VENQ
         J     CALLV
QDEQC    DS    0H
         STM   R14,R12,12(R13)
         LARL  R12,QSTUB
         LHI   R8,4
         L     R9,VDEQ
         J     CALLV
QSTATC   DS    0H
         STM   R14,R12,12(R13)
         LARL  R12,QSTUB
         LHI   R8,3
         L     R9,VSTAT
         J     CALLV
QSTOPC   DS    0H
         STM   R14,R12,12(R13)
         LARL  R12,QSTUB
         LHI   R8,1
         L     R9,VSTOP
         J     CALLV
*  R8=VALUE COUNT. R9=TARGET. R1=OS LIST. WORK IS THE NEXT WORD.
CALLV    DS    0H
         LR    R11,R1
         LR    R4,R8
         SLL   R4,2
         L     R10,0(R4,R11)
         NILF  R10,X'7FFFFFFF'
         L     R10,0(,R10)
         XC    0(72,R10),0(R10)
         ST    R13,4(,R10)
         ST    R10,8(,R13)
         LR    R13,R10
         LA    R7,96(,R13)
         LR    R6,R8
CWORD    DS    0H
         L     R2,0(,R11)
         NILF  R2,X'7FFFFFFF'
         L     R2,0(,R2)
         ST    R2,0(,R7)
         AHI   R11,4
         AHI   R7,4
         BCT   R6,CWORD
         LA    R1,96(,R13)
         BALR  R14,R9
         LR    R5,R15
         L     R13,4(,R13)
         ST    R5,16(,R13)
         L     R14,12(,R13)
         LM    R2,R12,28(R13)
         L     R15,16(,R13)
         BR    R14
*  SVC 1 WAITS FOR ONE EVENT. R0 MUST BE 1.
*  R1 IS THE ECB ADDRESS. THE HIGH BIT STAYS OFF.
WAITECB  DS    0H
         STM   R14,R12,12(R13)
         L     R1,0(,R1)
         NILF  R1,X'7FFFFFFF'
         L     R1,0(,R1)
         LHI   R0,1
         SVC   1
         L     R14,12(,R13)
         LM    R2,R12,28(R13)
         XR    R15,R15
         BR    R14
*  VALUE LIST FROM THE NOTIFIER. PRESERVE R2 R10 R12 R13 R14.
TSTCB    DS    0H
         L     R3,0(,R1)
         L     R4,8(,R1)
         ST    R4,4(,R3)
         LHI   R0,1
         LAAL  R15,R0,0(R3)
         XR    R0,R0
         LA    R1,8(,R3)
         SVC   2
         BR    R14
*  SLOW CALLBACK. CTX+0 CALLS, +4 PENDING SUM, +8 MAX,
*  +12 MILLISECONDS TO SPIN (0 SKIPS THE SPIN).
*  PRESERVE R2 R10 R12 R13 R14. TOD USES CTX+16 AND +24.
SLOWCB   DS    0H
         L     R3,0(,R1) CTX
         L     R4,8(,R1) PENDING
         LHI   R0,1
         LAAL  R15,R0,0(R3) COUNT THE CALL
         LAAL  R15,R4,4(R3) ADD PENDING TO THE SUM
SLOWMX   L     R5,8(,R3)
         CR    R4,R5
         JNH   SLOWSP
         CS    R5,R4,8(R3)
         JNE   SLOWMX
SLOWSP   L     R5,12(,R3) MILLISECONDS
         LTR   R5,R5
         BZ    SLOWX
         MHI   R5,1000 MICROSECONDS
         SLL   R5,12 TOD UNITS PER MICROSECOND
         STCK  16(R3)
SLOWWT   STCK  24(R3)
         LG    R6,24(R3)
         LG    R7,16(R3)
         SLGR  R6,R7
         LLGFR R8,R5
         CLGR  R6,R8
         JL    SLOWWT
SLOWX    BR    R14
         DS    0F
VINIT    DC    V(QINIT)
VENQ     DC    V(QENQ)
VDEQ     DC    V(QDEQ)
VSTAT    DC    V(QSTATS)
VSTOP    DC    V(QCBSTOP)
         END   QSTUB
