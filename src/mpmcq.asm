         TITLE 'MPMCQ - Lock-free MPMC FIFO queue (AMODE 31 callable)'
***********************************************************************
*  MPMCQ.ASM
*
*  Entry points:
*    QINIT   - initialize queue control block and start notifier (optional)
*    QENQ    - enqueue variable-length record (payload handled in later module)
*    QDEQ    - dequeue variable-length record (payload handled in later module)
*
*  This file implements the queue fast-path:
*    - Michael-Scott MPMC queue (unbounded linked list)
*    - Counted-pointer swings using CDS on (PTR31,EXTCOUNT32) pairs
*    - Node reuse via a lock-free freelist (Treiber stack) in src/mpmcq_freelist.asm
*
*  Notes:
*    - Payload allocation/copy/free is wired in by calling helper routines
*      implemented in src/mpmcq_storage.asm and src/mpmcq_copy64.mac.
*    - This code assumes z/Architecture with CDS (doubleword CAS).
*
*  Reentrancy / RENT:
*    - No writable static storage in this CSECT (all mutable state is in QCB/nodes).
*    - Safe for concurrent callers provided each queue instance has its own QCB.
*
*  Counted-pointer layout:
*    - A counted pointer is stored as two adjacent fullwords:
*        [PTR31][EXTCOUNT32]
*      and updated atomically via CDS to reduce ABA risk when pointers move.
***********************************************************************

         PRINT GEN

         COPY  'src/reg_equates.inc'
         COPY  'src/mpmcq_dsects.inc'
         COPY  'src/mpmcq_atomics.mac'
         COPY  'src/mpmcq_copy64.mac'

MPMCQ    CSECT
MPMCQ    AMODE 31
MPMCQ    RMODE ANY

         ENTRY QINIT
         ENTRY QENQ
         ENTRY QDEQ

         EXTRN MPMCQ_POPNODE
         EXTRN MPMCQ_PUSHNODE
         EXTRN MPMCQ_PAYGET
         EXTRN MPMCQ_PAYFREE
         EXTRN MPMCQ_NSTART

***********************************************************************
* Standard save area usage:
***********************************************************************
         USING MPMCQ,R15

***********************************************************************
* Internal helper prototypes (local labels only)
***********************************************************************

***********************************************************************
* QINIT(QCBaddr, options, initialPool, CB_EP, CB_CTX, USER_ECB)
***********************************************************************
QINIT     DS    0H
         STM   R14,R12,12(R13)
         LR    R12,R15
         USING MPMCQ,12

* R1 -> parm list (QINIT pl)
         L     R2,QINIT_QCBADDR(R1)         R2=QCB
         USING MPMCQ_QCB,R2

* Eyecatcher + version (helps validate QCB in dumps)
         MVC   QCB_EYECATCH,=CL8'MPMCQCB '
         MVC   QCB_NAME,=CL16'                '
         MVC   QCB_VERSION,=F'MPMCQ_STATS_VERSION'
         XR    R0,R0
         ST    R0,QCB_FLAGS

* Store callback configuration:
* - QCB_CB_EP: async callback entry point (invoked by notifier TCB)
* - QCB_CB_CTX: user context value passed to callback
* - QCB_USER_ECB: optional user ECB posted on each successful enqueue
         L     R3,QINIT_CB_EP(R1)
         ST    R3,QCB_CB_EP
         L     R3,QINIT_CB_CTX(R1)
         ST    R3,QCB_CB_CTX
         L     R3,QINIT_USER_ECB(R1)
         ST    R3,QCB_USER_ECB

* Initialize internal notifier fields:
* - QCB_ENQ_SEQ increments on each ENQ (monotonic best-effort)
* - QCB_CB_SEQ_SEEN is last ENQ_SEQ consumed by notifier
* - QCB_CB_ECB is an internal ECB used to wake notifier from WAIT
         XR    R0,R0
         ST    R0,QCB_CB_TCB
         ST    R0,QCB_ENQ_SEQ
         ST    R0,QCB_CB_SEQ_SEEN
         ST    R0,QCB_CB_ECB

* Zero stats area (approximate counters; see QSTATS)
         XC    QCB_STAT_ENQ_OK(QCB_SIZE-QCB_STAT_ENQ_OK),QCB_STAT_ENQ_OK

