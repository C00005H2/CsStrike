# CSNZ_Server.exe / CSOLauncher.exe — Performance Analysis & Optimization Plan

**Repo:** `C00005H2/CsStrike` · **Analysed binaries:** `CSNZ_Server.exe` (3,125,760 B), `CSOLauncher.exe` (785,920 B)
**Date:** 2026-10-03 · **Method:** static PE/import analysis + disassembly of the executables, cross-checked against the exact upstream source they were built from.

---

## 0. TL;DR

| # | Problem in the binary | Effect | Fix | Expected gain |
|---|---|---|---|---|
| 1 | `CTCPServer::Listen()` asks `WSAPoll()` for **write-readiness on every client, all the time** | On Windows a TCP socket is *always* writable → the poll returns instantly → **the network thread spins at ~100 % of one CPU core** as soon as 1 player is connected, while holding a global lock | `0001-server-network-loop.patch` | ~1 full core freed; large reduction of lag spikes |
| 2 | Per-fd **O(n) socket lookup × 2**, and the fd loop **restarts from `begin()`** after every accept/disconnect | O(n²) work per poll pass, worse the more players connect | `0001` (hash map + index loop) | CPU scales linearly instead of quadratically |
| 3 | `CFileLogger::LogVarg()` does **`fopen()` + `vfprintf()` + `fclose()` for every single log line** | 3+ file syscalls + flush per line, all under a logger mutex; on HDD/AV-machines this stutters the whole server | `0003-server-logger.patch` | 10–100× less I/O per log line |
| 4 | Receive path **copies the whole packet buffer 3–4×**, send path **1–2×** | Wasted CPU/allocations, most visible on big metadata/inventory packets | `0006-server-packet-copies.patch` | a few % CPU + fewer allocations |
| 5 | SQLite: **no secondary indexes**, rollback-journal mode, 2 MB cache, only ±5 statements wrapped in transactions | per-user queries and the **per-minute expiry scans** are full table scans; every write creates and deletes a journal file | `0005-server-sqlite-perf.patch` + `sql/optimize_database.sql` | big win as the DB grows past a few MB |
| 6 | All packet processing runs on **one event thread under one global critical section** | hard ceiling on how many players one process can hold; the spin (1) makes it worse by fighting for the same lock | architecture note (§5.6) | plan capacity around it |
| 7 | **Unbounded send queue** per socket (`m_SendPackets`) | a slow/stuck client can grow server RAM until it dies | hardening note (§5.7) | prevents OOM |
| 8 | `CSOLauncher.exe` **is the game process** (loads `filesystem_nar.dll` + `hw.dll` and runs the engine in-process) | the CPU/RAM you see is the *game*, not the launcher; launcher overhead is a one-time pattern scan at start-up | §6 | set expectations, tune the engine flags instead |

The whole fix pack is in [`patches/`](patches/) — see [`README.md`](README.md) for how to apply it.
Nothing in this document requires a rewrite: all patches are surgical and keep the existing behaviour, except where explicitly noted.

---

## 1. What these binaries are

### 1.1 Provenance (important — it makes this analysis exact)

Both executables are builds of public source, and the binaries match that source **one-to-one**:

| Binary | Evidence | Upstream source |
|---|---|---|
| `CSNZ_Server.exe` | PE32+ x64 console app, image base `0x140000000`, entry `0x1ee100`, timestamp `2026-09-30 10:57 UTC`. Embedded string `C:\GitHub\CSNZ_Server_JusicP\src\thirdparty\wolfssl\wolfcrypt\src\asn.c` | **`github.com/JusicP/CSNZ_Server`** — HEAD `6e5275cb` ("Fix ItemBox", 2026-09-30 11:58 +0100) |
| `CSOLauncher.exe` | PE32 x86 GUI, base `0x400000`, `.fptable` section, 1 export `CreateInterface`, PDB path `C:\GitHub\Launcher_CSNZ_JusicP\Release\CSOLauncher.pdb` | **`github.com/JusicP/Launcher_CSNZ`** — Source engine launcher + game hooks (`hook.cpp`, Detours, HLSDK) |

Cross-checks that were performed:

