         TITLE 'MPMCQ public API include (entry points + sizes)'
***********************************************************************
*  MPMCQ_API.INC
*
*  For application programmers:
*    - Include this ONE file to get:
*      - Register equates
*      - QCB/Node/Stats/parm-list DSECTs
*      - Public entry point externals
*      - Useful size/equate aliases for allocation
*
*  Usage:
*    COPY 'src/mpmcq_api.inc'
*
*  Notes:
*    - QCB storage is owned by the caller; allocate at least MPMCQ_QCB_LEN bytes.
*    - QCB address passed to QINIT must be 256-byte aligned (QINIT enforces this).
*    - Options for QINIT are in src/mpmcq_dsects.inc (MPMCQ_OPT_*).
***********************************************************************

***********************************************************************
* Include guard (prevents multiple inclusion redefinition errors)
***********************************************************************
         GBLB  &MPMCQ_API_INCLUDED
         AIF   (&MPMCQ_API_INCLUDED).MPMCQAPI_END
&MPMCQ_API_INCLUDED SETB  1

***********************************************************************
* Inline register equates (from src/reg_equates.inc)
***********************************************************************
R0       EQU   0
R1       EQU   1
R2       EQU   2
R3       EQU   3
R4       EQU   4
R5       EQU   5
R6       EQU   6
R7       EQU   7
R8       EQU   8
R9       EQU   9
R10      EQU   10
R11      EQU   11
R12      EQU   12
R13      EQU   13
R14      EQU   14
R15      EQU   15

Q_R        EQU   R2
NODE_R     EQU   R10
NEWNODE_R  EQU   R5
NEXTNODE_R EQU   R3

***********************************************************************
* Inline DSECTs + option equates (from src/mpmcq_dsects.inc)
***********************************************************************

MPMCQ_EQUATES          EQU   *
MPMCQ_STATS_VERSION    EQU   1
MPMCQ_MAX_REC_LEN      EQU   16777215        * MVCL length limit (24 bits): 16MB-1
MPMCQ_MAX_REC31_LEN    EQU   16384           * payload31 max (largest pool tier); avoids cross-task FREEMAIN

***********************************************************************
* QINIT option bits (QINIT_OPTIONS fullword)
***********************************************************************
MPMCQ_OPT_PAYLOAD31    EQU   X'00000000'  * default: payload allocated below 2G (cell pools; slab GETMAIN RC,LOC=ANY)
MPMCQ_OPT_PAYLOAD64    EQU   X'00000001'  * payload allocated in 64-bit storage (IARV64)

***********************************************************************
* Queue Control Block (QCB)
***********************************************************************
MPMCQ_QCB              DSECT
QCB_EYECATCH           DS    CL8               'MPMCQCB '
QCB_NAME               DS    CL16              user-assigned queue name
QCB_VERSION            DS    F                 version
QCB_FLAGS              DS    F                 runtime flags

* Async callback configuration (read-only after QINIT)
QCB_CB_EP              DS    F                 callback entry point (AMODE 31)
QCB_CB_CTX             DS    F                 user context pointer (31-bit)
QCB_USER_ECB           DS    F                 optional user ECB to POST per ENQ
QCB_OWNER_TCB          DS    F                 owner TCB addr (captured at QINIT)
QCB_OWNER_TTOKEN       DS    CL16              jobstep TTOKEN (IARV64 ownership)

* QCB layout uses ORG to place hot fields on 256-byte groups and ensure
* 8-byte alignment of (ABA,PTR) pairs for CDS.
* NOTE: QINIT enforces that the QCB base is 256-byte aligned so these ORG
* groups land on 256-byte boundaries as intended.
         ORG   MPMCQ_QCB+256
QCB_HEAD_ABA           DS    F                 ABA tag
QCB_HEAD_PTR           DS    F                 ptr to head node (31-bit)

         ORG   MPMCQ_QCB+512
QCB_TAIL_ABA           DS    F                 ABA tag
QCB_TAIL_PTR           DS    F                 ptr to tail node (31-bit)

         ORG   MPMCQ_QCB+768
QCB_FREE_ABA           DS    F                 ABA tag (node pool head)
QCB_FREE_PTR           DS    F                 ptr to free node

         ORG   MPMCQ_QCB+1024
QCB_PAY256_ABA         DS    F                 ABA tag (payload<=256 pool head)
QCB_PAY256_PTR         DS    F                 ptr to 256-byte payload cell
QCB_PAY1024_ABA        DS    F                 ABA tag (payload<=1024 pool head)
QCB_PAY1024_PTR        DS    F                 ptr to 1024-byte payload cell
QCB_PAY4096_ABA        DS    F                 ABA tag (payload<=4096 pool head)
QCB_PAY4096_PTR        DS    F                 ptr to 4096-byte payload cell
QCB_PAY16384_ABA       DS    F                 ABA tag (payload<=16384 pool head)
QCB_PAY16384_PTR       DS    F                 ptr to 16384-byte payload cell

         ORG   MPMCQ_QCB+1280
