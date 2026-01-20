         TITLE 'MPMCQ - Lock-free freelist for node reuse (counted pointer CDS)'
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
*    MPMCQ_POPNODE(QCBaddr)  -> R15=0 and R1=node or R15=4 empty
*    MPMCQ_PUSHNODE(QCBaddr,node) -> R15=0
***********************************************************************

         PRINT GEN

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
*   Input:  R2 = QCBaddr
*   Returns:
*     R15=0 success, R1=node address
*     R15=4 empty
***********************************************************************
MPMCQ_POPNODE DS 0H
         STM   R14,R12,12(R13)
         LR    R12,R15
         USING MPMCQFL,12
         USING MPMCQ_QCB,R2

POPN_LOOP DS 0H
* Expected head (ABA,PTR) from QCB.
* If PTR is zero, freelist is empty.
         L     R0,QCB_FREE_ABA
         L     R1,QCB_FREE_PTR
         LTR   R1,R1
         BZ    POPN_EMPTY

* Snapshot the node pointed to by the freelist head.
* NOTE: The pointer may change under us; CDS below validates the expected pair.
         LR    R5,R1                    node = old_ptr
         USING MPMCQ_NODE,R5

* Desired head becomes (node->next_aba, node->next_ptr).
* (We keep ABA from node->next; the head ABA itself is refreshed below.)
         L     R10,NODE_NEXT_ABA
         L     R11,NODE_NEXT_PTR

* Refresh ABA tag for freelist head update: ABA = QCB_ABA_SEQ++
POP_ABA_LOOP DS 0H
         L     R8,QCB_ABA_SEQ
         LA    R9,1(R8)
         CS    R8,R9,QCB_ABA_SEQ
         BNE   POP_ABA_LOOP
         LR    R10,R9                    desired ABA tag
         * desired PTR already in R11

* CAS QCB_FREE from expected (R0,R1) to desired (ABA,PTR).
* On failure, someone else won; retry with the new observed head.
         CDS   R0,R10,QCB_FREE_ABA(R2)
         BNE   POPN_LOOP

* Success: return node in R1
         LR    R1,R5
         XR    R15,R15
         LM    R14,R12,12(R13)
         BR    R14

POPN_EMPTY DS 0H
         LA    R15,4
         LM    R14,R12,12(R13)
         BR    R14

***********************************************************************
* MPMCQ_PUSHNODE
*   Input:  R2 = QCBaddr
*           R5 = node address
*   Returns R15=0
***********************************************************************
MPMCQ_PUSHNODE DS 0H
         STM   R14,R12,12(R13)
         LR    R12,R15
         USING MPMCQFL,12
         USING MPMCQ_QCB,R2
         USING MPMCQ_NODE,R5

PUSHN_LOOP DS 0H
* Expected head (ABA,PTR) from QCB.
         L     R0,QCB_FREE_ABA
         L     R1,QCB_FREE_PTR

* Link the pushed node to the current head.
* We store the head ABA/PTR into NODE_NEXT_(ABA,PTR).
         ST    R0,NODE_NEXT_ABA
         ST    R1,NODE_NEXT_PTR

* Desired new head = (newABA, node_ptr).
PUSH_ABA_LOOP DS 0H
         L     R8,QCB_ABA_SEQ
         LA    R9,1(R8)
         CS    R8,R9,QCB_ABA_SEQ
         BNE   PUSH_ABA_LOOP
         LR    R10,R9                    desired ABA
         LR    R11,R5                    desired PTR

* CAS QCB_FREE from expected (R0,R1) to desired (ABA,PTR).
* On failure, head changed; rewrite node->next_ptr and retry.
         CDS   R0,R10,QCB_FREE_ABA(R2)
         BNE   PUSHN_LOOP

         XR    R15,R15
         LM    R14,R12,12(R13)
         BR    R14

         END   MPMCQFL

