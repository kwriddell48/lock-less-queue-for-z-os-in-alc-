         TITLE 'MPMCQ - Lock-free MPMC FIFO queue (AMODE 31 callable)'
*PROCESS GOFF
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
*    - Tagged-pointer swings using CDS on (ABA32,PTR31) pairs
*    - Optional TBEGIN/TEND publish of the tail link or head swing,
*      with the CDS loops as the abort fallback
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
*  Tagged-pointer layout (ABA mitigation):
*    - Each pointer is stored as two adjacent fullwords:
*        [ABA32][PTR31]
*      and updated atomically via CDS to reduce ABA risk when pointers move.
***********************************************************************

         PRINT GEN
* ZS6 (zEC12): TBEGIN/TEND. The rest of the package remains ZS5.
         ACONTROL OPTABLE(ZS6)

         COPY  'src/reg_equates.inc'
         COPY  'src/mpmcq_dsects.inc'
         COPY  'src/mpmcq_atomics.mac'
         COPY  'src/mpmcq_copy64.mac'

***********************************************************************
* Tuning switches (assembly-time)
***********************************************************************
* Set to 1 to enable an exponential backoff in ENQ/DEQ retry loops.
* Default is 0 (lowest latency; highest retry-rate under extreme contention).
MPMCQ_ENABLE_BACKOFF  EQU  0
MPMCQ_BACKOFF_MAX     EQU  256              * max spin iterations per retry
* Unconstrained transaction around the publish only. 0 keeps the CDS path.
* Payload copy, GETMAIN, POST, and IARV64 stay outside the transaction.
MPMCQ_ENABLE_TX       EQU  1
MPMCQ_TX_RETRIES      EQU  3                * transient aborts before CDS fallback

MPMCQ    CSECT
MPMCQ    AMODE 31
MPMCQ    RMODE ANY

         ENTRY QINIT
         ENTRY QENQ
         ENTRY QDEQ

         EXTRN MPMCQ_PAYGET
         EXTRN MPMCQ_PAYFREE
         EXTRN MPMCQ_NSTART

***********************************************************************
* Standard save area usage:
***********************************************************************
         USING MPMCQ,R15

***********************************************************************
* TCBTOKEN template (for RENT: use MF=L/E)
***********************************************************************
TCBTOK_TEMPL DS  0D
         TCBTOKEN MF=L
TCBTOK_TLEN  EQU *-TCBTOK_TEMPL

***********************************************************************
* Internal helper prototypes (local labels only)
***********************************************************************

***********************************************************************
* QINIT(QCBaddr, options, CB_EP, CB_CTX, USER_ECB)
***********************************************************************
QINIT     DS    0H
         STM   R14,R12,12(R13)
         LARL  R12,MPMCQ
    
         USING MPMCQ,12

* R1 -> parm list (QINIT pl)
         USING MPMCQ_QINIT_PLIST,R1
         L     Q_R,QINIT_QCBADDR            Q_R=QCB
* Enforce 256-byte alignment:
* - Keeps all ORG-based 256-byte "hot groups" on 256-byte boundaries (cache geometry)
* - Implies 8-byte alignment for all (ABA,PTR) CDS pairs (prevents S0C6)
         LR    R0,Q_R
         NILF  R0,X'000000FF'
         LTR   R0,R0
         JZ    QINIT_ALN_OK
         LA    R15,12
         L     R14,12(,R13)
         LM    R2,R12,28(,R13)
         BR    R14
QINIT_ALN_OK DS 0H
         USING MPMCQ_QCB,Q_R

* Eyecatcher + version (helps validate QCB in dumps)
         MVC   QCB_EYECATCH,=CL8'MPMCQCB '
         MVC   QCB_NAME,=CL16'                '
         LLILF R0,MPMCQ_STATS_VERSION
         ST    R0,QCB_VERSION
         XR    R0,R0
         ST    R0,QCB_FLAGS

* QINIT_OPTIONS bit 0: payload storage mode (see src/mpmcq_dsects.inc equates)
*   MPMCQ_OPT_PAYLOAD31 (default) or MPMCQ_OPT_PAYLOAD64
         L     R0,QINIT_OPTIONS
         N     R0,=XL4'00000001'           * mask = MPMCQ_OPT_PAYLOAD64
         ST    R0,QCB_FLAGS

* Capture owner TCB at QINIT and (if payload64 requested) capture the jobstep TTOKEN.
* - QCB_OWNER_TCB is used for task-owned storage ownership decisions (shop-specific).
* - QCB_OWNER_TTOKEN is used to assign IARV64 memory objects to the jobstep task so any
*   producer/consumer task can DETACH them (per IARV64 TTOKEN restrictions).
PSATOLD   EQU  X'21C'                      PSA+21C -> current TCB
         L     R3,PSATOLD
         ST    R3,QCB_OWNER_TCB
         XC    QCB_OWNER_TTOKEN(16),QCB_OWNER_TTOKEN

* Only needed when payload64 mode is requested.
         TM    QCB_FLAGS+3(Q_R),X'01'      * payload64?
         JZ    QINIT_TTKN_DONE

* TCBTOKEN MF=L/E for RENT: allocate a private plist, copy template, execute.
         LA    R4,TCBTOK_TLEN
         GETMAIN RC,LV=(R4),LOC=ANY
         LTR   R15,R15
         JZ    QINIT_TOKOK
* Could not allocate TCBTOKEN plist work area.
         LA    R15,8
         J     QINIT_RET
QINIT_TOKOK DS 0H
         LR    R10,R1                      R10 = plist work area
* Copy list-form template (MVC max=256, so use MVCL).
         LR    R0,R10                      dest addr
         LR    R1,R4                       dest len
         LA    R8,TCBTOK_TEMPL             src addr
         LR    R9,R4                       src len
         MVCL  R0,R8
         LR    R1,R10
         TCBTOKEN TYPE=JOBSTEP,TTOKEN=QCB_OWNER_TTOKEN,MF=(E,(R1))
         LR    R0,R15                      save rc
         LA    R4,TCBTOK_TLEN
         LR    R1,R10
         FREEMAIN RU,A=(R1),LV=(R4)
         LR    R15,R0                      restore rc
         LTR   R15,R15
         JNZ   QINIT_TTKN_FAIL

* Probe that payload64 mode is usable in this runtime environment:
* - Allocate one minimal memory object (1 segment) using the captured jobstep TTOKEN.
* - DETACH it immediately.
* If GETSTOR fails (authorization/config/etc.), fail QINIT with a clear RC.
         LGHI  R7,1
         BRASL R14,MPMCQ_PAYGET           in: R7=len, out: R8=addr64, R15=rc
         LTR   R15,R15
         JZ    QINIT_PAY64_PROBE_FREE
         LA    R15,16                     payload64 unsupported in this environment
         J     QINIT_RET
QINIT_PAY64_PROBE_FREE DS 0H
         BRASL R14,MPMCQ_PAYFREE          in: R8=addr64, R7=len
         J     QINIT_TTKN_DONE

