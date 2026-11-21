# Agent notes

## Repo

Fork of `fooker/mnhttn` (diverged 2024-06-30 at `99ba960`). Layout changed to 5x4+3+1.
Workflow: commit directly on `main`, no PRs. Both keyboard halves live in one `.kicad_pcb`,
so DRC always reports unconnected nets between left and right half (GND zones, U1/U2 VCC). Expected.

## KiCad on this Mac

- KiCad 10.0.8 from Homebrew cask, managed through the nixos-config repo. `kicad-cli` is on PATH.
- nixpkgs `kicad` is `broken` on darwin, so `shell.nix` (KiCad + Linux Zephyr SDK) only works on Linux.
- No GUI control from the agent. Work on `.kicad_pcb` / `.kicad_mod` files directly, verify with `kicad-cli`.
- `kicad-cli` cannot update footprints in the board from the library. Patch the embedded footprints in
  `mnhttn.kicad_pcb` by script and let the `lib_footprint_mismatch` DRC check prove board == library.
  Embedded footprints carry different uuids than the library file, match by geometry not uuid.
- Every `kicad-cli` run rewrites `board/mnhttn.kicad_prl` (format migration). Revert it before committing.
- `board/Makefile` uses grouped targets (`&:`), which need GNU make >= 4.3. The installed make is 3.81,
  so `make out.zip` warns and rebuilds; `check` targets work.

## Verifying a board change

`board/check.sh` produces artefacts and compares two sets. Use it around every change:

```sh
cd board
make check-baseline   # once, from the state before the change
# edit footprint / board
make check            # regenerates check/current and diffs against check/baseline
git checkout mnhttn.kicad_prl
```

Artefacts per set: DRC (`--severity-all --all-track-errors --schematic-parity`, JSON), gerbers for all
fabrication layers, drill files, position file, and a 600 dpi raster per layer. Compare prints PASS/FAIL
per artefact. Acceptance: everything PASS except the deltas the change is supposed to make.

DRC gotchas baked into the script:
- Violations that involve net-less copper graphics (`<no net>` footprint lines) are reported
  non-deterministically by KiCad. They are counted only, not compared as a set.
- Unconnected items are keyed by net, because KiCad picks varying track segments to report.
- Gerber header timestamps are stripped before diffing.

## DRC history

Baseline 2026-11-21 before any fix: ~1300 violations, almost all from `Cherry_MX_ULP_Human.kicad_mod`.
Upstream has the same defects, no fork fixes them. Alternative library `pashutk/Cherry_MX_ULP` is clean
but has no PCB cutout, so it is not a drop-in.

**Fixed: copper lines in the switch footprint.** 6 `fp_line` on `F.Cu` and 6 on `B.Cu` bridged the pad
pairs 1-1 and 2-2 (upstream commit `fd64a9f`). Graphic lines carry no net, so every switch produced
clearance, shorting_items, solder_mask_bridge, hole_clearance errors and an unconnected 1-1 / 2-2 pair.
They are now oval SMD pads numbered 1 / 2 on `F.Cu` or `B.Cu` only (no mask, no paste). A line with
round caps equals an oval of size (width, length + width), so the copper is unchanged: raster diff 0 px,
only the gerber encoding moved from draws to flashes. Lessons from doing it:
- Derive the pad geometry from the library and apply it to every board instance. Two instances carry
  1 um rounding noise in their line coordinates, which flipped the oval orientation or changed the
  length by 1 nm. KiCad's parity check compares pad sizes exactly and reported
  "Pad 2 size differs on layer F.Cu" for the rotated thumb switches.
- Custom pads (anchor + gr_line primitives) also work for parity, but KiCad plots them as polygon
  macros with 16-segment arcs, so the copper deviates up to 2 um. Ovals are exact.
- To see what the parity check complains about, open the board in KiCad and use
  Inspect -> Compare Footprint With Library (Summary tab). `kicad-cli` only reports the count.

**Still open:**
- 24 `invalid_outline` from one Edge.Cuts arc on `SW_L_4_40` with a 1 nm radius.
- `SW_L_4_29`: three `/COL_0_R` tracks cross its net-less mounting pad (3 shorting_items,
  3 solder_mask_bridge). Real layout defect, was hidden in the noise before.
- 4 schematic parity issues and 4 unconnected net pairs between the halves are pre-existing.
