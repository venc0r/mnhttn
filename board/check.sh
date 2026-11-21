#!/usr/bin/env bash
# Produces verification artefacts for the PCB (DRC, gerbers, drills, placement, per-layer raster)
# and compares two artefact sets. Used to prove that a change alters exactly what it should.
#   ./check.sh generate <dir>
#   ./check.sh compare <baseline-dir> <current-dir>
set -euo pipefail

PCB=mnhttn.kicad_pcb
LAYERS="F.Cu,B.Cu,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts"
RASTER_DPI=600

# KiCad reports violations involving net-less copper graphics non-deterministically
# (one hit per item, chosen by whichever thread wins), so those are split off and only counted.
# Everything else is reduced to (type, description, item descriptions) which is stable across runs.
# Unconnected items are keyed by net only, since KiCad picks varying track segments to report.
DRC_NORMALIZE='
  def canonical: {type, severity, description, items: (.items | map(.description) | sort)};
  def involves_no_net: any(.items[]; .description | contains("<no net>"));
  def canonical_by_net: {type, description, items: (.items | map(.description | capture("\\[(?<net>[^\\]]+)\\]").net) | sort)};
  {
    stable: ([.violations[] | select(involves_no_net | not) | canonical] | unique),
    no_net_counts: ([.violations[] | select(involves_no_net)] | group_by(.type) | map({key: .[0].type, value: length}) | from_entries),
    raw_counts: (.violations | group_by(.type) | map({key: .[0].type, value: length}) | from_entries),
    unconnected: ([.unconnected_items[] | canonical_by_net] | unique),
    parity: ([.schematic_parity[] | canonical] | unique)
  }'

generate() {
  local out=$1
  rm -rf "$out"
  mkdir -p "$out/gerber" "$out/svg" "$out/png"

  kicad-cli pcb drc --severity-all --all-track-errors --schematic-parity --format json --units mm \
    --output "$out/drc.raw.json" "$PCB" >/dev/null
  jq "$DRC_NORMALIZE" "$out/drc.raw.json" > "$out/drc.json"
  rm "$out/drc.raw.json"

  kicad-cli pcb export gerbers --layers "$LAYERS" --output "$out/gerber/" "$PCB" >/dev/null
  kicad-cli pcb export drill --format gerber --drill-origin absolute --excellon-units mm \
    --excellon-zeros-format decimal --excellon-separate-th --output "$out/gerber/" "$PCB" >/dev/null
  sed -i '/CreationDate\|Created by KiCad/d' "$out"/gerber/*

  kicad-cli pcb export pos --format csv --units mm --side both --output "$out/pos.csv" "$PCB" >/dev/null

  kicad-cli pcb export svg --layers "$LAYERS" --mode-multi --exclude-drawing-sheet \
    --page-size-mode 2 --black-and-white --output "$out/svg/" "$PCB" >/dev/null
  for svg in "$out"/svg/*.svg; do
    magick -density "$RASTER_DPI" "$svg" "$out/png/$(basename "${svg%.svg}").png"
  done
  echo "artefacts written to $out"
}

print_count_table() {
  local base=$1 cur=$2 key=$3
  jq -r --slurpfile b "$base/drc.json" "
    (\$b[0].$key) as \$before | .$key as \$after
    | ((\$before | keys) + (\$after | keys) | unique)[]
    | \"  \\(.): \\(\$before[.] // 0) -> \\(\$after[.] // 0)\"" "$cur/drc.json"
}

print_set_delta() {
  local base=$1 cur=$2 key=$3 label=$4
  jq --slurpfile b "$base/drc.json" "\$b[0].$key - .$key" "$cur/drc.json" > "$cur/$key.removed.json"
  jq --slurpfile b "$base/drc.json" ".$key - \$b[0].$key" "$cur/drc.json" > "$cur/$key.added.json"
  echo "  $label: $(jq -r ".$key | length" "$base/drc.json") -> $(jq -r ".$key | length" "$cur/drc.json")" \
    "(removed $(jq length "$cur/$key.removed.json"), added $(jq length "$cur/$key.added.json"))"
  jq -r '.[] | "  + \(.type // "unconnected"): \(.description) | \(.items | join(" / "))"' "$cur/$key.added.json"
  [ "$(jq length "$cur/$key.added.json")" = 0 ]
}

compare_drc() {
  local base=$1 cur=$2 status=0
  echo "== DRC raw counts per type (baseline -> current)"
  print_count_table "$base" "$cur" raw_counts
  echo "== DRC violations involving net-less copper (non-deterministic, counted only)"
  print_count_table "$base" "$cur" no_net_counts
  echo "== DRC stable sets (details in *.removed.json / *.added.json)"
  print_set_delta "$base" "$cur" stable "violations" || status=1
  print_set_delta "$base" "$cur" unconnected "unconnected items" || status=1
  print_set_delta "$base" "$cur" parity "schematic parity" || status=1
  if [ $status = 0 ]; then echo "PASS drc: nothing new"; else echo "FAIL drc: new entries"; fi
  return $status
}

compare_files() {
  local base=$1 cur=$2 status=0
  echo "== fabrication outputs"
  for path in "$base"/gerber/* "$base"/pos.csv; do
    local file=${path#"$base"/}
    if diff -q "$path" "$cur/$file" >/dev/null; then
      echo "PASS $file"
    else
      echo "FAIL $file: $(diff "$path" "$cur/$file" | grep -c '^[<>]') lines differ"
      status=1
    fi
  done
  return $status
}

compare_raster() {
  local base=$1 cur=$2 status=0
  echo "== raster per layer (differing pixels after 50% threshold)"
  for png in "$base"/png/*.png; do
    local name diff_pixels
    name=$(basename "$png")
    diff_pixels=$(magick "$png" "$cur/png/$name" -threshold 50% -compose difference -composite \
      -threshold 0 -format '%[fx:int(mean*w*h+0.5)]' info:)
    if [ "$diff_pixels" = 0 ]; then
      echo "PASS $name"
    else
      magick "$png" "$cur/png/$name" -threshold 50% -compose difference -composite -threshold 0 -negate \
        "$cur/png/${name%.png}.diff.png"
      echo "FAIL $name: $diff_pixels px (see png/${name%.png}.diff.png)"
      status=1
    fi
  done
  return $status
}

compare_sets() {
  local base=$1 cur=$2 status=0
  compare_drc "$base" "$cur" || status=1
  compare_files "$base" "$cur" || status=1
  compare_raster "$base" "$cur" || status=1
  return $status
}

case "${1:-}" in
  generate) generate "$2" ;;
  compare) compare_sets "$2" "$3" ;;
  *) echo "usage: $0 generate <dir> | compare <baseline-dir> <current-dir>" >&2; exit 2 ;;
esac