QINIT_TTKN_FAIL DS 0H
* Could not obtain jobstep TTOKEN; payload64 mode is not usable.
         LA    R15,8
         J     QINIT_RET

QINIT_TTKN_DONE DS 0H

* Store callback configuration:
* - QCB_CB_EP: async callback entry point (invoked by notifier TCB)
* - QCB_CB_CTX: user context value passed to callback
* - QCB_USER_ECB: optional user ECB posted on each successful enqueue
         L     R3,QINIT_CB_EP
         ST    R3,QCB_CB_EP
         L     R3,QINIT_CB_CTX
         ST    R3,QCB_CB_CTX
         L     R3,QINIT_USER_ECB
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
         ST    R0,QCB_TERM_ECB
         ST    R0,QCB_CB_ARMED

* Zero stats area (approximate counters; see QSTATS). Stop at the TDB so
* the XC length stays within 256. The TDB is its own 256-byte group.
         XC    QCB_STAT_ENQ_OK(QCB_TDB-QCB_STAT_ENQ_OK),QCB_STAT_ENQ_OK
         XC    QCB_TDB(256),QCB_TDB

* Allocate initial dummy node (in 31-bit storage).
*
* Michael-Scott queue uses a dummy node:
* - HEAD points to a dummy node; first real element is HEAD->NEXT
* - DEQ swings HEAD forward and recycles the old dummy node
         LA    R4,NODE_SIZE
         GETMAIN RC,LV=(R4),LOC=ANY
         LTR   R15,R15
         JZ    QINIT_DUMMY_OK
         LA    R15,8
         J     QINIT_RET
QINIT_DUMMY_OK DS 0H
         LLGTR NEWNODE_R,R1                 NEWNODE_R = node addr (upper cleared)
         USING MPMCQ_NODE,NEWNODE_R
         XC    0(NODE_SIZE,NEWNODE_R),0(NEWNODE_R)

* Initialize node counters:
* - NODE_CNT_INT: internal references (reserved for future reclamation refinement)
* - NODE_CNT_EXT: reserved for future reclamation refinement
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
* ABA tags start at 0; each pointer update uses (old tag + 1). QCB_ABA_SEQ is no longer used.
         XR    R0,R0
         ST    R0,QCB_HEAD_ABA
         ST    NEWNODE_R,QCB_HEAD_PTR
         ST    R0,QCB_TAIL_ABA
         ST    NEWNODE_R,QCB_TAIL_PTR

* Initialize freelist empty (node reuse pool)
         ST    R0,QCB_FREE_ABA
         ST    R0,QCB_FREE_PTR
* Initialize payload cell pools empty (payload31 mode)
         ST    R0,QCB_PAY256_ABA
         ST    R0,QCB_PAY256_PTR
         ST    R0,QCB_PAY1024_ABA
         ST    R0,QCB_PAY1024_PTR
         ST    R0,QCB_PAY4096_ABA
         ST    R0,QCB_PAY4096_PTR
         ST    R0,QCB_PAY16384_ABA
         ST    R0,QCB_PAY16384_PTR

* Initialize ABA tag generator (separate from ENQ_SEQ used for notifier PendingCount)
         ST    R0,QCB_ABA_SEQ

* Start notifier TCB (if callback EP provided).
* Notifier lives in src/mpmcq_notify.asm; producers wake it via POST.
         BRASL R14,MPMCQ_NSTART

* Return rc from MPMCQ_NSTART (0 if no callback; nonzero if ATTACH/IDENTIFY failed).
* NOTE: Do NOT clobber R15 here; QINIT returns NSTART's rc.
QINIT_RET DS 0H
         L     R14,12(,R13)
         LM    R2,R12,28(,R13)           * restore non-volatiles only
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
         LARL  R12,MPMCQ
    
         USING MPMCQ,12

* Save parm list pointer across helper calls (POPNODE clobbers R6/R7 etc.)
         LR    R11,R1
         USING MPMCQ_QENQ_PLIST,R11
* Slab allocation uses IN_PUSHNODE which clobbers R11; keep a backup.
         LR    R3,R11

         L     Q_R,ENQ_QCBADDR
         USING MPMCQ_QCB,Q_R

* Enforce MVCL length limit (24-bit length field) BEFORE allocating a node.
* Use unsigned compare so "large" lengths don't appear negative.
         L     R0,ENQ_SRCLEN
         CLFI  R0,MPMCQ_MAX_REC_LEN
         JH    ENQ_TOO_LARGE

* Enforce payload31 maximum record length BEFORE allocating a node.
* This build does not support oversized payload31 buffers because freeing a
* task-owned GETMAIN from an arbitrary consumer task is not reliable.
         TM    QCB_FLAGS+3(Q_R),X'01'      * payload64?
         JNZ   ENQ_LEN_OK
         CLFI  R0,MPMCQ_MAX_REC31_LEN
         JH    ENQ_TOO_LARGE
ENQ_LEN_OK DS 0H

* Allocate/reuse node:
* - Try lock-free freelist pop first (fast, lock-free)
* - If empty, allocate a SLAB of nodes and push to freelist (slow path)
         BRASL R14,IN_POPNODE
         LTR   R1,R1
         JZ    QENQ_GETMAIN
         LR    NEWNODE_R,R1
         J     QENQ_HAVE_NODE_POP

QENQ_GETMAIN DS 0H
* Slab allocation (cold path): allocate a batch of nodes, push them to the
* freelist, then pop one.
SLAB_NODECNT EQU 64
SLAB_LEN     EQU SLAB_NODECNT*NODE_SIZE
         LA    R4,SLAB_LEN
         GETMAIN RC,LV=(R4),LOC=ANY
         LTR   R15,R15
         JZ    QENQ_SLAB_OK
* Could not grow node pool.
         MPMCQ_STATINC Q_R,QCB_STAT_ENQ_ALLOC_FAIL,R8,R9
         LA    R15,8
               L     R14,12(,R13)
               LM    R2,R12,28(,R13)
               BR    R14
QENQ_SLAB_OK DS 0H
         LLGTR R8,R1                       R8 = slab base (upper cleared)
         LA    R9,SLAB_NODECNT             R9 = nodes remaining
QENQ_SLAB_LOOP DS 0H
         LR    NEWNODE_R,R8
* Brand-new node: clear all fields (including NODE_NEXT_ABA initial value).
         XC    0(NODE_SIZE,NEWNODE_R),0(NEWNODE_R)
         BRASL R14,IN_PUSHNODE
         LA    R8,NODE_SIZE(,R8)
         BCT   R9,QENQ_SLAB_LOOP

* Now pop one node for this enqueue.
         BRASL R14,IN_POPNODE
         LTR   R1,R1
         JZ    ENQ_FATAL
         LR    NEWNODE_R,R1
         J     QENQ_HAVE_NODE_POP

QENQ_HAVE_NODE_POP DS 0H
         USING MPMCQ_NODE,NEWNODE_R
