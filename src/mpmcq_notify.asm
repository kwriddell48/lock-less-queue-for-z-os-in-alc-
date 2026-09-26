         TITLE 'MPMCQ - Async notify (ATTACH notifier TCB + ECB POST)'
*PROCESS GOFF
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
*   - Each successful QENQ increments QCB_ENQ_SEQ and POSTs QCB_CB_ECB when
*     the notifier is armed (posts coalesce to ~1 SVC per burst).
*   - ECB posts can coalesce; the notifier computes PendingCount as:
*       PendingCount = ENQ_SEQ - CB_SEQ_SEEN
*     so a single callback can represent multiple enqueues.
*
*  Entry points:
*    MPMCQ_NSTART (internal) - start notifier if CB_EP != 0
*    QCBSTOP      (public)   - request notifier stop (best-effort)
*    MPMCQ_NOTIF  (internal) - ATTACH entry point (notifier TCB)
*
*  Reentrancy / RENT:
*    IDENTIFY and ATTACH are list/execute form. The MF=L templates below
*    are copied into a GETMAIN work area and executed with MF=E, so a
*    RENT link never stores into this CSECT.
***********************************************************************

         PRINT GEN
         ACONTROL OPTABLE(ZS5)

         COPY  'src/reg_equates.inc'
         COPY  'src/mpmcq_dsects.inc'
         COPY  'src/mpmcq_atomics.mac'

MPMCQNT  CSECT
MPMCQNT  AMODE 31
MPMCQNT  RMODE ANY

         ENTRY MPMCQ_NSTART
         ENTRY QCBSTOP
         ENTRY MPMCQ_NOTIF

***********************************************************************
* IDENTIFY / ATTACH list-form templates (read-only; copied before use)
***********************************************************************
ID_TEMPL  DS   0D
          IDENTIFY MF=L
ID_TLEN   EQU  *-ID_TEMPL
ATT_TEMPL DS   0D
          ATTACH MF=L
ATT_TLEN  EQU  *-ATT_TEMPL
* Reused for one list at a time, so the area must hold the larger list.
IDATT_WLEN EQU ID_TLEN+ATT_TLEN

***********************************************************************
* Flags (QCB_FLAGS bit definitions)
***********************************************************************
QCBF_STOP    EQU X'80000000'

***********************************************************************
* MPMCQ_NSTART
*   Input: Q_R = QCBaddr (already initialized by QINIT)
*   Behavior: if QCB_CB_EP != 0, ATTACH a notifier TCB and store QCB_CB_TCB.
***********************************************************************
MPMCQ_NSTART DS 0H
* Leaf routine: preserve return address/base across SVCs.
* - ATTACH and XC may clobber volatile registers, and GETMAIN/FREEMAIN are SVCs.
* - QINIT does not rely on R10/R11, so use them here.
         LR    R11,R14                      return address (SVCs clobber R14)
         LR    R10,R12                      caller base (restore on exit)
         LARL R12,MPMCQNT
         USING MPMCQNT,12

         USING MPMCQ_QCB,Q_R
* If no callback entry point is configured, do nothing.
         LT    R3,QCB_CB_EP
         JZ    NSTART_NOCB

* Ensure internal ECB starts cleared (WAIT expects an ECB address in the QCB)
         XR    R0,R0
         ST    R0,QCB_CB_ECB
         ST    R0,QCB_TERM_ECB
         ST    R0,QCB_CB_ARMED

* Make an 8-character EP name for ATTACH using IDENTIFY, so EP= does not
* require a load-library directory search for a member name.
* IDENTIFY rc: 0=created, 4=already exists (same address), 8=exists (diff addr).
* Private plist: standard-form IDENTIFY/ATTACH would store into this CSECT.
         LLILF R4,IDATT_WLEN
         GETMAIN RC,LV=(R4),LOC=ANY
         LTR   R15,R15
         JNZ   NSTART_DONE                 R15 = GETMAIN rc
         LR    R8,R1                       R8 = plist work area (kept across SVCs)
         LR    R0,R8
         LLILF R1,ID_TLEN
         LARL  R6,ID_TEMPL
         LLILF R7,ID_TLEN
         MVCL  R0,R6
         LR    R1,R8
         IDENTIFY EP=MPMCQNTF,ENTRY=MPMCQ_NOTIF,MF=(E,(R1))
         LTR   R15,R15
         JZ    NSTART_IDOK
         CHI   R15,4
         JE    NSTART_IDOK
         LR    R9,R15                      save IDENTIFY rc across FREEMAIN
         J     NSTART_FREE