* The only `WSAPoll()` call site in the server disassembly (`0x14011a8b1`, timeout `0x3E8` = 1000 ms) is exactly `CTCPServer::Listen()` in the source.
* `Sleep` is only reached through two tail-jump thunks — it is `SleepMS(1000)` in `main.cpp`'s tick loop, not a hot path.
* The embedded SQLite version string is `3.43.0`, the framework is MSVC (`MSVCP140/VCRUNTIME140_1`, `<ppl.h>` concurrency runtime), and TLS is wolfSSL — all present in the source tree.

**Consequence:** every line reference below points at real code that *is* in your executables. You don't have to modify the EXEs by hand — apply the patches to the source and rebuild (see §7).

### 1.2 What each binary does

* **`CSNZ_Server.exe`** — the lobby/master server: TCP login + game lobby + shop/inventory/quests/clans, UDP hole-punching, SQLite user database, optional TLS.
* **`CSOLauncher.exe`** — the *client* launcher **and the game host process**: `WinMain` loads `filesystem_nar.dll`, then `hw.dll`, calls `Hook()` and runs the Source engine (`engineAPI->Run(...)`) inside this same process. Because it hosts the engine, its Task Manager numbers are the game's numbers.
* `CSOHLDS.exe` — dedicated/headless server binary (exports `CreateInterface`), `cstrike-online.exe` — 105 KB packed client stub.

---

## 2. How the server spends CPU today

### RC1 — The network thread busy-spins (the single biggest problem)

`src/net/tcpserver.cpp` → `CTCPServer::Listen()` (line 174):

```cpp
int result = poll(m_fds.data(), m_fds.size(), 1000);   // 1 s timeout
...
for (auto it = m_fds.begin(); it != m_fds.end(); it++)
{
    if (it->revents & POLLRDNORM) { ... }
    if (it->revents & POLLWRNORM && ...) { /* send at most ONE queued packet */ }
}
```

and when a client connects (same file, `Accept()` path):

```cpp
WSAPOLLFD fd;
fd.fd = socket->GetSocket();
fd.events = POLLRDNORM | POLLWRNORM;   // <-- requested unconditionally
m_fds.push_back(fd);
it = m_fds.begin();                    // <-- and restart the whole scan
```

Why this burns a core:

1. `POLLWRNORM` = "socket can be written to". A connected TCP socket **with free send-buffer space is always writable**, so `WSAPoll()` returns immediately on every call — the 1000 ms timeout is never reached.
2. `ListenThread()` is `while (IsRunning()) Listen();` — no sleep — so this becomes a ~100 %-CPU spin loop that only exists because of the wrong `events` mask.
3. While spinning it repeatedly **enters the global `g_ServerCriticalSection`** (`Listen()` takes it for the whole pass). The same lock is taken by the *event thread* for every packet it processes (`serverinstance.cpp:335 OnEvent()`), so the spin directly steals CPU *and* adds lock-wait latency to real game work — this is what "server uses CPU and still feels laggy" looks like.

Interesting detail: the codebase already knows the fix — `CTCPClient::Listen()` (`net/tcpclient.cpp:120`) only asks for write-readiness **when the queue is non-empty**:

```cpp
if (m_pSocket->GetPacketsToSend().size())
    FD_SET(m_pSocket->GetSocket(), &m_FdsWrite);
```

The client class does it right; the server class doesn't.

**Fix (patch 0001):** ask for `POLLWRNORM` only for sockets that actually have queued packets, and use a short poll timeout (10 ms) while clients are connected (1000 ms when there are none). The loop is then event-driven: idle ≈ 0 % CPU, and a queued packet still goes out immediately, because whenever the server has just *read* a packet the next poll iteration returns instantly and the send queue is drained.

### RC2 — O(n) lookups and O(n²) scan restarts

* `CTCPServer::GetExSocketBySocket()` is a linear scan over `m_Clients` and it is called **twice per ready fd per pass** (read branch + write branch) — and it's also called once more in `DisconnectClient()`'s lambda. With 100 players each pass does ~10 000 virtual calls.
* After `Accept()` and after `DisconnectClient()` the loop does `it = m_fds.begin(); continue;` — literally commented *"probably not the best solution"* / *"not the best solution"* in the source. A 100-player login storm costs ~100 restarts × 100 fds.
* Same pattern elsewhere: `CUserManager::GetUserById/GetUserBySocket` (`manager/usermanager.cpp:1131-1151`) and `CChannel::GetRoomById/GetUserById` (`channel/channel.cpp:169/179`) are linear scans; `GetUserBySocket` alone is called from **32 places**, usually as the first statement of a packet handler (i.e. on every packet).