* Reused node: do NOT clear NODE_NEXT_ABA; keep it monotonic across reuse (ABA mitigation).
* Clear the pointer to indicate "not linked", and clear freelist/payload ownership fields.
         XR    R0,R0
         ST    R0,NODE_NEXT_PTR
         ST    R0,NODE_FREE_ABA
         ST    R0,NODE_FREE_PTR
         XGR   R0,R0
         STG   R0,NODE_PAYLOAD64
         ST    R0,NODE_PAYLOAD_LEN
         J     QENQ_HAVE_NODE_INIT

QENQ_HAVE_NODE_INIT DS 0H
         USING MPMCQ_NODE,NEWNODE_R

* Load caller data pointer/length now (after POPNODE; POPNODE clobbers R6/R7)
         LR    R11,R3                      restore parm list pointer (slab path)
         L     R6,ENQ_SRCADDR
         L     R7,ENQ_SRCLEN

* Allocate payload and copy in (variable length).
* Default mode is 31-bit payload (below 2G). Optional 64-bit mode uses IARV64.
         LTR   R7,R7
         JZ    QENQ_PAYLOAD_SET
* Decide payload mode based on QCB_FLAGS bit 0 (MPMCQ_OPT_PAYLOAD64)
* (ZS5+ minimum) test the bit directly without loading/masking a fullword.
         TM    QCB_FLAGS+3(Q_R),X'01'      * MPMCQ_OPT_PAYLOAD64?
         JNZ   QENQ_PAYLOAD_64

* 31-bit payload (payload31 mode):
* Size-class payload cell pools to take GETMAIN/FREEMAIN off the hot path.
* We allocate a fixed-size cell from the smallest pool that fits the record.
* (Allocated size is tracked in R1 for payload-usage stats.)
         CHI   R7,256
         JNH   QENQ_PAY31_256
         CHI   R7,1024
         JNH   QENQ_PAY31_1024
         CHI   R7,4096
         JNH   QENQ_PAY31_4096
         CHI   R7,16384
         JNH   QENQ_PAY31_16384
         J     ENQ_TOO_LARGE

***********************************************************************
* PAY31: <=256 cell pool
***********************************************************************
QENQ_PAY31_256 DS 0H
* Pop a 256-byte payload cell from QCB_PAY256_*(ABA,PTR) (Treiber stack).
         LG    R0,QCB_PAY256_ABA(Q_R)       expected (ABA,PTR) in one 8B load
         LLGFR R1,R0                        R1 = PTR
         SRLG  R0,R0,32                     R0 = ABA
P256_POP_RETRY DS 0H
         LTR   R1,R1
         JZ    P256_SLAB
         LLGTR R4,R1                        R4 = payload cell (upper cleared)
         L     R9,0(R4)                     R9 = next cell (stored in first word)
         AHIK  R8,R0,1                      desired ABA = old + 1
         CDS   R0,R8,QCB_PAY256_ABA(Q_R)    swap PTR=R9 (odd reg of swap pair)
         JNE   P256_POP_RETRY

* Have payload cell in R4; copy bytes (<=256) with EXRL MVC (PC-relative target).
         LGHI  R1,256                       allocSize for stats (cell size)
         LLGTR R8,R4                        dest addr (upper cleared)
         LR    R9,R7
         BCTR  R9,0
         EXRL  R9,ENQ_MVC
         J     ENQ_COPY_DONE

P256_SLAB DS 0H
* Pool empty: allocate a batch of cells, push them, then retry pop.
P256_CELL_CNT EQU 64
P256_SLAB_LEN EQU P256_CELL_CNT*256
         LGHI  R4,P256_SLAB_LEN
         GETMAIN RC,LV=(R4),LOC=ANY
         LTR   R15,R15
         JNZ   ENQ_ALLOC_FAIL
         LLGTR R8,R1                        R8 = slab base (upper cleared)
         LA    R9,P256_CELL_CNT             R9 = cells remaining
P256_SLAB_LOOP DS 0H
         LLGTR R4,R8                        R4 = cell ptr (upper cleared)
* Push cell onto payload pool head.
         LG    R0,QCB_PAY256_ABA(Q_R)
         LLGFR R1,R0
         SRLG  R0,R0,32
P256_PUSH_RETRY DS 0H
         ST    R1,0(R4)                     link cell -> old head ptr
         AHIK  R10,R0,1                     desired ABA = old + 1
         LR    R11,R4                       desired PTR = cell
         CDS   R0,R10,QCB_PAY256_ABA(Q_R)
         JNE   P256_PUSH_RETRY
         AHI   R8,256
         BCT   R9,P256_SLAB_LOOP
         J     QENQ_PAY31_256

***********************************************************************
* PAY31: <=1024 cell pool
***********************************************************************
QENQ_PAY31_1024 DS 0H
* Pop a 1024-byte payload cell from QCB_PAY1024_*(ABA,PTR).
         LG    R0,QCB_PAY1024_ABA(Q_R)
         LLGFR R1,R0
         SRLG  R0,R0,32
P1K_POP_RETRY DS 0H
         LTR   R1,R1
         JZ    P1K_SLAB
         LLGTR R4,R1
         L     R9,0(R4)
         AHIK  R8,R0,1
         CDS   R0,R8,QCB_PAY1024_ABA(Q_R)
         JNE   P1K_POP_RETRY
         LGHI  R1,1024                      allocSize for stats (cell size)
         LLGTR R8,R4
         J     ENQ_COPY_MVCL

P1K_SLAB DS 0H
P1K_CELL_CNT EQU 64
P1K_SLAB_LEN EQU P1K_CELL_CNT*1024
         LLILF R4,P1K_SLAB_LEN
         GETMAIN RC,LV=(R4),LOC=ANY
         LTR   R15,R15
         JNZ   ENQ_ALLOC_FAIL
         LLGTR R8,R1
         LA    R9,P1K_CELL_CNT
P1K_SLAB_LOOP DS 0H
         LLGTR R4,R8
         LG    R0,QCB_PAY1024_ABA(Q_R)
         LLGFR R1,R0
         SRLG  R0,R0,32
P1K_PUSH_RETRY DS 0H
         ST    R1,0(R4)
         AHIK  R10,R0,1
         LR    R11,R4
         CDS   R0,R10,QCB_PAY1024_ABA(Q_R)
         JNE   P1K_PUSH_RETRY
         AHI   R8,1024
         BCT   R9,P1K_SLAB_LOOP
         J     QENQ_PAY31_1024

***********************************************************************
* PAY31: <=4096 cell pool
***********************************************************************
QENQ_PAY31_4096 DS 0H
* Pop a 4096-byte payload cell from QCB_PAY4096_*(ABA,PTR).
         LG    R0,QCB_PAY4096_ABA(Q_R)
         LLGFR R1,R0
         SRLG  R0,R0,32
P4K_POP_RETRY DS 0H
         LTR   R1,R1
         JZ    P4K_SLAB
         LLGTR R4,R1
         L     R9,0(R4)
         AHIK  R8,R0,1
         CDS   R0,R8,QCB_PAY4096_ABA(Q_R)
         JNE   P4K_POP_RETRY
         LGHI  R1,4096                      allocSize for stats (cell size)
         LLGTR R8,R4
         J     ENQ_COPY_MVCL

