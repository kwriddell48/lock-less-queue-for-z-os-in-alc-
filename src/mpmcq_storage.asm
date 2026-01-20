         TITLE 'MPMCQ - Storage helpers (IARV64 payload, GETMAIN node fallback)'
***********************************************************************
*  MPMCQ_STORAGE.ASM
*
*  Payload storage:
*    - Allocate/free 64-bit virtual storage for record payload bytes.
*    - Intended to be called from AMODE 31 code; uses z/OS IARV64.
*
*  Entry points:
*    MPMCQ_PAYGET  - allocate 64-bit storage for LEN bytes
*    MPMCQ_PAYFREE - free 64-bit storage previously obtained
*
*  Interfaces (register-based, internal):
*    MPMCQ_PAYGET:
*      In : R7 = length (fullword)
*      Out: R15=0 success, R8 contains 64-bit address (even reg)
*           R15=8 failure
*
*    MPMCQ_PAYFREE:
*      In : R8 = 64-bit address (even reg)
*           R7 = length (fullword)
*      Out: R15=0 best-effort
*
*  IMPORTANT:
*    The exact IARV64 operands vary by release/options. This module uses
*    a common MF=(L/E) pattern and documents the intent. You may need to
*    adjust macro operands to match your shop’s z/OS level and standards.
*
*  Reentrancy / RENT:
*    - IARV64 MF=L parameter lists are writable, so they must NOT be shared.
*    - We keep MF=L templates in the CSECT and copy them into a per-call
*      GETMAINed work area, then execute IARV64 with MF=(E,(workarea)).
***********************************************************************

         PRINT GEN

         COPY  'src/reg_equates.inc'
MPMCQSTO CSECT
MPMCQSTO AMODE 31
MPMCQSTO RMODE ANY

         ENTRY MPMCQ_PAYGET
         ENTRY MPMCQ_PAYFREE

         USING MPMCQSTO,R15

***********************************************************************
* IARV64 parameter lists
***********************************************************************
* IMPORTANT FOR REENTRANCY:
* - Do NOT use a single shared MF=L list directly (it is writable).
* - Keep a template in the CSECT and copy it to a private work area per call.
* - Use MF=(E,(workarea)) so each caller has isolated parameter storage.

GET64_TEMPL  DS  0D
* The following MF=L expansion is a TEMPLATE only.
         IARV64 MF=L
GET64_TLEN   EQU *-GET64_TEMPL

FREE64_TEMPL DS  0D
         IARV64 MF=L
FREE64_TLEN  EQU *-FREE64_TEMPL

***********************************************************************
* MPMCQ_PAYGET
***********************************************************************
MPMCQ_PAYGET DS 0H
         STM   R14,R12,12(R13)
         LR    R12,R15
         USING MPMCQSTO,12

         LTR   R7,R7
         BNZ   PAYGET_DO
* Zero-length payload: return address 0
         XR    R8,R8
         XR    R9,R9
         XR    R15,R15
         LM    R14,R12,12(R13)
         BR    R14

PAYGET_DO DS 0H
* Request 64-bit storage; return address in R8/R9 (R8 is even register).
* NOTE: Adjust operands to your required IARV64 policy (key, guard, etc.).
* Workarea lifetime: allocated before IARV64, freed before return (success/fail).
         LA    R4,GET64_TLEN
         GETMAIN RU,LV=(R4),LOC=BELOW
         LR    R10,R1                       R10 = workarea
         MVC   0(GET64_TLEN,R10),GET64_TEMPL
         LR    R1,R10
         IARV64 REQUEST=GETSTOR,COND=YES,LENGTH=(R7),ORIGIN=(R8),MF=(E,(R1))
* Convention: if RC non-zero, return failure
         LTR   R15,R15
         BZ    PAYGET_OK
* Free work area before returning
         LA    R4,GET64_TLEN
         LR    R1,R10
         FREEMAIN RU,A=(R1),LV=(R4)
         LA    R15,8
         LM    R14,R12,12(R13)
         BR    R14

PAYGET_OK DS 0H
         LA    R4,GET64_TLEN
         LR    R1,R10
         FREEMAIN RU,A=(R1),LV=(R4)
         XR    R15,R15
         LM    R14,R12,12(R13)
         BR    R14

***********************************************************************
* MPMCQ_PAYFREE
***********************************************************************
MPMCQ_PAYFREE DS 0H
         STM   R14,R12,12(R13)
         LR    R12,R15
         USING MPMCQSTO,12

         LTR   R7,R7
         BZ    PAYFREE_DONE

         LA    R4,FREE64_TLEN
         GETMAIN RU,LV=(R4),LOC=BELOW
         LR    R10,R1                       R10 = workarea
         MVC   0(FREE64_TLEN,R10),FREE64_TEMPL
         LR    R1,R10
* Free a 64-bit storage extent previously obtained by PAYGET.
         IARV64 REQUEST=FREESTOR,ORIGIN=(R8),LENGTH=(R7),MF=(E,(R1))
         LA    R4,FREE64_TLEN
         LR    R1,R10
         FREEMAIN RU,A=(R1),LV=(R4)

PAYFREE_DONE DS 0H
         XR    R15,R15
         LM    R14,R12,12(R13)
         BR    R14

         END   MPMCQSTO

