# ClaudeOS Phase 16 — LK Patch v2 (minimal NOP)

## Why v1 bootlooped

v1 replaced the first 4 bytes of `FUN_81e2af90` with `mov r0,#0; bx lr`.

Logically this returns success (r0=0), matching the caller's `cbz r0, 0x2082`
success path. But in practice the tablet bootlooped (preloader → BROM → repeat
every ~15s).

Hypothesis: the function has side effects beyond returning a status —
possibly:
- Reads `cfg_ptr->[0xE4]` which triggers lazy initialization of the config
  struct somewhere downstream.
- The call to `sbc_check` at 0x2AFBC initializes crypto state used later
  in the boot path.
- The surrounding prints update a boot-stage counter.

By returning immediately we skip all of that. Something downstream then
fails silently and the hardware watchdog resets the SoC within ~15s.

## v2 strategy — let the function run, only patch the failure branch

Function layout (stock):

```
0x2AF90: 16 4b         ldr    r3, [pc, #0x58]       ; load cfg ptr
0x2AF92: 10 b5         push   {r4, lr}
0x2AF94: 7b 44         add    r3, pc
0x2AF96: 1b 68         ldr    r3, [r3]
0x2AF98: d3 f8 e4 20   ldr.w  r2, [r3, #0xE4]       ; r2 = cfg->sbc_mode
0x2AF9C: 11 2a         cmp    r2, #0x11
0x2AF9E: 08 bf         it     eq
0x2AFA0: 01 24         moveq  r4, #1
0x2AFA2: 09 d0         beq    0x2AFB8               ; mode 0x11 → fail
0x2AFA4: 22 2a         cmp    r2, #0x22
0x2AFA6: 09 d0         beq    0x2AFBC               ; mode 0x22 → sbc_check
0x2AFA8: 42 b1         cbz    r2, 0x2AFBC           ; mode 0    → sbc_check
0x2AFAA..0x2AFB4:                                   ; invalid mode print
0x2AFB8: 20 46         mov    r0, r4
0x2AFBA: 10 bd         pop    {r4, pc}              ; return

0x2AFBC: 04 f0 ca fb   bl     sbc_check
0x2AFC0: 01 28         cmp    r0, #1
0x2AFC2: 04 46         mov    r4, r0
0x2AFC4: 09 d0         beq    0x2AFDA               ; FAIL branch  <-- PATCH
0x2AFC6..0x2AFD4:      success-print, r4 = 0
0x2AFD8: 10 bd         pop    {r4, pc}              ; return 0

0x2AFDA..0x2AFE6:      fail-print
0x2AFE8: e6 e7         b      0x2AFB8               ; return r4 (=1)
```

Patch: replace the `beq 0x2AFDA` at 0x2AFC4 with NOP.

- Stock bytes: `09 D0` (beq +18)
- Patch bytes: `00 BF` (nop.n T1 encoding)

After the patch:
- All config reads + sbc_check call still happen (side effects preserved).
- On sbc_check FAIL (r0=1), we no longer branch to the fail-print; we fall
  through to the success path, which sets `r4 = 0` and returns 0.
- On sbc_check PASS (r0=0), behavior is unchanged.

Only 2 bytes modified. Function prologue, config access, and sbc_check
invocation are intact.

## File

- Input:  `stock_backup/lk_stock.bin`
  SHA-256: `a131c0fa65dcd74960c770cc37f85e4517cd568bf924e71434d1a96f17b91624`
- Output: `binaries/lk_patched_v2.bin`
  SHA-256: `030a70bc782ee458135a06ea1cd128d0fe44c73c46a719ba7bd34ba4a6afd978`
- Size: 393216 bytes (unchanged)
- Diff: 2 bytes at file offset 0x2AFC4

## To flash

Tablet in fresh BROM/preloader, run from `C:\Users\arond\AppData\Local\Temp\adbtools\mtkclient`:

```
python mtk.py w lk C:\Users\arond\AlcatelBackup\claudeos-repo\binaries\lk_patched_v2.bin
```

Or use the repo's `scripts\flash_lk.ps1 -File "binaries/lk_patched_v2.bin"`.

## If v2 also bootloops

Fall back to stock LK (recovery proven in Phase 15.5). Possible deeper
causes to investigate next:
- Preloader-side LK hash verification (would require preloader patch).
- Watchdog/timer the function kicks as a side effect.
- A second verification site reached only when cfg mode is not 0x22/0x11/0.