P4K_SLAB DS 0H
P4K_CELL_CNT EQU 16
P4K_SLAB_LEN EQU P4K_CELL_CNT*4096
         LLILF R4,P4K_SLAB_LEN
         GETMAIN RC,LV=(R4),LOC=ANY
         LTR   R15,R15
         JNZ   ENQ_ALLOC_FAIL
         LLGTR R8,R1
         LA    R9,P4K_CELL_CNT
P4K_SLAB_LOOP DS 0H
         LLGTR R4,R8
         LG    R0,QCB_PAY4096_ABA(Q_R)
         LLGFR R1,R0
         SRLG  R0,R0,32
P4K_PUSH_RETRY DS 0H
         ST    R1,0(R4)
         AHIK  R10,R0,1
         LR    R11,R4
         CDS   R0,R10,QCB_PAY4096_ABA(Q_R)
         JNE   P4K_PUSH_RETRY
         AHI   R8,4096
         BCT   R9,P4K_SLAB_LOOP
         J     QENQ_PAY31_4096

***********************************************************************
* PAY31: <=16384 cell pool
***********************************************************************
QENQ_PAY31_16384 DS 0H
* Pop a 16384-byte payload cell from QCB_PAY16384_*(ABA,PTR).
         LG    R0,QCB_PAY16384_ABA(Q_R)
         LLGFR R1,R0
         SRLG  R0,R0,32
P16K_POP_RETRY DS 0H
         LTR   R1,R1
         JZ    P16K_SLAB
         LLGTR R4,R1
         L     R9,0(R4)
         AHIK  R8,R0,1
         CDS   R0,R8,QCB_PAY16384_ABA(Q_R)
         JNE   P16K_POP_RETRY
         LLILF R1,16384                     allocSize for stats (cell size)
         LLGTR R8,R4
         J     ENQ_COPY_MVCL

P16K_SLAB DS 0H
P16K_CELL_CNT EQU 4
P16K_SLAB_LEN EQU P16K_CELL_CNT*16384
         LLILF R4,P16K_SLAB_LEN
         GETMAIN RC,LV=(R4),LOC=ANY
         LTR   R15,R15
         JNZ   ENQ_ALLOC_FAIL
         LLGTR R8,R1
         LA    R9,P16K_CELL_CNT
P16K_SLAB_LOOP DS 0H
         LLGTR R4,R8
         LG    R0,QCB_PAY16384_ABA(Q_R)
         LLGFR R1,R0
         SRLG  R0,R0,32
P16K_PUSH_RETRY DS 0H
         ST    R1,0(R4)
         AHIK  R10,R0,1
         LR    R11,R4
         CDS   R0,R10,QCB_PAY16384_ABA(Q_R)
         JNE   P16K_PUSH_RETRY
         AHI   R8,16384
         BCT   R9,P16K_SLAB_LOOP
         J     QENQ_PAY31_16384
ENQ_COPY_MVCL DS 0H
         LR    R9,R7                       dest len
         LR    R10,R6                      src addr
         LR    R11,R7                      src len
         MVCL  R8,R10
ENQ_COPY_DONE DS 0H
         LLGTR R8,R4                       restore payload ptr for STG (upper cleared)
         STG   R8,NODE_PAYLOAD64
         ST    R7,NODE_PAYLOAD_LEN

* Update payload31 stats
* cur += len via one interlocked add (HI/LO form an aligned doubleword);
* raise max only when exceeded (compare first, CSG only if needed).
* R1 holds the allocated payload bytes (cell size).
         LAALG R0,R1,QCB_STAT_PAYLOAD31_CUR_HI   R0 = old cur
         ALGR  R0,R1                             R0 = new cur
         LG    R1,QCB_STAT_PAYLOAD31_MAX_HI
ENQ_M31  CLGR  R0,R1
         JNH   ENQ_M31_DONE
         CSG   R1,R0,QCB_STAT_PAYLOAD31_MAX_HI
         JNE   ENQ_M31                           R1 refreshed on failure
ENQ_M31_DONE DS 0H
         J     QENQ_PAYLOAD_DONE

QENQ_PAYLOAD_64 DS 0H
* 64-bit payload: IARV64 via MPMCQ_PAYGET + SAM64 copy macro
         BRASL R14,MPMCQ_PAYGET           in: R7=len, out: R8=addr64, R15=rc
         LTR   R15,R15
         JZ    QENQ_PAYLOAD_COPY
* Allocation failed: stats + recycle node
ENQ_ALLOC_FAIL DS 0H
         MPMCQ_STATINC Q_R,QCB_STAT_ENQ_ALLOC_FAIL,R8,R9
         BRASL R14,IN_PUSHNODE
         LA    R15,8
               L     R14,12(,R13)
               LM    R2,R12,28(,R13)
               BR    R14

QENQ_PAYLOAD_COPY DS 0H
* Copy from src (31-bit in R6) to payload (64-bit in R8), length R7.
* This is safe for AMODE 31 callers because the copy is wrapped with SAM64/SAM31.
* IMPORTANT: MVCL advances its operand registers; store payload start before the copy.
         STG   R8,NODE_PAYLOAD64
         MPMCQ_COPY_31_TO_64 R6,R8,R7,R8,R10,R11

* Record payload in node
         ST    R7,NODE_PAYLOAD_LEN

* Update 64-bit payload usage stats.
* IARV64 GETSTOR allocates in 1MB segments, so count allocated bytes:
*   allocSize = ceil(len / 1MB) * 1MB = ((len + (1MB-1)) >> 20) << 20
         LLGFR R1,R7
         LLILF R0,X'000FFFFF'               1MB-1
         ALGR  R1,R0
         SRLG  R1,R1,20
         SLLG  R1,R1,20
         LAALG R0,R1,QCB_STAT_PAYLOAD64_CUR_HI   R0 = old cur
         ALGR  R0,R1                             R0 = new cur
         LG    R1,QCB_STAT_PAYLOAD64_MAX_HI
ENQ_M64  CLGR  R0,R1
         JNH   ENQ_M64_DONE
         CSG   R1,R0,QCB_STAT_PAYLOAD64_MAX_HI
         JNE   ENQ_M64                           R1 refreshed on failure
ENQ_M64_DONE DS 0H
         J     QENQ_PAYLOAD_SET

QENQ_PAYLOAD_SET DS 0H
         LTR   R7,R7
         JNZ   QENQ_PAYLOAD_DONE
         XGR   R0,R0
         STG   R0,NODE_PAYLOAD64
         ST    R0,NODE_PAYLOAD_LEN
QENQ_PAYLOAD_DONE DS 0H
* Avoid ambiguous MPMCQ_NODE USINGs later (tail traversal uses NODE_R).
         DROP  NEWNODE_R

         AIF   (MPMCQ_ENABLE_BACKOFF EQ 0).ENQ_BOF_INIT_DONE
* Backoff state (R14) lives across ENQ_RETRY_LOOP iterations for this call only.
         XR    R14,R14                      backoff=0