QCB_CB_ECB             DS    F                 internal ECB (fullword)
QCB_TERM_ECB           DS    F                 notifier termination ECB (posted at subtask end)
QCB_CB_ARMED           DS    F                 notifier armed flag (1=waiting/arming)
QCB_ENQ_SEQ            DS    F                 enqueue sequence (monotonic)
QCB_CB_SEQ_SEEN        DS    F                 last processed by notifier
QCB_CB_TCB             DS    F                 notifier TCB addr (optional)
QCB_ABA_SEQ            DS    F                 reserved (no longer used; tags are old+1)

         ORG   MPMCQ_QCB+1536
QCB_STAT_ALIGN         DS    0D

QCB_STAT_ENQ_OK        DS    F
QCB_STAT_DEQ_OK        DS    F
QCB_STAT_DEQ_EMPTY     DS    F
QCB_STAT_ENQ_ALLOC_FAIL DS   F

QCB_STAT_ENQ_RETRY     DS    F
QCB_STAT_DEQ_RETRY     DS    F
QCB_STAT_FREELIST_POP_RETRY DS F
QCB_STAT_FREELIST_PUSH_RETRY DS F

QCB_STAT_QDEPTH_CUR    DS    F
QCB_STAT_QDEPTH_MAX    DS    F

* Payload byte usage (doubleword, updated via interlocked add)
* - PAYLOAD31_*: bytes reserved for payload in 31-bit mode
*                (size-class cell size; this build rejects payload31 records > 16384)
* - PAYLOAD64_*: bytes allocated in 64-bit virtual storage (IARV64, 1MB segments)
QCB_STAT_PAYLOAD31_CUR_HI DS  F
QCB_STAT_PAYLOAD31_CUR_LO DS  F
QCB_STAT_PAYLOAD31_MAX_HI DS  F
QCB_STAT_PAYLOAD31_MAX_LO DS  F

QCB_STAT_PAYLOAD64_CUR_HI DS  F
QCB_STAT_PAYLOAD64_CUR_LO DS  F
QCB_STAT_PAYLOAD64_MAX_HI DS  F
QCB_STAT_PAYLOAD64_MAX_LO DS  F

QCB_STAT_POST_INTERNAL DS   F
QCB_STAT_POST_USERECB DS   F
QCB_STAT_CB_CALLS      DS   F
QCB_STAT_CB_PENDING_MAX DS  F

* Transaction diagnostic block. See src/mpmcq_dsects.inc.
         ORG   MPMCQ_QCB+1792
QCB_TDB                DS    0D
QCB_TDB_PFX            DS    XL6
QCB_TDB_TAC            DS    H
QCB_TDB_ATIA           DS    D
QCB_TDB_TAIL           DS    CL240

         ORG   MPMCQ_QCB+2048
QCB_SIZE               EQU   *-MPMCQ_QCB

***********************************************************************
* Node layout (31-bit storage)
***********************************************************************
MPMCQ_NODE             DSECT
NODE_ALIGN0            DS    0D
NODE_CNT_INT           DS    F
NODE_CNT_EXT           DS    F
NODE_NEXT_ABA          DS    F
NODE_NEXT_PTR          DS    F
NODE_FREE_ABA          DS    F
NODE_FREE_PTR          DS    F
NODE_PAYLOAD64         DS    D
NODE_PAYLOAD_LEN       DS    F
NODE_RSVD              DS    F
NODE_SIZE              EQU   *-MPMCQ_NODE

***********************************************************************
* QSTATS snapshot layout (caller buffer)
***********************************************************************
MPMCQ_STATS             DSECT
STATS_VERSION           DS   F
STATS_SIZE              DS   F
STATS_ENQ_OK            DS   F
STATS_DEQ_OK            DS   F
STATS_DEQ_EMPTY         DS   F
STATS_ENQ_ALLOC_FAIL    DS   F
STATS_ENQ_RETRY         DS   F
STATS_DEQ_RETRY         DS   F
STATS_FREELIST_POP_RETRY DS  F
STATS_FREELIST_PUSH_RETRY DS F
STATS_QDEPTH_CUR        DS   F
STATS_QDEPTH_MAX        DS   F
STATS_PAYLOAD31_CUR     DS   D
STATS_PAYLOAD31_MAX     DS   D
STATS_PAYLOAD64_CUR     DS   D
STATS_PAYLOAD64_MAX     DS   D
STATS_POST_INTERNAL     DS   F
STATS_POST_USERECB      DS   F
STATS_CB_CALLS          DS   F
STATS_CB_PENDING_MAX    DS   F
STATS_RSVD              DS   0D
STATS_END               EQU  *