**Fix (patches 0001 + 0004):** `std::unordered_map` indexes for sockets, users-by-id and users-by-socket; index-based fd loop that doesn't restart. Complexity drops from O(n²) to O(n) per pass and O(1) per lookup.

### RC3 — Logging does a file open/close per line

`src/common/logger.cpp` → `CFileLogger::LogVarg()`:

```cpp
FILE* file = fopen(m_szLogPath, "a+");
if (file)
{
    vfprintf(file, msg, argptr);
    fclose(file);
}
```

Every `Logger().Info/Warn/Error` therefore costs: `CreateFile` + seek-to-end + write + `CloseHandle` (plus AV filtering and a `FlushFileBuffers`-like effect on close), **while holding the composite logger's critical section**. The server logs on every connect/disconnect, every UDP hole-punch/heartbeat packet, every login, every expired item, every minute tick, every DB error, etc. On a HDD or with an aggressive AV this alone produces visible hitches.

**Fix (patch 0003):** keep the `FILE*` open, use a 64 KB stdio buffer, flush immediately only for `ERROR`/`FATAL` and otherwise at most once per second.

### RC4 — Packet buffers are copied 3–4 times per packet

`src/net/extendedsocket.cpp` → `CExtendedSocket::Read()`:

```cpp
packetDataBuf.resize(PACKET_HEADER_SIZE);
recvResult = Read(...);                       // 1) header into a local vector
m_pMsg = new CReceivePacket(Buffer(packetDataBuf));   // 2) copy into the packet
	
Buffer& buf = m_pMsg->GetData();              // 3) copy the whole buffer out
vector<unsigned char> vecBuf = buf.getBuffer();
vecBuf.insert(vecBuf.end(), ...);             //    (realloc + copy again)
buf.setBuffer(vecBuf);                        // 4) copy back in
```

The send path has the same shape: `CSendPacket::SetPacketLength()` returns a **copy** of the whole outgoing buffer (`vector<unsigned char> v = m_OutStream.getBuffer();`), and `Send()` then encrypts it in place.

**Fix (patch 0006):** add `Buffer::append()`/`reserve()` and append received bytes in place (removes two full copies per packet). The `SetPacketLength()` copy is left as a follow-up because it touches every send call site.

### RC5 — SQLite is used with default, "safe but slow" settings

`src/manager/userdatabase_sqlite.cpp`:

* Opened as `SQLite::OPEN_READWRITE | OPEN_CREATE`, and `Init()` only sets:
  ```cpp
  m_Database.exec("PRAGMA synchronous=OFF");   // fast, but: power loss can corrupt the DB
  m_Database.exec("PRAGMA foreign_keys=ON");
  ```
  → journal mode is still the default **DELETE** (each write creates and deletes a `-journal` file), page cache is the default 2 MB, no mmap, temp tables on disk.
* **The schema has no secondary indexes at all** (only 14 PRIMARY KEY/UNIQUE auto-indexes) — see the actual DB shipped in this repo: `UserDatabase.db3`, 46 tables, 14 indexes. So every hot query is a full table scan of `UserInventory`, `UserQuest*`, `UserLoadout`, `UserCostumeLoadout`, `UserBuyMenu`, … — and those tables grow with every player and every item.
* `OnMinuteTick()` (line 5888) runs, **every minute**, for the whole server:
  * `SELECT ... FROM UserInventory WHERE expiryDate != 0 AND inUse = 1 AND expiryDate < ?` (full scan)
  * `DELETE FROM UserBan WHERE term <= ?`
  * `UPDATE UserSession SET sessionTime = sessionTime + 1` (write for every session)
  * `UPDATE ClanStorageItem SET ... WHERE itemID != 0 AND itemDuration <= ?` (full scan)
