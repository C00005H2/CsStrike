# Binary-patch notes — `CSNZ_Server.exe` (no rebuild)

This is the "patch the executable" half of the optimisation work. It changes the shipped
binary in place (in a **copy**), without recompiling anything.

| file | what it is |
|---|---|
| `docs/performance/binpatch/CSNZ_Server.patched.exe` | drop-in patched server, **same size** as the original (3,125,760 bytes), 357 bytes differ |
| `docs/performance/tools/patch_csnz_server_exe.py` | reproducible patcher (byte-guarded, idempotent, `--verify`, `--dry-run`) |
| `docs/performance/tools/cave.bin` | the 384 bytes of injected machine code (built from `cave.s` / `prepoll.inc`) |
| `docs/performance/tools/cave.s`, `prepoll.inc` | assembly source of the injected code |
| `docs/performance/tools/test_prepoll.s`, `test_main.c` | mock harness that unit-tests the injected network routine on Linux |

```
original  CSNZ_Server.exe         sha256 a8a386380d02b6aae1c1d29fea71a3bdbc4bce81fb54c4552a269591cd210856
patched   CSNZ_Server.patched.exe sha256 65c5c9af6d40d26364f569e5f57da63d7e67619538f1317021a86b83064cce8b
```

The original file in the repository is **not** modified — the patcher only ever writes to a
new path (or to a file you explicitly point it at).

---

## 1. What is patched

Three of the problems from `PERFORMANCE_ANALYSIS.md` can be fixed in machine code without
adding data structures, so they are patched in the EXE. Everything else is listed in
section 3 with the reason it needs a rebuild.

### 1.1 The 100 %-CPU network spin (RC1) — the big one

`CTCPServer::Listen()` polls with `WSAPoll` and, at every call, loops over every socket.
The pollfd event mask of each **client** socket was set once, at accept time, to
`POLLRDNORM | POLLWRNORM`. A connected TCP socket is almost always writable, so `WSAPoll`
reported `POLLWRNORM` on every call, `Listen()` never took the `if (!result) return;` path,
and the listen thread looped as fast as the CPU allowed — while holding
`g_ServerCriticalSection` for most of each iteration. That is one burned core per server
(and extra contention for every other thread) for as long as anybody is connected.

The patcher replaces the constant timeout instruction

```
14011A89C   mov  r8d, 1000          ; WSAPoll timeout = 1000 ms  (never reached in practice)
14011A8A2   mov  rcx, [rcx+68h]     ; m_fds.begin()   <- rcx = this
```

with a call into 384 bytes of padding at the end of `.text`:

```
14011A89C   call PrePoll            ; rebuilds every pollfd, returns timeout in r8d
14011A8A1   nop
14011A8A2   mov  rcx, [rdi+68h]     ; m_fds.begin()   <- rdi = this (rcx was clobbered)
```

`PrePoll(CTCPServer* this)` does, per poll:

1. asks every client socket whether it has queued outgoing data
   (`IExtendedSocket::GetPacketsToSend()`, vtable slot `0xC0`),
2. writes `.events = POLLRDNORM` for every client fd — plus `POLLWRNORM` **only** for the
   sockets that really have something queued, and zeroes `.revents`,
3. leaves index 0 (the listening socket) completely untouched,
4. returns a **1 ms** timeout in `r8d`.

So now the common case is `WSAPoll` blocking for 1 ms instead of returning instantly, and
`Listen()` walks the fd list once per millisecond instead of hundreds of thousands of
times per second. When a packet is queued, that socket's `POLLWRNORM` fires immediately and
the existing drain code in `Listen()` sends it, so outgoing latency is unchanged (≤ 1 ms
poll granularity, same as the old blocking behaviour it replaces).

The accept path is corrected too — it used to arm the new client's fd with the same
always-writable mask:

```
14011A9EF   mov dword [rsp+38h], 0x110   ->   0x100      ; POLLRDNORM|POLLWRNORM -> POLLRDNORM
```

`PrePoll` re-arms `POLLWRNORM` a few microseconds later if that client already has data
queued, so nothing can stall.

Because the `WSAPoll` timeout is rounded up to the system timer resolution, the injected
code also calls `timeBeginPeriod(1)` **once**, through `LoadLibraryA("winmm.dll")` +
`GetProcAddress` (no new import-table entries, fails silently if winmm is unavailable), so
1 ms really means ~1 ms.

> Deliberately **not** done: timeout `0`. That would be a pure spin again. Dropping
> `POLLWRNORM` entirely was also rejected — a queued packet would then sit in the queue
> until someone else flushed it. The mask is now a function of the queue, which is what
> `src/net/tcpclient.cpp:120` already does correctly in the same code base.

### 1.2 Log file: open once instead of once per line (RC3)

`CFileLogger::LogVarg()` did `fopen(...,"a+")` → `vfprintf` → `fclose` for **every single
log line** (the server logs from the login path, the database layer, the packet handlers,
…). Two call sites are rewritten to point at injected helpers:

```
1401101E0   call [fopen]      ->   call GetLogFile     ; cached FILE*, opened on first use
14011020D   call [fclose]     ->   call LogDone        ; fflush() instead of fclose()
```

`GetLogFile` keeps the handle in a BSS slot keyed on the path pointer (if a different path
ever shows up, it opens a new handle exactly like the original — nothing is reused wrongly);
`LogDone` flushes the stream, so each line still reaches the OS immediately, i.e. durability
is the same as the original open/close-per-line scheme, but without a `CreateFile`/`CloseHandle`
pair 10 000 times a second. Writes stay serialised by the composite logger's critical
section (verified in `src/common/logger.cpp`), and there is exactly one `CFileLogger`
instance in the shipped build, so the cache cannot mix up two log files.

### 1.3 Container / PE layout

The injected code sits in the zero padding at the end of `.text`
(VA `0x140265C70` … `0x140265DF0`, file `0x265070` … `0x2651F0`). Two header fields are
extended so the code and its three globals are inside the mapped image:

| field | original | patched |
|---|---|---|
| `.text` VirtualSize | `0x000264C6F` | `0x000265000` |
| `.data` VirtualSize | `0x00027AA8` | `0x00027AC8` (24 bytes of zeroed BSS for the cached `FILE*`, the cached path pointer and the timer flag) |

Everything else — size, entry point, imports, relocations, `SizeOfImage`, section
alignment — is byte-identical. The injected code contains **no absolute addresses**
(verified: only RIP-relative operands), so it is ASLR-safe like the rest of the image.

Total difference: **357 bytes in 34 runs** (3 header bytes, 19 bytes of rewritten
instructions, 335 bytes of injected code — 49 of the 384 cave bytes were already `0x00`).

---

## 2. How to apply, verify and revert

```bash
# patch a copy (recommended): original stays untouched
python3 docs/performance/tools/patch_csnz_server_exe.py CSNZ_Server.exe \
        --out CSNZ_Server_patched.exe --report-diff

# or use the pre-built patched binary directly
#   docs/performance/binpatch/CSNZ_Server.patched.exe
```

The patcher refuses to touch a file whose bytes do not match the expected original
(`refusing to patch: the file does not match the expected original`), and running it twice
is a no-op (`already patched …`, byte-identical output).

```bash
# sanity-check a patched file (no writes)
python3 docs/performance/tools/patch_csnz_server_exe.py CSNZ_Server.patched.exe --verify --dry-run

# hashes must match
sha256sum CSNZ_Server.exe                 # a8a386380d02b6aae1c1d29fea71a3bdbc4bce81fb54c4552a269591cd210856
sha256sum CSNZ_Server.patched.exe         # 65c5c9af6d40d26364f569e5f57da63d7e67619538f1317021a86b83064cce8b
```

**Revert** = put the original file back (the repository's `CSNZ_Server.exe`, or your own
backup): `git checkout -- CSNZ_Server.exe`, or just delete the patched copy. Nothing is
written outside the output file, and the patched EXE never modifies the original.

---

## 3. What is **not** in the EXE (and why)

Complete honesty about coverage — a byte patch cannot add data members, change an STL
container or restructure a loop. The fix pack in `docs/performance/patches/` remains the
full solution; this is what can be had without a compiler.

| fix pack item | in the patched EXE? | why / alternative |
|---|---|---|
| **0001** network loop | **partly** — the spin is gone (mask sync, 1 ms poll, accept mask). | The `unordered_map<SOCKET,…>` O(1) lookup and the rewritten index-based loop need new class members → rebuild. The leftover cost is one `GetExSocketBySocket()` per client fd in the rare pass where some queue is non-empty (this is the same O(n) call the original made for *every* client on *every* poll, so it is already a large reduction). |
| **0002** event queue (`vector` → `deque`) | no | STL container type change inside `CEventHandler` → rebuild. |
| **0003** logger | **yes, effectively** — the expensive part (open/close per line) is patched; every line is flushed, so durability is unchanged. The "≤ 1 flush/s" policy from the source patch is a *source-level* trade-off that the binary patch deliberately does **not** make, to keep zero loss on crash. | — |
| **0004** user lookup maps (`m_UsersById`, `m_UsersBySocket`) | no | needs new member containers in `CUserManager` → rebuild. |
| **0005** SQLite WAL + 36 indexes + pragmas | not in the EXE — **but it does not need to be**: the indexes and `journal_mode=WAL` are *persistent* properties of the database file. Run `docs/performance/sql/optimize_database.sql` once against `UserDatabase.db3` and every future server start uses them. | per-connection pragmas (`cache_size`, `synchronous`) cannot be set by a file, but with a 385 KB database the default 2 MB page cache already holds the whole DB → no measurable gain. |
| **0006** packet buffer copies | no | rewriting `CExtendedSocket::Read()` / `Buffer` growth needs real code → rebuild. |
| ServerConfig.json tuning | no EXE change needed | edit the JSON. |
| Windows-side tuning | no EXE change needed | `tools/tune-windows.ps1`. |
| partial-send corruption, packet leak on `WSAEWOULDBLOCK`, 20 KB `Buffer` reserve, per-minute `UPDATE UserSession` | no | structural → rebuild (see RC7/RC8 in the analysis report). |

