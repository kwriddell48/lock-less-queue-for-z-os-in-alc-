         TITLE 'MPMCQ - Async notify (ATTACH notifier TCB + ECB POST)'
***********************************************************************
*  MPMCQ_NOTIFY.ASM
*
*  Provides asynchronous enqueue notifications:
*   - One notifier TCB per queue, created with ATTACH (optional).
*   - Producers never execute user code; they only POST ECB(s).
*   - Notifier WAITs on internal ECB in QCB, computes PendingCount, calls
*     user callback EP with parm list: (CB_CTX, QCBaddr, PendingCount).
*
*  Notification semantics:
*   - Each successful QENQ increments QCB_ENQ_SEQ and POSTs QCB_CB_ECB.
*   - ECB posts can coalesce; the notifier computes PendingCount as:
*       PendingCount = ENQ_SEQ - CB_SEQ_SEEN
*     so a single callback can represent multiple enqueues.
*
*  Entry points:
*    MPMCQ_NSTART (internal) - start notifier if CB_EP != 0
*    QCBSTOP      (public)   - request notifier stop (best-effort)
*    MPMCQ_NOTIF  (internal) - ATTACH entry point (notifier TCB)
***********************************************************************

         PRINT GEN

         COPY  'src/reg_equates.inc'
         COPY  'src/mpmcq_dsects.inc'
         COPY  'src/mpmcq_atomics.mac'

MPMCQNT  CSECT
MPMCQNT  AMODE 31
MPMCQNT  RMODE ANY

         ENTRY MPMCQ_NSTART
         ENTRY QCBSTOP
         ENTRY MPMCQ_NOTIF

         USING MPMCQNT,R15

***********************************************************************
* Flags (QCB_FLAGS bit definitions)
***********************************************************************
QCBF_STOP    EQU X'80000000'

***********************************************************************
* MPMCQ_NSTART
*   Input: R2 = QCBaddr (already initialized by QINIT)
*   Behavior: if QCB_CB_EP != 0, ATTACH a notifier TCB and store QCB_CB_TCB.
***********************************************************************
MPMCQ_NSTART DS 0H
         STM   R14,R12,12(R13)
         LR    R12,R15
         USING MPMCQNT,12

         USING MPMCQ_QCB,R2
* If no callback entry point is configured, do nothing.
         L     R3,QCB_CB_EP
         LTR   R3,R3
         BZ    NSTART_DONE

* Ensure internal ECB starts cleared (WAIT expects an ECB address in the QCB)
         XR    R0,R0
         ST    R0,QCB_CB_ECB

* ATTACH notifier task. PARM is QCB address.
* NOTE: Adjust ATTACH operands per your standards (subtask attributes, key, etc.).
         ATTACH EP=MPMCQ_NOTIF,PARM=(2)

NSTART_DONE DS 0H
         XR    R15,R15
         LM    R14,R12,12(R13)
         BR    R14

***********************************************************************
* QCBSTOP(QCBaddr)
*   R1 -> parm list: (QCBaddr)
***********************************************************************
QCBSTOP  DS 0H
         STM   R14,R12,12(R13)
         LR    R12,R15
         USING MPMCQNT,12

         L     R2,0(R1)
         USING MPMCQ_QCB,R2

* Set stop flag (best-effort)
STOP_LOOP DS 0H
         L     R0,QCB_FLAGS
         LR    R3,R0
         O     R3,=XL4'80000000'
         CS    R0,R3,QCB_FLAGS
         BNE   STOP_LOOP

* Wake notifier so it can observe stop and exit.
* (If the notifier isn't running, this POST is harmless.)
         POST  ECB=QCB_CB_ECB

         XR    R15,R15
         LM    R14,R12,12(R13)
         BR    R14

***********************************************************************
* MPMCQ_NOTIF - notifier TCB body (ATTACH EP)
*   R1 may contain parm (QCBaddr) depending on ATTACH form.
***********************************************************************
MPMCQ_NOTIF DS 0H
         STM   R14,R12,12(R13)
         LR    R12,R15
         USING MPMCQNT,12

* ATTACH parm: QCB address (convention; adjust if needed)
         LR    R2,R1
         USING MPMCQ_QCB,R2

* Obtain a small private work area for callback parm list (reentrant).
* The callback parm list must not be in static storage because multiple
* notifiers (or reentry) could otherwise collide.
         LA    R4,32
         GETMAIN RU,LV=(R4),LOC=BELOW
         LR    R11,R1                      R11=work area

NOTIF_LOOP DS 0H
* WAIT until a producer posts the internal ECB.
         WAIT  ECB=QCB_CB_ECB

* Stop requested? (best-effort cooperative stop)
         L     R0,QCB_FLAGS
         N     R0,=XL4'80000000'
         LTR   R0,R0
         BNZ   NOTIF_DONE

* Compute PendingCount = ENQ_SEQ - CB_SEQ_SEEN.
* We accept wraparound as a best-effort approximation.
         L     R4,QCB_ENQ_SEQ
         L     R5,QCB_CB_SEQ_SEEN
         SR    R4,R5                        pending (wrap ignored)
         LTR   R4,R4
         BZ    NOTIF_LOOP

* Advance CB_SEQ_SEEN to current ENQ_SEQ (best-effort).
* This defines the "already notified" boundary.
         L     R6,QCB_ENQ_SEQ
         ST    R6,QCB_CB_SEQ_SEEN

* Stats: cb calls, pending max
         MPMCQ_STATINC R2,QCB_STAT_CB_CALLS,R8,R9
         MPMCQ_STATMAX R2,QCB_STAT_CB_PENDING_MAX,R4,R8,R9

* Invoke callback EP if provided.
* Callback runs on this notifier TCB (asynchronous relative to producers).
         L     R7,QCB_CB_EP
         LTR   R7,R7
         BZ    NOTIF_LOOP

* Build parm list in private work area (R1 -> plist):
*   (CB_CTX, QCBaddr, PendingCount)
         LR    R1,R11
         L     R0,QCB_CB_CTX
         ST    R0,CBP_CTX(R1)
         ST    R2,CBP_QCB(R1)
         ST    R4,CBP_PENDING(R1)

         BALR  R14,R7
         B     NOTIF_LOOP

NOTIF_DONE DS 0H
         LA    R4,32
         LR    R1,R11
         FREEMAIN RU,A=(R1),LV=(R4)
         LM    R14,R12,12(R13)
         BR    R14

         END   MPMCQNT

