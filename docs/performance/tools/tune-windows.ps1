<#
================================================================================
 tune-windows.ps1  --  host-side tuning for CSNZ_Server.exe / CSOLauncher.exe
================================================================================
 Run in an ELEVATED PowerShell (Run as Administrator).

 Every step is optional and can be commented out. The script is idempotent and
 only *reports* what it changes. Nothing here touches your game/server files.

 Usage:
   powershell -ExecutionPolicy Bypass -File .\tune-windows.ps1 `
       -ServerPath "C:\CSNZ\Server" -ClientPath "C:\CSNZ\Client"

   # only show what would happen:
   powershell -ExecutionPolicy Bypass -File .\tune-windows.ps1 -WhatIf
================================================================================
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ServerPath = "",
    [string]$ClientPath = "",
    [string]$ServerExe  = "CSNZ_Server.exe",
    [string]$ClientExe  = "CSOLauncher.exe",
    [switch]$SkipDefender,
    [switch]$SkipPowerPlan,
    [switch]$SkipNetwork
)

function Write-Step($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok  ($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------------------------
# 1. Antivirus exclusions
#    Real-time scanning intercepts every file open. The server opens its log
#    file and the SQLite database constantly, so this is one of the biggest
#    "free" wins on Windows.
# ----------------------------------------------------------------------------
if (-not $SkipDefender) {
    Write-Step "Adding Windows Defender exclusions"
    $paths = @()
    if ($ServerPath) { $paths += $ServerPath }
    if ($ClientPath) { $paths += $ClientPath }
    foreach ($p in $paths) {
        if (Test-Path $p) {
            if ($PSCmdlet.ShouldProcess($p, "Add-MpPreference -ExclusionPath")) {
                Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue
                Write-Ok "excluded folder: $p"
            }
        } else { Write-Warn "path not found, skipped: $p" }
    }
    foreach ($exe in @($ServerExe, $ClientExe)) {
        if ($PSCmdlet.ShouldProcess($exe, "Add-MpPreference -ExclusionProcess")) {
            Add-MpPreference -ExclusionProcess $exe -ErrorAction SilentlyContinue
            Write-Ok "excluded process: $exe"
        }
    }
    Write-Warn "If you use a third-party AV, add the same folder/process exclusions there."
}

# ----------------------------------------------------------------------------
# 2. Power plan / CPU behaviour
#    "Balanced" parks cores and downclocks them; a single-thread-bound game
#    server feels that directly.
# ----------------------------------------------------------------------------
if (-not $SkipPowerPlan) {
    Write-Step "Setting the High Performance power plan"
    $high = (powercfg /list | Select-String "High performance|Ultimate Performance")
    if ($high) {
        $guid = ($high -split '\s+')[3]
        if ($PSCmdlet.ShouldProcess($guid, "powercfg /setactive")) {
            powercfg /setactive $guid
            Write-Ok "active power plan set to: $guid"
        }
    } else {
        powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-Null
        Write-Warn "High performance plan was hidden; re-run the script."
    }

    Write-Step "Disabling core parking for the active plan"
    $sub = "54533251-82be-4824-96c1-47b60b740d00"
    foreach ($kv in @(
            @{k = "0cc5b647-c1df-4637-891a-dec35c318583"; v = 0},   # Processor performance core parking min cores
            @{k = "893dee8e-2bef-41e0-89c6-b55d0929964c"; v = 100} # Processor minimum state
        )) {
        if ($PSCmdlet.ShouldProcess($kv.k, "powercfg -setacvalueindex")) {
            powercfg -setacvalueindex SCHEME_CURRENT $sub $($kv.k) $($kv.v) 2>$null | Out-Null
        }
    }
    powercfg -setactive SCHEME_CURRENT
    Write-Ok "done (no-op on systems without these settings)"
}

# ----------------------------------------------------------------------------
# 3. Network stack (server side)
# ----------------------------------------------------------------------------
if (-not $SkipNetwork) {
    Write-Step "Tuning TCP settings for a game server"

    # Prefer throughput/latency over power saving for the NIC
    if ($PSCmdlet.ShouldProcess("NIC power saving", "Disable-NetAdapterPowerManagement")) {
        try {
            Get-NetAdapter -Physical | Where-Object Status -eq "Up" |
                Disable-NetAdapterPowerManagement -ErrorAction Stop
            Write-Ok "disabled NIC power management (prevents micro-stalls)"
        } catch { Write-Warn "could not change NIC power management: $($_.Exception.Message)" }
    }

    # Keep the socket send buffer the server asks for (TCP window auto-tuning stays on)
    if ($PSCmdlet.ShouldProcess("TCP autotuning", "netsh int tcp set global")) {
        netsh int tcp set global autotuninglevel=normal | Out-Null
        netsh int tcp set global rss=enabled        | Out-Null
        Write-Ok "TCP autotuning = normal, RSS = enabled"
        Write-Warn "Do NOT disable Nagle on the whole machine: the client sets its own socket options."
    }
}

# ----------------------------------------------------------------------------
# 4. Manual / advisory items (not automated on purpose)
# ----------------------------------------------------------------------------
Write-Step "Manual items still worth doing"
@"
    * Put UserDatabase.db3 (and the Logs folder) on an SSD/NVMe, not on a HDD
      or a network share.
    * Do not run the server and the game client on the same machine; the server
      is bound by a single event thread and a spinning poll loop, so they fight
      for the same cores.
    * Console window: right-click the title bar -> Properties -> OPTIONS ->
      uncheck "QuickEdit Mode". A stray click inside a console with QuickEdit
      enabled blocks the process until you press a key - which looks exactly
      like a server freeze.
    * If you start the server through a script/bat file, keep the console
      window visible but minimized: every Logger().Info() line also goes to the
      console (slow when a window is repainted).
    * Set the server process priority to "Above normal" only after you applied
      the CPU patches - on the unpatched binary it just steals CPU from
      everything else.
"@ | Write-Host

Write-Host "`nFinished." -ForegroundColor Cyan
