# ClaudeOS Phase 15 — Patched LK Ready + Flash Plan

**Status**: static work complete. Device not reachable in BROM mode from my
running tools without user intervention (handshake fails — device needs USB
replug and/or admin-elevated mtkclient on Windows). Everything is ready for
you to run ONE command when you're back.

Hashes verified:
- Preloader unchanged: `e3c66101…0104c`
- Stock LK unchanged: `a131c0fa…91624`

---

## 1. What's ready to flash

### 1.1 Patched LK — SHA-256 `b9f611c8e445612c76404ff1478c4a21f2d7b134013a1a92b835d5a30728f986`

File: `C:\Users\arond\AlcatelBackup\claudeos_phase4\lk_patched.bin`

- Byte-identical to stock LK except for a **4-byte patch at file offset 0x2AF90**:
  - Before: `16 4b 10 b5` (`ldr r3,[pc,#0x58]; push {r4,lr}`)
  - After:  `00 20 70 47` (`mov r0,#0; bx lr`)
- The patch target is `FUN_81e2af90` (LK's SBC enforcement gate). Making it
  always return 0 causes LK's main boot path (`FUN_81e01e80`) to branch past
  the image-signature verification (`FUN_81e2b008`) via the `cbz r0` at
  `0x81e02060`. Boot proceeds with any image.
- Size: 393,216 bytes (identical to stock).
- No GFH checksum updates needed — stock LK GFH has `sig_type=0, sig_len=0`.
- No OTP burn paths found in LK early-init (safe to boot, reversible).
- Phase 14 established the preloader does not verify LK's signature, so this
  patched LK will be accepted and jumped to.

### 1.2 Rollback file — stock LK

File: `C:\Users\arond\AlcatelBackup\stock_dump_2026-11-20\lk.bin`
- SHA-256: `a131c0fa65dcd74960c770cc37f85e4517cd568bf924e71434d1a96f17b91624`
- Can be flashed back via mtkclient if patched LK bricks the device.

---

## 2. The one command to flash

Open **PowerShell as Administrator** (right-click → Run as administrator — UAC prompt).
Then:

```powershell
cd C:\Users\arond\AppData\Local\Temp\adbtools\mtkclient
python mtk.py w lk C:\Users\arond\AlcatelBackup\claudeos_phase4\lk_patched.bin
```

Expected sequence:
1. mtkclient will say "Waiting for PreLoader VCOM, please reconnect mobile/iot device to brom mode".
2. **Unplug and replug the tablet's USB cable.**
3. mtkclient should catch the BROM window, upload the DA, find the `lk`
   partition in GPT, and write the patched file.
4. Success looks like: `Wrote lk_patched.bin to sector <N> with sector count <M>.`

If the handshake keeps failing without a replug:
- Hold Volume-Up + Power while plugging USB (force BROM mode).
- Or try unplugging the battery (tablet) for 30s then replugging USB-only.

---

## 3. Rollback — if patched LK causes problems

Same command, swap the filename:

```powershell
cd C:\Users\arond\AppData\Local\Temp\adbtools\mtkclient
python mtk.py w lk C:\Users\arond\AlcatelBackup\stock_dump_2026-11-20\lk.bin
```

BROM mode is in mask ROM — flashing LK can never block BROM. So as long as
Kamakiri + USB work, rollback is always possible.

---

## 4. Will this fix the current bootloop?

**Likely NO on its own**, because the bootloop is probably from kernel
dm-verity rejecting the modified /system (the GSI), not from LK's signature
check. LK's signature check would have HUNG the device (infinite loop in
`FUN_81e01e80`), not caused a reboot cycle. The red-state warning is set
separately via `FUN_81e2a750` and is non-fatal.

Patched LK alone enables:
- Flashing any boot image without LK rejecting it.
- Setting `androidboot.verifiedbootstate=orange` (no red-state banner).
- Using fastboot commands freely.

To actually boot the GSI, you'd also need one of:

**Option 1 (safest) — Restore stock /system then flash a GSI image with
AVB-disabled vbmeta logic built in**:
- Since the device has no vbmeta partition, GSIs that rely on AVB-2.0
  can't be "disabled" via standard vbmeta patch. You need a GSI built for
  non-AVB MT6580, OR you need to patch the kernel to skip dm-verity.

**Option 2 — Patch the kernel's cmdline building code in LK** to always
set `androidboot.veritymode=disabled` or `logging`. This is a second LK
patch I can prepare in Phase 16 if you want.

