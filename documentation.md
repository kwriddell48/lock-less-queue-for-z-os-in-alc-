### Overview

This project implements a **multi-producer / multi-consumer (MPMC), lock-free FIFO queue** in **z/OS HLASM**, callable from **AMODE 31** callers while storing variable-length payloads in **64-bit virtual storage**.

High-level properties:

- **Producers** call `QENQ` to copy variable-length data into the queue.
- **Consumers** call `QDEQ` to copy data out (with truncation support).
- **Nodes** live in **31-bit storage** (fast pointer/CAS operations).
- **Payload bytes** live in **64-bit storage** (obtained/freed via `IARV64` wrappers).
- **Asynchronous notification** is supported:
  - internal notifier ECB + optional notifier TCB callback
  - optional user-provided ECB posted on each successful enqueue
- **Statistics** are maintained (approximate under concurrency) and returned via `QSTATS`.
- Code is intended to be **RENT/reentrant** (no writable static work areas).
- Modules are constrained to z/Architecture via `OPTABLE ZOP` (targeting z900/z990-era z/Architecture).

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

- **Tagged pointers**
  - `QCB_HEAD_(ABA,PTR)` / `QCB_TAIL_(ABA,PTR)`: head/tail tagged pointers to nodes
  - `QCB_FREE_(ABA,PTR)`: freelist head tagged pointer

- **ABA tag generator**
  - `QCB_ABA_SEQ`: monotonic counter used to generate new ABA tags for pointer updates

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

#### `QINIT(QCBaddr, options, initialPool, CB_EP, CB_CTX, USER_ECB)`

- Initializes the caller-provided QCB.
- Allocates the initial **dummy node** and sets both head and tail to it.
- Starts the notifier TCB if `CB_EP != 0`.
- Stores `USER_ECB` into `QCB_USER_ECB` for enqueue-time `POST`.

#### `QENQ(QCBaddr, srcAddr, srcLen)`

- Allocates a node (freelist pop else `GETMAIN BELOW`).
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

- New ABA tags are obtained by incrementing `QCB_ABA_SEQ` (CS loop).
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
- 64-bit payload bytes: `PAYLOAD64_CUR`, `PAYLOAD64_MAX` (HI/LO -> D)
- Notification: `POST_INTERNAL`, `POST_USERECB`, `CB_CALLS`, `CB_PENDING_MAX`

All are **approximate under concurrency** by design.

---

### Storage model (31-bit nodes + 64-bit payload)

- Nodes: `GETMAIN BELOW` and recycled through `src/mpmcq_freelist.asm`.
- Payload bytes:
  - obtained in `MPMCQ_PAYGET` (`IARV64 REQUEST=GETSTOR`)
  - freed in `MPMCQ_PAYFREE` (`IARV64 REQUEST=FREESTOR`)
  - copied with `SAM64`/`SAM31` wrappers around `MVCL` (`src/mpmcq_copy64.mac`)

Reentrancy note: `src/mpmcq_storage.asm` uses MF=L templates copied into per-call
work areas to avoid shared writable IARV64 parameter lists.

---

### Build / compatibility

- Each module includes `OPTABLE ZOP` to constrain the instruction set to z/Architecture.
- Link-edit with `RENT` (recommended).

---

### Known “review points” (things maintainers should validate)

- **Tagged pointer reads**: ideally read `(ABA,PTR)` pairs consistently; the `CDS`
  validation prevents incorrect updates, but mixed reads can increase retries.
- **IARV64 operands**: shops differ (key/guard/attributes). `src/mpmcq_storage.asm`
  may require operand tuning for your standards.
- **Notifier ATTACH options**: `src/mpmcq_notify.asm` uses a minimal ATTACH; you
  may need attributes (TCB key, subtask environment) for your installation.

