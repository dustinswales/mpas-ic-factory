#!/usr/bin/env bash
#
# Add geographic datasets to an existing inputs release without re-uploading the
# whole geog bundle. Each DATASET_DIR becomes bundle geog-<name>, unpacking to
# geog/mpas_static/<name>/; scripts/fetch_inputs.sh fetches every geog-* bundle
# whenever "geog" is requested. The release's MANIFEST.sha256 is merged, not replaced.
#
# Usage:
#   bash tools/add_geog_dataset.sh [-u OWNER/REPO] [-t TAG] STAGE_DIR DATASET_DIR [DATASET_DIR ...]
#     -u   upload to release TAG in OWNER/REPO (needs gh + auth); the release must exist
#     -t   release tag (default v1.0.0)
#
# Example (21-class MODIS land use with lakes, from a WPS geog directory):
#   bash tools/add_geog_dataset.sh -u OWNER/mpas-ic-factory /path/to/stage \
#       /path/to/WPS_GEOG/modis_landuse_20class_30s_with_lakes
#
# Environment: SPLIT_SIZE (1900M), SPLIT_ABOVE (1990000000 bytes), as in stage_inputs.sh.
[ -n "${BASH_VERSION:-}" ] || { echo "ERROR: run with bash: bash $0 ..." >&2; exit 1; }
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
usage="usage: $0 [-u OWNER/REPO] [-t TAG] STAGE_DIR DATASET_DIR [DATASET_DIR ...]"

upload_repo="" tag="v1.0.0"
while getopts "u:t:" opt; do
  case $opt in
    u) upload_repo=$OPTARG ;;
    t) tag=$OPTARG ;;
    *) die "$usage" ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 2 ] || die "$usage"
stage=$1; shift
mkdir -p "$stage"; stage="$(cd "$stage" && pwd)"
SPLIT_SIZE=${SPLIT_SIZE:-1900M}
SPLIT_ABOVE=${SPLIT_ABOVE:-1990000000}

tree="$stage/tree" out="$stage/assets"
rm -rf "$tree" "$out"
mkdir -p "$tree/geog/mpas_static" "$out"

new_assets=()
for src in "$@"; do
  [ -d "$src" ] || die "no directory $src"
  src="$(cd "$src" && pwd)"
  name=$(basename "$src")
  [ -s "$src/index" ] || die "$src has no index file; is it a WPS/MPAS geographic dataset?"
  ln -s "$src" "$tree/geog/mpas_static/$name"
  bundle="geog-$name"
  echo "packing $bundle  ($(grep -E '^ *(category_max|islake|iswater|isice) *=' "$src/index" | tr -d ' ' | paste -sd' '))"
  tar -C "$tree" -chf - "geog/mpas_static/$name" | gzip -1 > "$out/$bundle.tar.gz"
  if [ "$(stat -c %s "$out/$bundle.tar.gz")" -gt "$SPLIT_ABOVE" ]; then
    split -b "$SPLIT_SIZE" -a 2 "$out/$bundle.tar.gz" "$out/$bundle.tar.gz.part-"
    rm "$out/$bundle.tar.gz"
  fi
  for a in "$out/$bundle".tar.gz*; do new_assets+=("$(basename "$a")"); done
done

(cd "$out" && sha256sum -- "${new_assets[@]}" > new.sha256)

merge_manifest() {  # $1 = existing manifest (may be empty); writes $out/MANIFEST.sha256
  local old=$1
  {
    # keep existing entries except ones being replaced
    if [ -s "$old" ]; then
      awk -v drop="$(printf '%s\n' "${new_assets[@]}")" \
        'BEGIN { n = split(drop, d, "\n"); for (i = 1; i <= n; i++) skip[d[i]] = 1 } !($2 in skip)' "$old"
    fi
    cat "$out/new.sha256"
  } > "$out/MANIFEST.sha256"
  rm "$out/new.sha256"
}

if [ -n "$upload_repo" ]; then
  command -v gh >/dev/null || die "gh CLI not found"
  gh release view "$tag" -R "$upload_repo" >/dev/null 2>&1 \
    || die "release $tag not found in $upload_repo (create it with tools/stage_inputs.sh first)"
  mkdir -p "$stage/old"
  gh release download "$tag" -R "$upload_repo" -p MANIFEST.sha256 -D "$stage/old" --clobber \
    || die "could not download MANIFEST.sha256 from $upload_repo@$tag"
  merge_manifest "$stage/old/MANIFEST.sha256"
  echo "Uploading ${new_assets[*]} and the merged MANIFEST.sha256 to $upload_repo@$tag"
  (cd "$out" && gh release upload "$tag" -R "$upload_repo" --clobber "${new_assets[@]}" MANIFEST.sha256)
else
  merge_manifest /dev/null
  echo
  echo "Assets are in $out. To add them to an existing release, re-run with -u OWNER/REPO,"
  echo "which merges MANIFEST.sha256 instead of replacing it."
fi
ls -lh "$out"
