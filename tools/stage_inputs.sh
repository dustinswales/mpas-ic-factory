#!/usr/bin/env bash
#
# One-time packaging of the MPAS IC factory inputs into release bundles.
# Run where the data already exist (e.g. Ursa), then upload the bundles to a
# GitHub release (gh CLI, here or after copying STAGE_DIR elsewhere).
#
# Usage:
#   tools/stage_inputs.sh [-u OWNER/REPO] [-t TAG] STAGE_DIR
#     -u   also create the release TAG in OWNER/REPO and upload (needs gh + auth)
#     -t   release tag (default inputs-v1)
#
# Source locations (override with environment variables). Defaults follow the
# layout used by barlage/mpas_testcase create_case on Ursa.
#   SYSTEM_DIR    /scratch4/BMC/wrfruc/Michael.Barlage/mpas
#   GLOBAL_GRID_DIR  $SYSTEM_DIR/data/120km/grid             (x1.40962.grid.nc, x1.40962.graph.info*)
#   CONUS_GRID_DIR   $SYSTEM_DIR/code-MPAS/MPAS-Limited-Area (conus.120km.grid.nc, conus.120km.graph.info*)
#   UNGRIB_DIR    $SYSTEM_DIR/data/ungrib                    (gfs.2023031015, sst.2023031015, rap.*)
#   AEROSOL_FILE  $SYSTEM_DIR/data/aerosols/QNWFA_QNIFA_SIGMA_MONTHLY.dat
#   GEOG_DIR      $SYSTEM_DIR/data/mpas_static
#   GEOG_SUBDIRS  datasets to include from GEOG_DIR, or "all"
#   UNGRIB_SETS   "gfs.2023031015 sst.2023031015 rap.2024020218 rap.2024081518"
#   SPLIT_SIZE    1900M  part size when a bundle is larger than SPLIT_ABOVE bytes
#                 (GitHub release assets must be < 2 GiB)
[ -n "${BASH_VERSION:-}" ] || { echo "ERROR: run with bash: bash $0 ..." >&2; exit 1; }
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

upload_repo="" tag="inputs-v1"
while getopts "u:t:" opt; do
  case $opt in
    u) upload_repo=$OPTARG ;;
    t) tag=$OPTARG ;;
    *) die "usage: $0 [-u OWNER/REPO] [-t TAG] STAGE_DIR" ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || die "usage: $0 [-u OWNER/REPO] [-t TAG] STAGE_DIR"
stage=$1
mkdir -p "$stage"; stage="$(cd "$stage" && pwd)"