**Option 3 — Patch boot image's kernel** to disable dm-verity enforcement
(find the `veritymode` cmdline reading and short-circuit). Harder.

**Option 4 — Replace /vendor's fstab** to remove `verify` flag from
/system. Requires flashing a modified /vendor.

My recommendation: **flash patched LK first and reboot**. If the device
still bootloops, we know dm-verity is the culprit, and Phase 16 produces
the second patch targeting `veritymode`.

---

## 5. Why I can't flash it from here

Flashing requires:
1. Device to be caught in BROM mode (Kamakiri window) — needs USB
   disconnect/reconnect timing.
2. mtkclient USB access — on Windows, that typically requires either
   admin shell (UAC prompt you have to accept) or a pre-installed UsbDk
   driver.
3. The timing-sensitive BROM capture.

From this session (no admin, no physical replug), mtkclient keeps
reporting "Handshake failed, retrying..." against a device that's
currently in red-state bootloop. Previous phases confirmed the retry
loop can sometimes catch the BROM window during the auto-reboot, but it
needs patience (hundreds of retries) and a USB replug to kick the
device.

**For you to run the flash**:
- Start PowerShell as Admin (accept UAC).
- Run the command in §2.
- Unplug + replug USB when prompted (or if silent for 30s).

---

## 6. What I verified statically in this phase

| Check | Status | How |
|---|---|---|
| Patch bytes correctly replace the SBC gate's entry | CONFIRMED | Exact disassembly match |
| Patched LK size matches stock (393,216 bytes) | CONFIRMED | `os.path.getsize` |
| Patched LK GFH checksum fields unchanged (sig_type=0, sig_len=0) | CONFIRMED | Byte comparison |
| `FUN_81e2af90` only reads eFuse + SECCFG byte 0xE4 (no side effects we're destroying) | CONFIRMED | Full decompile |
| Preloader doesn't verify LK signature | STRONGLY SUPPORTED | Phase 11-14 convergent evidence |
| LK has no OTP/fuse burn code reachable from boot | STRONGLY SUPPORTED | Scanned early-init for `fuse`/`otp`/`burn` strings — none found |
| mtkclient `w lk` doesn't apply checksums or sigs to writes | CONFIRMED | Source review of `da_write_partition` + `writeflash` |
| BROM mode remains accessible via Kamakiri even if patched LK hangs | CONFIRMED | BROM is in ROM, independent of LK |

---

## 7. What's outside my reach without you

| Blocker | What you do |
|---|---|
| Admin shell for mtkclient USB access | Right-click PowerShell → Run as administrator |
| Device in BROM mode | USB replug or key-combo at boot |
| Discord ping on success | I can't reach Discord. Push notifications are disabled per your /config. If you want a ping, set up a webhook and tell me the URL next time. |

---

## 8. Files you need

```
C:\Users\arond\AlcatelBackup\claudeos_phase4\lk_patched.bin         (patched LK — flash this)
C:\Users\arond\AlcatelBackup\stock_dump_2026-11-20\lk.bin           (stock LK — rollback)
C:\Users\arond\AlcatelBackup\post_gsi_evidence\preloader_u3a_10_wifi.bin  (preloader — DO NOT touch)
```

---

## 9. Phase 16 preview (ready when you give the go-ahead)

If patched LK boots but the bootloop continues due to dm-verity:
- Phase 16 will patch LK's cmdline-build code to force
  `androidboot.veritymode=disabled` and `androidboot.verifiedbootstate=orange`.
- That patch is in a different LK function (near the strings at 0x30E40 for
  verifiedbootstate and 0x3B49C for veritymode). I've already located these;
  the actual patch takes maybe 30 min of static work once we know the
  bootloop cause.

---

## 10. Hash summary

- Preloader (unchanged): `e3c66101face2f7aaf5df390708b7090acc69bb9a970254aa28602fc8230104c`
- Stock LK (unchanged): `a131c0fa65dcd74960c770cc37f85e4517cd568bf924e71434d1a96f17b91624`
- **Patched LK (Phase 15 output):** `b9f611c8e445612c76404ff1478c4a21f2d7b134013a1a92b835d5a30728f986`

The ONLY byte difference between stock and patched LK is at file offset
`0x2AF90`: 4 bytes `16 4b 10 b5` → `00 20 70 47`.

*End of Phase 15.*
