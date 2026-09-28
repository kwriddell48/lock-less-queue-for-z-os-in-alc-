         TITLE 'MPMCQ DSECTs - QCB, NODE, STATS, PARM LISTS'
***********************************************************************
*  MPMCQ DSECT INCLUDE
*
*  - AMODE 31 callable queue control block (QCB) + node layout
*  - Stats snapshot layout returned by QSTATS
*  - Parameter list layouts for entry points
*
*  Notes:
*  - Counted pointers used with CDS require doubleword alignment.
*  - This include is intended for HLASM.
***********************************************************************

MPMCQ_EQUATES          EQU   *
MPMCQ_STATS_VERSION    EQU   1

***********************************************************************
* QINIT option bits (QINIT_OPTIONS fullword)
***********************************************************************
MPMCQ_OPT_PAYLOAD31    EQU   X'00000000'  * default: payload allocated below 2G (cell pools; slab GETMAIN RC,LOC=ANY)
MPMCQ_OPT_PAYLOAD64    EQU   X'00000001'  * payload allocated in 64-bit storage (IARV64)
MPMCQ_MAX_REC_LEN      EQU   16777215        * MVCL length limit (24 bits): 16MB-1
MPMCQ_MAX_REC31_LEN    EQU   16384           * payload31 max (largest pool tier); avoids cross-task FREEMAIN

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

***********************************************************************
* QCB layout (cache-line separation + CDS alignment)
*
* Hot fields are placed on separate 256-byte groups using ORG so they
* naturally fall on different cache lines and so all (ABA,PTR) pairs are
* 8-byte aligned for CDS.
*
* NOTE: this guarantees pair alignment and intended cache geometry when the
* QCB base address itself is 256-byte aligned (QINIT enforces this).
***********************************************************************

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

***********************************************************************
* Stats (kept in QCB; returned via QSTATS)
***********************************************************************
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

QCB_STAT_QDEPTH_CUR    DS    F                 best-effort
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

* Transaction diagnostic block. Own 256-byte group so abort stores do not
* share a line with HEAD, TAIL, pools, or stats. Hardware writes this only
* when TBEGIN aborts. One block per queue: overlapping aborts can overwrite
* it. The condition code, not the TDB, selects the CDS fallback.
         ORG   MPMCQ_QCB+1792
QCB_TDB                DS    0D
QCB_TDB_PFX            DS    XL6               bytes 0-5: flags
QCB_TDB_TAC            DS    H                 bytes 6-7: transaction abort code
QCB_TDB_ATIA           DS    D                 bytes 8-15: aborted-instruction address
QCB_TDB_TAIL           DS    CL240             bytes 16-255, including GRs at +128

         ORG   MPMCQ_QCB+2048
QCB_SIZE               EQU   *-MPMCQ_QCB

***********************************************************************
* Node layout (31-bit storage)
***********************************************************************
MPMCQ_NODE             DSECT
NODE_ALIGN0            DS    0D

* Node reference counters (doubleword so we can update atomically with CDS)
NODE_CNT_INT           DS    F                 internal count
NODE_CNT_EXT           DS    F                 external counters

* Tagged pointer to next node (ABA, PTR)
NODE_NEXT_ABA          DS    F
NODE_NEXT_PTR          DS    F                 ptr31

* Tagged pointer used by freelist (ABA, PTR)
* Keep this separate from NODE_NEXT_* to avoid interference between queue links
* and node-pool links.
NODE_FREE_ABA          DS    F
NODE_FREE_PTR          DS    F                 ptr31

* Payload in 64-bit storage (address + length)
NODE_PAYLOAD64         DS    D                 64-bit address
NODE_PAYLOAD_LEN       DS    F                 length (bytes)
NODE_RSVD              DS    F                 reserved / align

NODE_SIZE              EQU   *-MPMCQ_NODE

***********************************************************************
* QSTATS snapshot layout (caller buffer)
***********************************************************************
MPMCQ_STATS             DSECT
STATS_VERSION           DS   F
STATS_SIZE              DS   F                 bytes copied

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

* QINIT(QCBaddr, options, CB_EP, CB_CTX, USER_ECB)
MPMCQ_QINIT_PLIST       DSECT
QINIT_QCBADDR           DS   F
QINIT_OPTIONS           DS   F
QINIT_CB_EP             DS   F
QINIT_CB_CTX            DS   F
QINIT_USER_ECB          DS   F

* QENQ(QCBaddr, srcAddr, srcLen)
MPMCQ_QENQ_PLIST        DSECT
ENQ_QCBADDR             DS   F
ENQ_SRCADDR             DS   F
ENQ_SRCLEN              DS   F

* QDEQ(QCBaddr, dstAddr, dstMaxLen, outLenAddr)
MPMCQ_QDEQ_PLIST        DSECT
DEQ_QCBADDR             DS   F
DEQ_DSTADDR             DS   F
DEQ_DSTMAX              DS   F
DEQ_OUTLENADDR          DS   F

* QSTATS(QCBaddr, outStatsAddr, outStatsLen)
MPMCQ_QSTATS_PLIST      DSECT
QST_QCBADDR             DS   F
QST_OUTADDR             DS   F
QST_OUTLEN              DS   F

* GETVERSION(outAddr, outMaxLen, outActLenAddr)
* - If outAddr==0, routine returns R1=ptr to version string, R0=len.
* - If outAddr!=0, routine copies up to outMaxLen and stores actual length
*   (full string length) at *outActLenAddr.
MPMCQ_GETVER_PLIST      DSECT
GVER_OUTADDR            DS   F
GVER_OUTMAX             DS   F
GVER_OUTACTLENADDR      DS   F

* Callback parm list: (CB_CTX, QCBaddr, PendingCount)
MPMCQ_CB_PLIST          DSECT
CBP_CTX                 DS   F
CBP_QCB                 DS   F
CBP_PENDING             DS   F

* End of include: src/mpmcq_dsects.inc

