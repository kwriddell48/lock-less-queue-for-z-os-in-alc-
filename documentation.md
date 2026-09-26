### Overview

This project implements a **multi-producer / multi-consumer (MPMC), lock-free FIFO queue** in **z/OS HLASM**, callable from **AMODE 31** callers while storing variable-length payloads in **31-bit storage by default** (pooled) with an **optional 64-bit payload mode** (IARV64 memory objects).

High-level properties:

- **Producers** call `QENQ` to copy variable-length data into the queue.
- **Consumers** call `QDEQ` to copy data out (with truncation support).
- **Multiple queues per program**: the queue is **instance-based**. Each queue is
  anchored by its own **QCB instance**, so one address space/program can create
  and use multiple independent queues simultaneously (each with its own options,
  callback/ECB settings, and statistics).
- **Nodes** live in **31-bit storage** (fast pointer/CAS operations).
- **Payload bytes** live in **31-bit storage by default**, with an **optional 64-bit storage mode**.
- **Asynchronous notification** is supported:
  - internal notifier ECB + optional notifier TCB callback
  - optional user-provided ECB posted on each successful enqueue
- **Statistics** are maintained (approximate under concurrency) and returned via `QSTATS`.
- Code is intended to be **RENT/reentrant** (no writable static work areas).
- Modules are constrained to z/Architecture via `ACONTROL OPTABLE(ZS5)` (z196+ / ZS5 minimum).

---

### File / module map

- **`src/mpmcq.asm`**
  - **Public**: `QINIT`, `QENQ`, `QDEQ`
  - Implements the core Michael-Scott style queue operations and posts ECBs after enqueue.

- **`src/mpmcq_freelist.asm`**
  - **Internal**: `MPMCQ_POPNODE`, `MPMCQ_PUSHNODE`
  - Lock-free Treiber stack used as a node pool (reuses old dummy nodes).

- **`src/mpmcq_storage.asm`**
  - **Internal**: `MPMCQ_PAYGET`, `MPMCQ_PAYFREE`
  - 64-bit payload allocation/free via `IARV64` using per-call MF=(E,workarea) parameter lists.

- **`src/mpmcq_copy64.mac`**
  - Macros that wrap `SAM64`/`SAM31` around `MVCL` for 31↔64 copies.

- **`src/mpmcq_notify.asm`**
  - **Public**: `QCBSTOP`
  - **Internal**: `MPMCQ_NSTART`, `MPMCQ_NOTIF`
  - Optional notifier TCB that `WAIT`s on an internal ECB and calls a user callback asynchronously.

- **`src/mpmcq_stats.asm`**
  - **Public**: `QSTATS`
  - Copies a versioned stats snapshot into a caller buffer.

- **`src/mpmcq_version.asm`**
  - **Public**: `GETVERSION`
  - Returns an assemble-time-stamped build string using `&SYSDATE` and `&SYSTIME`.

- **`src/mpmcq_dsects.inc`**
  - All DSECT layouts: QCB, node, stats, parm lists.

- **`src/mpmcq_api.inc`**
  - Single include intended for application programs:
    - brings in DSECTs/equates
    - declares public entry points via `EXTRN`
    - provides size aliases (e.g. `MPMCQ_QCB_LEN`)

- **`src/mpmcq_atomics.mac`**
  - CS/CDS retry-loop helper macros for atomic counters/max updates.

- **`src/reg_equates.inc`**
  - Register equates `R0..R15` and role aliases used throughout this project.

- **`jcl/asm_lked.jcl`**
  - Sample assemble/link job skeleton.

---

### Register conventions (readability)

Defined in `src/reg_equates.inc`:

- **`Q_R`**: QCB base register (currently `R2`)
- **`NODE_R`**: current node being dereferenced via DSECT (currently `R10`)
- **`NEWNODE_R`**: newly allocated / recycled node (currently `R5`)
- **`NEXTNODE_R`**: next pointer during traversal (currently `R3`)

These aliases are for readability only; they do not change the linkage convention.

---

### Data structures

All layouts are in `src/mpmcq_dsects.inc`.

#### QCB (Queue Control Block)

Key fields:

