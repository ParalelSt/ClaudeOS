# ClaudeOS — halt an LK bootloop by catching a preloader window
#
# When the tablet is bootlooping (patched LK rejected, cycling
# BROM -> preloader -> fail -> reset every ~5s), run this to grab
# the next preloader window and flash the LK partition. The flash
# process leaves the tablet in DA mode (PID_2001), which halts the
# cycle without booting anything.
#
# Default target is v2 (idempotent if already on partition); swap
# via -File to flash a new patch.
#
# Prereqs: mtkclient at C:\Users\arond\AppData\Local\Temp\adbtools\mtkclient,
# UsbDk installed, mtkclient\Library\DA\legacy\dalegacy_lib.py:654 patched
# (reconnect disabled).

param(
    [string]$File = "C:\Users\arond\AlcatelBackup\claudeos-repo\binaries\lk_patched_v2.bin"
)

$mtkclient = "C:\Users\arond\AppData\Local\Temp\adbtools\mtkclient"

if (-not (Test-Path $File)) {
    Write-Host "ERROR: $File not found" -ForegroundColor Red
    exit 1
}

function Get-TabletState {
    $devs = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match 'VID_0E8D' }
    if (-not $devs) { return "absent" }
    foreach ($d in $devs) {
        if ($d.InstanceId -match 'PID_0003') { return "brom" }
        if ($d.InstanceId -match 'PID_2000') { return "preloader" }
        if ($d.InstanceId -match 'PID_2001') { return "da" }
        if ($d.InstanceId -match 'PID_201C') { return "fastboot" }
        if ($d.InstanceId -match 'PID_0167') { return "android" }
    }
    return "unknown"
}

$state = Get-TabletState
Write-Host "Initial state: $state" -ForegroundColor Yellow

switch ($state) {
    "da"       { Write-Host "Already in DA mode — bootloop not active or already halted." -ForegroundColor Green ; exit 0 }
    "absent"   { Write-Host "No tablet. Plug in USB (any state); bootloop should start producing preloader windows." -ForegroundColor Red ; exit 1 }
    "android"  { Write-Host "Tablet is in Android. Nothing to halt." -ForegroundColor Green ; exit 0 }
    "fastboot" { Write-Host "Tablet is in fastboot. Not bootlooping." -ForegroundColor Green ; exit 0 }
}

Write-Host "`nLaunching mtkclient to catch next preloader window..." -ForegroundColor Cyan
Write-Host "It will exploit via kamakiri, upload DA, write $File to the lk partition," -ForegroundColor Cyan
Write-Host "and leave the tablet in DA mode (PID_2001) — bootloop halted.`n" -ForegroundColor Cyan

Set-Location $mtkclient
python mtk.py w lk $File

if ($LASTEXITCODE -eq 0) {
    $final = Get-TabletState
    Write-Host "`nFlash OK. Final state: $final" -ForegroundColor Green
    if ($final -eq "da") {
        Write-Host "Bootloop halted. Tablet is in DA mode — safe for further work." -ForegroundColor Green
    }
} else {
    Write-Host "`nFlash failed (exit $LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}
