#!/usr/bin/env bash
#
# Compare every mpas.*.nc in TEST_DIR/<case_dir>/case_files with the file of the
# same name under BASE_DIR, using nccmp (data only, as in mpas_testcase utils).
#
# Usage:
#   scripts/compare_cases.sh BASE_DIR TEST_DIR [REPORT.md]
#
# Environment:
#   NCCMP_FLAGS    default "-dsSqf"
#   NCCMP_EXCLUDE  comma list of variables to skip (nccmp -x)
#
# Writes a markdown table to REPORT.md (or stdout).
# Exit status: 0 all identical, 1 differences or missing baselines, 2 no nccmp.
set -uo pipefail

base=${1:?usage: $0 BASE_DIR TEST_DIR [REPORT.md]}
test=${2:?usage: $0 BASE_DIR TEST_DIR [REPORT.md]}
report=${3:-}
flags=${NCCMP_FLAGS:--dsSqf}
exclude=()
[ -n "${NCCMP_EXCLUDE:-}" ] && exclude=(-x "$NCCMP_EXCLUDE")

command -v nccmp >/dev/null || { echo "ERROR: nccmp not found" >&2; exit 2; }

status=0
tmp=$(mktemp)
{
  echo "| case | file | result |"
  echo "|---|---|---|"
} > "$tmp"

shopt -s nullglob
for f in "$test"/*/case_files/mpas.*.nc; do
  case_dir=$(basename "$(dirname "$(dirname "$f")")")
  name=$(basename "$f")
  b=$(find "$base" -path "*/$case_dir/case_files/$name" -print -quit 2>/dev/null)
  if [ -z "$b" ]; then
    result="no baseline"; status=1
  elif cmp -s "$f" "$b"; then
    result="identical (bitwise)"
  elif out=$(nccmp "${exclude[@]}" "$flags" "$b" "$f" 2>&1); then
    result="identical data"
  else
    n=$(printf '%s\n' "$out" | grep -c DIFFER || true)
    result="**DIFFER** ($n variables)"
    status=1
    printf '%s\n' "---- $case_dir/$name" "$out" | head -60 >&2
  fi
  echo "| $case_dir | $name | $result |" >> "$tmp"
done
[ -n "$(ls "$test"/*/case_files/mpas.*.nc 2>/dev/null)" ] || { echo "no files under $test" >&2; status=1; }

if [ -n "$report" ]; then cp "$tmp" "$report"; else cat "$tmp"; fi
rm -f "$tmp"
exit $status