- **Identification**
  - `QCB_EYECATCH` (`CL8`): `'MPMCQCB '`
  - `QCB_NAME` (`CL16`): user-assigned name (for logs/messages)
  - `QCB_VERSION` (`F`): structure/version marker

Operational notes:
- A QCB is the **anchor** for exactly **one** queue instance.
- A program may create **multiple queues** by allocating multiple QCBs and
  calling `QINIT` for each QCB.

- **Tagged pointers**
  - `QCB_HEAD_(ABA,PTR)` / `QCB_TAIL_(ABA,PTR)`: head/tail tagged pointers to nodes
  - `QCB_FREE_(ABA,PTR)`: freelist head tagged pointer

- **ABA tag handling**
  - Tags are per-pointer and computed as **old tag + 1** on each successful swing.
  - `QCB_ABA_SEQ` is reserved (no longer used).

- **Async notification**
  - `QCB_CB_EP`: callback entry point (optional)
  - `QCB_CB_CTX`: user context passed to callback
  - `QCB_CB_ECB`: internal ECB posted by `QENQ` to wake notifier
  - `QCB_ENQ_SEQ`: monotonic enqueue sequence used for notifier `PendingCount`
  - `QCB_CB_SEQ_SEEN`: last processed enqueue sequence by notifier
  - `QCB_USER_ECB`: optional user ECB posted on each successful enqueue

- **Stats**
  - `QCB_STAT_*` fields (see stats section)

#### Node

Nodes live in 31-bit storage; key fields:

- `NODE_NEXT_(ABA,PTR)`: next pointer in the linked list
- `NODE_PAYLOAD64` (doubleword): 64-bit address of payload bytes
- `NODE_PAYLOAD_LEN` (fullword): payload length in bytes

---

### Public API and calling conventions

All routines use standard z/OS linkage with **R1 -> parameter list**.

Parameter list DSECTs:

- `MPMCQ_QINIT_PLIST`
- `MPMCQ_QENQ_PLIST`
- `MPMCQ_QDEQ_PLIST`
- `MPMCQ_QSTATS_PLIST`
- `MPMCQ_GETVER_PLIST`
- `MPMCQ_CB_PLIST` (callback parameters)

#### `QINIT(QCBaddr, options, CB_EP, CB_CTX, USER_ECB)`

- Initializes the caller-provided QCB.
- **Alignment requirement**: `QCBaddr` must be **256-byte aligned** (QINIT enforces this; returns `R15=12` if misaligned).
- Allocates the initial **dummy node** and sets both head and tail to it.
- Starts the notifier TCB if `CB_EP != 0`.
- Stores `USER_ECB` into `QCB_USER_ECB` for enqueue-time `POST`.

**Lifetime requirement (important)**:
- The **QCB storage must remain valid and addressable** for the entire time the queue is in use (while any producer/consumer or notifier may reference it).
- Node and payload **slabs are never `FREEMAIN`'d** (including by `QCBSTOP`); they stay owned by the TCB that grew the pool. The QINIT-calling task must outlive every producer/consumer that may still reference a cell.
- Recommended practice is to `GETMAIN` the QCB, call `QINIT` once, then use the queue.
- When you are completely done:
  - stop producers/consumers
  - if used, call `QCBSTOP(QCBaddr)` to stop the notifier
  - then `FREEMAIN` the QCB storage (slab storage is released when its owning TCB ends)

#### `QENQ(QCBaddr, srcAddr, srcLen)`

- Allocates a node (freelist pop else slab grow via `GETMAIN RC,LOC=ANY`).
- Allocates 64-bit payload storage (`MPMCQ_PAYGET`) and copies in bytes.
- Links node at tail using `CDS` on `TAIL->NEXT` (linearization point).
- Posts:
  - internal `QCB_CB_ECB` (always)
  - user-provided ECB `QCB_USER_ECB` if non-zero

Return:

- `R15=0` success
- `R15=8` allocation failure (payload allocation path)

#### `QDEQ(QCBaddr, dstAddr, dstMaxLen, outLenAddr)`

- If empty, returns `R15=4`.
- Otherwise swings head forward via `CDS` (linearization point), extracts payload,
  copies to the caller buffer (truncation supported), frees payload, and recycles
  the old dummy node into the freelist.

