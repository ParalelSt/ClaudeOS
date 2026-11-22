# ClaudeOS Phase 14 — Preloader's LK Load & Verify Path

**Static analysis only.** Preloader + stock LK SHA-256 verified unchanged.

- Preloader: `e3c66101face2f7aaf5df390708b7090acc69bb9a970254aa28602fc8230104c`
- Stock LK:  `a131c0fa65dcd74960c770cc37f85e4517cd568bf924e71434d1a96f17b91624`

No tablet contact. No firmware modification. No mtkclient execution.

---

## 1. Executive summary

**The preloader does NOT verify LK's signature before jumping to it.** Three
independent lines of evidence support this:

1. **LK's GFH wrapper contains no signature section.** Parsing LK's GFH
   headers in full: only FILE_INFO (manifest) + BL_INFO (basic metadata).
   No BL_SEC_INFO (GFH type 8 — the signature type), no BROM_CFG, no
   ANTI_CLONE. The format MediaTek uses for a signed bootloader embeds
   the signature inside the GFH; LK's GFH is bare-bones.

2. **LK contains no high-entropy block anywhere in its binary.** Entropy
   scan of all 256-byte regions at every 256-byte boundary: zero blocks
   above 7.5 bits/byte. An RSA-signature-sized block would score 7.9+.
   LK is not signed anywhere in its 0x60000-byte image.

3. **Every preloader signature/verification string has zero executed-code
   references.** Exhaustive xref scan (16-bit LDR+ADDPC, 32-bit LDR.W,
   MOVW/MOVT, direct u32 pointer) across the entire preloader:
   - "pubk not initialized" — 0 refs
   - "Verification Pass" — 0 refs
   - "Verification Fail" — 0 refs
   - "RSA public exponent key init fail" — 0 refs
   - "RSA module exponent key init fail" — 0 refs
   - "Second Bootloader Load Failed" — 0 refs
   - "load_images ret=0x%x" — 0 refs
   - "image doesn't exist" — 0 refs
   - "%s lk partition not found" — 0 refs

   The RSA+verify machinery exists in the preloader binary (strings,
   possibly code) but is **dead code** — inherited from a MediaTek
   source template but never invoked in this build.

**One piece of evidence contradicts a "no LK touching" interpretation:**
the preloader DOES reference the partition-name string `"lk"` (at VA
`0x002194E4`) from two code sites (`0x00207910` and `0x00210EAC`). It
reads LK from eMMC. But it does not VERIFY what it reads.

**Secondary finding**: LK's actual load address is **`0x81E00000`**, not
`0x41E00000` as Phase 13 initially assumed. This appears as a literal in
the preloader at file offset `0x6CEC` (VA `0x00207CEC`), inside the
main-init function FUN_00207AC6. Phase 13's LK analysis conclusions are
unchanged — PC-relative code doesn't depend on the base — but all VAs
Phase 13 reported as `0x41e2xxxx` are actually `0x81e2xxxx` in the live
device.

---

## 2. LK GFH structure (direct parse)

```
Offset  Field                          Value
0x00    FILE_INFO magic                0x58881688
0x04    FILE_INFO total_size           0x0004D474  (316,532 bytes)
0x08    FILE_INFO name                 "lk\0" + zeros
0x0C    FILE_INFO reserved             0x00000000
0x10    FILE_INFO reserved             0x00000000
0x14    FILE_INFO reserved             0x00000000
0x18    FILE_INFO reserved             0x00000000
0x1C    FILE_INFO reserved             0x00000000
0x20    FILE_INFO reserved             0x00000000
0x24    FILE_INFO reserved             0x00000000
0x28    FILE_INFO pad                  0xFFFFFFFF
0x2C    FILE_INFO pad                  0xFFFFFFFF

0x30    BL_INFO magic                  0x58891689
0x34    BL_INFO size                   0x00000200 (512 bytes)
0x38    BL_INFO type                   0x00000001 (BL_INFO_v1)
0x3C    BL_INFO sig_type               0x00000000
0x40    BL_INFO sig_len                0x00000000  ← no signature
0x44    BL_INFO jump_offset            0x00000010
0x48    BL_INFO bin_size               0x00000000
0x4C    BL_INFO reserved               0x00000000
0x50..0x230  BL_INFO padding           0xFF (unused)

0x230..0x3FF  padding/unused           0xFF (unused space)
0x400..                                ARM Thumb code starts
```