* Allocate initial dummy node (in 31-bit storage).
*
* Michael-Scott queue uses a dummy node:
* - HEAD points to a dummy node; first real element is HEAD->NEXT
* - DEQ swings HEAD forward and recycles the old dummy node
         LA    R4,NODE_SIZE
         GETMAIN RU,LV=(R4),LOC=BELOW
         LR    R5,R1                        R5 = node addr
         USING MPMCQ_NODE,R5
         XC    0(NODE_SIZE,R5),0(R5)

* Initialize node counters:
* - NODE_CNT_INT: internal references (reserved for future reclamation refinement)
* - NODE_CNT_EXT: external references from counted pointers (HEAD/Tail)
* Seed NODE_CNT_EXT=2 because both HEAD and TAIL initially reference this dummy.
         XR    R0,R0
         ST    R0,NODE_CNT_INT
         LA    R0,2
         ST    R0,NODE_CNT_EXT

* Initialize node NEXT tagged pointer = NULL
         XR    R0,R0
         ST    R0,NODE_NEXT_ABA
         ST    R0,NODE_NEXT_PTR

* Initialize QCB head/tail tagged pointers to dummy node.
* ABA tags start at 0; each pointer update will take a fresh tag from QCB_ABA_SEQ.
         XR    R0,R0
         ST    R0,QCB_HEAD_ABA
         ST    R5,QCB_HEAD_PTR
         ST    R0,QCB_TAIL_ABA
         ST    R5,QCB_TAIL_PTR

* Initialize freelist empty (node reuse pool)
         ST    R0,QCB_FREE_ABA
         ST    R0,QCB_FREE_PTR

* Initialize ABA tag generator (separate from ENQ_SEQ used for notifier PendingCount)
         ST    R0,QCB_ABA_SEQ

* Start notifier TCB (if callback EP provided).
* Notifier lives in src/mpmcq_notify.asm; producers wake it via POST.
         L     R15,=V(MPMCQ_NSTART)
         BALR  R14,R15

         XR    R15,R15
         LM    R14,R12,12(R13)
         BR    R14

***********************************************************************
* Internal helper: INC_EXT_COUNT
*
* Increase the external count on a counted pointer (PTR,CNT) stored as
* adjacent fullwords suitable for CDS.
*
* Inputs:
*   R2 = address of counted pointer (points at PTR field)
* Outputs:
*   R6/R7 = resulting (PTR,CNT) after successful increment
* Clobbers:
*   R0,R1,R6,R7,R8,R9
***********************************************************************
INC_EXT_COUNT DS 0H
INCX_LOOP  DS 0H
         L     R6,0(R2)                   ptr
         L     R7,4(R2)                   cnt
         LR    R8,R6
         LR    R9,R7
         LA    R9,1(R9)
* CAS doubleword at (R2): expected=(R6,R7), new=(R8,R9)
         LR    R0,R6
         LR    R1,R7
* Use CDS: compare regs 0/1 with mem, store regs 8/9 if equal
         CDS   R0,R8,0(R2)
         BNE   INCX_LOOP
* Return updated values in R6/R7
         LR    R6,R8
         LR    R7,R9
         BR    R14

***********************************************************************
* Internal helper: NODE_ADJUST_COUNTS
*
* Atomically update node counters (CNT_INT,CNT_EXT) using CDS.
*
* Inputs:
*   R5 = node addr (NODE_CNT_INT at 0(R5))
*   R6 = add_to_internal (signed)
*   R7 = add_to_external (signed)  (typically -1 when dropping an external)
* Output:
*   R0/R1 = new (int,ext) after update
***********************************************************************
NODE_ADJUST_COUNTS DS 0H
NAC_LOOP DS 0H
         L     R0,NODE_CNT_INT(R5)
         L     R1,NODE_CNT_EXT(R5)
         LR    R8,R0
         LR    R9,R1
         AR    R8,R6
         AR    R9,R7
         CDS   R0,R8,NODE_CNT_INT(R5)
         BNE   NAC_LOOP
         LR    R0,R8
         LR    R1,R9
         BR    R14

***********************************************************************
* QENQ(QCBaddr, srcAddr, srcLen)
*
* Enqueue a record:
* - Allocates a node (from freelist or GETMAIN fallback)
* - Allocates 64-bit payload storage and copies bytes in
* - Links node into the lock-free MS-queue
* - Updates best-effort stats
* - Posts internal ECB (for notifier TCB) and user ECB (optional)
***********************************************************************
QENQ     DS    0H
         STM   R14,R12,12(R13)
         LR    R12,R15
         USING MPMCQ,12

         L     R2,ENQ_QCBADDR(R1)
         USING MPMCQ_QCB,R2
         L     R6,ENQ_SRCADDR(R1)
         L     R7,ENQ_SRCLEN(R1)