* Only a handful of places use explicit transactions (`itemmanager.cpp:1021/1373-1407`, `userdatabase_sqlite.cpp:1802/4005/4071/4208/4688`, helpers at 6539/6547) — everything else is auto-commit, i.e. one journal create/delete cycle per statement.
* `OnDayTick()` also does a full DB `backup()` (only in the non-`PUBLIC_RELEASE` build) — once a day is fine, but it is a full file copy, so keep the DB on a fast disk.

**Fix (patch 0005 + `sql/optimize_database.sql`):** WAL journal, 64 MB page cache, `temp_store=MEMORY`, 256 MB mmap, `busy_timeout`, plus 36 `CREATE INDEX IF NOT EXISTS` statements for all the `userID`/`clanID`/`expiryDate` columns used by the queries above.

### RC6 — Concurrency model (why one process has a ceiling)

* `main()`: `while (IsServerActive()) { g_Events.AddEventFunction(OnSecondTick); SleepMS(1000); }` — a 1 Hz tick that allocates a `std::function`/`CEvent_Function` every second (heap + mutex + `SetEvent`).
* `EventThread()` waits on an auto-reset event, `OnEvent()` pops **one** event at a time from `CEvents` and executes it inside `g_ServerCriticalSection`.
* `CEvents` is a `std::vector<IEvent*>` with `erase(begin())` per event (O(n) memmove per event, plus a `new`/`delete` per event) and a `printf` when the backlog exceeds 50.
* Therefore **all** packet handling (DB writes, room logic, packet building) is serialised on one thread; the TCP listen thread and the UDP listen thread only do I/O. One `CSNZ_Server.exe` = roughly 2 CPU-bound threads, so a 100-player `MaxPlayers` setting is optimistic on a busy server.

**Fix (patch 0002 for the cheap part):** `std::deque` instead of `std::vector` in `CEvents` (O(1) `pop_front()`). Longer-term (documented in §5.6, not patched): shard the event queue per channel/room, or move DB writes to a worker thread.

### RC7 — Unbounded send queue (memory)

`CExtendedSocket::Send(msg, ignoreQueue=false)` pushes into `m_SendPackets` with **no size limit**. A client that stops reading (or a saturated link) makes this vector grow without bound — one such client can consume all the process memory. There is also a small leak: on `WSAEWOULDBLOCK` in the `ignoreQueue=true` path the packet is neither sent nor deleted (`extendedsocket.cpp`, `Send(CSendPacket*, bool)`).

**Fix:** see hardening note §5.7 (cap + disconnect), not included in the patch set to keep behaviour unchanged.

### RC8 — Smaller items

* Only **one queued packet is sent per socket per poll pass** (`GetPacketsToSend().at(0)` + `erase(begin())`) — patched in 0001 (drain loop).
* `Buffer()` default-constructs with `buffer.reserve(20000)` — every `Buffer` allocates 20 KB, even for a 4-byte packet.
* `OnSecondTick()` calls `localtime()` (not thread-safe, and takes a lock internally) once per second — negligible, but `OnMinuteTick()` logs `GetMainInfo()` and iterates all managers.
* UDP server uses `select()` with `m_nMaxFD + 1` (on Windows, `select` ignores the first argument but is limited to `FD_SETSIZE` = 64 sockets) — fine here (one socket), just don't extend it.
* `CThread::Terminate()` uses `TerminateThread` (leaks the thread stack and can deadlock at shutdown) — only used for the console thread at exit.

---

## 3. Launcher analysis (`CSOLauncher.exe`)

**Key insight: this process *is* the game.** `launcher.cpp` → `WinMain` loads `filesystem_nar.dll`, loads `hw.dll`, calls `Hook(...)` and then `engineAPI->Run(hInstance, ...)` which never returns until the game exits. So:

