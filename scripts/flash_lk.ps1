# ClaudeOS — flash LK partition (patched or stock)
#
# Usage:
#   .\flash_lk.ps1                        # flash stock LK (recovery)
#   .\flash_lk.ps1 -Patched               # flash patched LK
#   .\flash_lk.ps1 -File "path\to.bin"    # flash arbitrary LK file
#
# Prerequisites:
#   - Tablet in BROM mode (PID_0003) OR Preloader mode (PID_2000)
#   - UsbDk driver installed
#   - mtkclient at C:\Users\arond\AppData\Local\Temp\adbtools\mtkclient
#   - mtkclient/Library/DA/legacy/dalegacy_lib.py:654 patched (reconnect disabled)
#
# Workflow proven on Alcatel 8082 (MT6580, Android 8.1), Windows 11 + UsbDk:
#   1. If tablet is bootlooping (LK crash loop), run `mtk.py crash` first
#      to drop into stable BROM mode (crashes preloader intentionally)
#   2. Verify PID_0003 is stable for 5+ seconds
#   3. Run `mtk.py w lk <file>` — takes ~90 seconds total:
#      - handshake + Kamakiri exploit (~5s)
#      - DA stage-1 upload (~2s)
#      - DA stage-2 upload (~40s, 384 KB at 1 MB/s)
#      - [skip reconnect-at-higher-speed — patched out]
#      - GPT read + partition detection (~5s)
#      - Write 384 KB LK to sector 58880 (~2s)
#      - Exit 0 — tablet left in DA mode (PID_2001, Status: Error — expected)

param(
    [switch]$Patched,
    [string]$File,
    [switch]$SkipCrash
)

$mtkclient = "C:\Users\arond\AppData\Local\Temp\adbtools\mtkclient"
$repo = "C:\Users\arond\AlcatelBackup\claudeos-repo"

if ($File) {
    $target = $File
} elseif ($Patched) {
    $target = "$repo\binaries\lk_patched.bin"
} else {
    $target = "$repo\stock_backup\lk_stock.bin"
}

if (-not (Test-Path $target)) {
    Write-Host "ERROR: $target not found" -ForegroundColor Red
    exit 1
}

$size = (Get-Item $target).Length
Write-Host "Target: $target ($size bytes)" -ForegroundColor Cyan

# Step 1: check tablet state
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

if ($state -eq "absent") {
    Write-Host "No tablet. Hold Vol-Up+Power, plug in USB, then rerun." -ForegroundColor Red
    exit 1
}

# Step 2: if bootlooping, crash preloader to drop into stable BROM
if (-not $SkipCrash) {
    # Watch for 10s — if we see multiple state changes, it's bootlooping
    $states = @()
    0..4 | ForEach-Object {
        $states += Get-TabletState
        Start-Sleep -Seconds 2
    }
    $unique = ($states | Select-Object -Unique).Count
    if ($unique -gt 1) {
        Write-Host "Bootloop detected ($($states -join ' -> ')). Crashing preloader..." -ForegroundColor Yellow
        Set-Location $mtkclient
        python mtk.py crash 2>&1 | Out-Host
        Start-Sleep -Seconds 3
        $state = Get-TabletState
        Write-Host "State after crash: $state" -ForegroundColor Yellow
    }
}

# Step 3: flash
Set-Location $mtkclient
Write-Host "`nFlashing $target to lk partition..." -ForegroundColor Cyan
python mtk.py w lk $target

if ($LASTEXITCODE -eq 0) {
    Write-Host "`nFLASH SUCCESSFUL" -ForegroundColor Green
    Write-Host "Unplug USB, hold Power 15s, then brief Power press to boot." -ForegroundColor Green
} else {
    Write-Host "`nFlash failed (exit $LASTEXITCODE)" -ForegroundColor Red
}
