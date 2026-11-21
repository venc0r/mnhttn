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

**Fixed: 24 `invalid_outline`.** Reported against `SW_L_4_40` only because KiCad attaches outline errors
to the first footprint in the file. The real cause were 24 board-level `gr_circle` on Edge.Cuts with
radius 1 nm and stroke 0.635 mm: the mouse bites of the bridge between the halves (y 70.5-78.1 mm,
x 131.3 and 167.1), drawn as dots. Replaced by footprint `MouseBites_10x0.5mm_P0.76mm` (10 NPTH
0.5 mm holes, pitch 0.76 mm, board-only, excluded from BOM and position file), placed as MB1 / MB2
on the old dot columns. The stored GND zone fill still avoids the old dots and sits 0.015 mm from the
new holes, so DRC reports 11 `hole_clearance` until the zones are refilled. A refill with
`kicad-cli pcb drc --refill-zones --save-board` clears them, but KiCad 10 regenerates the hatched fill
with a different pattern phase on both copper layers (2.4 M px raster diff) and re-serialises the
whole board in the new file format (~140k changed lines). Do that as its own commit, with a fresh
`make check-baseline` right before it, and expect the copper rasters to differ everywhere.

Raster notes: `pcb export svg` draws drill holes on every layer (`--drill-shape-opt` default), so new
holes show up as diff clusters on paste and silk rasters too. Judge raster diffs by cluster position.

Zones were refilled and the board saved with KiCad 10 on 2026-11-21 (own commit). Since then the
file is in KiCad 10 format and `make check` copper rasters compare against the new hatch.

**Fixed: `SW_L_4_29` shorting / mask bridge.** `/COL_0_R` and `/COL_1_R` ran as a 0.5 mm pair across
the switch's net-less housing pads and through its alignment bore at (218.32, 28.94). Rerouted:
`COL_0_R` now passes below-left of the right housing pad (diagonal x+y = 243.5, horizontal y = 30.6),
`COL_1_R` above-right of the bore (diagonal x+y = 248.5, horizontal y = 31.1). Track edits need a
zone refill afterwards (stored fill reports `clearance` to the moved tracks until then); with the
board already in KiCad 10 format the refill only touched the fill around the moved segments.

**Resolved: 199 `copper_edge_clearance`.** "Board edge clearance violation" without a number means
copper overlaps an Edge.Cuts item (board rule is 0 mm). 177 were the switch footprint's through-hole
pads straddling the pocket notch (pad r 0.70 mm, notch r 0.49 mm, drill r 0.508 mm: the pin sits at
the pocket edge, so this cannot be avoided without a D-shaped pad). 12 were the XIAO pads 15-20 on
its module cutout, same pattern. Both are accepted by design through `mnhttn.kicad_dru`
(`edge_clearance (min -1mm)` for pads of those two footprints). The remaining 22 were track end caps
or 45-degree approaches grazing the notch corner by 0.02-0.04 mm; those 13 tracks were moved so they
enter the pads through solid material. Any track move needs a zone refill afterwards.

**Still open:**
- 75 `isolated_copper` warnings: small hatch islands of the GND zones. Zone setting "remove islands"
  would clear them, not touched.
- 3 `track_dangling`, 2 `silk_edge_clearance`, 1 `text_thickness`: not looked at.
- 4 schematic parity issues and 4 unconnected net pairs between the halves are pre-existing.