* Allocate/reuse node:
* - Try lock-free freelist pop first (fast, lock-free)
* - If empty, GETMAIN a new node (slow path; system service)
         L     R15,=V(MPMCQ_POPNODE)
         BALR  R14,R15
         LTR   R15,R15
         BNZ   QENQ_GETMAIN
         LR    R5,R1
         B     QENQ_HAVE_NODE

QENQ_GETMAIN DS 0H
         LA    R4,NODE_SIZE
         GETMAIN RU,LV=(R4),LOC=BELOW
         LR    R5,R1

QENQ_HAVE_NODE DS 0H
         USING MPMCQ_NODE,R5
* Clear node: important when reusing from freelist (old NEXT/payload must not leak)
         XC    0(NODE_SIZE,R5),0(R5)
         XR    R0,R0
         ST    R0,NODE_CNT_INT
         LA    R0,2
         ST    R0,NODE_CNT_EXT
         XR    R0,R0
         ST    R0,NODE_NEXT_ABA
         ST    R0,NODE_NEXT_PTR

* Allocate 64-bit payload and copy in (variable length).
* - MPMCQ_PAYGET obtains 64-bit storage (IARV64)
* - MPMCQ_COPY_31_TO_64 switches to SAM64 only for the MVCL copy
         LTR   R7,R7
         BZ    QENQ_PAYLOAD_SET
         L     R15,=V(MPMCQ_PAYGET)
         BALR  R14,R15                    in: R7=len, out: R8=addr64, R15=rc
         LTR   R15,R15
         BZ    QENQ_PAYLOAD_COPY
* Allocation failed: stats + recycle node
         MPMCQ_STATINC R2,QCB_STAT_ENQ_ALLOC_FAIL,R8,R9
         L     R15,=V(MPMCQ_PUSHNODE)
         BALR  R14,R15
         LA    R15,8
         LM    R14,R12,12(R13)
         BR    R14

QENQ_PAYLOAD_COPY DS 0H
* Copy from src (31-bit in R6) to payload (64-bit in R8), length R7.
* This is safe for AMODE 31 callers because the copy is wrapped with SAM64/SAM31.
         MPMCQ_COPY_31_TO_64 R6,R8,R7,R8,R10,R11

* Record payload in node
         STG   R8,NODE_PAYLOAD64
         ST    R7,NODE_PAYLOAD_LEN

* Update 64-bit payload usage stats (cur += len; max = max(max,cur)).
* Counters are stored as HI/LO fullwords and updated using CDS retry loops.
         MPMCQ_STATADD64 R2,QCB_STAT_PAYLOAD64_CUR_HI,QCB_STAT_PAYLOAD64_CUR_LO,R7,R0,R8
         L     R4,QCB_STAT_PAYLOAD64_CUR_HI
         L     R5,QCB_STAT_PAYLOAD64_CUR_LO
         MPMCQ_STATMAX64 R2,QCB_STAT_PAYLOAD64_MAX_HI,QCB_STAT_PAYLOAD64_MAX_LO,R4,R5,R0,R8
         B     QENQ_PAYLOAD_SET

QENQ_PAYLOAD_SET DS 0H
         LTR   R7,R7
         BNZ   QENQ_PAYLOAD_DONE
         XR    R0,R0
         STG   R0,NODE_PAYLOAD64
         ST    R0,NODE_PAYLOAD_LEN
QENQ_PAYLOAD_DONE DS 0H

* Enqueue: Michael-Scott algorithm (counted pointers).
* CAS tail->next counted pointer from (0,0) to (new_node,1), then swing tail
* counted pointer forward (helping when tail lags).
ENQ_RETRY_LOOP DS 0H
         MPMCQ_STATINC R2,QCB_STAT_ENQ_RETRY,R8,R9

* Load tail tagged pointer (ABA,PTR) into (R0,R1).
* R0/R1 is the expected value for the tail swing (CDS on QCB_TAIL_ABA/QCB_TAIL_PTR).
         L     R0,QCB_TAIL_ABA
         L     R1,QCB_TAIL_PTR
         LTR   R1,R1
         BZ    ENQ_FATAL
         LR    R10,R1                      tail_ptr
         USING  MPMCQ_NODE,R10

* Read TAIL->NEXT (ABA,PTR).
* If NEXT_PTR != 0, some thread already linked a node; we "help" by advancing tail.
         L     R6,NODE_NEXT_ABA
         L     R7,NODE_NEXT_PTR
         LTR   R7,R7
         BNZ   ENQ_HELP_TAIL