So: **in the EXE** you get the network-spin fix, the accepted-socket mask fix and the
logger open/close fix — in the measured analysis those were the three biggest CPU burners
after the SQLite work. The remaining items still need the source patches, and the SQL part
is a one-off file operation.

---

## 4. What was verified here — and what was not

Verified statically (all in this sandbox):

* patcher guard: refuses foreign/edited files (sha256 + per-site byte guards), idempotent,
  byte-diff report is exact (357 bytes / 34 runs, all accounted for);
* `objdump -d` of the **patched output** shows exactly the intended instructions at all five
  sites and the injected block at `0x140265C70`;
* the injected network routine was extracted into a Linux unit test
  (`tools/test_prepoll.s` + `tools/test_main.c`, 5 cases: idle, one queued client, queued
  first client, no clients, unknown socket) — all pass, including "listening socket
  untouched" and "socket not found ⇒ read-only, never writable";
* no absolute addresses in the injected code (ASLR-safe), 16-byte stack alignment at every
  injected `call` (Win64 ABI), all registers the caller needs are preserved;
* both PE headers still parse, `SizeOfImage`/entry point/imports/relocations unchanged;
* the original file's hash is unchanged after building the patch.

**Not** verified: the patched EXE was never executed — there is no Windows or Wine in this
environment. Runtime behaviour must be confirmed on staging (below).

### Staging checklist

1. Stop the server, keep `UserDatabase.db3` and the `Logs/` folder backed up.
2. Put `CSNZ_Server.patched.exe` next to the original (same folder, same name if you prefer)
   and start it with the normal working directory and `ServerConfig.json`.
3. Watch Task Manager: with a client connected, the server's CPU should drop from
   ~one full core to a few percent for the same player count.
4. Check the log file in `Logs/` is still being written (one line per event, timestamps
   advancing) and that `Logs/Server_*.log` opens normally.
5. Functional pass: login, character select, enter a room, buy something (metadata burst),
   play a round, disconnect/reconnect, run one admin command; compare messages in the log
   to a session on the original EXE.
6. Keep an eye on latency-sensitive behaviour (hit registration, item pickup) — the poll
   interval is now 1 ms worst case, which is below anything a client can perceive, but this
   is the one number worth measuring against the original.
7. If anything looks wrong: stop, restore the original EXE, keep the log file for the
   report.

---

## 5. Risks and trade-offs (read this)

* **Antivirus / SmartScreen.** The result is an unsigned binary whose bytes differ from the
  published file and that contains code in section padding — heuristics may flag it. The
  tuning script already adds Defender exclusions; whitelist the folder if needed.
* **`timeBeginPeriod(1)`** raises the system timer resolution process-wide (slightly more
  power draw on the machine). It is required for the 1 ms poll to actually be 1 ms. If you
  prefer not to have it, the alternative is a 15.6 ms poll granularity — in that case do not
  use this patch as-is.
* **No unwind info for the injected helpers.** They only call CRT/Kernel32 functions that do
  not throw. If Windows ever raised an exception inside them (with the CPU already
  faulting), unwinding would not be graceful — but the process would be dying anyway.
* **The network patch keeps the original O(n) socket lookup** in the pass where some client
  has data queued (documented in section 3). It can no longer cause a spin, because that
  lookup only runs while there is data to flush.
* **Not a patch for a packed binary.** This EXE is plain MSVC code, which is why patching is
  possible at all; do not apply the patcher to another build — the byte guard will abort it.
* **This does not fix the correctness bugs** found during the analysis (truncated `send()`
  handling, packet leak on `WSAEWOULDBLOCK`, `UPDATE UserSession` churn). They need the
  rebuild; the binary patch intentionally stays away from them.

---

## 6. Reproducing the injected code

```bash
cd docs/performance/tools
as --64 -o cave.o cave.s
ld -Ttext=0x140265c70 -e 0 \
   --defsym GLOGFILE=0x1402f9aa8 --defsym GLOGPATH=0x1402f9ab0 --defsym GTIMERFLAG=0x1402f9ab8 \
   --defsym FOPEN_IAT=0x140266ad0 --defsym FFLUSH_IAT=0x140266b10 \
   --defsym LOADLIB_IAT=0x140266128 --defsym GETPROC_IAT=0x140266120 \
   --defsym GetExSocketBySocket=0x14011a710 -o cave.elf cave.o
objcopy -O binary --only-section=.text cave.elf cave.bin      # must stay <= 0x180 bytes
python3 patch_csnz_server_exe.py /path/to/CSNZ_Server.exe --out CSNZ_Server_patched.exe --report-diff
```

The mock test for the network routine:

```bash
gcc -o test_prepoll test_prepoll.s test_main.c && ./test_prepoll     # ALL TESTS PASSED
```
