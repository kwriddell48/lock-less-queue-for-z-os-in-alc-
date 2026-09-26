# Lock-free MPMC FIFO queue for z/OS (HLASM)

This repository contains a **multi-producer / multi-consumer, lock-free FIFO queue** written in **IBM z/OS High Level Assembler (HLASM)**.

It is designed to meet these requirements:

- **Callable from AMODE 31** callers (standard z/OS linkage).
- **Variable-length records** are **copied into the queue** at enqueue time.
- Queue stores record bytes in **31-bit storage by default**, with an **optional 64-bit virtual storage mode** (via `IARV64`).
- `QDEQ` **copies out** to caller buffer and returns actual length; truncation is supported.
- **Multiple queues per program**: each queue is an **instance** anchored by a distinct **QCB** (allocate one QCB per queue).
- **Asynchronous notification** on enqueue:
  - A single **ATTACH**ed notifier TCB calls a user exit asynchronously.
  - A user-supplied **ECB** may also be **POST**ed on each enqueue.
  - Callback parm list is: `(CB_CTX, QCBaddr, PendingCount)`.
- **Statistics** are maintained (approximate/low-overhead) and returned via `QSTATS`.

## Entry points (planned)

- `QINIT(QCBaddr, options, CB_EP, CB_CTX, USER_ECB)`
- `QENQ(QCBaddr, srcAddr, srcLen)`
- `QDEQ(QCBaddr, dstAddr, dstMaxLen, outLenAddr)`
- `QSTATS(QCBaddr, outStatsAddr, outStatsLen)`
- `GETVERSION(outAddr, outMaxLen, outActLenAddr)` (returns assemble-time stamped build string)
- `QCBSTOP(QCBaddr)` (optional): stop notifier TCB.

Return codes:

- `QENQ`: `RC=0` success, `RC=8` allocation failure.
- `QDEQ`: `RC=4` empty, `RC=0` success, `RC=8` truncated.

## Source layout

- `src/mpmcq_dsects.inc`: DSECTs for QCB, node, stats, parm lists.
- `src/mpmcq_api.inc`: single include for callers (entry points + sizes + DSECTs).
- `src/mpmcq_atomics.mac`: `CS`/`CDS` retry-loop macros.
- `src/mpmcq_copy64.mac`: `SAM64`/`SAM31` wrapped copy helpers (31<->64).
- `src/mpmcq_storage.asm`: wrappers for `IARV64` obtain/free (payload) and 31-bit node storage.
- `src/mpmcq_notify.asm`: notifier TCB body + callback invocation.
- `src/mpmcq_stats.asm`: `QSTATS` implementation.
- `src/mpmcq.asm`: `QINIT/QENQ/QDEQ` core.
- `jcl/asm_lked.jcl`: sample assemble/link JCL.

## Notes

- This code assumes a z/Architecture environment where `CDS` (doubleword compare-and-swap) is available.
- Statistics are **approximate** under concurrency to keep the queue lock-free and fast.
- `src/mpmcq_storage.asm` contains `IARV64` macro usage; you may need to adjust the macro operands to match your z/OS level/policy (key, guard pages, etc.).

## Using the async notification

- **User callback (async execution)**:
  - Provide `CB_EP` to `QINIT` to request a notifier subtask.
  - The notifier subtask `WAIT`s on an internal ECB and calls your exit with:
    - `(CB_CTX, QCBaddr, PendingCount)`
  - `PendingCount` is computed from a sequence delta, so multiple enqueues can be coalesced into one callback with `PendingCount > 1`.

- **User ECB (POST)**:
  - Provide `USER_ECB` to `QINIT`.
  - Each successful `QENQ` will `POST` that ECB (ECB posts may naturally coalesce if already posted).

## Statistics

Call `QSTATS(QCBaddr, outStatsAddr, outStatsLen)` to copy a snapshot (see `src/mpmcq_dsects.inc` `MPMCQ_STATS` DSECT).

Included counters:

- `ENQ_OK`, `DEQ_OK`, `DEQ_EMPTY`, `ENQ_ALLOC_FAIL`
- `ENQ_RETRY`, `DEQ_RETRY`
- `QDEPTH_CUR`, `QDEPTH_MAX` (best-effort)
- `PAYLOAD31_CUR`, `PAYLOAD31_MAX` (bytes in 31-bit storage)
- `PAYLOAD64_CUR`, `PAYLOAD64_MAX` (bytes in 64-bit storage)
- `POST_INTERNAL`, `POST_USERECB`, `CB_CALLS`, `CB_PENDING_MAX`

## Building on z/OS

Use the sample job in `jcl/asm_lked.jcl` as a starting point:

- Put the `.asm` modules into a source PDS (members named e.g. `MPMCQ`, `MPMCQFL`, `MPMCQSTO`, `MPMCQNT`, `MPMCQST`).
- Put the `.inc`/`.mac` files where your assembler can `COPY`/`MACRO` them (or inline them per your standards).
- Assemble each module with `ASMA90`, then link-edit with `HEWL` (RENT recommended).

