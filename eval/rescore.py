#!/usr/bin/env python3
"""Re-score a stored eval run against the current corpus and OWNERS set, without
re-running any sessions. The `fired` skill list per run is the raw observation;
scoring is derived, so it can be corrected after the fact."""
import json, os, sys, importlib.util

ROOT = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("re_", os.path.join(ROOT, "run-eval.py"))
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)

path = sys.argv[1]
agg = json.load(open(path))
corpus = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "corpus.jsonl")
cases = {json.loads(l)["id"]: json.loads(l) for l in open(corpus) if l.strip()}
dup = passed = total = 0
for r in agg["results"]:
    c = cases[r["id"]]
    new = []
    for run in r["runs_detail"]:
        s = mod.score(c, run["fired"]); s["error"] = run.get("error"); new.append(s)
    r["runs_detail"] = new
    r["passed"] = sum(1 for s in new if s["pass"])
    r["duplicate_owner_runs"] = sum(1 for s in new if s["duplicate_owner"])
    dup += r["duplicate_owner_runs"]; passed += r["passed"]; total += len(new)
agg["passRate"] = round(passed / max(1, total), 3); agg["duplicateOwnerRuns"] = dup
json.dump(agg, open(path, "w"), indent=2)
for r in agg["results"]:
    mark = "ok  " if r["passed"] == len(r["runs_detail"]) else "FAIL"
    print(f"  {mark} {r['passed']}/{len(r['runs_detail'])}  {r['id']:<26} dup:{r['duplicate_owner_runs']}"
          f"  {[s['fired'] for s in r['runs_detail']]}")
print(f"\npass {passed}/{total} = {agg['passRate']:.0%}   duplicate-owner runs {dup}")