* Attempt to link NEXT from (0,0) to (newABA,new_node_ptr).
* This is the ENQ linearization point: once this succeeds, consumers can see the node.
         XR    R6,R6
         XR    R7,R7
* Get a fresh ABA tag for the NEXT pointer
ENQ_NEXT_ABA_LOOP DS 0H
         L     R8,QCB_ABA_SEQ
         LA    R9,1(R8)
         CS    R8,R9,QCB_ABA_SEQ
         BNE   ENQ_NEXT_ABA_LOOP
         LR    R8,R9                       desired ABA
         LR    R9,R5                       desired PTR = new node
         CDS   R6,R8,NODE_NEXT_ABA(R10)
         BNE   ENQ_RETRY_LOOP

* Swing tail tagged pointer to the newly linked node (best-effort).
* It's fine if this fails; other threads will advance tail.
ENQ_TAIL_ABA_LOOP DS 0H
         L     R8,QCB_ABA_SEQ
         LA    R9,1(R8)
         CS    R8,R9,QCB_ABA_SEQ
         BNE   ENQ_TAIL_ABA_LOOP
         LR    R8,R9                       desired ABA
         LR    R9,R5                       desired PTR
         CDS   R0,R8,QCB_TAIL_ABA(R2)

* Update stats for success (approx)
         MPMCQ_STATINC R2,QCB_STAT_ENQ_OK,R8,R9
* depth++
         L     R8,QCB_STAT_QDEPTH_CUR
         LA    R9,1(R8)
ENQ_DEPTHCAS DS 0H
         CS    R8,R9,QCB_STAT_QDEPTH_CUR
         BNE   ENQ_DEPTHCAS
         MPMCQ_STATMAX R2,QCB_STAT_QDEPTH_MAX,R9,R8,R11

* ENQ notifications:
* - increment ENQ_SEQ (used by notifier to compute PendingCount)
* - POST internal ECB (wakes notifier TCB; posts may coalesce)
* - POST user ECB if provided (posts may coalesce)
ENQ_SEQ_LOOP DS 0H
         L     R0,QCB_ENQ_SEQ
         LA    R3,1(R0)
         CS    R0,R3,QCB_ENQ_SEQ
         BNE   ENQ_SEQ_LOOP

         POST  ECB=QCB_CB_ECB
         MPMCQ_STATINC R2,QCB_STAT_POST_INTERNAL,R8,R9

         L     R4,QCB_USER_ECB
         LTR   R4,R4
         BZ    ENQ_NO_USERECB
         POST  ECB=(R4)
         MPMCQ_STATINC R2,QCB_STAT_POST_USERECB,R8,R9
ENQ_NO_USERECB DS 0H

         XR    R15,R15
         LM    R14,R12,12(R13)
         BR    R14

ENQ_HELP_TAIL DS 0H
* Help advance tail when it lags: set tail to NEXT_PTR.
* This reduces contention by keeping tail close to the end of the list.
ENQ_HELP_TAIL_ABA_LOOP DS 0H
         L     R8,QCB_ABA_SEQ
         LA    R9,1(R8)
         CS    R8,R9,QCB_ABA_SEQ
         BNE   ENQ_HELP_TAIL_ABA_LOOP
         LR    R8,R9                       desired ABA
         LR    R9,R7                       desired PTR = NEXT_PTR
         CDS   R0,R8,QCB_TAIL_ABA(R2)
         B     ENQ_RETRY_LOOP

ENQ_FATAL DS 0H
* Unexpected: tail is null; treat as failure
         MPMCQ_STATINC R2,QCB_STAT_ENQ_ALLOC_FAIL,R8,R9
         LA    R15,8
         LM    R14,R12,12(R13)
         BR    R14

***********************************************************************
* QDEQ(QCBaddr, dstAddr, dstMaxLen, outLenAddr)
*
* Dequeue a record:
* - Swings HEAD forward (CDS on (ABA,PTR)); this is the DEQ linearization point
* - Copies payload out to caller buffer (truncation supported)
* - Frees 64-bit payload storage and updates byte-usage stats
* - Recycles old dummy node into freelist
***********************************************************************
QDEQ     DS    0H
         STM   R14,R12,12(R13)
         LR    R12,R15
         USING MPMCQ,12

         L     R2,DEQ_QCBADDR(R1)
         USING MPMCQ_QCB,R2
         L     R6,DEQ_DSTADDR(R1)
         L     R7,DEQ_DSTMAX(R1)

