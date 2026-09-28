---
name: IBMZ_lockfree_queue_full_feature_stats
overview: AMODE-31 lock-free MPMC FIFO. Payload is 31-bit size-class pools by default, with optional IARV64 mode. Async ATTACH callback and user ECB on enqueue. Approximate stats via QSTATS.
todos:
  - id: dsects-api-stats
    content: Define QCB/node/stats DSECTs, finalize calling conventions for QINIT/QENQ/QDEQ/QSTATS, and document approximate-stat semantics.
    status: completed
  - id: atomics-queue
    content: Implement CDS tagged-pointer queue plus inlined node freelist, with retry counters on the enqueue and dequeue CAS paths.
    status: completed
  - id: payload64-copy
    content: Implement IARV64 allocation/free and SAM64-wrapped copies; 31-bit size-class pools are the default payload path.
    status: completed
  - id: notify
    content: Implement notifier TCB plus callback invocation with context; gate internal POSTs with the armed flag; RENT list/execute form for IDENTIFY and ATTACH.
    status: completed
  - id: qstats
    content: Implement QSTATS snapshot routine and versioned stats layout.
    status: completed
  - id: docs-jcl
    content: Write README, documentation, and sample JCL build steps including how to use monitoring stats.
    status: completed
  - id: optional-stats
    content: Compile-time switch to omit stat updates on the hot path.
    status: pending
  - id: freelist-batch
    content: Batch node freelist pop on the producer and push on the consumer so a slab is not one CDS per node.
    status: pending
  - id: tx-design
    content: Unconstrained TBEGIN/TEND publishes the enqueue tail link and the dequeue head swing. CDS loops remain the abort fallback. Payload copy and SVCs stay outside the transaction.
    status: completed
---

# Lock-free MPMC FIFO queue + async notify + stats (HLASM, callable AMODE 31)

## Goal

Deliver a **lock-free MPMC FIFO** in **z/OS HLASM** that:

- Is **callable from AMODE 31**
- **Copies variable-length data into the queue**
- Stores payload in **31-bit size-class pools by default** (256, 1K, 4K, 16K), with **optional 64-bit** `IARV64` memory objects
- `QDEQ` **copies out** into a caller buffer and recycles the node and the payload cell
- Provides async notification:
  - one **ATTACH**ed notifier TCB calls a user callback
  - an optional **user ECB** is POSTed on every successful enqueue
- Exposes **low-overhead (approximate) statistics** via `QSTATS`

Caller-facing summary: [README.md](README.md). Design notes: [documentation.md](documentation.md).

## Core queue algorithm

- Michael-Scott MPMC FIFO. Pointers are `(ABA, PTR)` pairs updated with `CDS`. Tags are old tag + 1. There is no shared ABA counter and no hazard-pointer registration.
- Nodes and, in the default mode, payload cells live in **31-bit** storage. A failed `CDS` retries with `PPA` order 1 (spin-loop hint). The first attempt does not.
- The QCB must be **256-byte aligned**. `QINIT` rejects anything else (`R15=12`) so the `ORG` groups stay on separate 256-byte lines.
- Node freelist pop/push is inlined. `R1=0` means empty; a nonzero `R1` is the node. `R15` is not a pop return code.

## Variable-length payload semantics

- **Payload31 (default)**: `QENQ` copies into the smallest cell that fits. Maximum record length is **16384**. Longer records return `R15=12`. Cells return to their pool. Slabs are not `FREEMAIN`ed.
- **Payload64**: `QENQ` calls `MPMCQ_PAYGET` (`IARV64 GETSTOR`, 1MB segments, jobstep `TTOKEN`) and copies with `SAM64`. `QDEQ` detaches the memory object. `QINIT` probes `GETSTOR`/`DETACH` and returns `R15=16` if the probe fails, or `R15=8` if the jobstep TTOKEN cannot be obtained. Records longer than 16MB−1 return `R15=12`.
- `QDEQ`: `R15=4` empty, `R15=0` full copy, `R15=8` truncated (`*outLen` is the actual length). Copy length and the truncation return code use `LOCR`.

## Storage ownership

Problem state. `STORAGE ... TCBADDR=` is not used.

Slabs belong to the task that grew the pool. The `QINIT` task must outlive every producer and consumer that can still reference a cell. `QCBSTOP` does not free slabs.

64-bit objects are owned by the jobstep TTOKEN captured at `QINIT`, so another task in the job step can detach them.

## Notifications

- One notifier TCB per queue when `CB_EP` is nonzero. `IDENTIFY` and `ATTACH` use `MF=L` templates copied to a private work area (`MF=E`) so the module can be linked `RENT`.
- Producers do not run the exit. They `ASI` `ENQ_SEQ`, serialize with `BCR 15,0`, and `POST` the internal ECB only if they clear `QCB_CB_ARMED`.
- Callback parameter list: `(CB_CTX, QCBaddr, PendingCount)`.
- Optional `USER_ECB` is POSTed on every successful enqueue.
- `QCBSTOP` runs on the same task as `QINIT`.

## Statistics

Approximate under concurrency. Increments are `ASI`. Maximums compare first and `CS`/`CSG` only when the candidate is larger.

