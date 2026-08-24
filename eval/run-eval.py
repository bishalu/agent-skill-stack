#!/usr/bin/env python3
"""Routing eval: run each corpus prompt through a real headless Claude Code session
and record which skills actually fired.

Not a self-report. The session has the whole stack installed; every Skill tool call
in the stream is a real routing decision. Mutating tools are disallowed and the run
is cut short once routing has happened, so a case costs a routing decision, not a
full workflow.
"""
import argparse, json, os, subprocess, sys, concurrent.futures as cf, collections, datetime

ROOT = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(ROOT, "fixture")

DRY_RUN = (
    "ROUTING DRY RUN. Do not perform the task, do not investigate, do not read files "
    "beyond what a skill itself requires. Decide which skills apply and invoke them; "
    "if none apply, invoke none. As soon as the skills you selected have loaded, stop "
    "and reply with the single word DONE. Never invoke the same skill twice."
)

# Skills that RUN a lifecycle phase. Two of these firing in one session is the hard
# failure this whole stack exists to prevent.
#
# diagnosing-bugs is deliberately absent: it is an escalation partner, designed to run
# alongside ce-debug rather than instead of it. A case where it must NOT fire says so
# through its own `forbid` list.
OWNERS = {
    "ce-brainstorm", "ce-plan", "ce-work", "ce-debug", "ce-code-review", "ce-simplify-code",
    "ce-commit", "ce-commit-push-pr", "ce-resolve-pr-feedback", "ce-compound", "ce-doc-review",
    "ce-ideate", "ce-pov", "ce-prototype", "ce-explain", "ce-babysit-pr", "lfg",
    # non-Compound workflows that would own a phase if they fired
    "code-review", "implement", "vercel-optimize",
    # owner-shaped workflows from the AWS and MLflow plugins
    "launch-with-aws", "fix-agent-issue",
}


def run_once(prompt, model=None, timeout=420):
    cmd = ["claude", "-p", prompt, "--output-format", "stream-json", "--verbose",
           "--permission-mode", "bypassPermissions",
           "--disallowedTools", "Edit", "Write", "NotebookEdit", "Bash", "Agent", "Task",
           "WebFetch", "WebSearch",
           "--append-system-prompt", DRY_RUN]
    if model:
        cmd += ["--model", model]
    try:
        p = subprocess.run(cmd, cwd=FIXTURE, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"skills": [], "cost": 0.0, "error": "timeout"}
    skills, cost, err = [], 0.0, None
    for line in p.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get("type") == "assistant":
            for c in d["message"].get("content", []):
                if c.get("type") == "tool_use" and c["name"] == "Skill":
                    n = (c.get("input") or {}).get("skill") or (c.get("input") or {}).get("command")
                    if n:
                        skills.append(str(n).lstrip("/").split(":")[-1])
        elif d.get("type") == "result":
            cost = d.get("total_cost_usd") or 0.0
            if d.get("is_error"):
                err = d.get("subtype")
    if not p.stdout.strip():
        err = err or (p.stderr.strip()[:200] or "no output")
    return {"skills": skills, "cost": cost, "error": err}


# A plugin may expose the same capability as both a skill and a slash command
# (static-analysis ships /semgrep-scan for the ungated run). Routing to either is
# the same decision, so the scorer folds the aliases together.
ALIASES = {"semgrep-scan": "semgrep", "diff-review": "differential-review",
           "audit": "insecure-defaults"}


def score(case, fired):
    s = {ALIASES.get(x, x) for x in fired}
    owners = s & OWNERS
    allowed_owners = set(case.get("owner_any", []))
    res = {
        "fired": sorted(s),
        "owners_fired": sorted(owners),
        "duplicate_owner": len(owners) > 1,
        # owner_optional: a lifecycle owner is welcome but not required — the work may be
        # small enough that the supporting skill alone is the right answer.
        "owner_ok": (not owners) if case.get("expect_no_owner")
                    else (not owners or bool(owners & allowed_owners)) if case.get("owner_optional")
                    else bool(owners & allowed_owners) if allowed_owners else True,
        "missing_support": sorted(set(case.get("require", [])) - s),
        "forbidden_fired": sorted(set(case.get("forbid", [])) & s),
        "unexpected": sorted(s - allowed_owners - set(case.get("require", []))
                             - set(case.get("allow", []))),
    }
    res["pass"] = (res["owner_ok"] and not res["duplicate_owner"]
                   and not res["missing_support"] and not res["forbidden_fired"])
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=os.path.join(ROOT, "corpus.jsonl"))
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--case", default=None, help="filter by id substring")
    ap.add_argument("--tag", default=None)
    ap.add_argument("--model", default=None)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    cases = [json.loads(l) for l in open(a.corpus) if l.strip() and not l.startswith("//")]
    if a.case:
        cases = [c for c in cases if a.case in c["id"]]
    if a.tag:
        cases = [c for c in cases if a.tag in c.get("tags", [])]

    jobs = [(c, i) for c in cases for i in range(a.runs)]
    print(f"{len(cases)} cases x {a.runs} runs = {len(jobs)} sessions\n", flush=True)
    results = collections.defaultdict(list)
    total_cost = 0.0
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = {ex.submit(run_once, c["prompt"], a.model): (c, i) for c, i in jobs}
        for f in cf.as_completed(futs):
            c, i = futs[f]
            r = f.result()
            total_cost += r["cost"]
            sc = score(c, r["skills"])
            sc["error"] = r["error"]
            results[c["id"]].append(sc)
            flag = "ok  " if sc["pass"] else "FAIL"
            print(f"  {flag} {c['id']:<26} run{i+1}  [{', '.join(sc['fired']) or '-'}]"
                  + (f"  !{r['error']}" if r["error"] else ""), flush=True)

    print()
    summary, hard_fail = [], 0
    for c in cases:
        rs = results[c["id"]]
        p = sum(1 for r in rs if r["pass"])
        dup = sum(1 for r in rs if r["duplicate_owner"])
        hard_fail += dup
        summary.append(dict(id=c["id"], tags=c.get("tags", []), prompt=c["prompt"],
                            passed=p, runs=len(rs), duplicate_owner_runs=dup, runs_detail=rs))
        print(f"  {p}/{len(rs)}  {c['id']:<26} dup-owner:{dup}")
    agg = dict(ranAt=datetime.datetime.now().isoformat(timespec="seconds"),
               model=a.model or "session default", runs=a.runs,
               cases=len(cases), sessions=len(jobs),
               passRate=round(sum(s["passed"] for s in summary) / max(1, len(jobs)), 3),
               duplicateOwnerRuns=hard_fail, costUsd=round(total_cost, 2), results=summary)
    out = a.out or os.path.join(ROOT, "results", f"run-{datetime.date.today().isoformat()}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump(agg, open(out, "w"), indent=2)
    print(f"\npass rate {agg['passRate']:.0%}   duplicate-owner runs {hard_fail}   "
          f"cost ${agg['costUsd']}   -> {out}")
    sys.exit(1 if hard_fail else 0)


if __name__ == "__main__":
    main()
