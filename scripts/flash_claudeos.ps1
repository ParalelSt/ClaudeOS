# ClaudeOS LK Flash Script
# Run this from any PowerShell (admin or not - UsbDk is now enabled)
#
# BEFORE RUNNING: Power-cycle the tablet!
#   1. Unplug USB
#   2. Hold power 10 seconds (force off)
#   3. Wait 3 seconds
#   4. Hold Vol-Up + Power, then plug USB (forces BROM mode)
#   5. Run this script

$ErrorActionPreference = "Continue"
$logFile = "C:\Users\arond\AlcatelBackup\claudeos_phase4\flash_result.log"
$mtkclient = "C:\Users\arond\AppData\Local\Temp\adbtools\mtkclient"
$patchedLK = "C:\Users\arond\AlcatelBackup\claudeos_phase4\lk_patched.bin"

Write-Host "ClaudeOS LK Flash" -ForegroundColor Cyan
Write-Host "=================" -ForegroundColor Cyan

# Verify file
$hash = (Get-FileHash $patchedLK -Algorithm SHA256).Hash
if ($hash -ne "B9F611C8E445612C76404FF1478C4A21F2D7B134013A1A92B835D5A30728F986") {
    Write-Host "ERROR: lk_patched.bin hash mismatch!" -ForegroundColor Red
    Write-Host "Expected: B9F611C8...0728F986"
    Write-Host "Got:      $hash"
    exit 1
}
Write-Host "Patched LK verified OK (SHA-256 match)" -ForegroundColor Green

Write-Host ""
Write-Host "Flashing patched LK..." -ForegroundColor Yellow
Write-Host "When prompted, unplug+replug tablet USB"
Write-Host ""

Set-Location $mtkclient
$result = python mtk.py w lk $patchedLK 2>&1
$result | Out-File $logFile -Encoding utf8
$result | ForEach-Object { Write-Host $_ }

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "SUCCESS! Patched LK flashed." -ForegroundColor Green
    Write-Host "Reboot the tablet and check if bootloop is fixed."
    Write-Host "If still bootlooping: Phase 16 patch needed (dm-verity)."
} else {
    Write-Host ""
    Write-Host "Flash may have failed. Check log: $logFile" -ForegroundColor Red
    Write-Host ""
    Write-Host "If 'Access denied': try from Admin PowerShell:"
    Write-Host "  cd $mtkclient" -ForegroundColor Yellow
    Write-Host "  python mtk.py w lk $patchedLK" -ForegroundColor Yellow
}