Return:

- `R15=4` empty
- `R15=0` full message copied
- `R15=8` truncated (copied `dstMaxLen`, but `*outLenAddr` receives actual length)

#### `QSTATS(QCBaddr, outStatsAddr, outStatsLen)`

- Copies a snapshot of stats to `outStatsAddr`.
- `outStatsLen` provides forward compatibility (copy min(outStatsLen, statsSize)).
- Snapshot is **best-effort** under concurrency (no global lock).

Return:

- `R15=0`

#### `GETVERSION(outAddr, outMaxLen, outActLenAddr)`

Returns an assemble-time stamped string (see `src/mpmcq_version.asm`).

- If `outAddr==0`: returns `R1=ptr`, `R0=len`, `R15=0`.
- Else copies and returns `R15=0` or `R15=8` if truncated.

---

### Queue algorithm (how ENQ/DEQ work)

This is a Michael-Scott style linked queue with a permanent dummy node:

- `HEAD` points to a dummy node.
- Real elements appear at `HEAD->NEXT`.
- Dequeue moves `HEAD` forward; the previous dummy is recycled.

#### Linearization points (the important atomics)

- **Enqueue linearization**: the `CDS` that changes `TAIL->NEXT` from NULL to the new node.
- **Dequeue linearization**: the `CDS` that swings `(HEAD_ABA,HEAD_PTR)` forward to `next`.

#### ABA tagging

All key pointers are stored as `(ABA,PTR)` pairs and updated with `CDS`.

- New ABA tags are computed as **(old ABA + 1)** on each pointer swing.
- ABA tags help reduce the classic ABA problem on pointer swings.

Note: reads of `(ABA,PTR)` are done via separate loads in some places; the `CDS`
validation prevents incorrect swings, but mixed reads can increase retry rates.

---

### Notifications (ECB + async callback)

#### User ECB (POST on enqueue)

- Caller passes an ECB address in `QINIT` as `USER_ECB`.
- Each successful `QENQ` does `POST ECB=(userECB)`.
- ECB posts can coalesce (standard z/OS behavior).

#### Notifier TCB callback (asynchronous)

If `CB_EP != 0` in `QINIT`:

- `MPMCQ_NSTART` ATTACHes a notifier TCB (`MPMCQ_NOTIF`).
- Producers always `POST ECB=QCB_CB_ECB`.
- Notifier:
  - WAITs on `QCB_CB_ECB`
  - computes `PendingCount = ENQ_SEQ - CB_SEQ_SEEN`
  - calls user callback EP with parm list `(CB_CTX, QCBaddr, PendingCount)`

This yields “every enqueue” semantics without ATTACH-per-enqueue overhead.

---

### Statistics

Stats are stored in the QCB (`QCB_STAT_*`) and exposed via `QSTATS`.

Key counters include:

- Queue activity: `ENQ_OK`, `DEQ_OK`, `DEQ_EMPTY`, `ENQ_ALLOC_FAIL`
- Retry visibility: `ENQ_RETRY`, `DEQ_RETRY`, freelist retry counters
- Depth: `QDEPTH_CUR`, `QDEPTH_MAX` (best-effort)
- 31-bit payload bytes: `PAYLOAD31_CUR`, `PAYLOAD31_MAX` (HI/LO -> D)
- 64-bit payload bytes: `PAYLOAD64_CUR`, `PAYLOAD64_MAX` (HI/LO -> D)
- Notification: `POST_INTERNAL`, `POST_USERECB`, `CB_CALLS`, `CB_PENDING_MAX`

All are **approximate under concurrency** by design.

---

### Storage model (31-bit nodes + optional 31-bit or 64-bit payload)

- **Nodes**: slab `GETMAIN RC,LOC=ANY` (cold path) and recycled through the in-module node freelist.