SYSTEM_DIR=${SYSTEM_DIR:-/scratch4/BMC/wrfruc/Michael.Barlage/mpas}
GLOBAL_GRID_DIR=${GLOBAL_GRID_DIR:-$SYSTEM_DIR/data/120km/grid}
CONUS_GRID_DIR=${CONUS_GRID_DIR:-$SYSTEM_DIR/code-MPAS/MPAS-Limited-Area}
UNGRIB_DIR=${UNGRIB_DIR:-$SYSTEM_DIR/data/ungrib}
AEROSOL_FILE=${AEROSOL_FILE:-$SYSTEM_DIR/data/aerosols/QNWFA_QNIFA_SIGMA_MONTHLY.dat}
GEOG_DIR=${GEOG_DIR:-$SYSTEM_DIR/data/mpas_static}
# Datasets read by the ncar and gsl step1_static namelists (MPAS v8.3 / GSL v8.4):
GEOG_SUBDIRS=${GEOG_SUBDIRS:-"topo_gmted2010_30s modis_landuse_20class_30s landuse_30s
  soiltype_top_30s soiltemp_1deg greenfrac_fpar_modis albedo_modis maxsnowalb_modis
  lai_modis_30s soilgrids topo_ugwp_2.5m topo_ugwp_30s"}
UNGRIB_SETS=${UNGRIB_SETS:-"gfs.2023031015 sst.2023031015 rap.2024020218 rap.2024081518"}
SPLIT_SIZE=${SPLIT_SIZE:-1900M}
SPLIT_ABOVE=${SPLIT_ABOVE:-1990000000}   # bytes

tree="$stage/tree"     # layout that scripts/fetch_inputs.sh recreates
out="$stage/assets"
rm -rf "$tree" "$out"
for d in "$tree/grids" "$tree/ungrib" "$tree/aerosols" "$tree/geog" "$out"; do
  mkdir -p "$d" || die "cannot create $d"
done

# Symlink sources into the tree; tar -h follows the links.
link_glob() {  # $1 = destination dir, rest = files (must exist)
  local dest=$1; shift
  local f
  [ -d "$dest" ] || die "staging directory $dest does not exist"
  for f in "$@"; do
    [ -e "$f" ] || die "missing $f"
    ln -s "$f" "$dest/$(basename "$f")" || die "cannot link $f into $dest"
  done
}

shopt -s nullglob
link_glob "$tree/grids" "$GLOBAL_GRID_DIR/x1.40962.grid.nc" "$CONUS_GRID_DIR/conus.120km.grid.nc"
graphs=("$GLOBAL_GRID_DIR"/x1.40962.graph.info* "$CONUS_GRID_DIR"/conus.120km.graph.info*)
[ ${#graphs[@]} -gt 0 ] || die "no graph.info files found"
link_glob "$tree/grids" "${graphs[@]}"
for m in x1.40962 conus.120km; do
  [ -e "$tree/grids/$m.graph.info" ] || echo "WARNING: no $m.graph.info; only the staged part files will work"
done
shopt -u nullglob

link_glob "$tree/aerosols" "$AEROSOL_FILE"

for s in $UNGRIB_SETS; do
  [ -d "$UNGRIB_DIR/$s" ] || die "missing $UNGRIB_DIR/$s"
  ln -s "$UNGRIB_DIR/$s" "$tree/ungrib/$s"
done

if [ "$GEOG_SUBDIRS" = "all" ]; then
  ln -s "$GEOG_DIR" "$tree/geog/mpas_static"
else
  mkdir -p "$tree/geog/mpas_static"
  for d in $GEOG_SUBDIRS; do
    if [ -d "$GEOG_DIR/$d" ]; then ln -s "$GEOG_DIR/$d" "$tree/geog/mpas_static/$d"
    else echo "WARNING: $GEOG_DIR/$d not found, skipped"; fi
  done
fi

pack() {  # $1 = bundle name, rest = paths relative to $tree
  local name=$1; shift
  echo "packing $name"
  tar -C "$tree" -chf - "$@" | gzip -1 > "$out/$name.tar.gz"
  local size; size=$(stat -c %s "$out/$name.tar.gz")
  if [ "$size" -gt "$SPLIT_ABOVE" ]; then
    split -b "$SPLIT_SIZE" -a 2 "$out/$name.tar.gz" "$out/$name.tar.gz.part-"
    rm "$out/$name.tar.gz"
  fi
}

pack grids grids
pack aerosols aerosols
for s in $UNGRIB_SETS; do pack "ungrib-$s" "ungrib/$s"; done
pack geog geog

(cd "$out" && sha256sum -- * > MANIFEST.sha256)
echo
ls -lh "$out"

notes="Inputs for MPAS IC factory: grids (x1.40962, conus.120km), mpas_static subset,
ungrib intermediate files ($UNGRIB_SETS), Thompson climatological aerosols.
Staged $(date -u +%Y-%m-%d) from $SYSTEM_DIR."

if [ -n "$upload_repo" ]; then
  command -v gh >/dev/null || die "gh CLI not found; upload $out by hand"
  gh release view "$tag" -R "$upload_repo" >/dev/null 2>&1 \
    || gh release create "$tag" -R "$upload_repo" --title "Inputs $tag" --notes "$notes"
  gh release upload "$tag" -R "$upload_repo" --clobber "$out"/*
else
  echo
  echo "To publish (from any machine with gh and these files):"
  echo "  gh release create $tag -R OWNER/REPO --title 'Inputs $tag' --notes 'MPAS IC factory inputs'"
  echo "  gh release upload $tag -R OWNER/REPO $out/*"
fi