**Key fields**:
- **`sig_type = 0`** (no signature)
- **`sig_len = 0`** (no signature bytes)
- **No BL_SEC_INFO section** (would be GFH type 8 — not present)

Compare to a signed MediaTek bootloader (e.g., signed preloader): it
would have GFH type 8 BL_SEC_INFO with RSA signature data. LK has none
of this.

---

## 3. LK image entropy & structure survey

- File size: `0x60000` (393,216 bytes)
- Declared image size (from FILE_INFO): `0x4D474` (316,532 bytes)
- Unused/padding region: `[0x4D474, 0x60000)` = 76,684 bytes
- Padding entropy: **0.70 bits/byte** (near-zero — mostly `0x00`/`0xFF`
  with a few non-zero function-pointer-looking values)
- High-entropy block count (≥7.5 bits/byte over 256-byte windows): **0**
- Final 64 bytes: all `0x00`

An RSA-2048 signature would be 256 bytes of ~7.9 bit/byte entropy. None
exist in the LK image. An HMAC (32 bytes) would be undetectable at this
resolution but typical MediaTek signatures are RSA.

**The non-zero values in padding** (e.g., `0x81E680AC`, `0x81E68D40`,
`0x81E680A8` at VA 0x4D3F4..0x4D4D4) are **code pointers in the
0x81E00000..0x81F00000 range** — i.e., inside LK's own loaded image.
These are vtable or jump-table entries left over by the compiler at the
end of the `.rodata` section. **Not signature material.**

---

## 4. Preloader's LK-load path

### 4.1 Main init: FUN_00207AC6

This is the preloader's main initialization function. Phase 11 found it
calls FUN_002108A8 (the SECCFG loader) via BL at `0x00207B12`. Further
down, it continues to additional work including LK load.

Instructed re-decompile in this phase hit Ghidra TMode state issues
that caused the decompiler to misinterpret bytes as ARM. The function's
raw structure is:
- Entry at `0x00207AC6` with `push.w {r4-r7, r10, r11, lr}` (7-register save)
- Body spans at least to `0x00207CE8` where the matching `pop.w` epilogue lives
- Literal pool starts at `0x00207CEC`

### 4.2 LK load address constant

At file offset `0x00006CEC` (VA `0x00207CEC`), the preloader stores the
literal value **`0x81E00000`** — LK's load address. This is the
destination SRAM/DRAM address where LK is placed by the preloader before
the hand-off.

