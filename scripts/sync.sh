#!/usr/bin/env bash
# Fetch or update every upstream clone, then rebuild. Nothing in upstream/ is ever edited.
set -euo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$R/upstream"
python3 - "$R" <<'PY'
import json, os, subprocess, sys
R = sys.argv[1]
for key, s in json.load(open(f"{R}/sources.json"))["sources"].items():
    clone = s["repo"].replace("/", "_")
    d = os.path.join(R, "upstream", clone)
    if os.path.isdir(os.path.join(d, ".git")):
        subprocess.check_call(["git", "-C", d, "fetch", "--quiet", "--all"])
        subprocess.check_call(["git", "-C", d, "pull", "--quiet", "--ff-only"])
    else:
        subprocess.check_call(["git", "clone", "--quiet", f"https://github.com/{s['repo']}.git", d])
    head = subprocess.check_output(["git", "-C", d, "rev-parse", "--short", "HEAD"], text=True).strip()
    print(f"  {s['repo']:45s} {head}")
PY
python3 "$R/scripts/build.py"
python3 "$R/scripts/render-docs.py"
echo
echo "Upstreams synced and build/ regenerated. Review DEVIATIONS.md, then run scripts/install.sh."