- **Payload bytes**: configurable per queue (default: 31-bit)

  - **31-bit payload mode (default)**:
    - allocation: **size-class payload cell pools** (256, 1K, 4K, 16K) backed by
      `GETMAIN RC,LOC=ANY` slabs (cold path)
    - maximum record length: **16384 bytes** (largest pool tier); `QENQ` returns `R15=12` if exceeded
    - free: return cell to its pool
    - accounting: `QCB_STAT_PAYLOAD31_*` tracks **allocated/reserved bytes** (cell size), not record length

  - **64-bit payload mode (optional)**:
    - allocation: `MPMCQ_PAYGET` (`IARV64 REQUEST=GETSTOR`, **1MB segments**, `TTOKEN=QCB_OWNER_TTOKEN`)
    - free: `MPMCQ_PAYFREE` (`IARV64 REQUEST=DETACH`, `TTOKEN=QCB_OWNER_TTOKEN`)
    - accounting: `QCB_STAT_PAYLOAD64_*` tracks **allocated bytes** (segments), not record length
    - init-time validation: `QINIT` performs a minimal `GETSTOR`/`DETACH` probe; if it fails, `QINIT` returns `R15=16`

  - **Copying**:
    - 64-bit payload mode uses `SAM64`/`SAM31` wrapped `MVCL` helpers (`src/mpmcq_copy64.mac`).

#### Storage ownership (important)

This queue pools **nodes** and (in 31-bit payload mode) **common payload sizes** inside the queue
instance, so the enqueue/dequeue hot path avoids per-message `GETMAIN`/`FREEMAIN`.

Note: this build intentionally does **not** use `STORAGE OBTAIN/RELEASE ... TCBADDR=` / `OWNER=` because
those are **authorized parameters**; problem-state applications must use `GETMAIN`/`FREEMAIN` (or an
application-provided allocator) instead.

**31-bit storage ownership requirement (important)**:
Node and payload cell slabs are obtained with `GETMAIN` in the context of whichever task grows the pool.
If your producers/consumers are independent tasks, you must ensure they can legally free (or safely keep)
storage obtained by other tasks (typically achieved by appropriate subpool sharing, e.g. `ATTACH/ATTACHX`
`SHSPV`/`SHSPL`, or by ensuring tasks do not terminate while pooled storage is still in use).

**64-bit storage ownership (payload64 mode)**:
The queue captures the jobstep TTOKEN at `QINIT` (`QCB_OWNER_TTOKEN`) and passes it on `IARV64 ... TTOKEN=`
so memory objects can be detached by any producer/consumer task, per IARV64 TTOKEN restrictions.

---

### Arena / allocator design (Mode B) - current implementation

This package now uses an **arena-style design** (Mode B / queue-manager model) for node storage and
31-bit payload cells. It solves two problems at once:

- **Correctness**: eliminate per-message `GETMAIN/FREEMAIN` for pooled node/cell allocations (reduces
  cross-task frees). Slab ownership/lifetime still depends on your task/subpool model (see “Storage ownership”).
- **Performance**: remove most per-message storage SVCs from the enqueue/dequeue hot path (node and common
  payload sizes are pooled; cold-path slab growth uses `GETMAIN`).

#### Implementation status (this repo)

- **Nodes**: slab-allocated and recycled via the lock-free node freelist (`QCB_FREE_*`).
- **31-bit payloads**: size-class cell pools (`QCB_PAY256_*`, `QCB_PAY1024_*`, `QCB_PAY4096_*`, `QCB_PAY16384_*`)
  with slab allocation on empty; record bytes are copied into the cell start (no per-message SVCs for `len <= 16384`).
- **Notifier wakeups**: gated by `QCB_CB_ARMED` so bursts cost ~1 internal `POST`.
- **QCB layout**: `HEAD`, `TAIL`, pools, notifier fields, and stats start on 256-byte boundaries (QINIT
  requires the QCB itself to be 256-byte aligned) to reduce cache-line contention.
- **Payload usage stats**: `PAYLOAD31_*` reflects **reserved bytes** (cell size), not record length.

Remaining work (if needed for your environment):

- **64-bit payload arena**: avoid per-message `IARV64` churn by pooling/suballocating memory objects.
- **Very large 31-bit payloads** (`len > 16384`): this build rejects them in payload31 mode (see above). If you need larger records in payload31 mode, add larger size classes, an oversized-buffer pool, or a pluggable allocator.

#### Constraints / assumptions