.ENQ_BOF_INIT_DONE ANOP

* Enqueue publish.
* The node is private and the payload bytes are already in it.
* When MPMCQ_ENABLE_TX=1, one unconstrained transaction stores both
* TAIL->NEXT and TAIL. A hardware abort leaves no queue update and falls
* back to the CDS loop below (that loop also helps a lagging tail).
* A lagging tail executes TEND with no stores, then the CDS path.
* ABA tags are still advanced so the fallback and other CPUs stay consistent.
* I2=X'00FF': no AR or FP updates, all GR pairs restored on abort.
* QCB_TDB receives the abort code (bytes 6-7) and the aborted-instruction
* address (bytes 8-15). It is not referenced inside the transaction.
* R14 is the attempt count. It is restored with the other GRs, then
* decremented only on the abort path (outside the transaction).
         AIF   (MPMCQ_ENABLE_TX EQ 0).ENQ_TX_OFF
         LGHI  R14,MPMCQ_TX_RETRIES
ENQ_TX_TRY DS 0H
         TBEGIN QCB_TDB,X'00FF'
         JNZ   ENQ_TX_ABORT
         LT    R1,QCB_TAIL_PTR
         JZ    ENQ_TX_LEAVE
         L     R0,QCB_TAIL_ABA
         LR    NODE_R,R1
         USING MPMCQ_NODE,NODE_R
         LT    NEXTNODE_R,NODE_NEXT_PTR
         JNZ   ENQ_TX_LEAVE               lagging tail: commit nothing, CDS helps
         L     R6,NODE_NEXT_ABA
         AHIK  R6,R6,1
         ST    R6,NODE_NEXT_ABA
         ST    NEWNODE_R,NODE_NEXT_PTR
         DROP  NODE_R
         AHIK  R0,R0,1
         ST    R0,QCB_TAIL_ABA
         ST    NEWNODE_R,QCB_TAIL_PTR
         TEND
         J     ENQ_PUBLISHED
ENQ_TX_LEAVE DS 0H
         TEND
         J     ENQ_LOOP
ENQ_TX_ABORT DS 0H
* QCB_TDB_TAC and QCB_TDB_ATIA describe this abort. CC still selects the path.
         JO    ENQ_LOOP                    CC3: persistent, do not retry TX
         BCTR  R14,0
         JNZ   ENQ_TX_TRY
.ENQ_TX_OFF ANOP
* Michael-Scott algorithm (tagged pointers).
* CAS tail->next from (aba,0) to (newAba,new_node), then swing tail forward
* (helping when tail lags).
ENQ_LOOP DS 0H
* Load tail tagged pointer (ABA,PTR) into (R0,R1).
* R0/R1 is the expected value for the tail swing (CDS on QCB_TAIL_ABA/QCB_TAIL_PTR).
         LT    R1,QCB_TAIL_PTR
         JZ    ENQ_FATAL
         L     R0,QCB_TAIL_ABA
         LR    NODE_R,R1                   tail_ptr
         USING  MPMCQ_NODE,NODE_R

* Read TAIL->NEXT (ABA,PTR).
* If NEXT_PTR != 0, some thread already linked a node; we "help" by advancing tail.
         L     R6,NODE_NEXT_ABA
         LT    NEXTNODE_R,NODE_NEXT_PTR
         JNZ   ENQ_HELP_TAIL

* Revalidate tail snapshot before attempting to link.
* Prevents a stale enqueuer from linking via a recycled tail node.
         L     R4,QCB_TAIL_ABA
         CR    R4,R0
         JNE   ENQ_RETRY_LOOP
         L     R4,QCB_TAIL_PTR
         CR    R4,R1
         JNE   ENQ_RETRY_LOOP

* Attempt to link NEXT from (aba_read,0) to (newABA,new_node_ptr).
* This is the ENQ linearization point: once this succeeds, consumers can see the node.
         XR    R7,R7
* New NEXT tag = old NEXT tag + 1 (per-node and monotonic across reuse;
* no shared tag counter).
         AHIK  R8,R6,1                   desired ABA
         LR    R9,NEWNODE_R                desired PTR = new node
         CDS   R6,R8,NODE_NEXT_ABA(NODE_R)
         JNE   ENQ_RETRY_LOOP

* Swing tail tagged pointer to the newly linked node (best-effort).
* It's fine if this fails; other threads will advance tail.
         AHIK  R8,R0,1                   desired ABA = tail tag + 1
         LR    R9,NEWNODE_R                desired PTR
         CDS   R0,R8,QCB_TAIL_ABA(Q_R)

ENQ_PUBLISHED DS 0H
* Update stats for success (approx)
         MPMCQ_STATINC Q_R,QCB_STAT_ENQ_OK,R8,R9
* depth++ (then update max using the post-increment value)
         ASI   QCB_STAT_QDEPTH_CUR(Q_R),1
         L     R9,QCB_STAT_QDEPTH_CUR
         MPMCQ_STATMAX Q_R,QCB_STAT_QDEPTH_MAX,R9,R8,R11

* ENQ notifications:
* - increment ENQ_SEQ (used by notifier to compute PendingCount)
* - POST internal ECB (wakes notifier TCB; posts may coalesce)
* - POST user ECB if provided (posts may coalesce)
ENQ_SEQ_LOOP DS 0H
* Wake the notifier only if a callback was configured at QINIT (no notifier
* exists otherwise, so ENQ_SEQ and the POST SVC are pure overhead).
         LT    R0,QCB_CB_EP
         JZ    ENQ_NO_NOTIFY
         ASI   QCB_ENQ_SEQ(Q_R),1
* Serialize store->load so notifier cannot miss ENQ_SEQ update vs ARMED.
* Note: ASI is an interlocked-update reference (atomic), but does not provide
* CPU-wide serialization across distinct locations; the serializing BCR is
* required for the ARMED/SEQ handshake to be robust under SMP.
         BCR   15,0
* Coalesce internal POSTs: only POST when the notifier is armed (waiting/arming).
* Producers clear QCB_CB_ARMED as they POST so bursts cost ~1 SVC.
         LT    R0,QCB_CB_ARMED
         JZ    ENQ_NO_NOTIFY
         XR    R1,R1
         CS    R0,R1,QCB_CB_ARMED          try to clear 1->0; only one wins
         JNE   ENQ_NO_NOTIFY
         POST  ECB=QCB_CB_ECB
         MPMCQ_STATINC Q_R,QCB_STAT_POST_INTERNAL,R8,R9
ENQ_NO_NOTIFY DS 0H

         LT    R4,QCB_USER_ECB
         JZ    ENQ_NO_USERECB
         POST  ECB=(R4)
         MPMCQ_STATINC Q_R,QCB_STAT_POST_USERECB,R8,R9
         
ENQ_NO_USERECB DS 0H

         XR    R15,R15
               L     R14,12(,R13)
               LM    R2,R12,28(,R13)
               BR    R14

