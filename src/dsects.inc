         TITLE 'DSECTS - QCB, NODE, STATS'
***********************************************************************
*  DSECTS.INC
*  QCB BASE MUST BE 256-BYTE ALIGNED (QINIT RETURNS 12).
*  HEAD, TAIL, FREE, AND STATS EACH START ON THEIR OWN LINE.
*  EACH (ABA,PTR) PAIR IS 8-BYTE ALIGNED FOR CDS.
*  NODE_CNT_EXT IS THE EMPTY-NEXT GENERATION. IT SURVIVES REUSE.
*  NODE_CNT_INT IS NODE_F_INLINE WHEN THE BYTES SIT IN THE NODE.
*  INLINE BYTES START ON THEIR OWN CACHE LINE (SAVE AREA TOO).
*  QCB_POOL IS SIX 31-BIT SLAB FREELISTS (2K 4K 8K 16K 32K 64K).
*  QCB_TLS POINTS AT A TCB-SLOT TABLE. PSATOLD IS PSA+X'21C'.
*  TLS_STAMP IS THE SLOT'S LAST USE. AGE MATH USES THE SLOT TAIL.
*  QCB_SIZE IS ALSO PUBLISHED IN API.INC AS QCB_SIZE_PUB.
*  COPY DSECTS BEFORE API.
***********************************************************************
PSATOLD                EQU   X'21C'
TLS_SLOTS              EQU   64
TLS_LINE               EQU   256
TLS_BYTES              EQU   TLS_SLOTS*TLS_LINE
TLS_DEPTH              EQU   8
TLS_FILL               EQU   4
TLS_OWNER              EQU   0
TLS_COUNT              EQU   4
TLS_STAMP              EQU   8
TLS_NODES              EQU   16
TLS_MASK               EQU   TLS_SLOTS-1
POOL_N                 EQU   6
POOL_2K                EQU   2048
POOL_4K                EQU   4096
POOL_8K                EQU   8192
POOL_16K               EQU   16384
POOL_32K               EQU   32768
POOL_64K               EQU   65536
*
MPMCQ_STATS_VERSION EQU 1
*
MPMCQ_QCB              DSECT
QCB_EYECATCH           DS    CL8
QCB_NAME               DS    CL16
QCB_VERSION            DS    F
QCB_FLAGS              DS    F
QCB_CB_EP              DS    F
QCB_CB_CTX             DS    F
QCB_USER_ECB           DS    F
QCB_CB_ECB             DS    F
QCB_ENQ_SEQ            DS    F
QCB_CB_SEQ_SEEN        DS    F
QCB_CB_TCB             DS    F
*  COPY OF THE QCB ADDRESS. THE ATTACH LIST IS BELOW 16MB.
QCB_TASKPARM           DS    F
                       DS    0D
*  WORD 1 IS THE BELOW-LINE AREA. PARM WORD AT +0, TASK ECB AT +4.
*  THE TASK ECB STAYS BELOW 16MB SO ATTACH POSTS THE WORD WE WAIT ON.
*  THE REST IS UNUSED. NOT PAST +256.
QCB_STWORK             DS    XL176
                       ORG   MPMCQ_QCB+256
                       DS    0D
QCB_HEAD_ABA           DS    F
QCB_HEAD_PTR           DS    F
                       ORG   MPMCQ_QCB+512
                       DS    0D
QCB_TAIL_ABA           DS    F
QCB_TAIL_PTR           DS    F
                       ORG   MPMCQ_QCB+768
                       DS    0D
QCB_FREE_ABA           DS    F
QCB_FREE_PTR           DS    F
                       ORG   MPMCQ_QCB+1024
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
QCB_STAT_PAYLOAD64_CUR_HI DS F
QCB_STAT_PAYLOAD64_CUR_LO DS F
QCB_STAT_PAYLOAD64_MAX_HI DS F
QCB_STAT_PAYLOAD64_MAX_LO DS F
QCB_STAT_POST_INTERNAL DS   F
QCB_STAT_POST_USERECB  DS   F
QCB_STAT_CB_CALLS      DS   F
QCB_STAT_CB_PENDING_MAX DS  F
                       ORG   MPMCQ_QCB+1280
                       DS    0D
QCB_TLS                DS    A
                       DS    F
QCB_POOL               DS    6D
QCB_SIZE               EQU   *-MPMCQ_QCB
*
MPMCQ_NODE             DSECT
                       DS    0D
NODE_CNT_INT           DS    F
NODE_CNT_EXT           DS    F
NODE_NEXT_ABA          DS    F
NODE_NEXT_PTR          DS    F
NODE_PAYLOAD64         DS    D
NODE_PAYLOAD_LEN       DS    F
NODE_RSVD              DS    F
                       ORG   MPMCQ_NODE+256
NODE_INLINE            DS    CL1024
NODE_INLINE_MAX        EQU   1024
NODE_F_INLINE          EQU   1
NODE_SIZE              EQU   *-MPMCQ_NODE
*
MPMCQ_STATS            DSECT
STATS_VERSION          DS    F
STATS_SIZE             DS    F
STATS_ENQ_OK           DS    F
STATS_DEQ_OK           DS    F
STATS_DEQ_EMPTY        DS    F
STATS_ENQ_ALLOC_FAIL   DS    F
STATS_ENQ_RETRY        DS    F
STATS_DEQ_RETRY        DS    F
STATS_FREELIST_POP_RETRY DS  F
STATS_FREELIST_PUSH_RETRY DS F
STATS_QDEPTH_CUR       DS    F
STATS_QDEPTH_MAX       DS    F
STATS_PAYLOAD64_CUR    DS    D
STATS_PAYLOAD64_MAX    DS    D
STATS_POST_INTERNAL    DS    F
STATS_POST_USERECB     DS    F
STATS_CB_CALLS         DS    F
STATS_CB_PENDING_MAX   DS    F
STATS_END              EQU   *
