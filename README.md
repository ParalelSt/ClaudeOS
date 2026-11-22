# ClaudeOS — Alcatel 8082 Custom OS Project

Turn an Alcatel 8082 tablet (TCL U3A_10_WIFI, MediaTek MT6580, Android 8.1)
into a dedicated thin-client remote screen for Claude Code.

## Device Info

| Field | Value |
|-------|-------|
| Model | Alcatel 8082 (8082_EEA) |
| Codename | U3A_10_WIFI |
| SoC | MediaTek MT6580 (ARM32, armeabi-v7a) |
| Android | 8.1 Oreo |
| BROM USB ID | VID 0x0E8D / PID 0x0003 |
| Preloader USB ID | VID 0x0E8D / PID 0x2000 |

## Current State: PHASE 15 COMPLETE — Ready to Flash

### What's done

- **Phases 1–9**: Device analysis, partition dumps, preloader reverse-engineering
- **Phases 10–13**: LK (Little Kernel) verification chain fully reversed in Ghidra
- **Phase 14**: Traced preloader → LK load path, confirmed LK loaded at `0x81E00000`
- **Phase 15**: Created 4-byte patch to bypass Secure Boot Check in LK
  - File offset `0x2AF90`: `16 4b 10 b5` → `00 20 70 47`
  - Makes `FUN_81e2af90` (SBC gate) return 0, skipping boot image verification
- **UsbDk non-admin path**: Confirmed working on Windows 11 build 26200
  - mtkclient patched to re-enable UsbDk (`libusb_set_option(ctx, 1)`)
  - Enables BROM access from a normal (non-admin) PowerShell

### What's NOT done

- [ ] **Flash patched LK** — blocked by BROM hung state, needs USB power cycle
- [ ] **Test boot** — verify bootloop is resolved after LK patch
- [ ] **Phase 16 (if needed)** — dm-verity / verifiedbootstate bypass if bootloop persists
- [ ] **Build ClaudeOS UI** — the actual thin-client interface

## Repository Contents

```
binaries/
  lk_patched.bin          # Ready-to-flash LK with SBC bypass (393,216 bytes)

stock_backup/
  lk_stock.bin            # Original LK for reference/rollback
  preloader_stock.bin     # Original preloader dump

patches/
  lk_sbc_bypass.patch     # Documents the binary patch applied to LK
  mtkclient_usbdk_enable.patch  # mtkclient fix for non-admin USB access

scripts/
  flash_claudeos.ps1      # Flash helper (verifies hash, runs mtkclient)

analysis/
  PHASE13_LK_VERIFICATION_REVERSE.md   # LK verification chain analysis
  PHASE14_PRELOADER_LK_LOAD_TRACE.md   # Preloader → LK load path
  PHASE15_PATCH_READY.md               # Patch derivation and verification
  SESSION2_USB_STATUS.md               # USB connection findings
```

## SHA-256 Hashes

```
Patched LK:  B9F611C8E445612C76404FF1478C4A21F2D7B134013A1A92B835D5A30728F986
Stock LK:    A131C0FA65DCD74960C770CC37F85E4517CD568BF924E71434D1A96F17B91624
Preloader:   E3C66101FACE2F7AAF5DF390708B7090ACC69BB9A970254AA28602FC8230104C
```

## How to Flash (Next Session)

### Prerequisites

- Python 3.x with pyusb, pyserial, libusb1
- mtkclient 2.1.4 installed at `C:\Users\arond\AppData\Local\Temp\adbtools\mtkclient`
- UsbDk filter driver installed
- Apply `patches/mtkclient_usbdk_enable.patch` to mtkclient's `usblib.py`

### Flash Steps

1. **Power-cycle the tablet** (the BROM is currently hung):
   - Unplug USB cable
   - Hold power button 10 seconds (force off)
   - Wait 3 seconds
   - Hold **Volume-Up + Power**, then plug in USB (forces BROM mode on MT6580)

2. **Flash the patched LK** (normal PowerShell, no admin needed):
   ```powershell
   cd C:\Users\arond\AppData\Local\Temp\adbtools\mtkclient
   python mtk.py w lk C:\Users\arond\AlcatelBackup\claudeos-repo\binaries\lk_patched.bin
   ```

3. **If non-admin fails**, use Admin PowerShell (right-click Start → Terminal (Admin)):
   ```powershell
   cd C:\Users\arond\AppData\Local\Temp\adbtools\mtkclient
   python mtk.py w lk C:\Users\arond\AlcatelBackup\claudeos-repo\binaries\lk_patched.bin
   ```

4. **After flash**, reboot tablet. If it boots:
   - SBC bypass is working
   - Proceed to Phase 16 if dm-verity blocks boot

### Alternative: PC restart to clear hung BROM

If the BROM is still hung from a previous session and you can't physically
power-cycle the tablet, restart the PC:

```powershell
shutdown /r /t 30
```

This power-cycles all USB ports. After reboot, immediately run the flash
command while the tablet is still in BROM mode.

## Technical Details

### The Patch

The LK binary contains a Secure Boot Check function at virtual address
`0x81E2AF90` (file offset `0x2AF90`). This function is called during boot
to verify the boot image signature.

**Original code (Thumb-2):**
```asm
81e2af90: 16 4b    LDR R3, [PC, #0x58]   ; Load verification key/params
81e2af92: 10 b5    PUSH {R4, LR}         ; Set up stack frame
; ... full verification logic follows ...
```

**Patched code:**
```asm
81e2af90: 00 20    MOVS R0, #0           ; Return value = 0 (success)
81e2af92: 70 47    BX LR                 ; Return immediately
```

This makes the function return success without checking anything, allowing
unsigned boot images to load.

### UsbDk Non-Admin Discovery

mtkclient ships with UsbDk support disabled on Windows due to enumeration
issues. We discovered that:

1. UsbDk `libusb_set_option(ctx, 1)` returns 0 (success) from non-admin
2. Device enumeration, configuration, and interface claiming all work
3. Only requirement: UsbDk filter driver must be installed (one-time admin)
4. After that, `python mtk.py w lk <file>` works from normal PowerShell

### BROM Protocol (MT6580)

- USB VID `0x0E8D` PID `0x0003` = BROM mode
- CDC bulk endpoints: EP_IN=`0x81`, EP_OUT=`0x01`, maxpacket=64
- Serial handshake: send `0xA0 0x0A 0x50 0x05`, expect `0x5F 0xF5 0xAF 0xFA`
- If BROM is hung (no response to handshake), USB power cycle required

## Constraints

- **No pivoting** — we will NOT restore the original. Stock backups are for reference only.
- **Option C** — genuine custom/replacement OS, not a launcher or kiosk mode.
- **We HAVE to succeed** — this is the committed path.
