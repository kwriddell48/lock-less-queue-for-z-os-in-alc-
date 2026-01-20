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
* Queue Control Block (QCB)
***********************************************************************
MPMCQ_QCB              DSECT
QCB_EYECATCH           DS    CL8               'MPMCQCB '
QCB_NAME               DS    CL16              user-assigned queue name
QCB_VERSION            DS    F                 version
QCB_FLAGS              DS    F                 runtime flags

* Ensure counted pointers are doubleword aligned for CDS.
QCB_ALIGN0             DS    0D

* Tagged pointer: (ABA32, PTR31)
* ABA is a monotonic tag used to reduce ABA effects when pointers are updated.
QCB_HEAD_ABA           DS    F                 ABA tag
QCB_HEAD_PTR           DS    F                 ptr to head node (31-bit)
QCB_TAIL_ABA           DS    F                 ABA tag
QCB_TAIL_PTR           DS    F                 ptr to tail node (31-bit)

* Optional node freelist head (tagged pointer)
QCB_FREE_ABA           DS    F                 ABA tag
QCB_FREE_PTR           DS    F                 ptr to free node

* Async callback fields
QCB_CB_EP              DS    F                 callback entry point (AMODE 31)
QCB_CB_CTX             DS    F                 user context pointer (31-bit)
QCB_USER_ECB           DS    F                 optional user ECB to POST per ENQ

* Internal notifier support
QCB_CB_ECB             DS    F                 internal ECB (fullword)
QCB_ENQ_SEQ            DS    F                 enqueue sequence (monotonic)
QCB_CB_SEQ_SEEN        DS    F                 last processed by notifier
QCB_CB_TCB             DS    F                 notifier TCB addr (optional)
QCB_ABA_SEQ            DS    F                 global ABA tag generator (monotonic)

***********************************************************************
* Stats (kept in QCB; returned via QSTATS)
***********************************************************************
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

* 64-bit payload byte usage (doubleword, updated via CDS loops)
QCB_STAT_PAYLOAD64_CUR_HI DS  F
QCB_STAT_PAYLOAD64_CUR_LO DS  F
QCB_STAT_PAYLOAD64_MAX_HI DS  F
QCB_STAT_PAYLOAD64_MAX_LO DS  F

QCB_STAT_POST_INTERNAL DS   F
QCB_STAT_POST_USERECB DS   F
QCB_STAT_CB_CALLS      DS   F
QCB_STAT_CB_PENDING_MAX DS  F

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

* QINIT(QCBaddr, options, initialPool, CB_EP, CB_CTX, USER_ECB)
MPMCQ_QINIT_PLIST       DSECT
QINIT_QCBADDR           DS   F
QINIT_OPTIONS           DS   F
QINIT_INITPOOL          DS   F
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

* Callback parm list: (CB_CTX, QCBaddr, PendingCount)
MPMCQ_CB_PLIST          DSECT
CBP_CTX                 DS   F
CBP_QCB                 DS   F
CBP_PENDING             DS   F

         END

