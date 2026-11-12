# Lock-free MPMC FIFO queue for z/OS (HLASM)

This repository contains a **multi-producer / multi-consumer, lock-free FIFO queue** written in **IBM z/OS High Level Assembler (HLASM)**.

It is designed to meet these requirements:

- **Callable from AMODE 31** callers (standard z/OS linkage).
- **Variable-length records** are **copied into the queue** at enqueue time.
- Queue stores record bytes in **64-bit virtual storage** (obtained/freed with `IARV64`).
- `QDEQ` **copies out** to caller buffer and returns actual length; truncation is supported.
- **Asynchronous notification** on enqueue:
  - A single **ATTACH**ed notifier TCB calls a user exit asynchronously.
  - A user-supplied **ECB** may also be **POST**ed on each enqueue.
  - Callback parm list is: `(CB_CTX, QCBaddr, PendingCount)`.
- **Statistics** are maintained (approximate/low-overhead) and returned via `QSTATS`.

## Entry points (planned)

- `QINIT(QCBaddr, options, initialPool, CB_EP, CB_CTX, USER_ECB)`
- `QENQ(QCBaddr, srcAddr, srcLen)`
- `QDEQ(QCBaddr, dstAddr, dstMaxLen, outLenAddr)`
- `QSTATS(QCBaddr, outStatsAddr, outStatsLen)`
- `QCBSTOP(QCBaddr)` (optional): stop notifier TCB.

Return codes:

- `QENQ`: `RC=0` success, `RC=8` allocation failure.
- `QDEQ`: `RC=4` empty, `RC=0` success, `RC=8` truncated.

## Source layout

- `src/mpmcq_dsects.inc`: DSECTs for QCB, node, stats, parm lists.
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
- `PAYLOAD64_CUR`, `PAYLOAD64_MAX` (bytes in 64-bit storage)
- `POST_INTERNAL`, `POST_USERECB`, `CB_CALLS`, `CB_PENDING_MAX`

## Building on z/OS

Use the sample job in `jcl/asm_lked.jcl` as a starting point:

- Put the `.asm` modules into a source PDS (members named e.g. `MPMCQ`, `MPMCQFL`, `MPMCQSTO`, `MPMCQNT`, `MPMCQST`).
- Put the `.inc`/`.mac` files where your assembler can `COPY`/`MACRO` them (or inline them per your standards).
- Assemble each module with `ASMA90`, then link-edit with `HEWL` (RENT recommended).

## Testing plan

The C programs in `TEST/` exercise the queue from simple calls up to several producers and consumers. Each program prints `Tnnxxxx PASS` or `Tnnxxxx FAIL ...` on `SYSPRINT`. A passing step ends with condition code 0. `S07` must not end with system abend A03 after the PASS line.

### How to run

1. Upload the assembler sources and submit `jcl/asm_lked.jcl`. The bind must complete before the tests link.
2. Upload `TEST/` with `ZOWE/upload-test.ps1`. `qstub.asm` goes to `QUEUE.ASM`, each `.c` to `QUEUE.C`, and each `.h` to `QUEUE.H`.
3. Submit `jcl/test_go.jcl` (job `MPMCQT`). It assembles `QSTUB`, compiles `QCALL` and the test members, binds each test with the queue, and runs `S01` through `S25`.
4. Read each `GO` step. Expect return code 0 and a `PASS` line. `S08` through `S13`, `S16`, `S18`, `S19`, `S20`, `S21`, `S23`, and `S25` are submitted with `POSIX(ON)`. `S24` is an assembler program, `T24HGPR`.

Run the steps in order. A later step is not evidence for a feature an earlier step already failed.

### What each step covers

