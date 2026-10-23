#!/usr/bin/env python3
"""Resolve the init_atmosphere code to repo/ref/commit.

  resolve_refs.py MATRIX_JSON

MATRIX_JSON is the output of `case_info.py matrix`. Overrides come from the
environment: MPAS_REPO, MPAS_REF (empty = cases.yaml default). A ref may be a
branch, a tag or a full commit SHA. Prints JSON: {"repo", "ref", "sha"}.
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
    d = json.loads(sys.argv[1])["code"]
    repo = os.environ.get("MPAS_REPO") or d["repo"]
    ref = os.environ.get("MPAS_REF") or d["ref"]
    sha = ref if re.fullmatch(r"[0-9a-f]{40}", ref) else ls_remote(repo, ref)
    print(json.dumps({"repo": repo, "ref": ref, "sha": sha}, separators=(",", ":")))


if __name__ == "__main__":
    main()