NSTART_IDOK DS 0H

* ATTACH notifier task. PARM is the QCB address in R2.
* NOTE: Adjust ATTACH operands per your standards (subtask attributes, key, etc.).
         LR    R0,R8
         LLILF R1,ATT_TLEN
         LARL  R6,ATT_TEMPL
         LLILF R7,ATT_TLEN
         MVCL  R0,R6
         LR    R1,R8
         ATTACH EP=MPMCQNTF,PARM=(2),ECB=QCB_TERM_ECB,MF=(E,(R1))
* On success, ATTACH returns the new TCB address in R1.
         LR    R9,R15                      save ATTACH rc across FREEMAIN
         LTR   R9,R9
         JNZ   NSTART_FREE
         ST    R1,QCB_CB_TCB
NSTART_FREE DS 0H
         LLILF R4,IDATT_WLEN
         LR    R1,R8
         FREEMAIN RU,A=(R1),LV=(R4)
         LR    R15,R9
         J     NSTART_DONE

NSTART_NOCB DS 0H
         XR    R15,R15

NSTART_DONE DS 0H
         LR    R12,R10
         BR    R11

***********************************************************************
* QCBSTOP(QCBaddr)
*   R1 -> parm list: (QCBaddr)
*   NOTE: node/payload slabs from GETMAIN RC are never FREEMAIN'd here (or
*   anywhere); they remain owned by the allocating TCB(s). The QINIT task
*   must outlive every producer/consumer that may still reference a cell.
***********************************************************************
QCBSTOP  DS 0H
         STM   R14,R12,12(R13)
         LARL R12,MPMCQNT
         USING MPMCQNT,12

         L     Q_R,0(R1)
         USING MPMCQ_QCB,Q_R

* Set stop flag (best-effort)
STOP_LOOP DS 0H
         L     R0,QCB_FLAGS
         LR    R3,R0
         O     R3,=XL4'80000000'
         CS    R0,R3,QCB_FLAGS
         JNE   STOP_LOOP