- Activity: `ENQ_OK`, `DEQ_OK`, `DEQ_EMPTY`, `ENQ_ALLOC_FAIL`
- Retries: `ENQ_RETRY`, `DEQ_RETRY` (freelist retry fields exist in the snapshot and stay zero)
- Depth: `QDEPTH_CUR`, `QDEPTH_MAX`
- Payload bytes: `PAYLOAD31_*` is cell size reserved; `PAYLOAD64_*` is 1MB-segment bytes allocated
- Notification: `POST_INTERNAL`, `POST_USERECB`, `CB_CALLS`, `CB_PENDING_MAX`

`QSTATS(QCBaddr, outStatsAddr, outStatsLen)` copies `min(outStatsLen, stats size)`.

## Entry points

- `QINIT(QCBaddr, options, CB_EP, CB_CTX, USER_ECB)`
- `QENQ(QCBaddr, srcAddr, srcLen)`
- `QDEQ(QCBaddr, dstAddr, dstMaxLen, outLenAddr)`
- `QSTATS(QCBaddr, outStatsAddr, outStatsLen)`
- `GETVERSION(outAddr, outMaxLen, outActLenAddr)`
- `QCBSTOP(QCBaddr)`

## Files

- [README.md](README.md)
- [documentation.md](documentation.md)
- [src/mpmcq_api.inc](src/mpmcq_api.inc)
- [src/mpmcq_dsects.inc](src/mpmcq_dsects.inc)
- [src/mpmcq_internal.inc](src/mpmcq_internal.inc)
- [src/mpmcq_atomics.mac](src/mpmcq_atomics.mac)
- [src/mpmcq_copy64.mac](src/mpmcq_copy64.mac)
- [src/mpmcq.asm](src/mpmcq.asm)
- [src/mpmcq_storage.asm](src/mpmcq_storage.asm)
- [src/mpmcq_notify.asm](src/mpmcq_notify.asm)
- [src/mpmcq_stats.asm](src/mpmcq_stats.asm)
- [src/mpmcq_version.asm](src/mpmcq_version.asm)
- [src/mpmcq_freelist.asm](src/mpmcq_freelist.asm) (external copy of the node freelist; hot path is inlined)
- [jcl/asm_lked.jcl](jcl/asm_lked.jcl)

## Acceptance criteria

- FIFO order under multiple producers and consumers.
- Variable-length copy-in and copy-out, including truncation.
- Payload31 rejects records above 16384. Payload64 fails `QINIT` when `IARV64 GETSTOR` is not usable.
- Callback runs on the notifier TCB with `(CB_CTX, QCB, PendingCount)`.
- User ECB is POSTed on every successful enqueue.
- `QSTATS` returns a snapshot suitable for monitoring.
- Linked `RENT`, the `IDENTIFY`/`ATTACH`/`IARV64` parameter lists are not stored into the load module.

## Still open

- Compile-time option to skip stat updates.
- Batch freelist pop (producer) and push (consumer).
- A 64-bit payload suballocator, if payload64 rates make 1MB `GETSTOR` too coarse.
- Larger payload31 size classes, if records above 16K are required without payload64.

## Transactional execution

`src/mpmcq.asm` (`OPTABLE(ZS6)`, zEC12) publishes with an unconstrained transaction when `MPMCQ_ENABLE_TX` is 1 (the default).

- Enqueue: after the node is private and the payload is copied, `TBEGIN` stores `TAIL->NEXT` and `TAIL`, then `TEND`. A lagging tail commits no stores and uses the `CDS` help path.
- Dequeue: when an element is already visible, `TBEGIN` re-reads the head pointer and the payload, then stores `HEAD`, then `TEND`. It does not re-read the head ABA. Every writer updates the ABA tag and the pointer together, so an unchanged pointer means the pre-transaction tag in `R4` is still current. The payload read commits with the head store. Empty and help-the-tail stay on the non-transactional path.
- `TBEGIN`, `TEND`, and `PPA` are problem-state. No APF authorization, supervisor state, or key 0–7 is required. Transactional execution must be enabled (control register 0, bit 8), or `TBEGIN` gets a special-operation exception instead of the `CDS` fallback.
- `TBEGIN` I2 is `X'00FF'` (no access-register or floating-point updates; every general-register pair is restored on abort). The TDB is `QCB_TDB` in the caller-owned QCB (256 bytes, own cache-line group). Abort code is bytes 6–7; aborted-instruction address is bytes 8–15. The queue has one TDB, so concurrent aborts can overwrite it. The condition code still selects the fallback.
- Hardware abort: condition code 3 uses the `CDS` fallback immediately. Other abort codes retry up to `MPMCQ_TX_RETRIES`, then use `CDS`.
- `TBEGINC` is not used.
- `GETMAIN`, `MVCL`, `POST`, `SAM64`, `IARV64`, and `PPA` stay outside the transaction.
- ABA tags are still written. The fallback and any other CPU using `CDS` depend on them.

Set `MPMCQ_ENABLE_TX` to 0 to assemble only the `CDS` publish path. Whether the transaction is faster still depends on contention: aborts cost more than a `CDS` retry when the tail is hot.
