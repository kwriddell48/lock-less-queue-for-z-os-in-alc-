         TITLE 'MPMCQ - GETVERSION (product build/version string)'
*PROCESS GOFF
***********************************************************************
*  MPMCQ_VERSION.ASM
*
*  GETVERSION
*    Returns a version/build string for this product.
*
*  Timestamping:
*    - Uses HLASM system variables &SYSDATE and &SYSTIME, so the string is
*      stamped at ASSEMBLE TIME (not at runtime).
*
*  Calling:
*    R1 -> parm list (MPMCQ_GETVER_PLIST):
*      outAddr (F)          - 31-bit buffer address (or 0)
*      outMaxLen (F)        - max bytes to copy into outAddr
*      outActLenAddr (F)    - 31-bit address of fullword to receive actual length
*
*    Behavior:
*      - If outAddr == 0:
*          returns R1 = address of internal constant string
*                  R0 = length
*                  R15=0
*      - If outAddr != 0:
*          copies min(outMaxLen, length) bytes to outAddr,
*          stores full length at *outActLenAddr (if provided),
*          returns R15=0 if not truncated, R15=8 if truncated.
*
*  Reentrancy / RENT:
*    - Version string is constant.
*    - No writable static storage used.
***********************************************************************

         PRINT GEN
         ACONTROL OPTABLE(ZS5)

         COPY  'src/reg_equates.inc'
         COPY  'src/mpmcq_dsects.inc'

MPMCQVER CSECT
MPMCQVER AMODE 31
MPMCQVER RMODE ANY

         ENTRY GETVERSION
         USING MPMCQVER,R15

***********************************************************************
* Assemble-time stamped version string
***********************************************************************
VER_STR  DC    C'MPMCQ build &SYSDATE &SYSTIME'
VER_END  DS    0C
VER_LEN  EQU   VER_END-VER_STR

***********************************************************************
* GETVERSION(outAddr, outMaxLen, outActLenAddr)
***********************************************************************
GETVERSION DS 0H
         STM   R14,R12,12(R13)
         LR    R12,R15
         USING MPMCQVER,R12

         USING MPMCQ_GETVER_PLIST,R1

         L     R3,GVER_OUTADDR
         L     R4,GVER_OUTMAX

* If caller requested the pointer, return it directly.
         LT     R3,GVER_OUTADDR
         JNZ   GV_DO_COPY
         LA    R1,VER_STR
         LA    R0,VER_LEN
         XR    R15,R15
         L     R14,12(,R13)
         LM    R2,R12,28(,R13)
         BR    R14

GV_DO_COPY DS 0H
* Store actual/full length (if caller provided an address)
         LT    R5,GVER_OUTACTLENADDR
         JZ    GV_LEN_DONE
         LA    R0,VER_LEN
         ST    R0,0(R5)
GV_LEN_DONE DS 0H

* Compute copy length: copyLen = min(outMaxLen, VER_LEN)
         LA    R0,VER_LEN
         LR    R6,R0                    R6 = copyLen candidate
         CR    R4,R6
         JNL   GV_FITS
         LR    R6,R4                    copyLen = outMaxLen
         LA    R15,8                    truncated RC
         J     GV_HAVE_LEN
GV_FITS  DS 0H
         XR    R15,R15                  RC=0
GV_HAVE_LEN DS 0H

* Copy using MVCL with equal lengths so no padding occurs.
* Dest pair: R8/R9, Src pair: R10/R11
         LR    R8,R3
         LR    R9,R6
         LA    R10,VER_STR
         LR    R11,R6
         MVCL  R8,R10

         L     R14,12(,R13)
         LM    R2,R12,28(,R13)
         BR    R14

         END   MPMCQVER

