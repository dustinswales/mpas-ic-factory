#!/usr/bin/env python3
"""Resolve the MPAS code bases a set of cases needs to repo/ref/commit.

  resolve_refs.py MATRIX_JSON

MATRIX_JSON is the output of `case_info.py matrix`. Overrides come from the
environment: NCAR_REPO, NCAR_REF, GSL_REPO, GSL_REF (empty = cases.yaml default).
A ref may be a branch, a tag or a full commit SHA. Prints JSON:
  {"builds": [{"code_base", "repo", "ref", "sha"}...], "shas": {code_base: sha}}
"""
import json
import os
import re
import subprocess
import sys


def ls_remote(repo, ref):
    url = f"https://github.com/{repo}.git"
    out = subprocess.run(["git", "ls-remote", url], check=True,
                         capture_output=True, text=True).stdout
    refs = {}
    for line in out.splitlines():
        sha, name = line.split("\t")
        refs[name] = sha
    for name in (f"refs/tags/{ref}^{{}}", f"refs/tags/{ref}", f"refs/heads/{ref}", ref):
        if name in refs:
            return refs[name]
    sys.exit(f"ERROR: ref '{ref}' not found in {repo}")


def main():
    m = json.loads(sys.argv[1])
    builds, shas = [], {}
    for cb in m["code_bases"]:
        d = m["defaults"][cb]
        repo = os.environ.get(f"{cb.upper()}_REPO") or d["repo"]
        ref = os.environ.get(f"{cb.upper()}_REF") or d["ref"]
        sha = ref if re.fullmatch(r"[0-9a-f]{40}", ref) else ls_remote(repo, ref)
        builds.append({"code_base": cb, "repo": repo, "ref": ref, "sha": sha})
        shas[cb] = sha
    print(json.dumps({"builds": builds, "shas": shas}, separators=(",", ":")))


if __name__ == "__main__":
    main()