ENQ_HELP_TAIL DS 0H
* Help advance tail when it lags: set tail to NEXT_PTR.
* This reduces contention by keeping tail close to the end of the list.
         AHIK  R8,R0,1                   desired ABA = tail tag + 1
         LR    R9,NEXTNODE_R               desired PTR = NEXT_PTR
         CDS   R0,R8,QCB_TAIL_ABA(Q_R)
         J     ENQ_RETRY_LOOP

ENQ_FATAL DS 0H
* Unexpected: tail is null; treat as failure
         MPMCQ_STATINC Q_R,QCB_STAT_ENQ_ALLOC_FAIL,R8,R9
         LA    R15,8
               L     R14,12(,R13)
               LM    R2,R12,28(,R13)
               BR    R14

ENQ_TOO_LARGE DS 0H
* Record too large for this build:
* - payload31 mode: len > 16384 (largest pool tier)
* - payload64 mode: len > 16MB-1 (MVCL limit)
         LA    R15,12
               L     R14,12(,R13)
               LM    R2,R12,28(,R13)
               BR    R14

* Out-of-line retry entry: counts only actual retries (keeps the fast path
* free of an interlocked update).
ENQ_RETRY_LOOP DS 0H
* PPA order 1: spinning on CAS. R0=0 means no lock address and no target CPU.
         XR    R0,R0
         PPA   0,0,1
         MPMCQ_STATINC Q_R,QCB_STAT_ENQ_RETRY,R8,R9
         AIF   (MPMCQ_ENABLE_BACKOFF EQ 0).ENQ_BOF_SKIP
* Exponential backoff (register-only spin) to reduce cache-line ping-pong
* under extreme contention. Uses R14 as the per-call backoff counter.
         LTR   R14,R14
         JNZ   ENQ_BOF_GROW
         LGHI  R14,1
         J     ENQ_BOF_SPIN
ENQ_BOF_GROW DS 0H
         SLLG  R14,R14,1
         CLFI  R14,MPMCQ_BACKOFF_MAX
         JNH   ENQ_BOF_SPIN
         LGHI  R14,MPMCQ_BACKOFF_MAX
ENQ_BOF_SPIN DS 0H
         LR    R1,R14
ENQ_BOF_LOOP DS 0H
         BCR   0,0
         BCT   R1,ENQ_BOF_LOOP
.ENQ_BOF_SKIP ANOP
         J     ENQ_LOOP

* EX targets for small copies (executed instructions; read-only, in CSECT)
ENQ_MVC  MVC   0(1,R8),0(R6)

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
         LARL  R12,MPMCQ
    
         USING MPMCQ,12

* Save parm list pointer across retries/helper calls.
         LR    R11,R1
         USING MPMCQ_QDEQ_PLIST,R11

         L     Q_R,DEQ_QCBADDR
         USING MPMCQ_QCB,Q_R

         AIF   (MPMCQ_ENABLE_BACKOFF EQ 0).DEQ_BOF_INIT_DONE
* Backoff state (R14) lives across DEQ_RETRY_LOOP iterations for this call only.
         XR    R14,R14                      backoff=0
.DEQ_BOF_INIT_DONE ANOP

DEQ_LOOP DS 0H
* Michael-Scott dequeue:
* - Read head/tail/next snapshot
* - If head==tail and next!=0, help advance tail and retry
* - Read payload from next BEFORE swinging head
* - Swing head to next (linearization point)
*
* Snapshot head (ABA,PTR) and tail (ABA,PTR)
* Use dedicated even/odd pairs for CDS:
* - head expected in (R4,R5)
* - tail expected in (R6,R7)
         LT    R5,QCB_HEAD_PTR             head_ptr
         JZ    DEQ_EMPTY                   (corrupt/never-inited QCB)
         L     R4,QCB_HEAD_ABA

         L     R6,QCB_TAIL_ABA
         L     R7,QCB_TAIL_PTR             tail_ptr

* Read head->next pointer
         LR    NODE_R,R5
         USING MPMCQ_NODE,NODE_R
         LT    NEXTNODE_R,NODE_NEXT_PTR    next_ptr
         JZ    DEQ_NEXT_NULL

* If head_ptr == tail_ptr, help advance tail and retry
         CR    R5,R7
         JNE   DEQ_HAVE_ELEM

DEQ_HELP_TAIL DS 0H
* Help: swing tail from (tail_aba,tail_ptr) to (newABA,next_ptr)
         AHIK  R8,R6,1                   desired ABA = tail tag + 1
         LR    R9,NEXTNODE_R               desired PTR
         CDS   R6,R8,QCB_TAIL_ABA(Q_R)
         J     DEQ_RETRY_LOOP

DEQ_HAVE_ELEM DS 0H
         DROP  NODE_R
* Publish the head swing in one transaction when the element is already
* visible (next != 0 and head != tail). TBEGIN/TEND are problem-state
* instructions; they do not need authorization.
* Payload length and address are loaded inside the transaction, so those
* reads commit with the HEAD store. The CDS fallback below reads them
* before its own swing and relies on the queue invariants instead.
         AIF   (MPMCQ_ENABLE_TX EQ 0).DEQ_TX_OFF
         LGHI  R14,MPMCQ_TX_RETRIES
DEQ_TX_TRY DS 0H
         TBEGIN QCB_TDB,X'00FF'
         JNZ   DEQ_TX_ABORT
         L     R0,QCB_HEAD_PTR
* R4 still holds the pre-transaction head ABA. Do not reload QCB_HEAD_ABA.
* Every writer (CDS and this transaction) updates ABA and PTR in one
* atomic operation, so an unchanged PTR means the ABA is unchanged too.
         CR    R0,R5
         JNE   DEQ_TX_LEAVE
         LR    NODE_R,R5
         USING MPMCQ_NODE,NODE_R
         L     NEXTNODE_R,NODE_NEXT_PTR
         LTR   NEXTNODE_R,NEXTNODE_R
         JZ    DEQ_TX_LEAVE
         DROP  NODE_R
         USING MPMCQ_NODE,NEXTNODE_R
         L     R9,NODE_PAYLOAD_LEN
         LG    R8,NODE_PAYLOAD64
         DROP  NEXTNODE_R
         AHIK  R0,R4,1
         ST    R0,QCB_HEAD_ABA
         ST    NEXTNODE_R,QCB_HEAD_PTR
         TEND
         J     DEQ_SWUNG
DEQ_TX_LEAVE DS 0H
         TEND
* Head moved or next disappeared. Bound the retries, then use CDS.
         BCTR  R14,0
         JNZ   DEQ_TX_TRY
         J     DEQ_CDS_SWING
DEQ_TX_ABORT DS 0H
* QCB_TDB_TAC (bytes 6-7) and QCB_TDB_ATIA (+8) describe this abort.
         JO    DEQ_CDS_SWING
         BCTR  R14,0
         JNZ   DEQ_TX_TRY