***********************************************************************
* Parameter lists (R1 -> parm list)
***********************************************************************
MPMCQ_QINIT_PLIST       DSECT
QINIT_QCBADDR           DS   F
QINIT_OPTIONS           DS   F
QINIT_CB_EP             DS   F
QINIT_CB_CTX            DS   F
QINIT_USER_ECB          DS   F

MPMCQ_QENQ_PLIST        DSECT
ENQ_QCBADDR             DS   F
ENQ_SRCADDR             DS   F
ENQ_SRCLEN              DS   F

MPMCQ_QDEQ_PLIST        DSECT
DEQ_QCBADDR             DS   F
DEQ_DSTADDR             DS   F
DEQ_DSTMAX              DS   F
DEQ_OUTLENADDR          DS   F

MPMCQ_QSTATS_PLIST      DSECT
QST_QCBADDR             DS   F
QST_OUTADDR             DS   F
QST_OUTLEN              DS   F

MPMCQ_GETVER_PLIST      DSECT
GVER_OUTADDR            DS   F
GVER_OUTMAX             DS   F
GVER_OUTACTLENADDR      DS   F

MPMCQ_CB_PLIST          DSECT
CBP_CTX                 DS   F
CBP_QCB                 DS   F
CBP_PENDING             DS   F

***********************************************************************
* Public entry points (load module exports)
***********************************************************************
         EXTRN QINIT
         EXTRN QENQ
         EXTRN QDEQ
         EXTRN QSTATS
         EXTRN QCBSTOP
         EXTRN GETVERSION

