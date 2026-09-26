         TITLE 'MPMCQ - Storage helpers (IARV64 payload, GETMAIN node fallback)'
*PROCESS GOFF
***********************************************************************
*  MPMCQ_STORAGE.ASM
*
*  Payload storage:
*    - Allocate/free 64-bit virtual storage for record payload bytes.
*    - NOTE: IARV64 GETSTOR allocates in 1MB segments (memory objects), so
*      small payloads are rounded up to 1MB. For high rates of small records,
*      prefer 31-bit payload mode or implement a 64-bit arena/suballocator.
*    - Intended to be called from AMODE 31 code; uses z/OS IARV64.
*
*  Entry points:
*    MPMCQ_PAYGET  - allocate 64-bit storage for LEN bytes (rounded to 1MB segments)
*    MPMCQ_PAYFREE - free 64-bit storage previously obtained
*
*  Interfaces (register-based, internal):
*    MPMCQ_PAYGET:
*      In : Q_R (R2) = QCBaddr (for owner TTOKEN)
*      In : R7 = length (fullword)
*      Out: R15=0 success, R8 contains 64-bit address (even reg)
*           R15=8 failure
*
*    MPMCQ_PAYFREE:
*      In : Q_R (R2) = QCBaddr (for owner TTOKEN)
*      In : R8 = 64-bit address (even reg)
*           R7 = length (fullword, ignored; kept for call-site compatibility)
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
         ACONTROL OPTABLE(ZS5)

         COPY  'src/reg_equates.inc'
         COPY  'src/mpmcq_dsects.inc'
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
GET64_SEGS   EQU GET64_TLEN                 * +0: AD segments count (1MB units)
GET64_ORIG   EQU GET64_TLEN+8               * +8: AD origin (returned)
GET64_WLEN   EQU GET64_TLEN+16              * total workarea length (plist + segs + origin)

FREE64_TEMPL DS  0D
         IARV64 MF=L
FREE64_TLEN  EQU *-FREE64_TEMPL
FREE64_MOS   EQU FREE64_TLEN                * +0: AD memobjstart (input)
FREE64_WLEN  EQU FREE64_TLEN+8              * total workarea length (plist + memobjstart)

***********************************************************************
* MPMCQ_PAYGET
***********************************************************************
MPMCQ_PAYGET DS 0H
* Leaf routine: does not use caller save area (R13) so it can be called
* from other MPMCQ entry points without overwriting their saved registers.
         LR    R11,R14                      save return address
         USING MPMCQ_QCB,Q_R

         LTR   R7,R7
         JNZ   PAYGET_DO
* Zero-length payload: return address 0
         XGR   R8,R8
         XR    R15,R15
         LR    R14,R11
         BR    R14

PAYGET_DO DS 0H
* Request 64-bit storage; return address in R8/R9 (R8 is even register).
* NOTE: Adjust operands to your required IARV64 policy (key, guard, etc.).
* Workarea lifetime: allocated before IARV64, freed before return (success/fail).
         LA    R4,GET64_WLEN
         GETMAIN RC,LV=(R4),LOC=ANY
         LTR   R15,R15
         JZ    PAYGET_WA_OK
* Could not allocate IARV64 parameter work area.
         XGR   R8,R8
         LA    R15,8
         LR    R14,R11
         BR    R14
PAYGET_WA_OK DS 0H
         LR    R10,R1                       R10 = workarea
* Copy MF=L template list to private work area (fast MVC; templates are <256B).
         LARL  R8,GET64_TEMPL               src addr (no base-reg dependency)
         MVC   0(GET64_TLEN,R10),0(R8)
*
* IARV64 GETSTOR allocates in 1MB segments. Compute:
*   segments = ceil(len / 1MB) = (len + (1MB-1)) >> 20
         LLGFR R0,R7
         LLILF R1,X'000FFFFF'               1MB-1
         ALGR  R0,R1
         SRLG  R0,R0,20
         STG   R0,GET64_SEGS(R10)
         XGR   R0,R0
         STG   R0,GET64_ORIG(R10)
*
         LA    R9,GET64_SEGS(R10)           SEGMENTS field address
         LA    R8,GET64_ORIG(R10)           ORIGIN field address
* Assign ownership to the jobstep TTOKEN captured at QINIT.
         LA    R6,QCB_OWNER_TTOKEN
         LR    R1,R10                       execute-form plist address
         IARV64 REQUEST=GETSTOR,COND=YES,SEGMENTS=(R9),TTOKEN=(R6),ORIGIN=(R8),MF=(E,(R1))
* Convention: if RC non-zero, return failure
         LTR   R15,R15
         JZ    PAYGET_OK
* Free work area before returning
         LA    R4,GET64_WLEN
         LR    R1,R10
         FREEMAIN RU,A=(R1),LV=(R4)
         LA    R15,8
         LR    R14,R11
         BR    R14

PAYGET_OK DS 0H
* Load returned ORIGIN (64-bit) into R8.
         LG    R8,GET64_ORIG(R10)
         LA    R4,GET64_WLEN
         LR    R1,R10
         FREEMAIN RU,A=(R1),LV=(R4)
         XR    R15,R15
         LR    R14,R11
         BR    R14

***********************************************************************
* MPMCQ_PAYFREE
***********************************************************************
MPMCQ_PAYFREE DS 0H
* Leaf routine: does not use caller save area (R13).
         LR    R11,R14                      save return address
         USING MPMCQ_QCB,Q_R

         LTR   R7,R7
         JZ    PAYFREE_DONE

         LA    R4,FREE64_WLEN
         GETMAIN RC,LV=(R4),LOC=ANY
         LTR   R15,R15
         JNZ   PAYFREE_DONE                best-effort; cannot detach without workarea
         LR    R10,R1                       R10 = workarea
* Copy MF=L template list to private work area (fast MVC; templates are <256B).
         LARL  R4,FREE64_TEMPL              src addr (no base-reg dependency)
         MVC   0(FREE64_TLEN,R10),0(R4)
         LR    R1,R10
* Free a 64-bit storage extent previously obtained by PAYGET.
         STG   R8,FREE64_MOS(R10)
         LA    R9,FREE64_MOS(R10)          MEMOBJSTART field address
* Specify the owner TTOKEN so any task can detach this memory object.
         LA    R6,QCB_OWNER_TTOKEN
         IARV64 REQUEST=DETACH,COND=YES,MEMOBJSTART=(R9),TTOKEN=(R6),MF=(E,(R1))
         LA    R4,FREE64_WLEN
         LR    R1,R10
         FREEMAIN RU,A=(R1),LV=(R4)

PAYFREE_DONE DS 0H
         XR    R15,R15
         LR    R14,R11
         BR    R14

         END   MPMCQSTO