DEQ_RETRY_LOOP DS 0H
         MPMCQ_STATINC R2,QCB_STAT_DEQ_RETRY,R8,R9

* Load head tagged pointer into (R0,R1), and read HEAD->NEXT.
* If NEXT_PTR == 0 then queue is empty (no element to return).
         L     R0,QCB_HEAD_ABA
         L     R1,QCB_HEAD_PTR
         L     R11,QCB_TAIL_PTR
         LTR   R1,R1
         BZ    DEQ_EMPTY
         LR    R10,R1                      head_ptr
         USING MPMCQ_NODE,R10
         L     R3,NODE_NEXT_PTR            next_ptr
         LTR   R3,R3
         BZ    DEQ_EMPTY

* Swing head tagged pointer from old head to (newABA,next_ptr).
* This is the DEQ linearization point: element is now logically removed.
DEQ_HEAD_ABA_LOOP DS 0H
         L     R8,QCB_ABA_SEQ
         LA    R9,1(R8)
         CS    R8,R9,QCB_ABA_SEQ
         BNE   DEQ_HEAD_ABA_LOOP
         LR    R8,R9                       desired ABA
         LR    R9,R3                       desired PTR
         CDS   R0,R8,QCB_HEAD_ABA(R2)
         BNE   DEQ_RETRY_LOOP

* At this point:
* - old dummy node is R10 (to be recycled)
* - new head is R3
*   - its payload fields hold the dequeued message
*   - it becomes the new dummy head after we extract and clear payload
         USING MPMCQ_NODE,R3

* Load payload metadata from the dequeued node (R3)
         L     R9,NODE_PAYLOAD_LEN
         LG    R8,NODE_PAYLOAD64

* Store actual length to *outLenAddr (always actual, even if truncated)
         L     R4,DEQ_OUTLENADDR(R1)
         LTR   R4,R4
         BZ    DEQ_OUTLEN_DONE
         ST    R9,0(R4)
DEQ_OUTLEN_DONE DS 0H

* Determine copy length and return code:
* - RC=0 if full message copied
* - RC=8 if truncated (outLen still reports actual message length)
         LR    R5,R9                       actual
         CR    R9,R7                       actual vs dstMax
         BNH   DEQ_COPY_FULL
* Truncated
         LR    R5,R7                       copyLen = dstMax
         LA    R15,8                       RC=8
         B     DEQ_DO_COPY
DEQ_COPY_FULL DS 0H
         XR    R15,R15                     RC=0

DEQ_DO_COPY DS 0H
         LTR   R5,R5
         BZ    DEQ_SKIP_COPY
         MPMCQ_COPY_64_TO_31 R8,R6,R5,R10,R8,R11
DEQ_SKIP_COPY DS 0H

* Free 64-bit payload storage and adjust payload usage stats (cur -= actualLen)
         LTR   R9,R9
         BZ    DEQ_SKIP_FREE
         LR    R7,R9                       pass actual length to PAYFREE
         L     R15,=V(MPMCQ_PAYFREE)
         BALR  R14,R15                     in: R8=addr64, R7=len
DEQ_SKIP_FREE DS 0H

* Update payload64 current usage: cur -= actualLen
         LR    R7,R9
         LCR   R7,R7                        signed -len
         MPMCQ_STATADD64S R2,QCB_STAT_PAYLOAD64_CUR_HI,QCB_STAT_PAYLOAD64_CUR_LO,R7,R0,R8

* Clear payload fields in new head (now dummy).
* Dummy nodes must never retain ownership of a payload.
         XR    R0,R0
         STG   R0,NODE_PAYLOAD64
         ST    R0,NODE_PAYLOAD_LEN

* Recycle old dummy node into freelist for reuse by producers.
         LR    R5,R10
         L     R15,=V(MPMCQ_PUSHNODE)
         BALR  R14,R15

* stats: deq ok, depth--
         MPMCQ_STATINC R2,QCB_STAT_DEQ_OK,R8,R9
DEQ_DEC_LOOP DS 0H
         L     R8,QCB_STAT_QDEPTH_CUR
         LR    R9,R8
         BCTR  R9,0
         CS    R8,R9,QCB_STAT_QDEPTH_CUR
         BNE   DEQ_DEC_LOOP

         LM    R14,R12,12(R13)
         BR    R14

DEQ_EMPTY DS 0H
         MPMCQ_STATINC R2,QCB_STAT_DEQ_EMPTY,R8,R9
         LA    R15,4
         LM    R14,R12,12(R13)
         BR    R14

         END   MPMCQ

