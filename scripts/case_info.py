#!/usr/bin/env python3
"""Read cases.yaml and answer questions about cases.

  case_info.py env CASE            shell assignments for scripts/create_case.sh
  case_info.py matrix [CASES]      JSON static/case matrices for GitHub Actions
                                   CASES: "all" (default) or "case05,case07,..."
  case_info.py list                one case id per line

Optional: --file PATH (default: cases.yaml in the repository root).
"""
import argparse
import json
import shlex
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent

# Combinations the namelists in case_files/ support: (domain, resolution, source).
VALID = {
    ("conus", "120km", "gfs"),
    ("global", "120km", "gfs"),
    ("conus", "120km", "rap"),
}


def load(path):
    with open(path) as f:
        return yaml.safe_load(f)


def resolve(cfg, case_id):
    if case_id not in cfg["cases"]:
        sys.exit(f"ERROR: unknown case '{case_id}'. Known: {', '.join(cfg['cases'])}")
    c = dict(cfg.get("defaults", {}))
    c.update(cfg["cases"][case_id])
    c["case_id"] = case_id

    key = (c["domain"], c["resolution"], c["source"])
    if key not in VALID:
        sys.exit("ERROR: domain/resolution/source = " + "/".join(key) + " not supported")

    if c["source"] == "gfs":
        date = str(cfg["dates"]["gfs"])
    else:  # rap
        season = c.get("season")
        if season not in cfg["dates"]["rap"]:
            sys.exit(f"ERROR: {case_id}: rap source needs season in {list(cfg['dates']['rap'])}")
        date = str(cfg["dates"]["rap"][season])
    c["date"] = date

    try:
        c["mesh"] = cfg["meshes"][c["domain"]][c["resolution"]]
    except KeyError:
        sys.exit(f"ERROR: {case_id}: no mesh for {c['domain']}/{c['resolution']}")

    c["static_key"] = f"{c['domain']}-{c['resolution']}"
    c["case_dir"] = ".".join([c["domain"], c["resolution"], c["source"], date])
    c["use_climo_aerosols"] = str(bool(c.get("use_climo_aerosols", True))).lower()
    c.setdefault("season", "")
    return c


def select(cfg, spec):
    if not spec or spec.strip().lower() == "all":
        return list(cfg["cases"])
    ids = [s.strip() for s in spec.replace(" ", ",").split(",") if s.strip()]
    for i in ids:
        if i not in cfg["cases"]:
            sys.exit(f"ERROR: unknown case '{i}'. Known: {', '.join(cfg['cases'])}")
    return ids


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--file", default=str(ROOT / "cases.yaml"))
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("env")
    e.add_argument("case")
    m = sub.add_parser("matrix")
    m.add_argument("cases", nargs="?", default="all")
    sub.add_parser("list")
    a = p.parse_args()
    cfg = load(a.file)

    if a.cmd == "list":
        print("\n".join(cfg["cases"]))
    elif a.cmd == "env":
        c = resolve(cfg, a.case)
        for k in ("case_id", "domain", "resolution", "source", "season", "date",
                  "mesh", "case_dir", "static_key", "use_climo_aerosols"):
            print(f"{k}={shlex.quote(str(c[k]))}")
    elif a.cmd == "matrix":
        cases = [resolve(cfg, i) for i in select(cfg, a.cases)]
        statics = {}
        for c in cases:
            statics.setdefault(c["static_key"], {
                "static_key": c["static_key"],
                "case_id": c["case_id"],  # any case using this static file
            })
        out = {
            "statics": list(statics.values()),
            "cases": [{"case_id": c["case_id"], "static_key": c["static_key"],
                       "case_dir": c["case_dir"], "source": c["source"], "date": c["date"]}
                      for c in cases],
            "code": cfg["code"],
        }
        print(json.dumps(out, separators=(",", ":")))


if __name__ == "__main__":
    main()