- Queue pointers (`HEAD/TAIL/NEXT/FREE`) remain **31-bit** and updated via `CDS` on `(ABA,PTR)`.
- Callers are AMODE 31; the queue is RENT/reentrant (no shared writable static storage).
- Not all installations can use common storage (SQA/CSA/ECSA) from problem state; assume problem state.

#### Ownership model (what is actually possible on z/OS)

There is no magic “free from any TCB” primitive for private subpools unless tasks have ownership or
sharing control of the subpool. Therefore, any arena design must choose one of:

- **A. Subpool-sharing model** (recommended when producers/consumers are subtasks you create):
  create producer/consumer tasks with the appropriate `ATTACH/ATTACHX SHSPV/SHSPL` so all tasks
  share the arena subpool(s). All frees are then legal from any of those tasks.

- **B. Queue-manager model** (works if one long-lived “manager” task exists):
  allocate all slabs from a task that outlives all producers/consumers and never `FREEMAIN` slabs
  until the queue is shut down. Individual nodes/cells are recycled inside the arena without returning
  storage to the system mid-run.

- **C. Pluggable allocator** (most flexible; best for “arbitrary TCBs”):
  extend `QINIT` (or add `QINITX`) to accept caller-provided `ALLOC`/`FREE` entry points (plus a context),
  and use those for all node/payload allocations. The caller can then back the queue with a storage
  mechanism appropriate for their environment (for example: a shared subpool, a CPOOL, LE heap, etc.).

The current code effectively assumes (A) or (B); (C) is the cleanest way to make the package robust
without forcing task-creation policy on the application.

#### Data layout: fixed-size cells (node pool + payload pools)

- **Node cells**: fixed-size `MPMCQ_NODE` blocks, allocated in slabs and recycled via `QCB_FREE_*`.
- **Payload cells (31-bit mode)**: fixed-size payload blocks (256/1024/4096/16384), allocated in slabs and recycled
  via their own freelists (`QCB_PAY*_*`). The freelist link for a free payload cell is stored in the first word of the
  payload cell itself; when a record is enqueued, the record bytes overwrite that word.

#### Size classes for 31-bit payload cells

This implementation uses fixed size classes: **256, 1K, 4K, 16K**.
For `len > 16384`, payload31 mode returns `R15=12` (record too large).

#### Concurrency structure (lock-free)

All arena pools are lock-free stacks (Treiber) like the current node freelist:

- one freelist for **node cells**
- one freelist per **payload size class**

Each freelist head is an `(ABA,PTR)` pair updated via `CDS`, with tags computed as `old+1`.

#### Stats impact

With an arena, payload “bytes currently allocated” becomes ambiguous:

- If payload is inline in the node cell, those bytes are part of the cell and are not separately allocated.
- If payload comes from a size-class block pool, the “allocated bytes” are the block size, not the record length.

Recommendation:

- keep `PAYLOAD*_CUR` semantics as “record bytes enqueued” only if you want application-level visibility, or
- redefine them as “bytes reserved by arena” if you want storage-footprint visibility, or
- split into two counters (record bytes vs reserved bytes).

#### Suggested remaining incremental steps (if you need them)

1. Add a **64-bit payload object pool** (reduces `IARV64` churn).
2. Add larger 31-bit payload size classes (or a pluggable allocator / oversized-buffer pool) to support `len > 16384` in payload31 mode.
3. Consider a compile-time option to reduce stats updates if absolute max throughput is required.

Reentrancy note: `src/mpmcq_storage.asm` uses MF=L templates copied into per-call
work areas to avoid shared writable IARV64 parameter lists.

---

### Build / compatibility

- Each module includes `ACONTROL OPTABLE(ZS5)` to constrain the instruction set and document the minimum machine level.
- Link-edit with `RENT` (recommended).

---

### Known “review points” (things maintainers should validate)

- **Tagged pointer reads**: ideally read `(ABA,PTR)` pairs consistently; the `CDS`
  validation prevents incorrect updates, but mixed reads can increase retries.
- **IARV64 operands**: shops differ (key/guard/attributes). `src/mpmcq_storage.asm`
  may require operand tuning for your standards.
- **Notifier ATTACH options**: `src/mpmcq_notify.asm` uses a minimal ATTACH; you
  may need attributes (TCB key, subtask environment) for your installation.

