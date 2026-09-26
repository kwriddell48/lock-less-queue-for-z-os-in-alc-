         TITLE 'MPMCQ - QSTATS snapshot routine'
*PROCESS GOFF
***********************************************************************
*  MPMCQ_STATS.ASM
*
*  QSTATS(QCBaddr, outStatsAddr, outStatsLen)
*   - Copies a versioned stats snapshot to caller buffer.
*   - Stats are approximate under concurrency; this is a best-effort snapshot.
*
*  Snapshot semantics:
*   - No global lock is taken (queue remains lock-free).
*   - Individual counters are read and stored; values can be slightly skewed
*     relative to each other if producers/consumers are updating concurrently.
*   - outStatsLen allows forward-compatible extension of the stats DSECT.
***********************************************************************

         PRINT GEN
         ACONTROL OPTABLE(ZS5)

         COPY  'src/reg_equates.inc'
         COPY  'src/mpmcq_dsects.inc'

MPMCQST  CSECT
MPMCQST  AMODE 31
MPMCQST  RMODE ANY

         ENTRY QSTATS
         USING MPMCQST,R15

QSTATS   DS 0H
         STM   R14,R12,12(R13)
         LR    R12,R15
         USING MPMCQST,12

         USING MPMCQ_QSTATS_PLIST,R1
         L     R4,QST_OUTLEN
         LT    Q_R,QST_QCBADDR
         JZ    QST_DONE
         LT    R3,QST_OUTADDR
         JZ    QST_DONE

         USING MPMCQ_QCB,Q_R
         USING MPMCQ_STATS,R3

* Require a full buffer to avoid overruns (caller can retry with a larger one).
         LA    R5,STATS_END-MPMCQ_STATS         required size
         CR    R4,R5
         JNL   QST_LEN_OK
         LA    R15,8                           RC=8 (buffer too small)
         J     QST_RET
QST_LEN_OK DS 0H

         LLILF R0,MPMCQ_STATS_VERSION
         ST    R0,STATS_VERSION
         ST    R5,STATS_SIZE

* Copy fullword counters
         L     R0,QCB_STAT_ENQ_OK
         ST    R0,STATS_ENQ_OK
         L     R0,QCB_STAT_DEQ_OK
         ST    R0,STATS_DEQ_OK
         L     R0,QCB_STAT_DEQ_EMPTY
         ST    R0,STATS_DEQ_EMPTY
         L     R0,QCB_STAT_ENQ_ALLOC_FAIL
         ST    R0,STATS_ENQ_ALLOC_FAIL

         L     R0,QCB_STAT_ENQ_RETRY
         ST    R0,STATS_ENQ_RETRY
         L     R0,QCB_STAT_DEQ_RETRY
         ST    R0,STATS_DEQ_RETRY
         L     R0,QCB_STAT_FREELIST_POP_RETRY
         ST    R0,STATS_FREELIST_POP_RETRY
         L     R0,QCB_STAT_FREELIST_PUSH_RETRY
         ST    R0,STATS_FREELIST_PUSH_RETRY

         L     R0,QCB_STAT_QDEPTH_CUR
         ST    R0,STATS_QDEPTH_CUR
         L     R0,QCB_STAT_QDEPTH_MAX
         ST    R0,STATS_QDEPTH_MAX

* Copy 31-bit payload byte counters (hi/lo -> D)
         L     R0,QCB_STAT_PAYLOAD31_CUR_HI
         ST    R0,STATS_PAYLOAD31_CUR
         L     R0,QCB_STAT_PAYLOAD31_CUR_LO
         ST    R0,STATS_PAYLOAD31_CUR+4
         L     R0,QCB_STAT_PAYLOAD31_MAX_HI
         ST    R0,STATS_PAYLOAD31_MAX
         L     R0,QCB_STAT_PAYLOAD31_MAX_LO
         ST    R0,STATS_PAYLOAD31_MAX+4

* Copy 64-bit payload byte counters (hi/lo -> D)
         L     R0,QCB_STAT_PAYLOAD64_CUR_HI
         ST    R0,STATS_PAYLOAD64_CUR
         L     R0,QCB_STAT_PAYLOAD64_CUR_LO
         ST    R0,STATS_PAYLOAD64_CUR+4
         L     R0,QCB_STAT_PAYLOAD64_MAX_HI
         ST    R0,STATS_PAYLOAD64_MAX
         L     R0,QCB_STAT_PAYLOAD64_MAX_LO
         ST    R0,STATS_PAYLOAD64_MAX+4

         L     R0,QCB_STAT_POST_INTERNAL
         ST    R0,STATS_POST_INTERNAL
         L     R0,QCB_STAT_POST_USERECB
         ST    R0,STATS_POST_USERECB
         L     R0,QCB_STAT_CB_CALLS
         ST    R0,STATS_CB_CALLS
         L     R0,QCB_STAT_CB_PENDING_MAX
         ST    R0,STATS_CB_PENDING_MAX

QST_DONE DS 0H
         XR    R15,R15                         RC=0
QST_RET  DS 0H
         L     R14,12(,R13)
         LM    R2,R12,28(,R13)
         BR    R14

         END   MPMCQST