* Task Manager's "CSOLauncher.exe: 1–3 GB RAM, 20–60 % CPU" is **the Source engine + CSO client**, not launcher code. Optimising the launcher itself cannot change that number; you must tune the *game* (resolution, `fps_max`, `dxlevel`, windowed mode, model/texture settings) and the OS.
* Launcher-side costs, in order of importance:
  1. **Start-up pattern scanning** — `hookutils.cpp:290/315` `FindPattern()` is a naive byte-by-byte scan (`for i in start..end { for idx in pattern }`) with no `memchr`/Boyer-Moore skip. `Hook()` runs ~30-40 such scans over the whole engine module, plus more in `HookThread` for `gameui.dll`/`mp.dll`. One-time cost: typically a few hundred ms of one core; on a slow disk / with AV it can be seconds.
  2. `HookThread` polls for `gameui.dll`/`mp.dll` with `Sleep(500)` — negligible, but it is a second thread for the whole session.
  3. `GameUI_RunFrame` (per-frame VGUI hook, `hook.cpp:1105`) runs pattern scans **only until the login UI is set up** (`bShowLoginDlg` guard), then it is a pass-through — correct, no per-frame scanning.
  4. Detours/`VirtualProtect` patches (`FPS_PATCH`, 100 fps cap, SSL/`EVP_CIPHER_CTX_new` hooks when not using the original server) — one-time.
  5. `-writemetadata` / `-dumpmetadata` / `-dumpall` / the `metadata_requestall` console command build ZIPs in memory and write JSON files — only when *you* ask for them, but don't leave them in a shortcut.
* Behaviour worth knowing when debugging "the game freezes at start-up": several hook failures pop a **modal `MessageBox`** (`"…== NULL!!!"`). If a dialog ends up behind the game window, the process looks hung. Also `-nomutex` allows a second instance (= a second full game process), and `-disableauthui` skips the custom VGUI login dialog patch (test it before rolling it out to players).

Practical launcher-side recommendations (no binary edits):

* Shortcut flags: `-windowed -width 1280 -height 720 -novid` (lower resolution = lower GPU/CPU/RAM), avoid `-debug`, `-developer 1`, `-dumpmetadata`, `-dumpall`, `-writemetadata`.
* Use `-ignoremetadata` (or `-loaddedifromfile` if you ship the dedi CSV) so the client doesn't fetch/write metadata on a normal launch.
* Add the whole client folder to antivirus exclusions — the client reads thousands of resource files at start-up.
* Don't run the server and the game on the same PC while testing performance.
* Patch opportunity if you ever rebuild the launcher: pre-filter `FindPattern()` with a first-byte search (or `memchr` for the first mask byte) — same results, ~10-50× less start-up scanning:

  ```cpp
  for (DWORD i = start; i < end - patternLength; )
  {
      // jump straight to the next candidate with the same first byte
      if (pattern[0] != *(PCHAR)i) { i++; continue; }   // memchr(pattern[0], ...) is much faster
      ...existing masked compare...
  }
  ```

---

## 4. Fix pack

| Patch | Files | What it changes | Risk |
|---|---|---|---|
| `0001-server-network-loop.patch` | `net/tcpserver.{cpp,h}` | write-readiness only when the send queue is non-empty; adaptive poll timeout; `unordered_map` socket lookup; index-based fd loop (no restarts); drain the whole send queue | Low (logic only, no protocol change) |
| `0002-server-event-queue.patch` | `event.h` | `std::vector` → `std::deque` for the event queue; `pop_front()` | Very low |
| `0003-server-logger.patch` | `common/logger.{cpp,h}` | keep the log `FILE*` open, 64 KB buffer, flush on error or 1×/s | Very low (`~CFileLogger` flushes+closes) |
| `0004-server-user-lookup.patch` | `manager/usermanager.{cpp,h}` | `unordered_map` indexes for users by id / by socket | Low |
| `0005-server-sqlite-perf.patch` | `manager/userdatabase_sqlite.cpp` | WAL + 64 MB cache + MEMORY temp store + mmap + busy_timeout; creates the missing indexes (`IF NOT EXISTS`) | Medium — read §5.5 (WAL durability, first-start index build) |
| `0006-server-packet-copies.patch` | `common/buffer.{cpp,h}`, `net/extendedsocket.cpp` | in-place `Buffer::append()` instead of copying the packet buffer twice per read | Low |

Everything is a *unified diff against upstream `JusicP/CSNZ_Server`*. [`README.md`](README.md) has the exact `git apply` + build commands.

If you don't want to rebuild the server: `sql/optimize_database.sql` alone gives you the database part (indexes + WAL), which is the second biggest win, and `tools/tune-windows.ps1` gives you the host-side part. The CPU spin (#1) and logging (#3) can only be fixed in the binary.

