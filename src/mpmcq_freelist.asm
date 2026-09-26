TITLE 'MPMCQ - Lock-free freelist for node reuse (counted pointer CDS)'
*PROCESS GOFF
***********************************************************************
*  MPMCQ_FREELIST.ASM
*
*  Implements a lock-free stack (Treiber) used as a node pool.
*  This is an internal component: nodes are never returned to the system
*  here; they are re-used by pushing/popping from QCB_FREE_(PTR,CNT).
*
*  ABA mitigation:
*    - The freelist head is a tagged pointer (ABA32, PTR31).
*    - Pop/push update the pair atomically with CDS.
*
*  Reentrancy:
*    - No static work areas; this module is safe RENT/reentrant.
*    - All shared state is in the caller's QCB (QCB_FREE_ABA/QCB_FREE_PTR).
*
*  Exported internal entry points:
*    MPMCQ_POPNODE(QCBaddr)  -> R1=node, or R1=0 if empty (R15 is not a return code)
*    MPMCQ_PUSHNODE(QCBaddr,node) -> R15=0
***********************************************************************

         PRINT GEN
         ACONTROL OPTABLE(ZS5)

         COPY  'src/reg_equates.inc'
         COPY  'src/mpmcq_dsects.inc'
         COPY  'src/mpmcq_atomics.mac'

MPMCQFL  CSECT
MPMCQFL  AMODE 31
MPMCQFL  RMODE ANY

         ENTRY MPMCQ_POPNODE
         ENTRY MPMCQ_PUSHNODE

         USING MPMCQFL,R15

***********************************************************************
* MPMCQ_POPNODE
*   Input:  Q_R = QCBaddr
*   Returns:
*     R1=node address, or R1=0 if the freelist is empty
*     R15 is not set
***********************************************************************
MPMCQ_POPNODE DS 0H
         USING MPMCQ_QCB,Q_R
* Clobbers: R0,R1,R6,R7,NODE_R (R10). Preserves: R8,R9,R11.
* Caller must not keep live values in the clobber set across this call.

* Initial atomic fetch of the (ABA, PTR) pair into (R0, R1) to prevent torn reads
* (Pair is 8-byte aligned by QCB layout.)
         LG    R0,QCB_FREE_ABA(Q_R)          R0 = [ABA32][PTR32]
         LR    R1,R0
         SRLG  R0,R0,32                     R0 = ABA
         LLGFR R1,R1                        R1 = PTR

POPN_RETRY DS 0H
* Test the pointer. On CDS failure, R1 is auto-updated by the hardware.
* If PTR is zero, freelist is empty.
         LTR   R1,R1
         JZ    POPN_EMPTY

* Snapshot the node pointed to by the freelist head.
* NOTE: The pointer may change under us; CDS below validates the expected pair.
         LR    NODE_R,R1                 node = old_ptr
         USING MPMCQ_NODE,NODE_R

* Desired head = (head tag + 1, node->free_ptr). The tag is per pointer, so no
* shared counter is needed; NODE_FREE_ABA is no longer used.
         AHIK  R6,R0,1                 desired ABA
         L     R7,NODE_FREE_PTR          desired PTR

* CAS QCB_FREE from expected (R0,R1) to desired (ABA,PTR).
* On failure, branch back to POPN_RETRY to reuse R0/R1 without memory loads.
         CDS   R0,R6,QCB_FREE_ABA(Q_R)
         JE    POPN_OK
* R0/R1 hold the reloaded head. Order 1 with R6=0: no lock address, no target CPU.
         XR    R6,R6
         PPA   R6,R6,1
         J     POPN_RETRY
POPN_OK  DS    0H

* Success: return node in R1 (R15 is not a return code)
         LR    R1,NODE_R
         BR    R14

POPN_EMPTY DS 0H
         BR    R14                          R1 already 0

***********************************************************************
* MPMCQ_PUSHNODE
*   Input:  Q_R = QCBaddr
*           NEWNODE_R = node address
*   Returns R15=0
***********************************************************************
         DROP  NODE_R                      * prevent USING tie with NEWNODE_R below
MPMCQ_PUSHNODE DS 0H
         USING MPMCQ_QCB,Q_R
         USING MPMCQ_NODE,NEWNODE_R
* Clobbers: R0,R1,R10,R11,NEWNODE_R fields used.

* Expected head (ABA,PTR) from QCB. Atomic fetch to prevent torn reads.
         LG    R0,QCB_FREE_ABA(Q_R)          R0 = [ABA32][PTR32]
         LR    R1,R0
         SRLG  R0,R0,32
         LLGFR R1,R1

PUSHN_RETRY DS 0H
* Link the pushed node to the current head, then CAS QCB_FREE to
* (head tag + 1, node). CDS refreshes R0/R1 on failure, so a retry only
* has to re-link.
         ST    R1,NODE_FREE_PTR
         AHIK  R10,R0,1                desired ABA
         LR    R11,NEWNODE_R             desired PTR
         CDS   R0,R10,QCB_FREE_ABA(Q_R)
         JE    PUSHN_OK
         XR    R10,R10
         PPA   R10,R10,1                  spin-loop hint (order 1); fast path skips this
         J     PUSHN_RETRY
PUSHN_OK DS   0H

         XR    R15,R15
         BR    R14

         END   MPMCQFL