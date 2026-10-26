#!/usr/bin/env python3
"""Check WPS/ungrib intermediate files (format version 5) for bad values.

  check_intermediate.py [-v] FILE [FILE ...]

Decodes each record the way MPAS init_atmosphere does (mpas_init_atm_read_met.F:
big-endian Fortran sequential records) and reports, per field:
  field, level, nx x ny, projection, header values, slab min/max,
  number of NaN / Inf values in the header and slab.
Prints only problem records unless -v. Exit status 1 if any record has
non-finite header values, non-finite slab values, or a damaged record.
"""
import argparse
import struct
import sys

import numpy as np

# Floats after the 8-character startloc in record 3, by projection code.
PROJ = {
    0: ("latlon", ["startlat", "startlon", "deltalat", "deltalon", "earth_radius"]),
    1: ("mercator", ["startlat", "startlon", "dx", "dy", "truelat1", "earth_radius"]),
    3: ("lambert", ["startlat", "startlon", "dx", "dy", "xlonc", "truelat1", "truelat2", "earth_radius"]),
    4: ("gaussian", ["startlat", "startlon", "nlats", "deltalon", "earth_radius"]),
    5: ("polar", ["startlat", "startlon", "dx", "dy", "xlonc", "truelat1", "earth_radius"]),
    6: ("cassini", ["startlat", "startlon", "dx", "dy", "centerlat", "centerlon", "earth_radius"]),
}


class Damaged(Exception):
    pass


def records(buf):
    """Yield the payload of each big-endian Fortran sequential record."""
    pos, n = 0, len(buf)
    while pos < n:
        if pos + 4 > n:
            raise Damaged(f"truncated record marker at byte {pos}")
        (length,) = struct.unpack(">i", buf[pos:pos + 4])
        end = pos + 4 + length
        if length < 0 or end + 4 > n:
            raise Damaged(f"bad record length {length} at byte {pos}")
        (trail,) = struct.unpack(">i", buf[end:end + 4])
        if trail != length:
            raise Damaged(f"record markers disagree ({length} vs {trail}) at byte {pos}")
        yield buf[pos + 4:end]
        pos = end + 4


def check_file(path, verbose):
    with open(path, "rb") as f:
        buf = f.read()
    bad = 0
    nrec = 0
    recs = records(buf)
    try:
        while True:
            try:
                r1 = next(recs)
            except StopIteration:
                break
            (version,) = struct.unpack(">i", r1)
            if version != 5:
                print(f"{path}: record {nrec + 1}: format version {version} (expected 5)")
                return 1
            r2 = next(recs)
            if len(r2) != 156:
                raise Damaged(f"header record is {len(r2)} bytes, expected 156")
            hdate = r2[0:24].decode(errors="replace").strip()
            (xfcst,) = struct.unpack(">f", r2[24:28])
            field = r2[60:69].decode(errors="replace").strip()
            xlvl, nx, ny, iproj = struct.unpack(">fiii", r2[140:156])

            r3 = next(recs)
            startloc = r3[0:8].decode(errors="replace").strip()
            name, keys = PROJ.get(iproj, (f"proj{iproj}", []))
            nfl = (len(r3) - 8) // 4
            vals = struct.unpack(f">{nfl}f", r3[8:8 + 4 * nfl])
            hdr = dict(zip(keys or [f"v{i}" for i in range(nfl)], vals))

            r4 = next(recs)  # is_wind_grid_rel
            r5 = next(recs)
            if len(r5) != 4 * nx * ny:
                raise Damaged(f"{field} level {xlvl}: slab is {len(r5)} bytes, expected {4 * nx * ny}")
            slab = np.frombuffer(r5, dtype=">f4")
            nan = int(np.isnan(slab).sum())
            inf = int(np.isinf(slab).sum())
            finite = slab[np.isfinite(slab)]
            lo, hi = (float(finite.min()), float(finite.max())) if finite.size else (np.nan, np.nan)
            hdr_bad = [k for k, v in list(hdr.items()) + [("xfcst", xfcst), ("xlvl", xlvl)]
                       if not np.isfinite(v)]
            nrec += 1

            problem = []
            if iproj not in PROJ:
                problem.append(f"unknown projection {iproj}")
            if nx <= 0 or ny <= 0:
                problem.append(f"nx,ny = {nx},{ny}")
            if hdr_bad:
                problem.append("non-finite header: " + ",".join(hdr_bad))
            if nan or inf:
                problem.append(f"slab NaN={nan} Inf={inf}")
            if abs(hdr.get("startlat", 0.0)) > 90.0:
                problem.append(f"startlat={hdr['startlat']}")
            if problem:
                bad += 1
            if problem or verbose:
                hv = " ".join(f"{k}={v:g}" for k, v in hdr.items())
                flag = ("  <-- " + "; ".join(problem)) if problem else ""
                print(f"{path}: {field:9s} lvl={xlvl:<9g} {nx}x{ny} {name}/{startloc} {hv} "
                      f"wind_rel={struct.unpack('>i', r4)[0]} slab=[{lo:g},{hi:g}] {hdate}{flag}")
    except (Damaged, StopIteration, struct.error) as e:
        print(f"{path}: DAMAGED after {nrec} complete fields: {e or 'file ends mid-field'}")
        return 1
    print(f"{path}: {nrec} fields, {bad} with problems")
    return 1 if bad else 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-v", "--verbose", action="store_true", help="print every field")
    p.add_argument("files", nargs="+")
    a = p.parse_args()
    status = 0
    for f in a.files:
        status |= check_file(f, a.verbose)
    sys.exit(status)


if __name__ == "__main__":
    main()