* Wake notifier so it can observe stop and exit.
* (If the notifier isn't running, this POST is harmless.)
         POST  ECB=QCB_CB_ECB

* If no notifier is running, we're done.
         LT    R3,QCB_CB_TCB
         JZ    STOP_DONE

* Wait for notifier termination (ATTACH ECB=QCB_TERM_ECB is posted at end).
         WAIT  ECB=QCB_TERM_ECB

* Detach the subtask (best-effort).
* DETACH expects the address of a fullword containing the TCB address.
         DETACH QCB_CB_TCB
         XR    R0,R0
         ST    R0,QCB_CB_TCB

STOP_DONE DS 0H
         XR    R15,R15
         L     R14,12(,R13)
         LM    R2,R12,28(,R13)
         BR    R14

***********************************************************************
* MPMCQ_NOTIF - notifier TCB body (ATTACH EP)
*   R1 may contain parm (QCBaddr) depending on ATTACH form.
***********************************************************************
MPMCQ_NOTIF DS 0H
         STM   R14,R12,12(R13)
         LARL R12,MPMCQNT
         USING MPMCQNT,12

* ATTACH parm: QCB address (convention; adjust if needed)
         LR    Q_R,R1
         USING MPMCQ_QCB,Q_R

* Obtain a small private work area for callback parm list (reentrant).
* The callback parm list must not be in static storage because multiple
* notifiers (or reentry) could otherwise collide.
* Work area layout:
*   +0   callback parm list (CB_CTX, QCBaddr, PendingCount)
*   +32  72-byte save area for the user callback (problem-state safe)
         LA    R4,104
         GETMAIN RU,LV=(R4),LOC=ANY
         LR    R11,R1                      R11=work area

NOTIF_LOOP DS 0H
* Disarm while running. Producers only POST when armed, so bursts cost ~1 SVC.
         XR    R0,R0
         ST    R0,QCB_CB_ARMED

NOTIF_CHECK DS 0H
* Stop requested? (best-effort cooperative stop)
* (ZS5+ minimum) test the stop bit directly.
         TM    QCB_FLAGS(Q_R),X'80'        * QCBF_STOP?
         JNZ   NOTIF_DONE

* Compute PendingCount = ENQ_SEQ - CB_SEQ_SEEN.
* Use a single ENQ_SEQ snapshot for both the subtract and the CB_SEQ_SEEN update,
* so enqueues between the two aren't "lost" from PendingCount.
* We accept wraparound as a best-effort approximation.
         L     R6,QCB_ENQ_SEQ               enq_seq snapshot
         L     R5,QCB_CB_SEQ_SEEN
         LR    R4,R6
         SR    R4,R5                        pending (wrap ignored)
         LTR   R4,R4
         JZ    NOTIF_ARM_WAIT

* Advance CB_SEQ_SEEN to current ENQ_SEQ (best-effort).
* This defines the "already notified" boundary.
         ST    R6,QCB_CB_SEQ_SEEN

* Stats: cb calls, pending max
         MPMCQ_STATINC R2,QCB_STAT_CB_CALLS,R8,R9
         MPMCQ_STATMAX R2,QCB_STAT_CB_PENDING_MAX,R4,R8,R9

* Invoke callback EP if provided.
         LT    R7,QCB_CB_EP
         JZ    NOTIF_CHECK

* Build parm list in private work area (R1 -> plist):
*   (CB_CTX, QCBaddr, PendingCount)
         LR    R1,R11
         USING MPMCQ_CB_PLIST,R1
         L     R0,QCB_CB_CTX
         ST    R0,CBP_CTX
         ST    R2,CBP_QCB
         ST    R4,CBP_PENDING
         DROP  R1

* Call user callback asynchronously on notifier TCB.
* Provide a private 72-byte save area so the callback does not clobber ours.
         LR    R10,R13                     save notifier save area
         L     R9,8(R10)                   save forward chain
         LA    R13,32(R11)                 R13 -> callback save area
         XC    0(72,R13),0(R13)
         ST    R10,4(R13)                  backchain
         ST    R13,8(R10)                  forward chain
* Standard call convention: entry point must be in R15.
         LR    R15,R7
         BALR  R14,R15
         ST    R9,8(R10)                   restore forward chain
         LR    R13,R10                     restore notifier save area

         J     NOTIF_CHECK

NOTIF_ARM_WAIT DS 0H
* Arm and recheck to avoid a missed wakeup between "pending==0" and WAIT.
         LA    R0,1
         ST    R0,QCB_CB_ARMED
* Serialize store->load so producers cannot miss ARMED=1.
* (Simple ST is not serializing; without this, store->load reordering can
* allow a missed wakeup under heavy SMP contention.)
         BCR   15,0
         L     R6,QCB_ENQ_SEQ
         L     R5,QCB_CB_SEQ_SEEN
         CR    R6,R5
         JNE   NOTIF_LOOP

* WAIT until a producer posts the internal ECB (or QCBSTOP posts it).
         WAIT  ECB=QCB_CB_ECB
* Clear ECB after WAIT so the next WAIT blocks.
         XR    R0,R0
         ST    R0,QCB_CB_ECB
         J     NOTIF_LOOP

NOTIF_DONE DS 0H
         LA    R4,104
         LR    R1,R11
         FREEMAIN RU,A=(R1),LV=(R4)
         L     R14,12(,R13)
         LM    R2,R12,28(,R13)
         BR    R14

         END   MPMCQNT

