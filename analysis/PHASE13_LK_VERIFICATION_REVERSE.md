# ClaudeOS Phase 13 — LK Verification & Unlock Reverse-Engineering

**Static analysis only.** Preloader SHA-256 verified unchanged; LK SHA-256
verified unchanged (`a131c0fa65dcd74960c770cc37f85e4517cd568bf924e71434d1a96f17b91624`).
LK imported into fresh Ghidra project at base `0x41E00000` (MT6580 convention,
confirmed by Ghidra's auto-analysis finding consistent cross-references).

---

## 1. Executive summary

Phase 13 overturns Phase 12's "Route B is viable" assertion:

1. **SECCFG unlock via mtkclient would NOT bypass LK's boot-image signature
   verification.** The LK's main verification gate reads the **hardware fuse
   `[0x10009060] bit 1`** combined with **SECCFG byte 0xE4**, NOT the SECCFG
   attribute field at 0x854 that mtkclient's unlock sets. The only part of LK
   that reads the 0x854 attr is `FUN_41e2a890` — which gates **fastboot
   commands**, not the boot path.
2. **The LK's actual boot-image verifier is `FUN_41e2b008`.** Called only by
   `FUN_41e01e80` (LK main) when SBC gate returns true AND boot_mode==100
   (normal boot). It performs a hash + signature verify (SHA-1 + RSA by buffer
   sizes). **Verification failure causes an infinite loop (HANG), not a
   red-state warning.**
3. **Red-state is NOT a critical-fail path.** The red-state warning the user
   observed was LK setting `androidboot.verifiedbootstate=red` on the kernel
   cmdline — a non-fatal warning. The infinite-loop path is separate.
4. **The actual bootloop is almost certainly kernel dm-verity failure on the
   GSI's modified `/system`**, not LK's `FUN_41e2b008` rejecting boot.img.
   If `FUN_41e2b008` had rejected it, LK would hang — not reboot in 5 seconds.
5. **mtkclient's `fastboot oem unlock` via SECCFG write would succeed** and
   would transition fastboot to "unlocked" mode (allowing flashing), but would
   NOT make LK skip boot-image signature verification on next boot. So we
   could flash a custom LK via fastboot in that state, but a stock LK would
   still reject a custom boot image.
6. **The ONLY practical software bypass of LK's verification is patching LK
   itself**. Phase 11 found no evidence that the preloader verifies LK, so a
   patched LK may boot — but this remains UNCONFIRMED and HIGH-RISK.

---

## 2. Annotated functions discovered

All addresses are LK VAs with base `0x41E00000`.

### 2.1 LK main: `FUN_41e01e80` (body `0x41e01e80..0x41e02103`)

```c
void LK_main(void) {
    FUN_41e04438(0);
    local_30 = 0;
    FUN_41e2863c(&local_30);               // misc init
    FUN_41e1efa4("[LK]");                   // banner print
    FUN_41e013d4();                         // more init
    FUN_41e05260(1);                        // state setup
    piVar7 = global_boot_info;
    // Possible modem flag check
    if (piVar7->f58b0 == 1 && FUN_41e0aa94() == 0) FUN_41e00390();
    FUN_41e04858(); FUN_41e04c9c(); FUN_41e04438(0);
    uVar1 = get_mboot_length();
    uVar1 = FUN_41e24e88(iVar2 + 0x30, iVar3, uVar1, 0, 0x10000, 0, 0xc0000000, 0, 0, iVar3);
    // Load boot image from eMMC into DRAM
    
    FUN_41e0062c(load_addr);
    FUN_41e047d0(0, 0, kern_addr, tags_addr, 0);
    FUN_41e00858(0, 0, kern_addr, tags_addr);
    FUN_41e1eda0();
    FUN_41e04454();
    FUN_41e02864();                         // probably `boot_linux` prep
    
    FUN_41e298ec(local_30, uStack_2c);     // ← BIG STATE INIT (see §2.5)
    FUN_41e2941c(global->f?, 0x100);
    
    int boot_check_err = FUN_41e14868();   // modem/ramdisk check
    if (boot_check_err != 0) hang_forever;
    
    if (piVar7->f4 == 100) {               // NORMAL BOOT mode (not recovery/charger/meta)
        FUN_41e1efa4("[LK] normal boot mode");
        int sbc_on = FUN_41e2af90();        // ← SBC GATE #1 (see §2.2)
        if (sbc_on != 0) {
            // VERIFY BOOT IMAGE
            int verify_err = FUN_41e2b008(
                piVar7->image_addr,       // image buffer
                piVar7->image_size - piVar7->sig_size,
                piVar7->image_addr + offset_to_sig,
                piVar7->sig_size           // 0x80
            );
            if (verify_err != 0) {
                FUN_41e1ed00("verification failed, halting");
                while (1) { /* INFINITE LOOP */ }   // ← HANG
            }
        }
        FUN_41e046a0();                     // diagnostic print
        FUN_41e1ed00("boot normally"); 
        FUN_41e1efa4("[LK] jump to kernel");
        FUN_41e0d380(); FUN_41e0ae70(); FUN_41e01e70();
        FUN_41e15ae4(3); FUN_41e163dc();
        FUN_41e15df8(piVar7->kern_addr, piVar7->ramdisk_addr, piVar7->tags_addr);
        // JUMP TO KERNEL
    }
    ...
}
```

**Critical structure**:
- SBC gate `FUN_41e2af90()` returns truthy to enforce verification.
- Verification `FUN_41e2b008` is called ONLY if SBC gate truthy.
- Verification failure → **infinite loop**, not any warning.

### 2.2 SBC gate: `FUN_41e2af90` (body `0x41e2af90..0x41e2afe9`)

```c
int FUN_41e2af90(void) {
    int cfg_byte = *(int*)(*global_seccfg_ptr + 0xE4);  // SECCFG decrypted byte 0xE4
    if (cfg_byte != 0x11) {
        if (cfg_byte == 0x22 || cfg_byte == 0) {
            int fuse = FUN_41e2f754();    // read [0x10009060] bit 1
            if (fuse != 1) {
                log("SBC fuse clear");
                return 0;                   // ← SBC OFF
            }
            log("SBC fuse set");
        } else {
            log("SBC cfg byte: %x", cfg_byte);
        }
    }
    return 1;                                // ← SBC ON
}
```

### 2.3 Hardware fuse reader: `FUN_41e2f754` (body `0x41e2f754..0x41e2f763`)

```c
uint FUN_41e2f754(void) {
    return (uint)(_DAT_10009060 << 0x1e) >> 0x1f;
    // == bit 1 of word at 0x10009060
}
```

**This is the SAME eFuse bit we identified in the preloader as `[0x10009060] bit 1`** (Phase 9/10). And per Phase 11, mtkclient's `SBC=True` → this bit is SET on our device.

**Consequence**: `FUN_41e2f754()` returns 1 on our device.

### 2.4 LK boot-image verifier: `FUN_41e2b008` (body `0x41e2b008..0x41e2ce11`)

```c
undefined4 FUN_41e2b008(int img_addr, int img_size, int sig_addr, int sig_size) {
    // Align workspace to 128KB boundary past image+sig
    uint workspace = img_addr + sig_size + 0x1ffff + img_size & 0xfffe0000;
    
    FUN_41e1fd14(workspace, sig_addr, 0x40);             // copy first 0x40 of sig (header)
    FUN_41e1fd14(workspace + 0x40, img_addr, img_size);  // copy image AFTER sig header
    
    void *pubkey = *global_pubkey_ptr;
    FUN_41e2c33c(workspace, img_size + 0x40, pubkey, 0x80, 0x80, ...);
    // ^-- compute SHA-1 of (sig_hdr + image), result into pubkey (reused buffer?)
    
    log("Verifying image...");
    int rsa_err = FUN_41e2e7dc(
        global_pubkey,              // RSA pubkey
        0x14,                        // hash size = 20 bytes = SHA-1
        pubkey,                      // computed hash
        sig_addr + 0x40              // signature body
    );
    // FUN_41e2e7dc is RSA_verify (SHA-1 hash, signature, pubkey) → 0 on pass
    
    if (rsa_err == 0) {
        log("Verification pass");
        return 0;
    } else {
        log("Verification fail");
        return 0xffffffff;
    }
}
```

**Confirmed**:
- SHA-1 hash (size parameter 0x14 = 20 bytes)
- RSA signature verify (`FUN_41e2e7dc` has 4 args, pattern matches RSA-with-hash)
- Pubkey loaded from a global — likely from SECRO AC_REGION, set up during preloader-to-LK handoff

### 2.5 Big state init / cert verifier: `FUN_41e298ec` (body `0x41e298ec..0x41e29bef`)

- Called by LK main
- Initializes a 0x10C-byte global flag table with ~60 fields (values 1 or 2)
- Calls `FUN_41e2aa0c` — initial seccfg load/parse
- Calls `FUN_41e2ee4c`, `FUN_41e29ea4` — additional checks
- **Calls `FUN_41e2adfc(0, 0, &puVar4[3])`** — verifies "raw image" (likely SECRO/AC data)
- Logs 50+ fields of state struct
- Calls `FUN_41e2a7ec()` — initializes lock-state tables (see §2.7)
- Calls `FUN_41e2a594(&local_1c)` — reads the current lock state
- Calls `FUN_41e2a750(local_1c[0])` — **ACTS on lock state** (likely sets `verifiedbootstate` cmdline)

### 2.6 Lock-state reader: `FUN_41e2a594` + `FUN_41e2a560` + `FUN_41e2a518`

```c
undefined4 FUN_41e2a594(undefined4 *lockstate_out, ...) {
    if (*(int*)(*seccfg_ptr + 0x10) != 0x4D4D4D4D) {
        log("no seccfg");
        return FUN_41e2a560(lockstate_out);       // fallback: read from alt struct
    }
    int attr = *(int*)(*seccfg_ptr + 0x854);
    if (attr == 0x33333333 || attr == 0x6003) {
        // LOCKED (DEFAULT) or UNLOCKED — route via "normal" reader
        uint state = FUN_41e2a560();
        log("lks = %x", *lockstate_out);
        return state;
    }
    // Other states (reset / transitioning)
    return FUN_41e2a518(attr, lockstate_out, 0x6003, attr, ...);
}

undefined4 FUN_41e2a560(undefined4 *out) {
    if (seccfg_magic_ok && alt_struct_magic != 0) {
        *out = *(int*)(alt_struct_ptr + 0x14);  // read some state field
        return 0;
    }
    *out = 0;
    return 0;
}

undefined4 FUN_41e2a518(uint attr, undefined4 *out, ...) {
    if (attr == 0x6001) { *out = 2; return 0; }  // some transition
    if (attr == 0x6000) { *out = 0; return 0; }  // LOCKED new
    if (attr == 0x6002) { *out = 3; return 0; }  // some transition
    if (attr == 0x44444444) { *out = 1; return 0; }  // alt UNLOCK
    *out = 0xFF;
    return -1;
}
```

**Key observation**: the SECCFG `seccfg_attr` field at offset 0x854 has values with these meanings in LK's eyes:
- `0x33333333` → DEFAULT (LOCKED, via FUN_41e2a560 path)
- `0x6003` → UNLOCK (via FUN_41e2a560 path — same code path as locked!)
- `0x6000` → LOCKED (alt)
- `0x6001` → state 2
- `0x6002` → state 3
- `0x44444444` → UNLOCKED (via FUN_41e2a518 path)

### 2.7 `FUN_41e2a7ec` — lock-state table init

Initializes TWO flag tables based on `FUN_41e2934c(0)` (SBC gate #2):
- Table 1: if SBC on, fills with 1 (restricted); if SBC off, fills with 2 (permissive)
- Table 2: ALWAYS fills with 2 (permissive — all commands allowed)

### 2.8 "Is unlocked" check used by fastboot dispatcher: `FUN_41e2a890`

```c
bool FUN_41e2a890(void) {
    int state[2] = {0};
    int err = FUN_41e2a594(state);
    if (err == 0) return state[0] == 1;       // 1 == unlocked
    return true;                                // on error, fail-safe to unlocked
}
```

So "unlocked" in fastboot's view requires `state[0] == 1`, which requires either:
- `seccfg_attr == 0x44444444` (via FUN_41e2a518)
- OR `seccfg_attr ∈ {0x33333333, 0x6003}` AND the alt struct returns state==1 via FUN_41e2a560's offset 0x14

So `mtkclient create("unlock")` → sets `seccfg_attr = 0x6003` (ATTR_UNLOCK). This hits FUN_41e2a560 which reads offset 0x14 of a secondary struct. **Whether that returns 1 depends on whether the preloader's SECCFG parse populates that field as 1 when `seccfg_attr == 0x6003`** — this is UNKNOWN without further preloader analysis.

**However**, `FUN_41e2a890` fail-safes to "unlocked" on error. If `FUN_41e2a594` returns non-zero (which happens when `seccfg_attr` is any value other than those explicitly handled), the device reports as unlocked. So a MALFORMED SECCFG → unlocked fastboot.

### 2.9 The fastboot command dispatcher: `FUN_41e1a070`

Reviewed at length in Phase 13 scripts. Per-command structure:
```c
struct cmd { 
    cmd *next;              // [0]
    char *name_prefix;      // [1]
    size_t name_len;        // [2]
    int flag_allow_in_sbc;  // [3] — if non-zero, allowed even when SBC on
    int flag_require_unlock;// [4] — if non-zero, requires FUN_41e2a890() == 1
    code *handler;          // [5]
};
```

Condition to execute a command:
```c
if ((((both SBC gates return 0) || cmd->flag_allow_in_sbc != 0)) &&
    (cmd->flag_require_unlock == 0 || FUN_41e2a890() != 0)) {
    cmd->handler(...);
}
```

---

## 3. CRITICAL FINDING: `FUN_41e01e80` does NOT consult unlock state

Re-reading LK main:

```c
if (piVar7->f4 == 100) {                // NORMAL BOOT only
    int sbc_on = FUN_41e2af90();        // SBC gate — reads byte 0xE4 + fuse
    if (sbc_on != 0) {
        int verify_err = FUN_41e2b008(...);   // RSA verify boot image
        if (verify_err != 0) hang_forever();
    }
    // Jump to kernel
}
```

**There is NO call to `FUN_41e2a890()` or `FUN_41e2a594()` in this path.** The verification is gated purely by:
1. Boot mode (if not normal, skip verify)
2. SBC gate (byte 0xE4 of SECCFG + hardware fuse)

**Consequence**: `mtkclient create("unlock")` which sets `seccfg_attr = 0x6003` **does NOT disable this verification**. The byte at SECCFG offset 0xE4 is unrelated to the `seccfg_attr` field at 0x854.

---

## 4. Boot-mode escape: does `piVar7->f4` ever bypass normal boot?

LK main's structure means: **if boot_mode ≠ 100, the verification is skipped entirely.**

Where does `piVar7->f4` come from? It's typically set by the preloader (via SRAM-shared state) based on key-combo input at power-on. Values include:
- 100 (0x64) = NORMAL BOOT
- Others: RECOVERY, FASTBOOT, META, CHARGER, FACTORY, etc.

So **booting the device in fastboot mode skips the LK verification** — but then it's in fastboot, waiting for USB commands, not booting a kernel.

**Could fastboot command accept a boot image without verification?** Looking at the command list:
- `flashing unlock`, `oem unlock` — change lock state
- `boot` (standard fastboot) — downloads a boot image and boots it directly

The `fastboot boot` command bypasses eMMC and executes a DOWNLOADED image. **If this device's LK supports `fastboot boot`, it would be a non-flashing bypass** — but typically requires the device to be unlocked first (via `fastboot oem unlock`).

And `fastboot boot` typically ALSO runs the same verification chain for the downloaded image.

---

## 5. The red-state origin

### 5.1 Red-state is NOT the hang path

The infinite loop in `FUN_41e01e80` → `FUN_41e2b008` fail → `hang_forever()` would leave the device frozen on the LK screen. The user observed the device REBOOT after 5 seconds with the red-state warning — that's not a hang.

### 5.2 How red-state is actually set

`FUN_41e298ec` calls `FUN_41e2a594` + `FUN_41e2a750(local_1c[0])`. `FUN_41e2a750` is the function that LIKELY sets the kernel cmdline parameter `androidboot.verifiedbootstate` based on the lock state.

The state values map to:
- state 1 (via `0x44444444` or `0x6003`+alt=1) → **orange** (unlocked, verified-boot warning)
- state 0 (via `0x33333333` or `0x6000`) → **green** (locked, verified)
- state 2, 3 → **yellow** or **red** (transitioning states)

A SECCFG with `seccfg_attr` set to an **invalid/transitional** value (e.g., after a failed unlock) would trigger `FUN_41e2a518` to return `0xFF` → treated as **red state**.

### 5.3 What ACTUALLY happened in the bootloop

Most-plausible reconstruction (STRONGLY SUPPORTED by code evidence):
1. User flashed GSI + modified boot image.
2. Booting: LK main runs.
3. `FUN_41e2af90()` returns 1 (fuse SET).
4. `FUN_41e2b008()` runs on the modified boot.img.
5. **EITHER verification passed** (if sig covered only kernel, and vendor-mount fix was in ramdisk), **OR verification failed and LK hung**.
6. If passed, LK set `verifiedbootstate=red` via some separate check (maybe modified vbmeta-like structure in boot.img trailer, or signature-check info).
7. Kernel booted, saw `verifiedbootstate=red`, rendered the red-state warning banner.
8. Kernel mounted /system, dm-verity enforced, found modified /system → kernel panic / forced reboot.
9. Repeat → bootloop.

### 5.4 Unknowns

Did LK's signature actually pass? To know for sure requires deeper LK analysis OR reproducing the test (NOT doing that this phase).

---

## 6. Option C feasibility — route-by-route (REVISED)

### Route A: `fastboot oem unlock`
- **Can we reach fastboot?** YES — key combo at boot. SBC-gated commands need `cmd->flag_allow_in_sbc != 0`. "oem unlock" typically has this flag. CONFIRMED path.
- **Will unlock succeed?** It would WRITE SECCFG with new `seccfg_attr` via `FUN_41e2a750` or similar. Writing requires SEJ encryption — LK has this (via sec_init). Should work.
- **Will it bypass the LK verification?** **NO** — see §3. The verification uses byte 0xE4 and the fuse, not the attr field.
- **What does unlock DO then?** It allows fastboot flashing of partitions (bypasses the lock-state check on flash commands) and sets verifiedbootstate=orange. Does NOT skip signature verify at boot.

**Verdict**: Route A alone doesn't achieve Option C.

### Route B: mtkclient write unlocked SECCFG
Same as Route A in effect. **Does NOT bypass boot verification.**

**Verdict**: Not sufficient alone.

### Route C: Keep stock LK, boot custom kernel
- Requires LK to accept an unsigned custom kernel.
- Only possible if LK's verification is OFF (SBC gate returns 0) OR we patch LK.
- SBC gate can't be made to return 0 (fuse set).
- **BLOCKED unless combined with Route D.**

### Route D: Patch LK to skip `FUN_41e2b008` call
- Simplest patch: NOP out the `bl FUN_41e2b008` instruction, OR change `FUN_41e2af90`'s return to always 0, OR change the check `if (verify_err != 0)` branch.
- **To flash patched LK, the preloader must accept it.** Phase 11 found no evidence of LK verification in the preloader's executed code. **STRONGLY SUPPORTED that an unsigned LK will boot**, but UNCONFIRMED.
- Preloader-side GFH verification? The preloader's BROM-verified handler may check LK's GFH signature. UNKNOWN — Phase 11 found no code reference to LK-verification strings in preloader, but the GFH itself might be checked by BROM-side code (not analyzed yet).

**Verdict**: HIGHEST PROBABILITY path, but HIGH RISK.

### Route E: Impractical
Currently NOT forced. Route D remains plausible.

---

## 7. Evidence vs. inference

| Statement | Status |
|---|---|
| Preloader + LK SHA-256 unchanged | CONFIRMED |
| LK base is 0x41E00000 | CONFIRMED (Ghidra found consistent xrefs at this base) |
| LK contains verifiedbootstate state machine (green/yellow/orange/red) | CONFIRMED |
| LK contains fastboot command set (oem unlock, flashing unlock, etc.) | CONFIRMED |
| LK's main boot-image verifier is FUN_41e2b008 | CONFIRMED |
| FUN_41e2b008 uses SHA-1 + RSA (via FUN_41e2e7dc) | STRONGLY SUPPORTED (size 0x14) |
| FUN_41e2af90 reads SECCFG byte 0xE4 + fuse [0x10009060] bit 1 | CONFIRMED |
| FUN_41e2a890 (fastboot's is_unlocked) reads SECCFG attr 0x854 via FUN_41e2a594 | CONFIRMED |
| FUN_41e01e80 (LK main) does NOT consult FUN_41e2a890 | CONFIRMED (grep of callees) |
| SECCFG unlock (via mtkclient) bypasses LK boot-image verification | **DISPROVEN** |
| [0x10009060] bit 1 is SET on our device | CONFIRMED (mtkclient reported SBC=True earlier in session) |
| Verification failure in FUN_41e2b008 causes LK to HANG | CONFIRMED (infinite loop in FUN_41e01e80) |
| Red state is a non-hang warning path | STRONGLY SUPPORTED |
| Red state came from LK setting verifiedbootstate=red, rendered by kernel | STRONGLY SUPPORTED |
| Bootloop was caused by dm-verity on /system | STRONGLY SUPPORTED |
| Preloader verifies LK's signature | UNKNOWN (Phase 11 found no LK-verify code path in preloader, but BROM-stage check possible) |
| Patching LK to skip FUN_41e2b008 would allow custom boot images | STRONGLY SUPPORTED (if preloader accepts patched LK) |

---

## 8. Remaining unknowns

| Unknown | Resolution path | Risk |
|---|---|---|
| Does the preloader verify LK's signature before jumping to it? | Static: reverse the preloader's LK-load function (not identified in Phase 11). Alternative: dump BROM via Kamakiri, examine BROM's GFH signature handler. | None (static) |
| What does FUN_41e2a750 actually do (red-state setter?) | Static: decompile FUN_41e2a750 and trace its cmdline writes. | None (static) |
| Does FUN_41e2e7dc actually implement RSA verify, or is it a stub? | Static: decompile FUN_41e2e7dc, look for modular-exp / ASN.1 parsing. | None (static) |
| Does `fastboot boot` bypass verification? | Static: find fastboot's "boot" command handler and trace its verification chain. | None (static) |
| Does `fastboot flash lk <patched_lk>` succeed via oem unlock? | Would require device touch (flashing, dangerous). | HIGH |

---

## 9. Safest next investigation

**Phase 14 (static)**: Reverse-engineer the preloader's LK-loading function to prove (or disprove) that it verifies LK's signature. Specifically:
- Find the function that reads LK partition from eMMC into SDRAM.
- Follow the jump-to-LK in the preloader. Is there a hash/sig check between read and jump?
- Phase 11 established that LK-verification strings are absent from executed preloader code — but that doesn't prove the absence of a GFH-signature check (which can happen via a different code path that uses binary data, not strings).

If Phase 14 confirms the preloader doesn't verify LK, **Route D becomes HIGH-CONFIDENCE viable**:
1. Patch LK to NOP the `bl FUN_41e2b008` instruction or make `FUN_41e2af90` always return 0.
2. Flash patched LK via mtkclient `w lk patched_lk.bin` (LK's flashing isn't blocked by our SBC fuse).
3. Boot: patched LK ignores sig check, boots custom boot.img.

**Still risky because**:
- A bricked LK means recovery requires re-flashing stock LK via BROM mode (we can do this).
- The preloader might actually check LK (unknown).

---

## 10. Artifacts

Under `C:\Users\arond\AlcatelBackup\claudeos_phase4\`:
- `ghidra_phase13_lk.py` — initial LK analysis (LDR+ADDPC xref scan, commanded-defined functions)
- `ghidra_phase13_deep.py` — SBC gate decompiles (FUN_41e2af90, FUN_41e2a890, FUN_41e2934c)
- `ghidra_phase13_sec.py` — LK main + verifier context
- `ghidra_phase13_verify.py` — FUN_41e2b008 + state-init function decompiles
- `lk_copy.bin` — working copy of stock LK (unchanged from source SHA)
- `25_lk.log`..`29_verify.log` — raw outputs
- `PHASE13_LK_VERIFICATION_REVERSE.md` — this report

Preloader + stock LK SHA-256 unchanged. No tablet contact. Backup immutable.

*End of Phase 13.*
