#!/usr/bin/env bash
#
# Build init_atmosphere_model from an MPAS-Model checkout with GNU compilers.
#
# Usage:
#   scripts/build_init_atmosphere.sh SRC_DIR [OUT_EXE]
#
# Environment:
#   NETCDF, PNETCDF   library prefixes (default: $CONDA_PREFIX)
#   PRECISION         "single" (MPAS default) or "double"
#   DEBUG             "true" for a debug build (-g, -fcheck=all, -fbacktrace)
#   FPE_TRAP          with DEBUG=true: "true" keeps MPAS's -ffpe-trap=invalid,zero,overflow,
#                     "false" (default) drops it so bounds errors past a benign FPE are reached
#   MAKE_JOBS         parallel make jobs (default: nproc)
#   MPAS_PATCH_DIR    directory of *.patch files applied to SRC_DIR before building
#                     (default: patches/mpas next to this script's repo); patches that
#                     are already in the source are skipped
set -euo pipefail

src=${1:?usage: $0 SRC_DIR [OUT_EXE]}
out=${2:-}
# Resolve OUT_EXE against the caller's directory before changing into SRC_DIR.
if [ -n "$out" ]; then
  mkdir -p "$(dirname "$out")"
  out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
fi
prefix=${CONDA_PREFIX:-/usr}
export NETCDF=${NETCDF:-$prefix}
export PNETCDF=${PNETCDF:-$prefix}
precision=${PRECISION:-single}
jobs=${MAKE_JOBS:-$(nproc)}

patch_dir=${MPAS_PATCH_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/patches/mpas}

cd "$src"
shopt -s nullglob
for p in "$patch_dir"/*.patch; do
  if git apply --check "$p" 2>/dev/null; then
    git apply "$p"
    echo "Applied $(basename "$p")"
  elif git apply --reverse --check "$p" 2>/dev/null; then
    echo "Already in source, skipped: $(basename "$p")"
  else
    echo "ERROR: $(basename "$p") does not apply to this MPAS source"; git apply --check "$p"; exit 1
  fi
done
shopt -u nullglob

make_args=(gfortran CORE=init_atmosphere PRECISION="$precision" AUTOCLEAN=true)
if [ "${DEBUG:-false}" = "true" ]; then
  make_args+=(DEBUG=true)
  if [ "${FPE_TRAP:-false}" != "true" ]; then
    # Edits the throwaway checkout only.
    sed -i 's/ -ffpe-trap=invalid,zero,overflow//' Makefile
    echo "Debug build without -ffpe-trap (set FPE_TRAP=true to keep it)"
  fi
fi

echo "Building init_atmosphere in $src: ${make_args[*]} (NETCDF=$NETCDF PNETCDF=$PNETCDF)"
mpif90 --version | head -1
make -j"$jobs" "${make_args[@]}" 2>&1 | tee build.log | grep -E "^(\*|ERROR|Error|make.*Error)" || true
[ -x init_atmosphere_model ] || { echo "ERROR: build failed"; tail -60 build.log; exit 1; }

if [ -n "$out" ]; then
  mkdir -p "$(dirname "$out")"
  cp init_atmosphere_model "$out"
fi
echo "Built: $src/init_atmosphere_model"