| Step | Member | What it checks |
| --- | --- | --- |
| S01 | `T01INIT` | A null or misaligned QCB returns 12. A good `QINIT` plants eyecatcher `MPMCQCB` and version 1. The first `QDEQ` is empty (4). One enqueue and one dequeue round-trip. |
| S02 | `T02FIFO` | Twenty-four records come out in enqueue order, including the tag bytes. |
| S03 | `T03TRUNC` | A zero-length record enqueues and dequeues. A short caller buffer returns 8, copies the prefix, and reports the real length. The record is then gone. |
| S04 | `T04LENS` | One record at a time, on the main task: 0, 1, and 1024 bytes inline; then 2K, 4K, 8K, 16K, 32K, and 64K slabs; then 65537 bytes through `IARV64`. Each length is copied back unchanged. |
| S05 | `T05STAT` | The stats block is 80 bytes. After a known series of enqueues and dequeues, the activity, depth, payload, and retry counters match that series. An empty dequeue is counted. |
| S06 | `T06ECB` | `QINIT` is given a user ECB. Two enqueues post it. A wait on that ECB completes, and `POST_USERECB` is at least 1. |
| S07 | `T07CB` | A notifier subtask is attached. Three enqueues may coalesce into one callback; `PendingCount` is the sequence gap. `QCBSTOP` returns, the subtask is detached, and the step does not abend A03. Trace lines on `SYSPRINT` show the last step reached. |
| S08 | `T08PAIR` | One producer and one consumer, 40 inline records. The initial node pool is large enough that the worker does not `GETMAIN` a cell. Records stay in order. |
| S09 | `T09MPMC` | Four producers and four consumers, 50 messages each (200). Each producer’s sequence stays in order. Payloads stay inline. The initial pool is 400 nodes. No record is missing or delivered twice. |
| S10 | `T10MP25` | Twenty-five producers and twenty-five consumers, 20 messages each (500). Lengths are 16, 32, 64, 128, 256, 512, 768, and 1024, all inline. Each byte depends on the producer, the sequence, and the offset. Per-producer order is preserved. The pool is 600 nodes so thread-local caches do not force a worker `GETMAIN`. Afterwards the depth and payload byte counters are zero, and enqueue and dequeue success counts are 500. |
| S11 | `T11LARGE` | The main task enqueues eight records: 1025 through 64K slabs, then 65537 bytes through `IARV64`. Four consumers dequeue them and check the bytes. The main task obtained the payload and is still alive when it is freed. |
| S12 | `T12WAVE` | Four producers and four consumers run twice on the same queue, 24 messages each wave, with no second `QINIT`. Each producer’s sequence stays in order in both waves. |
| S13 | `T13ASYM` | Eight producers and one consumer, then one producer and eight consumers, on the same queue. Per-producer order holds, and the depth high-water is at least 1. |
| S14 | `T14STOP` | After `QCBSTOP`, a new enqueue still dequeues. The callback count does not increase. The step does not abend A03. |
| S15 | `T15BOTH` | One queue has both a callback and a user ECB. Four enqueues post the user ECB and the callback reports the sequence gap. |
| S16 | `T16STAT` | `QSTATS` runs on its own thread while two producers and two consumers move 80 inline records. Every snapshot returns 0. The final enqueue and dequeue counts match. |
| S17 | `T17NOPOL` | `QINIT` is given an initial pool of 0. The main task obtains every node, enqueues eight records, and drains them in order. |
| S18 | `T18MULTI` | Four queues run at the same time. Each has two producers and two consumers and 20 inline messages. A record carries its queue id. Each queue keeps its own order. Final enqueue and dequeue counts are 40 per queue, and the depth is 0. |
| S19 | `T19CHURN` | 192 short threads, in waves of 8. Each enqueues 4 records and dequeues 2, then exits, leaving nodes in its TLS slot. After a 2 second pause a second set of threads runs, then the main task drains every record. |
| S20 | `T20LRGMP` | Eight producers and eight consumers at once. Sizes are 512, every slab from 2K through 64K, 65537, and 2MB. Every byte is checked. Payload byte counters end at 0. |
| S21 | `T21COLD` | Initial pool is 0. Sixteen producers and sixteen consumers allocate nodes while the freelist grows from empty. |
| S22 | `T22BOUND` | Edges at 1024/1025, 2048/2049, 65536/65537, 1MB/1MB+1, and 16777215. 16777216 and `0x80000000` return 8. A null length pointer, a zero destination, and a huge destination max are checked. |
| S23 | `T23NTFST` | A callback that spins 50ms sees exactly 2000 messages from eight producers, with pending max greater than 1. `QCBSTOP` then runs while four producers and that callback are still active. A later enqueue still dequeues. |
| S24 | `T24HGPR` | Assembler driver. Bits 0–31 of R2–R12 are `X'DEADBEEF'` across `QINIT`, inline, slab, and `IARV64` enqueue/dequeue, empty dequeue, `QSTATS`, and `QCBSTOP`. Return code 0 passes. Return code 2–12 names the register that changed. |
| S25 | `T25BENCH` | 150000 messages at 1/1, 2/2, 4/4, and 8/8. That is 1.2 million enqueue plus dequeue calls. Elapsed seconds and stats are printed. Then 32 notifier enqueues start at sequence `X'FFFFFFF0'` and the pending sum is 32. |

### Pass

- Assemble and bind of the queue finish with a return code of 4 or less.
- `QSTUB` assemble and `QCALL` compile finish with a return code of 4 or less, so `S01`–`S23` and `S25` are not flushed. `S24` assembles `T24HGPR` from `QUEUE.ASM`.
- Every `GO` step is return code 0 and its `SYSPRINT` contains `PASS`.
- `S07`, `S14`, and `S15` have no system abend A03. A PASS line followed by A03 is a failed stop path: the notifier was still attached when the main task ended.