---

## 5. Findings detail, trade-offs and extra options

### 5.1 What the CPU spin costs (why #1 first)

With the current code, one core is *always* busy while ≥1 client is connected, no matter whether anything is happening. That has three consequences beyond the electricity bill:

1. The listen thread and the event thread contend for `g_ServerCriticalSection` thousands of times per second → real packet processing waits behind an empty send loop.
2. On a shared/cloud CPU the server looks "always overloaded" and gets throttled.
3. It hides the real bottleneck: without the spin you can actually measure what the game logic costs.

### 5.2 The 10 ms poll timeout (patch 0001) — trade-off

After the patch the loop blocks in `poll()` instead of spinning. Because the server cannot signal the listening thread from the event thread (there is no wake-up socket in this design), a packet queued while the thread is *already* blocked waits for the next poll return — at most the timeout. 10 ms while clients are connected is a good compromise:

* idle server: 100 wake-ups/s × ~n cheap checks ≈ 0 % CPU (vs 100 % before);
* busy server: the socket that just received data returns immediately, so responses go out in the same pass — *no* added latency;
* worst case (packet queued right after the poll started, nothing to read): ≤10 ms (Windows timer granularity can make that ~15 ms realistically).

If you want *zero* added latency later, replace the timeout with a proper wake-up: add a loopback UDP socket pair to `m_fds` and `send()` one byte to it from `Send()` whenever a packet is queued; `poll()` then returns instantly. That is a bigger change and needs a `CExtendedSocket → CTCPServer` back-pointer.

### 5.3 Logging

* After patch 0003 the log file is opened once and written through a 64 KB buffer. Errors still hit disk immediately.
* Consider *also* reducing what you log: `serverinstance.cpp` logs an Info line for **every UDP hole-punch/heartbeat packet** and every connect/disconnect. On a 100-player server that is a lot of lines even with buffered I/O.
* If you need "no log at all" performance for a tournament, point `Logs/` at a RAM disk — but keep in mind the file logger is also your crash diagnostics.

### 5.4 `MaxPlayers` and process capacity (architecture note)

All game logic is serialised (RC6), so the practical ceiling of one `CSNZ_Server.exe` is roughly *one busy core of packet work*. Recommended:

* For a real deployment, set `MaxPlayers` to something the single event thread can serve comfortably (start around 32–64 and measure `Logger()` timing / CPU), or
* run several server instances (different ports) and split channels between them, instead of one process with `MaxPlayers: 100`.

Also relevant: `MaxPlayers` is enforced in `CUserManager::AddUser` by `m_Users.size() >= g_pServerConfig->maxPlayers`, so the config value is a hard cap — lowering it does not break anything.

### 5.5 SQLite (patch 0005 / SQL script)