.DEQ_TX_OFF ANOP
DEQ_CDS_SWING DS 0H
* Read payload metadata from the node that will become the new head (NEXTNODE_R).
* IMPORTANT: read before swinging head.
         USING MPMCQ_NODE,NEXTNODE_R
         L     R9,NODE_PAYLOAD_LEN         actual length
         LG    R8,NODE_PAYLOAD64           payload address (64-bit)
         DROP  NEXTNODE_R

* Swing head tagged pointer from old head to (newABA,next_ptr).
* Use R0/R1 as desired (ABA,PTR) pair so we don't clobber payload regs (R8/R9).
         AHIK  R0,R4,1                   desired ABA = head tag + 1
         LR    R1,NEXTNODE_R               desired PTR
         CDS   R4,R0,QCB_HEAD_ABA(Q_R)
         JNE   DEQ_RETRY_LOOP

DEQ_SWUNG DS 0H
* Head swing succeeded:
* - old head node address is R5 (from expected head PTR)
* - payload address is in R8 (64-bit)
* - actual length is in R9 (32-bit)
         LR    R7,R9                       save actual length (copy macro clobbers R9)

* Reload caller output controls (dst addr/max/outLenAddr) after CAS success.
* Keep return code in R6 so it survives PAYFREE/PUSHNODE/stats.
         L     R3,DEQ_DSTADDR              dstAddr
         L     R4,DEQ_DSTMAX               dstMax

* Store actual length to *outLenAddr (always actual, even if truncated)
         LT    R10,DEQ_OUTLENADDR
         JZ    DEQ_OUTLEN_DONE
         ST    R7,0(R10)
DEQ_OUTLEN_DONE DS 0H

* Compute return code now (before later clobbers):
*   RC=8 if actualLen > dstMax, else RC=0.
* LOCR mask 2 selects CC=high (actualLen > dstMax), same as CR / JNH.
         LA    R0,8
         XR    R6,R6
         CR    R7,R4
         LOCR  R6,R0,2

* Determine copy length: copyLen = min(actualLen, dstMax)
         LR    R1,R7
         CR    R1,R4
         LOCR  R1,R4,2                     if actualLen > dstMax, copy dstMax

DEQ_DO_COPY DS 0H
         LTR   R1,R1
         JZ    DEQ_SKIP_COPY
* Small copy in 31-bit payload mode: EXRL MVC (PC-relative target).
         CHI   R1,256
         JH    DEQ_COPY_MVCL
         TM    QCB_FLAGS+3(Q_R),X'01'      64-bit payload? (address may be > 2G)
         JNZ   DEQ_COPY_MVCL
         LR    R9,R1
         BCTR  R9,0
         EXRL  R9,DEQ_MVC
         J     DEQ_SKIP_COPY
DEQ_COPY_MVCL DS 0H
* Copy payload to 31-bit destination. MVCL advances operand registers.
* Preserve payload start in R10 and use a local MVCL setup to avoid
* clobbering the saved return code in R6 and the parm pointer in R11.
         LGR   R10,R8                      save payload start
         LLGTR R0,R3                       dest addr (zero-extended)
         LR    R9,R1                       src len (copyLen)
* Only enter AMODE 64 when payload64 mode is enabled (payload may be >2G).
         TM    QCB_FLAGS+3(Q_R),X'01'      payload64?
         JNZ   DEQ_COPY64_MVCL
* 31-bit payload mode: plain MVCL in AMODE 31.
         MVCL  R0,R8                       dest pair R0/R1, src pair R8/R9
         J     DEQ_COPY_MVCL_DONE
DEQ_COPY64_MVCL DS 0H
         SAM64
         MVCL  R0,R8
         SAM31
DEQ_COPY_MVCL_DONE DS 0H
         LGR   R8,R10                      restore payload start
DEQ_SKIP_COPY DS 0H

* Free payload storage and adjust payload usage stats (cur -= actualLen)
         LTR   R7,R7
         JZ    DEQ_SKIP_FREE
* Restore actual length into R9 for RC computation and free logic
         LR    R9,R7
* Decide payload mode based on QCB_FLAGS bit 0 (MPMCQ_OPT_PAYLOAD64)
* (ZS5+ minimum) test the bit directly without loading/masking a fullword.
* QCB_FLAGS is a fullword; bit0 lives in the low-order byte.
         TM    QCB_FLAGS+3(Q_R),X'01'      * MPMCQ_OPT_PAYLOAD64?
         JNZ   DEQ_FREE_64

* 31-bit payload free:
* Size-class cell pools are returned to their corresponding freelists.
         CHI   R9,256
         JNH   DEQ_FREE31_256
         CHI   R9,1024
         JNH   DEQ_FREE31_1024
         CHI   R9,4096
         JNH   DEQ_FREE31_4096
         CHI   R9,16384
         JNH   DEQ_FREE31_16384
         J     DEQ_FREE31_BADLEN

DEQ_FREE31_256 DS 0H
* Return pooled payload cell to QCB_PAY256_*(ABA,PTR).
         LLGTR R4,R8                        cell address (upper cleared)
         LG    R0,QCB_PAY256_ABA(Q_R)        expected (ABA,PTR)
         LLGFR R1,R0
         SRLG  R0,R0,32
P256_DEQ_PUSH_RETRY DS 0H
         ST    R1,0(R4)                     link cell -> old head ptr
         AHIK  R10,R0,1                     desired ABA = old + 1
         LR    R11,R4                       desired PTR = cell
         CDS   R0,R10,QCB_PAY256_ABA(Q_R)
         JNE   P256_DEQ_PUSH_RETRY
         LGHI  R7,256                       allocSize for stats (cell size)
         J     DEQ_FREE31_STATS

DEQ_FREE31_1024 DS 0H
         LLGTR R4,R8
         LG    R0,QCB_PAY1024_ABA(Q_R)
         LLGFR R1,R0
         SRLG  R0,R0,32
P1K_DEQ_PUSH_RETRY DS 0H
         ST    R1,0(R4)
         AHIK  R10,R0,1
         LR    R11,R4
         CDS   R0,R10,QCB_PAY1024_ABA(Q_R)
         JNE   P1K_DEQ_PUSH_RETRY
         LGHI  R7,1024
         J     DEQ_FREE31_STATS

DEQ_FREE31_4096 DS 0H
         LLGTR R4,R8
         LG    R0,QCB_PAY4096_ABA(Q_R)
         LLGFR R1,R0
         SRLG  R0,R0,32
P4K_DEQ_PUSH_RETRY DS 0H
         ST    R1,0(R4)
         AHIK  R10,R0,1
         LR    R11,R4
         CDS   R0,R10,QCB_PAY4096_ABA(Q_R)
         JNE   P4K_DEQ_PUSH_RETRY
         LGHI  R7,4096
         J     DEQ_FREE31_STATS

DEQ_FREE31_16384 DS 0H
         LLGTR R4,R8
         LG    R0,QCB_PAY16384_ABA(Q_R)
         LLGFR R1,R0
         SRLG  R0,R0,32
P16K_DEQ_PUSH_RETRY DS 0H
         ST    R1,0(R4)
         AHIK  R10,R0,1
         LR    R11,R4
         CDS   R0,R10,QCB_PAY16384_ABA(Q_R)
         JNE   P16K_DEQ_PUSH_RETRY
         LGHI  R7,16384
         J     DEQ_FREE31_STATS

