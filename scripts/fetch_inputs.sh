#!/usr/bin/env bash
#
# Download input bundles from a GitHub release and unpack them into INPUT_DIR.
#
# Usage:
#   scripts/fetch_inputs.sh -r OWNER/REPO -t TAG -d INPUT_DIR BUNDLE [BUNDLE ...]
#
# BUNDLE names (assets are BUNDLE.tar.gz, or BUNDLE.tar.gz.part-aa, -ab, ... when split):
#   grids                 -> INPUT_DIR/grids/
#   geog                  -> INPUT_DIR/geog/mpas_static/
#   aerosols              -> INPUT_DIR/aerosols/
#   ungrib-<src>.<date>   -> INPUT_DIR/ungrib/<src>.<date>/   (e.g. ungrib-gfs.2023031015)
#
# Every asset is checked against MANIFEST.sha256 from the same release.
# Uses the gh CLI when available (GH_TOKEN), otherwise plain https downloads
# (public repositories only).
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

repo="" tag="" input_dir=""
while getopts "r:t:d:" opt; do
  case $opt in
    r) repo=$OPTARG ;;
    t) tag=$OPTARG ;;
    d) input_dir=$OPTARG ;;
    *) die "usage: $0 -r OWNER/REPO -t TAG -d INPUT_DIR BUNDLE..." ;;
  esac
done
shift $((OPTIND - 1))
[ -n "$repo" ] && [ -n "$tag" ] && [ -n "$input_dir" ] || die "-r, -t and -d are required"
[ $# -gt 0 ] || die "no bundles requested"

mkdir -p "$input_dir"
input_dir="$(cd "$input_dir" && pwd)"
dl="$input_dir/.download"
mkdir -p "$dl"

use_gh=false
if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then use_gh=true; fi

fetch() {  # fetch asset names into $dl
  if $use_gh; then
    local args=()
    for a in "$@"; do args+=(-p "$a"); done
    gh release download "$tag" -R "$repo" -D "$dl" --clobber "${args[@]}"
  else
    for a in "$@"; do
      curl -fL --retry 5 --retry-delay 10 -sS -o "$dl/$a" \
        "https://github.com/$repo/releases/download/$tag/$a"
    done
  fi
}

[ -s "$dl/MANIFEST.sha256" ] || fetch MANIFEST.sha256

for bundle in "$@"; do
  marker="$input_dir/.done.$bundle"
  if [ -e "$marker" ]; then echo "$bundle: already unpacked"; continue; fi

  mapfile -t assets < <(awk '{print $2}' "$dl/MANIFEST.sha256" \
                         | grep -E "^${bundle//./\\.}\.tar\.gz(\.part-[a-z]+)?$" | sort)
  [ ${#assets[@]} -gt 0 ] || die "bundle '$bundle' not in release $repo@$tag"

  echo "$bundle: downloading ${#assets[@]} asset(s)"
  fetch "${assets[@]}"
  (cd "$dl" && grep -E " (${bundle//./\\.}\.tar\.gz(\.part-[a-z]+)?)$" MANIFEST.sha256 | sha256sum -c --quiet -) \
    || die "$bundle: checksum mismatch"

  echo "$bundle: unpacking"
  (cd "$dl" && cat "${assets[@]}") | tar -xzf - -C "$input_dir"
  (cd "$dl" && rm -f "${assets[@]}")
  touch "$marker"
done

echo "$repo@$tag" > "$input_dir/INPUTS_TAG"
du -sh "$input_dir"/* 2>/dev/null || true
