#!/usr/bin/env bash
#
# Package existing static files (made on HPC by mpas_testcase create_case or by
# scripts/create_case.sh) as release bundles, so CI can skip the slow static step.
#
# Usage:
#   bash tools/stage_static.sh [-u OWNER/REPO] [-t TAG] SOURCE_DIR STAGE_DIR
#     SOURCE_DIR  searched recursively for, per domain in DOMAINS:
#                   *<domain>.120km.static.nc  and  *<domain>.120km.ugwp_oro_data.nc
#                 e.g. a mpas_testcase baseline directory such as
#                 .../baselines_mpas/create_case/gsl-v8.3.0-1.0-intelmpi/
#     -u   create release TAG in OWNER/REPO and upload (needs gh + auth)
#     -t   release tag (default static-v1)
#
# Environment:
#   DOMAINS     "conus global"
#   RESOLUTION  120km
#
# Produces bundles static-<domain>-<resolution>.tar.gz unpacking to
#   static/<domain>-<resolution>/mpas.<domain>.<resolution>.{static,ugwp_oro_data}.nc
# Use them with the workflow input static_tag=TAG.
[ -n "${BASH_VERSION:-}" ] || { echo "ERROR: run with bash: bash $0 ..." >&2; exit 1; }
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

upload_repo="" tag="static-v1"
while getopts "u:t:" opt; do
  case $opt in
    u) upload_repo=$OPTARG ;;
    t) tag=$OPTARG ;;
    *) die "usage: $0 [-u OWNER/REPO] [-t TAG] SOURCE_DIR STAGE_DIR" ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 2 ] || die "usage: $0 [-u OWNER/REPO] [-t TAG] SOURCE_DIR STAGE_DIR"
src=$1 stage=$2
[ -d "$src" ] || die "no directory $src"
src="$(cd "$src" && pwd)"
mkdir -p "$stage"; stage="$(cd "$stage" && pwd)"

DOMAINS=${DOMAINS:-"conus global"}
RESOLUTION=${RESOLUTION:-120km}

tree="$stage/tree" out="$stage/assets"
rm -rf "$tree" "$out"
mkdir -p "$tree" "$out"

find_one() {  # $1 = filename suffix; prints the single match or dies
  local matches
  mapfile -t matches < <(find -L "$src" -type f -name "*$1" | sort)
  [ ${#matches[@]} -gt 0 ] || die "no *$1 under $src"
  # Every case directory keeps a copy of its domain's static file; that is fine
  # as long as the copies are identical.
  local m
  for m in "${matches[@]:1}"; do
    cmp -s "${matches[0]}" "$m" || die "*$1 files under $src differ (${matches[0]} vs $m); pass a narrower SOURCE_DIR"
  done
  echo "${matches[0]}"
}

for d in $DOMAINS; do
  key="$d-$RESOLUTION"
  dest="$tree/static/$key"
  mkdir -p "$dest"
  for kind in static ugwp_oro_data; do
    f=$(find_one ".$d.$RESOLUTION.$kind.nc")
    echo "$key: $kind <- $f"
    ln -s "$f" "$dest/mpas.$d.$RESOLUTION.$kind.nc"
  done
  log="$(dirname "$f")/log.static"
  [ -e "$log" ] && ln -s "$log" "$dest/log.static"
  {
    echo "Static files staged $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname)"
    echo "from: $(dirname "$f")"
    desc="$(dirname "$f")/description"
    [ -e "$desc" ] && cat "$desc"
    true
  } > "$dest/description.static"
  echo "packing static-$key"
  tar -C "$tree" -chf - "static/$key" | gzip -1 > "$out/static-$key.tar.gz"
done

(cd "$out" && sha256sum -- * > MANIFEST.sha256)
ls -lh "$out"

if [ -n "$upload_repo" ]; then
  command -v gh >/dev/null || die "gh CLI not found; upload $out by hand"
  gh release view "$tag" -R "$upload_repo" >/dev/null 2>&1 \
    || gh release create "$tag" -R "$upload_repo" --title "Static files $tag" \
         --notes "Prebuilt MPAS static and ugwp_oro_data files ($DOMAINS, $RESOLUTION) from $src"
  gh release upload "$tag" -R "$upload_repo" --clobber "$out"/*
else
  echo
  echo "To publish:"
  echo "  gh release create $tag -R OWNER/REPO --title 'Static files $tag' --notes 'Prebuilt static files'"
  echo "  gh release upload $tag -R OWNER/REPO $out/*"
fi