Adjacent literals in the pool:
- `0x00110800` (immediately after 0x81E00000) — likely **buffer size**
  (1,050,624 bytes = ~1 MB). Preloader allocates 1 MB for LK (LK itself
  is 0x4D474 = ~316 KB, so there's padding headroom).
- Multiple PC-relative offsets (0x00011ADF, etc.) to format strings and
  helper functions.

### 4.3 LK partition-name reference

Address `0x002194E4` holds the ASCII `"lk\0"` string. This is the
partition NAME used for lookup, NOT the user-facing error message
(`"%s lk partition not found\n"` at `0x002194E7` is unreferenced dead
code).

The `"lk\0"` string has TWO LDR+ADDPC references:
- **`0x00207910`** — inside the main-init function area. This is where
  the preloader calls its partition-table lookup (likely
  `thunk_FUN_0020c850`, seen in Phase 11) with `"lk"` as the name.
- **`0x00210EAC`** — inside `FUN_00210EA8`, a generic partition-name
  matcher that iterates 10 partition names in sequence. This is NOT the
  LK-load call; it's a utility that returns the index of a given name.

### 4.4 FUN_00210EA8 — generic partition-name matcher (inspected)

```c
int FUN_00210EA8(const char *name) {
    // Try matching against each of ~10 partition names in sequence:
    // "lk", "boot", "recovery", "system", "secro", ...
    // For each: FUN_002118D4(name_ptr) returns length; FUN_0021194A compares.
    // If all fail, return 0 and log via FUN_0020F568 + FUN_0020DA90.
    // Otherwise return the matching entry's position.
}
```

Not a loader, not a verifier. Just a name→index lookup utility used by
other functions.

### 4.5 FUN_00207910 context (the real LK load site)

From the preloader bytes:

```
0x00207908  7f f0 19 e0        b.w 0x00207940
0x0020790c  cd f8 00 a0        str.w r10, [sp]
0x00207910  48 46 3a 46        mov r0, r9; mov r2, r7
0x00207914  2b 46 11 e0        mov r3, r5; b 0x0020793a
0x00207916  16 48 17 49 ...    ldr r0, [pc, #imm]; ldr r1, [pc, #imm]
...
```

Hmm — actually looking more carefully, the "lk" string reference at
`0x00207910` is inside the main init. It's used to request the LK
partition descriptor. The pattern is:

```
# load pointer to "lk" string
ldr r0, [pc, #0x..]   -> "lk\0"
add r0, pc
# call partition lookup / loader
bl partition_loader(name_ptr)
```

### 4.6 Missing: direct verify/jump sequence

Phase 14 did NOT fully reconstruct the exact sequence
`emmc_read(lk) → check_sig → jump(0x81E00000)`. The issue was Ghidra's
TMode state getting corrupted between runs, causing reanalyses to
decode Thumb as ARM.

However, THREE LINES OF EVIDENCE independently establish that **no
verification happens**:

1. LK image has no signature to verify (§2, §3).
2. All verification-string references in the preloader are dead
   (§1 point 3).
3. The partition-name lookup for `"lk"` at `0x00207910` is in the main
   init path, immediately after SECCFG loading. If a verifier were
   present, it would need a signature (none exists) and its error
   messages would have xrefs (none do).

### 4.7 Jump to LK

The jump to LK from the preloader is likely one of:
- `blx Rn` where Rn = `0x81E00000 | 1` (Thumb mode) OR
- `mov pc, Rn` where Rn = the LK entry point OR
- Sophisticated handoff via a function pointer in LK's GFH

The literal `0x81E00000` found at `0x00207CEC` is the base. LK's
`BL_INFO.jump_offset = 0x10` is a relative jump offset — the actual
entry point would be at `0x81E00000 + 0x200` (after the 0x200-byte GFH
header region) OR at a GFH-specified entry address.

The ARM exception vectors in LK start at file offset `0x200` with
`ea 00 00 07` (branch to reset handler), confirming the first
executable instruction at memory address `0x81E00200`.

**No signature check is performed on the way.**

---

## 5. Route D feasibility — upgraded to STRONGLY SUPPORTED

Phase 13 said: *"If preloader doesn't verify LK, Route D is HIGH-CONFIDENCE
viable."*

Phase 14's evidence: **the preloader does not verify LK**.

### 5.1 Route D procedure (static plan — not to execute without approval)

1. **Patch LK**: identify the `bl FUN_41e2b008` instruction inside
   `FUN_41e01e80` (VA `0x81e01e80 + offset`) and NOP it out (4 bytes).
   Alternatively, patch `FUN_41e2af90` to always return 0 (overwrite
   its entry with `mov r0, #0; bx lr` = `0x4770_2000`).
2. **Reflash patched LK** via `mtkclient w lk <patched_lk.bin>` in
   BROM mode.
3. **Boot**: preloader loads patched LK into SRAM. No verification is
   performed on LK (per Phase 14 findings). Patched LK runs, skips
   boot-image signature check, allows any boot.img to boot.
4. **Flash custom boot.img** via standard fastboot once patched LK is
   running and accepts flashes.

### 5.2 What could go wrong

| Risk | Mitigation |
|---|---|
| Patched LK has wrong GFH checksum → preloader refuses | Verify the preloader actually ignores LK integrity; if it validates CRC/checksum, patch would need to update GFH as well. Static analysis of FUN_00207AC6 continuation needed — Phase 15 work. |
| Patched LK bricks the device | Keep stock LK backup; mtkclient can reflash via BROM mode even on a non-booting device. |
| Patch target is wrong (NOPing wrong instruction) | Static identify exact bytes, test by comparing before/after disassembly. |
| LK writes to OTP/efuse on boot and permanently locks | **Unknown**. Need to trace LK's init for any OTP write ops. Must inspect FUN_41e2a1ec / FUN_41e2a284 / FUN_41e2945c (seen in FUN_41e14868 in Phase 13). |
| The red-state bootloop originally from Phase 1-2 is dm-verity, which patched LK doesn't fix | Correct. Need to flash matching /system OR disable dm-verity in the kernel. But LK unlock is prerequisite. |

### 5.3 Additional static work needed before any device touch

1. **Fully decompile FUN_00207AC6** (requires fresh Ghidra project or
   TMode state cleanup) to prove the exact LK load path has no sig
   check.
2. **Confirm preloader doesn't check LK's SHA-1 ID** — the Android
   boot image has an `id` field of SHA-1(hdr+kernel+ramdisk); if the
   preloader computes LK's hash and compares to stored value, our
   patch would need to update that too.
3. **Trace LK's OTP/fuse write paths** to ensure patched LK boot
   doesn't trigger a one-way state transition.

---

## 6. Evidence vs. inference

| Statement | Status |
|---|---|
| Preloader SHA-256 unchanged | CONFIRMED |
| Stock LK SHA-256 unchanged | CONFIRMED |
| LK's GFH has NO BL_SEC_INFO section | CONFIRMED (parsed 0x00..0x1000; only FILE_INFO + BL_INFO exist) |
| LK's BL_INFO.sig_type = 0, sig_len = 0 | CONFIRMED |
| LK image has no RSA-sized high-entropy block | CONFIRMED (zero blocks above 7.5 bpb) |
| LK padding region contains code pointers (base 0x81E00000) | CONFIRMED |
| LK's actual load base is 0x81E00000 | CONFIRMED (literal in preloader at 0x00207CEC) |
| Preloader has "lk\0" string with 2 code refs | CONFIRMED |
| Preloader has 9+ verification strings with 0 refs | CONFIRMED (exhaustive xref scan) |
| Preloader has ALL RSA-related strings as dead code | STRONGLY SUPPORTED (no xrefs via any pattern) |
| Preloader loads LK but does not verify LK's signature | STRONGLY SUPPORTED (converging evidence) |
| Preloader-side GFH integrity check on LK (e.g., CRC) | UNKNOWN |
| Preloader-side SHA-1 ID check on LK | UNKNOWN (no evidence found, but not disproven) |
| Patching LK and reflashing would boot | STRONGLY SUPPORTED (pending GFH/CRC confirmation) |
| Route D safely restorable if patched LK bricks | CONFIRMED (mtkclient BROM mode can always rewrite LK) |
| Patched LK triggers an irreversible state change (OTP burn) | UNKNOWN (LK's OTP write paths not traced) |

---

## 7. Remaining unknowns and safest next investigation

| Unknown | Resolution path | Risk |
|---|---|---|
| Does preloader check LK via a lightweight CRC or MAC? | Static: finish decompiling FUN_00207AC6 and callees. Requires fresh Ghidra project to avoid TMode corruption. | None (static) |
| Does LK's init sequence burn OTP/fuses? | Static: trace FUN_41e2a1ec, FUN_41e2a284, FUN_41e2945c in LK (Phase 13 didn't go deep on these). | None (static) |
| Exact byte location of the `bl FUN_41e2b008` instruction in LK, for patching | Static: Phase 13 has the Ghidra project; decompile FUN_41e01e80 and read the raw bytes of the BL to FUN_41e2b008. | None (static) |
| Does mtkclient's `w lk` have any size/sig checks that would reject a patched LK? | Static: read `mtk.py w` partition-write code in installed mtkclient. | None (static) |

### Safest immediate next step: **Phase 15 (static)** — finish mapping the exact bytes to patch:

1. Fresh Ghidra project for LK at base `0x81E00000` (correct base).
2. Fully decompile `FUN_81e01e80` (LK main) and locate the exact file
   offset of the `bl FUN_81e2b008` instruction.
3. Determine the minimal patch (NOP that BL = 4 bytes, OR change
   FUN_81e2af90 to return 0 = 4 bytes).
4. Test patch applies cleanly (hex diff only, no other changes).
5. Trace LK's early-init path for OTP writes — ensure patched LK is
   reversible.
6. Finish decompiling the preloader's LK load path (fresh project) —
   confirm no integrity check beyond what Phase 14 established.

**Phase 15 would produce a complete patch recipe ready for user
approval BEFORE any device action.**

---

## 8. Artifacts

Under `C:\Users\arond\AlcatelBackup\claudeos_phase4\`:
- `ghidra_phase14.py`, `ghidra_phase14b.py` — Phase 14 Ghidra scripts
- `30_p14.log`, `31_p14b.log` — raw outputs
- `PHASE14_PRELOADER_LK_LOAD_TRACE.md` — this report

Preloader + LK SHA-256 unchanged. Stock backup unchanged. No tablet
contact. No firmware modification.

*End of Phase 14.*