* **WAL** removes the per-write journal create/delete cycle. WAL persists in the DB header, so even if you later run the *unpatched* server it keeps using WAL (that's why the standalone SQL script works too).
  *Consequences:* the DB directory gains `UserDatabase.db3-wal` / `-shm`; when backing up, copy all three files (or use `VACUUM INTO 'backup.db3'`). WAL needs the DB on a local disk, not on a network share.
* **`synchronous=OFF`** is already set by the server and is *not* changed by the patches. It is the fastest setting, but a power loss or crash can corrupt the DB. If the data matters more than the last bit of speed, change that one line to `PRAGMA synchronous=NORMAL` (with WAL, `NORMAL` is already much safer than `FULL` and still fast).
* **First start after the patch may take longer** (index build). On a big production DB, run the SQL script manually during a maintenance window instead of letting the server do it — it's the same `CREATE INDEX IF NOT EXISTS` statements plus `VACUUM`/`ANALYZE`.
* Keep the daily backup behaviour in mind (`OnDayTick`); it copies the whole file.

### 5.6 If you want more after the patches (source-level roadmap)

1. **Queue/thread architecture**: replace the single `g_Events` + global critical section with per-channel queues and one worker per channel (or at least move all DB writes to a dedicated writer thread with a job queue). This is the only way to scale past one core.
2. **`CEvents`**: no `new`/`delete` per event (pool or `std::unique_ptr` + ring buffer); `AddEvent` currently holds a mutex + does `SetEvent` for every packet, fine at 100 pps, not at 10 kpps.
3. **Send path**: keep a byte offset per queued packet so a partially sent packet can be resumed instead of dropped/duplicated (see the bug note in §5.8); then `Send()` can be attempted immediately from the calling thread.
4. **DB writes**: batch the "user state" writes that currently happen per action (inventory, loadout, buy menu, quests) into a per-second flush inside one transaction.
5. `GetUserByUsername` (`usermanager.cpp:1153`) and `CChannel::GetRoomById`/`GetUserById` are still linear — add maps if your chat/room traffic is heavy.

### 5.7 Hardening: cap the send queue (memory)

In `CExtendedSocket::Send(CSendPacket* msg, bool ignoreQueue)`:

```cpp
if (!ignoreQueue)
{
    // limit: a client that stops reading must not be able to exhaust server RAM
    if (m_SendPackets.size() >= 4096)          // ≈ a few MB worst case
    {
        Logger().Warn("CExtendedSocket::Send(%s): send queue overflow, disconnecting\n", GetIP().c_str());
        // ask the owner to disconnect this client (or set a flag checked in Listen())
        return 0;
    }

    m_SendPackets.push_back(msg);
}
```

and fix the leak in the `ignoreQueue == true` branch (the packet is dropped without `delete` when `send()` returns `WSAEWOULDBLOCK`).

### 5.8 Bugs found while analysing (not performance, but you'll hit them)

1. **Partial sends corrupt the stream.** `CExtendedSocket::Send(vector<unsigned char>&)` resets `m_nPacketSentSize = 0` on entry and loops until everything is sent; if `send()` returns `WSAEWOULDBLOCK` in the middle, the caller (`Listen()`) sees a positive `sendResult` and **erases the packet from the queue** — the client receives a truncated packet and the next packet continues the same byte stream. On a fast local network this is rare; under load it is not. Fix: track the offset inside the queued packet and retry the remainder (§5.6-3).
2. **Packet leak on `WSAEWOULDBLOCK`** in the `ignoreQueue == true` path (memory growth under backpressure).
3. **`Logs` directory uses the process working directory** — start the server with the working directory set to its folder, otherwise logs/database/`Data/` land next to whatever started it.
4. **Console QuickEdit** can freeze the whole process with a stray click (see host tuning).
5. `Logger()`'s console output goes through `vprintf` from many threads; console rendering (especially a *visible, scrolling* window) can dominate. Running the server with the console minimised — or as a service — is measurably faster.

---

## 6. Server configuration (`ServerConfig.json`) — what to change and why

These are *compatibility/bandwidth* knobs, not magic: they don't fix RC1-RC6, but they reduce work per login and per packet.

| Key | Current | Suggestion | Why |
|---|---|---|---|
| `MaxPlayers` | 100 | 32–64 per process (or keep 100 only if you patch/measure) | all packet processing is single-threaded (§5.4) |
| `Metadata.*` | almost all `true` | turn off the ones your client doesn't need | every `true` flag sends an extra metadata blob to **every** client on login (`SendMetadata()` → ~41 metadata packets with the shipped config), each copied several times and queued |
| `InventorySlotMax` | 4000 | only as large as your players need | more slots = more rows in `UserInventory`, bigger per-user payloads, slower queries |
| `TCPSendBufferSize` | 131072 | keep (or lower to 32768 if you have many clients with slow links) | each socket pins this much kernel memory |
| `SSL` / `Crypt` | false | keep false unless you expose the server to the internet without a VPN | wolfSSL per-socket RC4/TLS costs CPU per packet; `Crypt` also enables the RC4 stream on every packet |
| `CheckClientBuild` | false | keep false | avoids rejecting clients on version mismatch only; no perf impact |
| `BanListMaxSize` | 300 | keep | ban lookups are per-connection |
| `MiniGames.*` | Bingo/WeaponRelease inactive | keep inactive if you don't run them | event packets + per-user minigame rows |
| `Voxel.*` | `52.28.231.59:3000` | make sure that host is reachable, or disable voxel metadata | the client will stall/time out on an unreachable voxel HTTP host |

---

## 7. How to build & apply the patches

```bash
# 1. get the exact source revision the EXEs were built from
git clone https://github.com/JusicP/CSNZ_Server
cd CSNZ_Server
git checkout 6e5275cb4bf4178b391a1db09dd604c8eaa1420b

# 2. optional but recommended: submodules (wolfSSL, SQLiteCpp, ...)
git submodule init && git submodule update --depth 1

# 3. apply the fixes
git apply /path/to/docs/performance/patches/0001-server-network-loop.patch
git apply /path/to/docs/performance/patches/0002-server-event-queue.patch
git apply /path/to/docs/performance/patches/0003-server-logger.patch
git apply /path/to/docs/performance/patches/0004-server-user-lookup.patch
git apply /path/to/docs/performance/patches/0005-server-sqlite-perf.patch
git apply /path/to/docs/performance/patches/0006-server-packet-copies.patch

# 4. build (Windows: open src/ in VS2019+ with CMake, or:)
cd src && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release
```

Then copy the new executable into your server folder (keep a copy of the old one!) and start it exactly as before — no config changes are required by the patches.

> **Note:** the patches were produced by editing the upstream sources and verifying the result by inspection; they could not be compiled here (this environment has no Windows/MSVC toolchain). Apply them to a copy of the source, expect the compiler to be your last check, and test on a staging server before replacing a live one.

### Verification (do this before/after, it takes 5 minutes)

1. Start the server, connect one client, do nothing.
   `Get-Process CSNZ_Server | Select CPU, WorkingSet64` → watch `CPU` for 60 s.
   *Before:* CPU keeps growing at ~1 core (≈ 100 % of one CPU per Task Manager).
   *After:* it stops growing when idle.
2. Log in with 4-6 clients and compare the same numbers again (the spin scaled with the number of clients because of the O(n) lookups).
3. Process Explorer → `CSNZ_Server.exe` → Threads → sort by CPU: the listen thread should no longer be the top consumer while idle.
4. Copy the `Logs` folder size before/after a 10-minute session (patch 0003 makes the writes cheap; volume stays the same).
5. With the SQL script applied, time a query that used to be slow:
   `sqlite3 UserDatabase.db3 "EXPLAIN QUERY PLAN SELECT * FROM UserInventory WHERE userID = 1;"` → should say `USING INDEX IX_UserInventory_userID` instead of `SCAN UserInventory`.

---

## 8. Do NOT do these

* **Don't set the poll timeout to 0 / don't "fix" the spin with `Sleep(0)` or `SwitchToThread()`** — that keeps the CPU burn and just moves it.
* **Don't remove the `POLLRDNORM` handling for the listening socket** — that is what makes accept work; only the unconditional `POLLWRNORM` is wrong.
* **Don't disable `synchronous=OFF`→`FULL`** hoping for speed; `FULL` is the slowest and the code already chose `OFF`. If you change anything, go to `NORMAL` (safer than `OFF`, WAL makes it fast).
* **Don't put `UserDatabase.db3` or `Logs/` on a network share or a HDD** — both are I/O-sensitive by design (per-statement writes, per-line logs).
* **Don't run two `CSNZ_Server.exe` instances against the same database** — SQLite locking will serialise them and, with `synchronous=OFF`, that is a corruption risk.
* **Don't run the game client (`CSOLauncher.exe`) and the server on the same machine** while measuring; the server needs a core for itself.
* **Don't judge the launcher by its RAM number** — that is the game engine (§3).

---

## 9. Files in this folder

```
docs/performance/
├── PERFORMANCE_ANALYSIS.md   ← this document
├── README.md                 ← how to apply everything, quick start
├── patches/
│   ├── 0001-server-network-loop.patch
│   ├── 0002-server-event-queue.patch
│   ├── 0003-server-logger.patch
│   ├── 0004-server-user-lookup.patch
│   ├── 0005-server-sqlite-perf.patch
│   └── 0006-server-packet-copies.patch
├── sql/
│   └── optimize_database.sql ← indexes + WAL (works without rebuilding)
└── tools/
    └── tune-windows.ps1      ← Defender exclusions, power plan, NIC tuning
```
