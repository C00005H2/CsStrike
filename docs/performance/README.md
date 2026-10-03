# Performance pack for `CSNZ_Server.exe` / `CSOLauncher.exe`

Start with **[PERFORMANCE_ANALYSIS.md](PERFORMANCE_ANALYSIS.md)** — it explains what is wrong, why the binaries behave the way they do, and how each fix was derived.

## Quick start (pick what you can do)

| You can… | Do this | Biggest win |
|---|---|---|
| rebuild the server from source | apply all patches in `patches/`, rebuild | CPU (the 100 %-core spin), logging I/O, DB, copies |
| **not** rebuild — patch the shipped EXE | use `binpatch/CSNZ_Server.patched.exe` (or `tools/patch_csnz_server_exe.py`) — see **[PATCH_NOTES.md](PATCH_NOTES.md)** | CPU (the 100 %-core spin) + logging I/O |
| only touch the server folder | run `sql/optimize_database.sql` while the server is stopped | database (indexes + WAL) |
| only touch Windows | run `tools/tune-windows.ps1` as Administrator | AV/disk stalls, power plan |
| only edit config | §6 of the analysis (`ServerConfig.json`) | login bandwidth/CPU per client |

> The binary patch and the SQL script are complementary and are the combination for a
> no-rebuild setup: patched EXE for the CPU spin + log I/O, `optimize_database.sql` for the
> database. The source patches remain the complete fix (see PATCH_NOTES.md §3 for the
> precise coverage matrix).

## 1. Server-side patches (rebuild path)

The executables in this repo are builds of **`github.com/JusicP/CSNZ_Server`**, commit `6e5275cb` (2026-09-30). The patches are unified diffs against that exact revision.

```bash
git clone https://github.com/JusicP/CSNZ_Server
cd CSNZ_Server
git checkout 6e5275cb4bf4178b391a1db09dd604c8eaa1420b
git submodule init && git submodule update --depth 1

git apply /path/to/patches/0001-server-network-loop.patch
git apply /path/to/patches/0002-server-event-queue.patch
git apply /path/to/patches/0003-server-logger.patch
git apply /path/to/patches/0004-server-user-lookup.patch
git apply /path/to/patches/0005-server-sqlite-perf.patch
git apply /path/to/patches/0006-server-packet-copies.patch

cd src
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

On Windows you can also just open the `src/` folder in Visual Studio 2019+ (CMake project) and press *Build All*; Qt 6.5.3 is optional (GUI only).

| Patch | Files | Fixes |
|---|---|---|
| 0001 | `net/tcpserver.{cpp,h}` | the `WSAPoll` busy-spin (100 % CPU), O(n)/O(n²) socket lookups & scan restarts, one-packet-per-poll send |
| 0002 | `event.h` | event queue `vector` → `deque` (O(1) dequeue) |
| 0003 | `common/logger.{cpp,h}` | `fopen`/`fclose` per log line → buffered, kept-open file |
| 0004 | `manager/usermanager.{cpp,h}` | users-by-id / by-socket hash maps |
| 0005 | `manager/userdatabase_sqlite.cpp` | WAL, 64 MB cache, mmap, MEMORY temp store, missing indexes |
| 0006 | `common/buffer.{cpp,h}`, `net/extendedsocket.cpp` | remove two full packet-buffer copies per received packet |

They are independent — you can apply only 0001 (the CPU fix) if you want the smallest change.

> The patches were written and reviewed against the upstream sources but **not compiled** in this environment (no Windows toolchain available). Build on a copy first, then test on a staging server.

## 1b. Server EXE patching (no rebuild)

The shipped `CSNZ_Server.exe` can be patched directly — the network spin, the accepted-socket
event mask and the open/close-per-log-line logging are all fixable in machine code.

```bash
python3 tools/patch_csnz_server_exe.py CSNZ_Server.exe --out CSNZ_Server_patched.exe
```

or just use the ready-made `binpatch/CSNZ_Server.patched.exe` (same size as the original,
341 bytes differ, original untouched). Full details — what is patched, what cannot be
patched in machine code, verification status and the staging checklist — are in
**[PATCH_NOTES.md](PATCH_NOTES.md)**. Not covered by the binary patch: the O(1) socket map,
the event-queue container change, the user hash maps and the packet-copy removal — those
still need the rebuild.

## 2. Database (no rebuild needed)

Stop the server, **back up `UserDatabase.db3`**, then:

```bat
sqlite3.exe UserDatabase.db3 ".read sql/optimize_database.sql"
```

or paste `sql/optimize_database.sql` into DB Browser for SQLite → *Execute SQL*.

This switches the DB to WAL (persistent — the server keeps using it) and creates the 36 missing indexes that every per-user query and the per-minute expiry scan depend on. Details and caveats: §5.5 of the analysis.

## 3. Windows host tuning

```powershell
# elevated PowerShell
powershell -ExecutionPolicy Bypass -File tools/tune-windows.ps1 `
    -ServerPath "C:\CSNZ\Server" -ClientPath "C:\CSNZ\Client"
```

Adds Defender exclusions, sets the High Performance power plan / disables core parking, and disables NIC power saving. Also read the "manual items" it prints at the end — especially the console **QuickEdit** one, which is a classic "server froze" cause.

## 4. Launcher (`CSOLauncher.exe`)

`CSOLauncher.exe` is the **game process** — it loads `filesystem_nar.dll` + `hw.dll` and runs the Source engine inside itself. Its RAM/CPU in Task Manager is the game, not launcher code. Launcher-side guidance (shortcut flags, start-up scanning, what not to leave enabled) is in §3 and §6 of the analysis.

## 5. Verify

§7 of the analysis has a 5-minute before/after check list (`Get-Process … | Select CPU`, Process Explorer per-thread CPU, `EXPLAIN QUERY PLAN` for the new indexes).
