# Lock-free MPMC FIFO queue for z/OS (HLASM)

Multi-producer / multi-consumer lock-free FIFO queue in IBM z/OS High Level Assembler. Callers are AMODE 31. Each queue is one QCB.

Payload bytes are copied into the queue. The default stores them in 31-bit size-class pools (256, 1K, 4K, 16K). Optional 64-bit mode uses `IARV64` memory objects. `QDEQ` copies out to a caller buffer and reports the actual length. Truncation is supported.

Design detail is in [documentation.md](documentation.md).

## Calling interface

Standard z/OS linkage: `R1` points at the parameter list. Layouts and `EXTRN`s are in `src/mpmcq_api.inc`.

| Entry | Purpose |
| --- | --- |
| `QINIT(QCBaddr, options, CB_EP, CB_CTX, USER_ECB)` | Initialize one queue. `QCBaddr` must be 256-byte aligned. |
| `QENQ(QCBaddr, srcAddr, srcLen)` | Copy a record in. |
| `QDEQ(QCBaddr, dstAddr, dstMaxLen, outLenAddr)` | Copy a record out. |
| `QSTATS(QCBaddr, outStatsAddr, outStatsLen)` | Best-effort stats snapshot. |
| `GETVERSION(outAddr, outMaxLen, outActLenAddr)` | Assemble-time build string (`&SYSDATE` / `&SYSTIME`). |
| `QCBSTOP(QCBaddr)` | Stop the notifier subtask, if one was started. Call it from the same task as `QINIT`. |

`QINIT` options: `MPMCQ_OPT_PAYLOAD31` (default) or `MPMCQ_OPT_PAYLOAD64`.

Return codes:

- `QINIT`: `0` success; `8` payload64 requested but the jobstep TTOKEN could not be obtained; `12` QCB is not 256-byte aligned; `16` payload64 probe (`GETSTOR`/`DETACH`) failed; any other nonzero value is the notifier `IDENTIFY`/`ATTACH` return code.
- `QENQ`: `0` success; `8` allocation failure; `12` record too large (payload31: longer than 16384; payload64: longer than 16MB−1).
- `QDEQ`: `4` empty; `0` full copy; `8` truncated (`*outLenAddr` is the actual length).

## Lifetime

The QCB must stay addressable while any producer, consumer, or notifier can touch it. Node and payload slabs are `GETMAIN`ed when a pool grows and are never `FREEMAIN`ed, including by `QCBSTOP`. The task that called `QINIT` must outlive every task that can still hold a cell from those slabs.

`STORAGE OBTAIN ... TCBADDR=` is not used. That operand is authorized-only. Problem-state callers rely on task lifetime or on subpool sharing (`ATTACH` `SHSPV`/`SHSPL`).

## Notification

If `CB_EP` is nonzero, `QINIT` starts one notifier subtask. Producers do not call the exit. They increment `ENQ_SEQ` and `POST` an internal ECB only while the notifier is armed, so a burst is about one `POST`. The notifier calls `(CB_CTX, QCBaddr, PendingCount)`.

`USER_ECB`, if nonzero, is `POST`ed on every successful enqueue. Posts can coalesce.

`IDENTIFY` and `ATTACH` use list/execute form (`MF=L` copied into a private work area, then `MF=E`) so the notifier module can be link-edited `RENT`.

## Source

- `src/mpmcq.asm` — `QINIT`, `QENQ`, `QDEQ`, inlined node freelist
- `src/mpmcq_notify.asm` — `QCBSTOP`, notifier subtask
- `src/mpmcq_storage.asm` — `IARV64` payload get/free
- `src/mpmcq_stats.asm` — `QSTATS`
- `src/mpmcq_version.asm` — `GETVERSION`
- `src/mpmcq_freelist.asm` — external node freelist (same contract as the inlined copy; hot path does not call it)
- `src/mpmcq_api.inc` — caller include
- `src/mpmcq_dsects.inc` — QCB, node, stats, parameter lists
- `src/mpmcq_atomics.mac`, `src/mpmcq_copy64.mac` — atomic and 31↔64 copy helpers
- `jcl/asm_lked.jcl` — sample assemble and link

Minimum architecture for `src/mpmcq.asm` is zEC12 (`ACONTROL OPTABLE(ZS6)`) because the publish path uses `TBEGIN`/`TEND`. The other modules assemble at z196 / ZS5. Link with `RENT`.

`TBEGIN`, `TEND`, and `PPA` run in problem state. They do not need APF authorization. Transactional execution must still be enabled (control register 0, bit 8). If that bit is off, `TBEGIN` raises a special-operation exception instead of falling back to compare-and-swap. Set `MPMCQ_ENABLE_TX` to 0 in `src/mpmcq.asm` in that environment.

The dequeue transaction re-reads the head pointer and keeps the ABA tag from before `TBEGIN`. That tag is still valid when the pointer matches, because every writer updates the tag and the pointer together. The payload length and address are read inside the transaction, so they commit with the head update. On abort, `QCB_TDB` holds the abort code (bytes 6–7) and the aborted-instruction address (bytes 8–15).

Failed compare-and-swap retries issue `PPA` order 1 (spin-loop hint). The processor-assist facility must be installed; otherwise `PPA` raises an operation exception.