DEQ_FREE31_BADLEN DS 0H
* Should never happen: payload31 mode enforces len <= 16384 at ENQ.
* Do NOT attempt a cross-task FREEMAIN; leave the payload allocated.
         J     DEQ_SKIP_FREE

DEQ_FREE31_STATS DS 0H
* Update payload31 current usage: cur -= len
         LLGFR R0,R7
         LCGR  R0,R0                        -allocSize (64-bit)
         LAAG  R0,R0,QCB_STAT_PAYLOAD31_CUR_HI
         J     DEQ_SKIP_FREE

DEQ_FREE_64 DS 0H
         LR    R9,R7
         LR    R7,R9                       pass actual length to PAYFREE
         BRASL R14,MPMCQ_PAYFREE           in: R8=addr64, R7=len
* Update payload64 current usage: cur -= allocSize (1MB segments)
         LLGFR R0,R7
         LLILF R1,X'000FFFFF'               1MB-1
         ALGR  R0,R1
         SRLG  R0,R0,20
         SLLG  R0,R0,20
         LCGR  R0,R0                        -len (64-bit)
         LAAG  R0,R0,QCB_STAT_PAYLOAD64_CUR_HI

DEQ_SKIP_FREE DS 0H

* Recycle old dummy node into freelist for reuse by producers.
         LR    NEWNODE_R,R5                old head node address
         BRASL R14,IN_PUSHNODE

* stats: deq ok, depth--
         MPMCQ_STATINC Q_R,QCB_STAT_DEQ_OK,R8,R9
         ASI   QCB_STAT_QDEPTH_CUR(Q_R),-1

* Return code was computed earlier into R6.
         LR    R15,R6
DEQ_RET DS 0H
               L     R14,12(,R13)
               LM    R2,R12,28(,R13)
               BR    R14

DEQ_NEXT_NULL DS 0H
* next_ptr is null. Revalidate that head is unchanged before declaring empty.
         LT    R0,QCB_HEAD_PTR
         JZ    DEQ_EMPTY
         CR    R0,R5
         JNE   DEQ_RETRY_LOOP
         L     R1,QCB_HEAD_ABA
         CR    R1,R4
         JNE   DEQ_RETRY_LOOP
* Head unchanged and next is null => empty.
         J     DEQ_EMPTY

DEQ_EMPTY DS 0H
         MPMCQ_STATINC Q_R,QCB_STAT_DEQ_EMPTY,R8,R9
         LA    R15,4
               L     R14,12(,R13)
               LM    R2,R12,28(,R13)
               BR    R14

* Out-of-line retry entry: counts only actual retries.
DEQ_RETRY_LOOP DS 0H
* PPA order 1: spinning on CAS. R0=0 means no lock address and no target CPU.
         XR    R0,R0
         PPA   0,0,1
         MPMCQ_STATINC Q_R,QCB_STAT_DEQ_RETRY,R8,R9
         AIF   (MPMCQ_ENABLE_BACKOFF EQ 0).DEQ_BOF_SKIP
* Exponential backoff (register-only spin) to reduce cache-line ping-pong
* under extreme contention. Uses R14 as the per-call backoff counter.
         LTR   R14,R14
         JNZ   DEQ_BOF_GROW
         LGHI  R14,1
         J     DEQ_BOF_SPIN
DEQ_BOF_GROW DS 0H
         SLLG  R14,R14,1
         CLFI  R14,MPMCQ_BACKOFF_MAX
         JNH   DEQ_BOF_SPIN
         LGHI  R14,MPMCQ_BACKOFF_MAX
DEQ_BOF_SPIN DS 0H
         LR    R1,R14
DEQ_BOF_LOOP DS 0H
         BCR   0,0
         BCT   R1,DEQ_BOF_LOOP
.DEQ_BOF_SKIP ANOP
         J     DEQ_LOOP

* EX target for small copies (executed instruction; read-only, in CSECT)
DEQ_MVC  MVC   0(1,R3),0(R8)

***********************************************************************
* Internal node freelist (Treiber stack) - inlined for speed
*
* Input conventions match the old external helpers:
*   IN_POPNODE:
*     in:  Q_R = QCBaddr
*     out: R1=node, or R1=0 if the freelist is empty (R15 is not a return code)
*     clobbers: R0,R6,R7,NODE_R (R10)
*   IN_PUSHNODE:
*     in:  Q_R = QCBaddr, NEWNODE_R = node addr
*     out: R15=0
*     clobbers: R0,R1,R10,R11
***********************************************************************

         DROP  NODE_R
IN_POPNODE DS 0H
         USING MPMCQ_QCB,Q_R
* Atomic fetch of (ABA,PTR) head. Split once; a failed CDS reloads R0/R1.
         LG    R0,QCB_FREE_ABA(Q_R)          R0=[ABA32][PTR32]
         LLGFR R1,R0                        R1=PTR
         LTR   R1,R1
         JZ    INP_EMPTY                    R1=0 => empty
         SRLG  R0,R0,32                     R0=ABA
INP_RETRY DS 0H
         LR    NODE_R,R1
         USING MPMCQ_NODE,NODE_R
         AHIK  R6,R0,1                      desired ABA = old + 1
         L     R7,NODE_FREE_PTR             desired PTR = node->free_ptr
         DROP  NODE_R
         CDS   R0,R6,QCB_FREE_ABA(Q_R)
         JE    INP_RETRY_DONE
         LTR   R1,R1                        test result of CDS change
         JZ    INP_EMPTY
* Failed CAS and the reloaded head is not empty: spin, then retry.
* R0/R1 hold the reloaded (ABA,PTR) pair, so the hint uses R6 (dead here).
         XR    R6,R6
         PPA   R6,R6,1
         J     INP_RETRY
INP_EMPTY DS 0H
         BR    R14                          R1 already 0
         
INP_RETRY_DONE DS 0H         
         LR    R1,NODE_R                    R1=node
         BR    R14

         DROP  NODE_R
IN_PUSHNODE DS 0H
         USING MPMCQ_QCB,Q_R
         USING MPMCQ_NODE,NEWNODE_R
* Atomic fetch of (ABA,PTR) head
         LG    R0,QCB_FREE_ABA(Q_R)
         LLGFR R1,R0
         SRLG  R0,R0,32
INPS_RETRY DS 0H
         ST    R1,NODE_FREE_PTR             link node -> old head ptr
         AHIK  R10,R0,1                     desired ABA = old + 1
         LR    R11,NEWNODE_R                desired PTR = node
         CDS   R0,R10,QCB_FREE_ABA(Q_R)
         JE    INPS_OK
* R0/R1 hold the reloaded head, so the hint uses R10 (recomputed on retry).
         XR    R10,R10
         PPA   R10,R10,1
         J     INPS_RETRY
INPS_OK  DS    0H
         DROP  NEWNODE_R
         XR    R15,R15
         BR    R14

         END   MPMCQ

