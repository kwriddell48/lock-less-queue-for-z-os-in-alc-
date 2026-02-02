---
name: IBMZ_lockfree_queue_full_feature_stats
overview: Implement an AMODE-31-callable lock-free MPMC FIFO queue with variable-length messages stored in 64-bit storage, async ATTACH callback + user ECB posting on enqueue, and a low-overhead statistics subsystem retrievable via QSTATS.
todos:
  - id: dsects-api-stats
    content: Define QCB/node/stats DSECTs, finalize calling conventions for QINIT/QENQ/QDEQ/QSTATS, and document approximate-stat semantics.
    status: completed
  - id: atomics-queue
    content: Implement DCAS/refcount queue + freelist, and add retry counters in CAS loops.
    status: completed
  - id: payload64-copy
    content: Implement IARV64 allocation/free and SAM64-wrapped copies; update 64-bit byte-usage stats (cur/max).
    status: completed
  - id: notify
    content: Implement notifier TCB + callback invocation with context; post internal/user ECBs; add notification stats.
    status: completed
  - id: qstats
    content: Implement QSTATS snapshot routine and versioned stats layout.
    status: completed
  - id: docs-jcl
    content: Write README and sample JCL build steps including how to use monitoring stats.
    status: completed
---

# Lock-free MPMC FIFO queue + async notify + stats (HLASM, callable AMODE 31)

## Goal

Deliver a **lock-free MPMC FIFO** in **z/OS HLASM** that:

- Is **callable from AMODE 31**
- **Copies variable-length data into the queue**; message bytes are stored in **64-bit virtual storage**
- `QDEQ` **copies out** into caller buffer and frees payload storage
- Provides async notification:
- **ATTACHed notifier TCB** calls a user callback asynchronously
- Optional **user-provided ECB** is POSTed on every successful enqueue
- Exposes **low-overhead (approximate) runtime statistics** via a `QSTATS` snapshot routine

## Core queue algorithm

- Michael-Scott MPMC FIFO with counted pointers updated via **`CDS`** (doubleword CAS) and refcount-based reclamation so nodes can be safely reused without thread registration.
- **QCB + nodes in 31-bit storage**, payload bytes in **64-bit storage** via `IARV64`.

## Variable-length payload semantics

- `QENQ(QCB, srcAddr, srcLen)`: allocates 64-bit buffer (`IARV64`), `SAM64` copy-in, enqueues node containing `(payload64Addr, payloadLen)`.
- `QDEQ(QCB, dstAddr, dstMaxLen, outLenAddr)`:
- RC=4 empty
- RC=0 copied full message
- RC=8 truncated (copied `dstMaxLen`, but `*outLen=actualLen`)
- frees 64-bit payload + recycles node.

## Notifications

### Async callback on separate TCB

- One notifier TCB is created once (via `ATTACH`). Producers never run user code.
- Callback parm list order (R1->list): **`(CB_CTX, QCBaddr, PendingCount)`**.
- `QENQ` increments `ENQ_SEQ` and `POST`s internal ECB to wake notifier.

### User ECB notify

- Optional `USER_ECB` in QCB; `QENQ` does `POST USER_ECB` on every successful enqueue.

## Statistics (approximate, low overhead)

### Principles

- Stats are **approximate** under concurrency (monotonic counters; current-size is best-effort).
- Updates use **`CS` loops** (fullword) or **`CDS`** for paired updates only where needed.
- `QSTATS` provides a consistent-enough snapshot by copying fields (no global lock).

### Stats to maintain (QCB fields)

Counters are suggested as **fullword** unless noted.

- **Enqueue/dequeue activity**
- `STAT_ENQ_OK`
- `STAT_DEQ_OK`
- `STAT_DEQ_EMPTY` (how often consumers found empty)
- `STAT_ENQ_ALLOC_FAIL` (IARV64 obtain failed)
- **Retry/contended-path visibility**
- `STAT_ENQ_RETRY` (CAS loops / link retries)
- `STAT_DEQ_RETRY`
- `STAT_FREELIST_POP_RETRY` / `STAT_FREELIST_PUSH_RETRY`
- **Queue depth (best-effort)**
- `STAT_QDEPTH_CUR` (signed fullword; increment after successful enqueue link, decrement after successful dequeue)
- `STAT_QDEPTH_MAX` (max observed; update via CS loop when `CUR` exceeds)
- **64-bit storage usage** (doubleword counters)
- `STAT_PAYLOAD64_CUR` (bytes currently allocated for enqueued payloads)
- `STAT_PAYLOAD64_MAX` (max observed)
- Optional: `STAT_PAYLOAD64_ALLOC` (total bytes ever obtained) / `STAT_PAYLOAD64_FREE`
- **Notification activity**
- `STAT_POST_INTERNAL` (internal ECB posts)
- `STAT_POST_USERECB`
- `STAT_CB_CALLS`
- `STAT_CB_PENDING_MAX` (largest `PendingCount` ever delivered)

### Stats retrieval API

- `QSTATS(QCBaddr, outStatsAddr, outStatsLen)`
- Copies a packed stats DSECT to caller.
- `outStatsLen` allows versioning/forward compatibility.

## Entry points

- `QINIT(QCBaddr, options, initialPool, CB_EP, CB_CTX, USER_ECB)`
- `QENQ(QCBaddr, srcAddr, srcLen)`
- `QDEQ(QCBaddr, dstAddr, dstMaxLen, outLenAddr)`
- `QSTATS(QCBaddr, outStatsAddr, outStatsLen)`
- `QCBSTOP(QCBaddr)` optional

## Files to add

- [README.md](README.md)
- [src/mpmcq_dsects.inc](src/mpmcq_dsects.inc) (QCB/node + stats DSECT)
- [src/mpmcq_atomics.mac](src/mpmcq_atomics.mac)
- [src/mpmcq_copy64.mac](src/mpmcq_copy64.mac)
- [src/mpmcq_storage.asm](src/mpmcq_storage.asm)
- [src/mpmcq_notify.asm](src/mpmcq_notify.asm)
- [src/mpmcq_stats.asm](src/mpmcq_stats.asm) (`QSTATS`, helper macros for counter increments/max)
- [src/mpmcq.asm](src/mpmcq.asm)
- [jcl/asm_lked.jcl](jcl/asm_lked.jcl)

## Acceptance criteria

- FIFO correctness under MPMC.
- Varlen copy-in/out correctness, including truncation return codes.
- Async callback executes on notifier TCB and receives correct `(CB_CTX, QCB, PendingCount)`.
- User ECB POSTed on every enqueue.
- Stats counters move as expected; `QSTATS` returns a coherent snapshot suitable for monitoring.W