***********************************************************************
* Usage examples (comments only)
*
* These examples show what the parameter lists "look like" in a C-like form
* and how a caller would typically set them up in HLASM (R1 -> parm list).
*
* IMPORTANT:
* - All addresses shown are 31-bit unless explicitly stated.
* - QCB storage is caller-owned; allocate at least MPMCQ_QCB_LEN bytes.
***********************************************************************
*
* ---------------------------------------------------------------------
* QINIT(QCBaddr, options, CB_EP, CB_CTX, USER_ECB)
* ---------------------------------------------------------------------
* C-like parameter list:
*
*   struct QINIT_PLIST {
*     uint32_t qcbAddr;     // -> QCB storage (MPMCQ_QCB_LEN bytes)
*     uint32_t options;     // MPMCQ_OPT_PAYLOAD31 (default) or MPMCQ_OPT_PAYLOAD64
*     uint32_t cb_ep;       // 0 = no notifier TCB callback; else entry point
*     uint32_t cb_ctx;      // user context value passed to callback
*     uint32_t user_ecb;    // 0 = none; else ECB address to POST on each ENQ
*   };
*
* Return code (R15):
*   0  = success
*   8  = payload64 requested but jobstep TTOKEN unavailable (init failed)
*  16  = payload64 requested but IARV64 GETSTOR/DETACH probe failed (environment not usable)
*  12  = QCB misaligned (must be 256-byte aligned; preserves cache geometry and CDS alignment)
*  !=0 = notifier start failure (IDENTIFY/ATTACH); rc returned from MPMCQ_NSTART
*
* HLASM sketch:
*
*   * IMPORTANT: QCB must be 256-byte aligned (QINIT enforces this).
*   * A common pattern is to GETMAIN extra and round up to a 256B boundary:
*          LA    R4,MPMCQ_QCB_LEN+255
*          GETMAIN RU,LV=(R4),LOC=ANY
*          LR    R5,R1                      ; base
*          AHI   R5,255
*          NILF  R5,X'FFFFFF00'             ; R5 = 256B-aligned QCB address
*   * Then pass A(R5) as the QCB address to QINIT.
*   QINITPL DS  0F
*          DS  F                           ; qcbAddr (filled at runtime)
*          DC  F(MPMCQ_OPT_PAYLOAD31)     ; or MPMCQ_OPT_PAYLOAD64
*          DC  A(0)                       ; cb_ep (0 = none)
*          DC  A(0)                       ; cb_ctx
*          DC  A(MYECB)                   ; user ECB (optional)
*          ST  R5,QINITPL                 ; store qcbAddr
*   LA   R1,QINITPL
*   CALL QINIT
*
* Callback signature (if cb_ep != 0):
*   struct CB_PLIST { uint32_t cb_ctx; uint32_t qcbAddr; uint32_t pendingCount; };
*
* ---------------------------------------------------------------------
* QENQ(QCBaddr, srcAddr, srcLen)
* ---------------------------------------------------------------------
* C-like parameter list:
*
*   struct QENQ_PLIST {
*     uint32_t qcbAddr;
*     uint32_t srcAddr;   // -> bytes to copy into the queue
*     uint32_t srcLen;    // length in bytes
*   };
*
* Return code (R15):
*   0 = success
*   8 = allocation failure
*  12 = record too large for this build:
*       - payload31 mode: srcLen > 16384 (largest pool tier)
*       - payload64 mode: srcLen > 16MB-1 (MVCL limitation)
*
* HLASM sketch:
*   ENQPL  DS 0F
*         DC A(QCB)
*         DC A(SRCBUF)
*         DC F(SRCLEN)
*   LA  R1,ENQPL
*   CALL QENQ
*
* ---------------------------------------------------------------------
* QDEQ(QCBaddr, dstAddr, dstMaxLen, outLenAddr)
* ---------------------------------------------------------------------
* C-like parameter list:
*
*   struct QDEQ_PLIST {
*     uint32_t qcbAddr;
*     uint32_t dstAddr;        // -> caller buffer
*     uint32_t dstMaxLen;      // max bytes to copy
*     uint32_t outLenAddr;     // -> uint32_t to receive ACTUAL message length
*   };
*
* Return code (R15):
*   4 = empty
*   0 = success (full message copied)
*   8 = truncated (copied dstMaxLen bytes; *outLenAddr = actualLen)
*
* HLASM sketch:
*   OUTLEN  DS  F
*   DEQPL   DS  0F
*          DC  A(QCB)
*          DC  A(DSTBUF)
*          DC  F(DSTMAX)
*          DC  A(OUTLEN)
*   LA  R1,DEQPL
*   CALL QDEQ
*
* ---------------------------------------------------------------------
* QSTATS(QCBaddr, outStatsAddr, outStatsLen)
* ---------------------------------------------------------------------
* C-like parameter list:
*
*   struct QSTATS_PLIST {
*     uint32_t qcbAddr;
*     uint32_t outStatsAddr;   // -> struct MPMCQ_STATS buffer
*     uint32_t outStatsLen;    // bytes available at outStatsAddr
*   };
*
* HLASM sketch:
*   STBUF  DS  CL(MPMCQ_STATS_LEN)
*   STPL   DS  0F
*         DC  A(QCB)
*         DC  A(STBUF)
*         DC  F(MPMCQ_STATS_LEN)
*   LA  R1,STPL
*   CALL QSTATS
*
* ---------------------------------------------------------------------
* QCBSTOP(QCBaddr)
* ---------------------------------------------------------------------
* Stops the notifier TCB (if one was started).
* Requirements:
* - Must be issued from the SAME task that called QINIT (it DETACHes the subtask).
* - This call POSTs the notifier, then WAITs for it to end (via QCB_TERM_ECB),
*   then DETACHes it.
* - QCBSTOP does not FREEMAIN node/payload slabs; those GETMAIN RC pools stay
*   owned by the allocating TCB(s). Keep the QINIT task alive until no
*   producer/consumer can still reference a cell.
*
* C-like parameter list:
*   struct QCBSTOP_PLIST { uint32_t qcbAddr; };
*
* HLASM sketch:
*   STPPL  DS  0F
*         DC  A(QCB)
*   LA  R1,STPPL
*   CALL QCBSTOP
*
* ---------------------------------------------------------------------
* GETVERSION(outAddr, outMaxLen, outActLenAddr)
* ---------------------------------------------------------------------
* Returns an assemble-time-stamped build string.
*
* C-like parameter list:
*
*   struct GETVER_PLIST {
*     uint32_t outAddr;        // 0 => return pointer in R1 and length in R0
*     uint32_t outMaxLen;      // max bytes to copy if outAddr != 0
*     uint32_t outActLenAddr;  // -> uint32_t receives full length (optional, may be 0)
*   };
*
* HLASM sketch (copy into caller buffer):
*   VLEN   DS  F
*   VBUF   DS  CL64
*   VPL    DS  0F
*         DC  A(VBUF)
*         DC  F(L'VBUF)
*         DC  A(VLEN)
*   LA  R1,VPL
*   CALL GETVERSION
*
***********************************************************************
* Size aliases (for allocating caller-owned storage)
***********************************************************************
MPMCQ_QCB_LEN     EQU   QCB_SIZE
MPMCQ_STATS_LEN   EQU   STATS_END-MPMCQ_STATS

.MPMCQAPI_END ANOP