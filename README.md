# CsStrike — private CSN:Z server files

Payload of this repository: the server/launcher executables, their configuration
(`ServerConfig.json`, `Shop.json`, `ItemBox.json`, `ItemRewards.json`,
`ClassMod*.csv`, `EventQuests.json`), the SQLite user database (`UserDatabase.db3`
and dated backups) and the client stub.

## Contents

| File | What it is |
|---|---|
| `CSNZ_Server.exe` | lobby/master server (TCP `30002`, UDP hole-punching, SQLite, optional TLS) |
| `CSOLauncher.exe` | client launcher — it also hosts the game: it loads `filesystem_nar.dll` + `hw.dll` and runs the Source engine in-process |
| `CSOHLDS.exe` | dedicated/headless server binary |
| `cstrike-online.exe` | client stub |
| `ServerConfig.json` | server configuration (players, ports, metadata flags, events) |
| `UserDatabase.db3` | user/character/inventory/clan/quest database (46 tables) |

## Performance work

Both executables are builds of public source (`JusicP/CSNZ_Server`,
`JusicP/Launcher_CSNZ`), so their hot spots can be fixed at source level.

**→ [docs/performance/PERFORMANCE_ANALYSIS.md](docs/performance/PERFORMANCE_ANALYSIS.md)**
— what makes them burn CPU/RAM/disk, the six ready-to-apply patches
(`docs/performance/patches/`), a database tuning script
(`docs/performance/sql/optimize_database.sql`) and a Windows host tuning script
(`docs/performance/tools/tune-windows.ps1`).
