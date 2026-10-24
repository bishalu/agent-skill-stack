#!/usr/bin/env python3
"""The hooks of one host-ticket-runner run, and the step evaluation they share with htr.py.

Installed per run through `claude --settings <run>/settings.json`, never into the owner's
settings. Every hook reads the hook payload as JSON on stdin and takes its run directory
from `--run`:

  htr_hooks.py post-tool-use   --run DIR   records a marker (Skill, Bash, Edit/Write)
  htr_hooks.py post-tool-fail  --run DIR   records a failed Bash or Skill call
  htr_hooks.py pre-tool-use    --run DIR   denies reads of the real ~/.aws (the one deny)
  htr_hooks.py stop            --run DIR   blocks the end of the run until every step is shown
  htr_hooks.py evaluate        --run DIR   prints the evaluation as JSON (for people and tests)

Markers are one JSON object per line in DIR/markers.jsonl; line order is event order.
A hook that cannot read its payload or its run exits 0 and records nothing: a broken
recorder must not wedge the agent, and the Stop hook then reports the step as missing.

Standard library only, Python 3.9 or later, macOS, Linux and Windows.
"""
import datetime as _dt
import json
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------- command classes
# A Bash call is split into segments at && || ; | and newlines; a segment counts when it
# starts (after env assignments, `cd x`, `time`, `env`) with one of these. run.json may
# replace either pattern (--test-regex / --lint-regex at launch).
TEST_RE = (r"((uv|poetry|pipenv|hatch|pdm) run +)?(python3? +-m +)?(pytest|unittest|tox|nox)\b"
           r"|(npm|pnpm|yarn|bun)( +-C +\S+)?( +run)? +(test|e2e|gate)\b|npx +(vitest|jest|playwright)\b"
           r"|vitest\b|jest\b|go +test\b|cargo +test\b|(just|make|task) +(test|gate|check)[\w:-]*"
           r"|(bash|sh) +\S*test\S*\.sh\b|\S*\.test\.sh\b|(python3? +)?\S*_test\.py\b|swift +test\b|dotnet +test\b|mvn +test\b|gradle +test\b")
LINT_RE = (r"((uv|poetry|pipenv|hatch|pdm) run +)?(python3? +-m +)?(ruff|flake8|pylint|mypy|pyright|black +--check|isort +--check)\b"
           r"|(npm|pnpm|yarn|bun)( +-C +\S+)?( +run)? +(lint|typecheck|check|format:check|gate)\b|npx +(eslint|tsc|prettier)\b"
           r"|eslint\b|tsc\b|prettier +--check|shellcheck\b|golangci-lint\b|cargo +clippy\b|(just|make|task) +(lint|gate|check)[\w:-]*"
           r"|terraform +(fmt +-check|validate)\b|actionlint\b|markdownlint\b|python3? +\S*check-doc-\S+\.py\b")
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
LEAD_RE = re.compile(r"^(\s*(\w+=\S*|cd +\S+ *&&|time|env|command|exec|sudo +-E)\s+)*")

# The skills the lifecycle needs, by the name after any plugin namespace.
SKILL_STEPS = ["ce-plan", "ce-work", "ce-simplify-code", "ce-code-review", "ce-compound", "ce-commit-push-pr"]

# What the Stop hook tells the agent to do for each missing step. The ticket file and plan
# path are filled in from run.json.
STEP_HELP = {
    "ce-plan": "invoke the ce-plan skill with the ticket file {ticket} as the request (Durable contract), and commit the plan",
    "ce-work": "invoke the ce-work skill: `ce-work mode:return-to-caller {work_input}`",
    "ce-simplify-code": "invoke the ce-simplify-code skill on the branch diff",
    "ce-code-review": "invoke the ce-code-review skill: `ce-code-review apply:local plan:{work_input}`, then commit the findings it applied",
    "ce-compound": "invoke the ce-compound skill: `ce-compound mode:non-interactive depth:lightweight` (ending `Documentation skipped` is fine when nothing is non-obvious)",
    "ce-commit-push-pr": "invoke the ce-commit-push-pr skill: `ce-commit-push-pr mode:pipeline babysit:off`, which pushes {branch} and opens the PR",
    "tests": "run the project's test suite and get it green",
    "lint": "run the project's linters and get them green",
    "pr": "push every commit and open the PR for {branch} (ce-commit-push-pr)",
}


def now():
    return _dt.datetime.now(_dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def append_marker(run_dir, marker):
    marker = dict(marker)
    marker.setdefault("at", now())
    line = json.dumps(marker, ensure_ascii=False) + "\n"
    # One write call per line on an O_APPEND descriptor: concurrent hooks (a subagent's
    # tool calls) never interleave inside a line.
    fd = os.open(os.path.join(run_dir, "markers.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)


def read_markers(run_dir):
    out = []
    try:
        with open(os.path.join(run_dir, "markers.jsonl"), encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                if isinstance(m, dict):
                    out.append(m)
    except OSError:
        pass
    return out


def skill_name(raw):
    """`compound-engineering:ce-work` and `/ce-work` are both `ce-work`."""
    s = str(raw or "").strip().lstrip("/")
    return s.rsplit(":", 1)[-1]


def segments(command):
    return [s.strip() for s in re.split(r"&&|\|\||;|\||\n", command or "") if s.strip()]


def classify(command, test_re=TEST_RE, lint_re=LINT_RE):
    """The set of classes (test, lint) a Bash command is evidence for."""
    kinds = set()
    for seg in segments(command):
        seg = LEAD_RE.sub("", seg)
        if re.match(r"(%s)" % test_re, seg):
            kinds.add("test")
        if re.match(r"(%s)" % lint_re, seg):
            kinds.add("lint")
    return kinds


def masked(command):
    """A command whose failure cannot reach its exit code proves nothing either way."""
    return bool(re.search(r"\|\|\s*(true|:|exit +0)\b|;\s*(true|:)\s*$|\|\s*(tee|head|tail|grep|cat)\b", command or ""))


# ---------------------------------------------------------------- markers from tool calls
def marker_for(payload, failed):
    tool = payload.get("tool_name") or ""
    ti = payload.get("tool_input") or {}
    base = {"tool": tool, "agent": payload.get("agent_id") or None}
    if tool == "Skill":
        name = skill_name(ti.get("skill"))
        return dict(base, kind="skill", skill=name, raw=ti.get("skill"), args=str(ti.get("args") or "")[:300],
                    ok=not failed)
    if tool == "Bash":
        cmd = str(ti.get("command") or "")
        code = 0
        if failed:
            m = re.search(r"[Ee]xit code (\d+)", str(payload.get("error") or ""))
            code = int(m.group(1)) if m else 1
        return dict(base, kind="bash", command=cmd[:2000], exit=code, interrupted=bool(payload.get("is_interrupt")))
    if tool in EDIT_TOOLS:
        path = ti.get("file_path") or ti.get("notebook_path") or ""
        return dict(base, kind="edit", path=str(path))
    return None


# ---------------------------------------------------------------- the real ~/.aws
def real_aws_dirs(run):
    dirs = set()
    for d in (run or {}).get("real_aws_dirs") or []:
        dirs.add(d)
    home = os.path.expanduser("~")
    dirs.add(os.path.join(home, ".aws"))
    out = set()
    for d in dirs:
        out.add(os.path.normcase(os.path.abspath(d)))
        try:
            out.add(os.path.normcase(os.path.realpath(d)))
        except OSError:
            pass
    return out


def touches_real_aws(payload, run):
    """The reason this tool call reaches into the real ~/.aws, or None."""
    tool = payload.get("tool_name") or ""
    ti = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    dirs = real_aws_dirs(run)
    if tool == "Bash":
        cmd = str(ti.get("command") or "")
        home = re.escape(os.path.expanduser("~").replace("\\", "/"))
        pats = [r"(~|\$HOME|\$\{HOME\}|%USERPROFILE%|\$env:USERPROFILE|" + home + r")[/\\]+\.aws\b",
                r"(^|[\s'\"=/\\])\.aws[/\\]+(credentials|config|sso|cli|login)\b"]
        for p in pats:
            if re.search(p, cmd.replace("\\\\", "\\"), re.IGNORECASE):
                return "the command names the real ~/.aws"
        return None
    for key in ("file_path", "path", "notebook_path", "pattern"):
        v = ti.get(key)
        if not v or not isinstance(v, str):
            continue
        p = os.path.expanduser(v)
        if not os.path.isabs(p):
            base = ti.get("path") if key == "pattern" and isinstance(ti.get("path"), str) else cwd
            p = os.path.join(os.path.expanduser(base), p)
        cands = {os.path.normcase(os.path.abspath(p))}
        try:
            cands.add(os.path.normcase(os.path.realpath(p)))
        except OSError:
            pass
        for c in cands:
            for d in dirs:
                if c == d or c.startswith(d.rstrip("/\\") + os.sep) or c.startswith(d.rstrip("/\\") + "/"):
                    return "%s %s is inside the real ~/.aws" % (key, v)
    return None


# ---------------------------------------------------------------- evaluation
def git(worktree, *args):
    try:
        r = subprocess.run(["git", "-C", worktree] + list(args), capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, "", str(e)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def pr_state(run):
    """(pr dict or None, problem or None) for the run's branch, read from GitHub now."""
    if os.environ.get("HTR_FAKE_PR"):   # tests: a JSON file standing in for `gh pr view`
        return read_json(os.environ["HTR_FAKE_PR"]), None
    cmd = ["gh", "pr", "view", run["branch"], "-R", run["repo"], "--json", "number,url,state,headRefOid,body,isDraft"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, "gh pr view could not run: %s" % e
    if r.returncode != 0:
        msg = (r.stderr or r.stdout).strip().splitlines()
        return None, "no PR for %s yet (gh: %s)" % (run["branch"], msg[-1] if msg else "exit %d" % r.returncode)
    try:
        return json.loads(r.stdout), None
    except ValueError:
        return None, "gh pr view printed no JSON"


def last_index(markers, pred):
    idx = -1
    for i, m in enumerate(markers):
        if pred(m):
            idx = i
    return idx


def first_index(markers, pred):
    for i, m in enumerate(markers):
        if pred(m):
            return i
    return -1


def evaluate(run_dir, run=None, markers=None, check_pr=True):
    """What the markers and the repository show, step by step.

    Returns {"missing": [{"step", "why", "do"}...], "done": [...], "pr": {...} or None}.
    A step is done only from recorded evidence: a Skill marker, a Bash marker with its exit
    code, the worktree's git state and the PR as GitHub reports it. Nothing the agent says
    counts.
    """
    run = run or read_json(os.path.join(run_dir, "run.json"), {})
    markers = read_markers(run_dir) if markers is None else markers
    test_re = run.get("test_regex") or TEST_RE
    lint_re = run.get("lint_regex") or LINT_RE
    worktree = run.get("worktree") or ""
    required = run.get("required") or []
    fill = {"ticket": run.get("ticket_file", "the ticket file"), "branch": run.get("branch", "the branch"),
            "work_input": run.get("work_input") or run.get("ticket_file", "the ticket file")}
    missing, done = [], []

    def miss(step, why):
        missing.append({"step": step, "why": why, "do": STEP_HELP.get(step, step).format(**fill)})

    def is_skill(name):
        return lambda m: m.get("kind") == "skill" and m.get("skill") == name and m.get("ok", True)

    for step in [s for s in SKILL_STEPS if s in required]:
        if first_index(markers, is_skill(step)) < 0:
            miss(step, "no %s skill call is recorded" % step)
        else:
            done.append(step)

    # Order: plan before work, work before review, review before the shipping call.
    w = first_index(markers, is_skill("ce-work"))
    if "ce-plan" in required and w >= 0 and "ce-plan" in done and first_index(markers, is_skill("ce-plan")) > w:
        miss("ce-work", "ce-work ran before ce-plan; run it again on the plan")
    r_last = last_index(markers, is_skill("ce-code-review"))
    if "ce-code-review" in done and w >= 0 and r_last < w:
        miss("ce-code-review", "ce-code-review ran before ce-work; review the finished change")
    s_last = last_index(markers, is_skill("ce-commit-push-pr"))
    if "ce-commit-push-pr" in done and r_last >= 0 and s_last < r_last:
        miss("ce-commit-push-pr", "the last ce-code-review came after the last ce-commit-push-pr; ship the reviewed change")

    edit_last = last_index(markers, lambda m: m.get("kind") == "edit" and _inside(m.get("path"), worktree))
    for step, rx in (("tests", test_re), ("lint", lint_re)):
        if step not in required:
            continue
        runs = [(i, m) for i, m in enumerate(markers) if m.get("kind") == "bash" and step[:4] in classify(m.get("command"), test_re, lint_re)]
        if not runs:
            miss(step, "no %s command is recorded" % ("test" if step == "tests" else "lint"))
            continue
        i, m = runs[-1]
        if m.get("exit") != 0:
            miss(step, "the last %s run exited %s: %s" % (step, m.get("exit"), m.get("command", "")[:160]))
        elif masked(m.get("command")):
            miss(step, "the last %s run masks its exit code (%s); run it plainly" % (step, m.get("command", "")[:160]))
        elif i < edit_last:
            miss(step, "files changed after the last passing %s run; run it again" % step)
        else:
            done.append(step)

    pr = None
    if "pr" in required and check_pr:
        problems = []
        code, head, err = git(worktree, "rev-parse", "HEAD")
        code2, dirt, _ = git(worktree, "status", "--porcelain", "--untracked-files=normal")
        if code != 0:
            problems.append("cannot read the worktree HEAD: %s" % err)
        elif dirt:
            problems.append("the worktree has uncommitted changes: %s" % ", ".join(l[3:] for l in dirt.splitlines()[:5]))
        pr, why = pr_state(run)
        if why:
            problems.append(why)
        elif pr:
            if pr.get("state") not in ("OPEN", "MERGED"):
                problems.append("PR %s is %s" % (pr.get("url"), pr.get("state")))
            if code == 0 and pr.get("headRefOid") and pr.get("headRefOid") != head:
                problems.append("PR head %s is not the worktree HEAD %s; push" % (pr["headRefOid"][:12], head[:12]))
            body = pr.get("body") or ""
            ids = [c["id"] for c in run.get("criteria") or []]
            absent = [i for i in ids if not re.search(r"(?<![\w.])%s(?![\w])" % re.escape(i), body)]
            if absent:
                problems.append("the PR body does not cite criteria %s" % ", ".join(absent))
            if not re.search(r"(?im)^#+ .*review", body):
                problems.append("the PR body has no heading naming the review findings (applied and residual)")
        if problems:
            missing.append({"step": "pr", "why": "; ".join(problems),
                            "do": "fix this, then update the PR (git push, and `gh pr edit %s -R %s --body-file <file>` for the body)" % (run.get("branch"), run.get("repo"))})
        else:
            done.append("pr")
    return {"missing": missing, "done": done, "pr": pr}


def _inside(path, root):
    if not path or not root:
        return False
    try:
        p = os.path.normcase(os.path.realpath(path))
        r = os.path.normcase(os.path.realpath(root))
    except OSError:
        return False
    return p == r or p.startswith(r.rstrip("/\\") + os.sep)


# ---------------------------------------------------------------- the Stop hook
def stop_decision(run_dir, payload, run=None, markers=None, ev=None):
    """(output dict or None, marker dict). None output means: let the run end."""
    run = run or read_json(os.path.join(run_dir, "run.json"), {})
    markers = read_markers(run_dir) if markers is None else markers
    ev = ev or evaluate(run_dir, run, markers)
    missing = ev["missing"]
    active = bool(payload.get("stop_hook_active"))
    budget = run.get("budgets") or {}
    max_blocks = int(budget.get("stop_blocks", 8))
    max_stall = int(budget.get("stalled_blocks", 2))
    keys = sorted("%s: %s" % (m["step"], m["why"]) for m in missing)

    if not missing:
        write_json(os.path.join(run_dir, "complete.json"), {"at": now(), "done": ev["done"], "pr": (ev.get("pr") or {}).get("url")})
        return None, {"kind": "stop", "decision": "allow", "stop_hook_active": active, "reason": "every required step is shown"}

    blocks = [m for m in markers if m.get("kind") == "stop" and m.get("decision") == "block"]
    # A stall: the hook already blocked, the agent stopped again (stop_hook_active) with the
    # same steps missing and no tool call recorded in between.
    stalled = 0
    if active and blocks:
        last_block = max(i for i, m in enumerate(markers) if m.get("kind") == "stop" and m.get("decision") == "block")
        progressed = any(m.get("kind") in ("skill", "bash", "edit") for m in markers[last_block + 1:])
        prev = markers[last_block]
        stalled = 0 if progressed or prev.get("missing") != keys else int(prev.get("stalled", 0)) + 1
    if len(blocks) >= max_blocks or stalled >= max_stall:
        why = ("the Stop hook has blocked %d times (budget %d)" % (len(blocks), max_blocks) if len(blocks) >= max_blocks
               else "the agent stopped %d times in a row with nothing done in between (budget %d)" % (stalled + 1, max_stall))
        write_escalation(run_dir, run, missing, why, payload)
        return ({"systemMessage": "host-ticket-runner: escalated (%s); see %s" % (why, os.path.join(run_dir, "escalation.md"))},
                {"kind": "stop", "decision": "escalate", "stop_hook_active": active, "missing": keys, "reason": why})

    lines = ["host-ticket-runner: this run cannot end yet. The Stop hook reads what your tool calls recorded, "
             "not what you report. Still missing, in order:"]
    for n, m in enumerate(missing, 1):
        lines.append("%d. %s: %s. Do: %s." % (n, m["step"], m["why"], m["do"]))
    lines.append("Do them now, then stop. (Block %d of %d.)" % (len(blocks) + 1, max_blocks))
    return ({"decision": "block", "reason": "\n".join(lines)},
            {"kind": "stop", "decision": "block", "stop_hook_active": active, "missing": keys, "stalled": stalled})


def write_escalation(run_dir, run, missing, why, payload):
    rid = os.path.basename(run_dir.rstrip("/\\"))
    text = ["# Escalation: %s" % rid, "",
            "Ticket: %s#%s. Branch: %s. Worktree: %s." % (run.get("repo"), run.get("issue"), run.get("branch"), run.get("worktree")), "",
            "Why the run stopped: %s." % why, "", "Steps the markers do not show:", ""]
    text += ["- **%s**: %s" % (m["step"], m["why"]) for m in missing]
    last = str(payload.get("last_assistant_message") or "").strip()
    if last:
        text += ["", "The agent's last message:", "", "> " + last[:2000].replace("\n", "\n> ")]
    text += ["", "Next: read the log (%s) and the markers (%s), then either give one finishing turn" % (
        os.path.join(run_dir, "agent.log"), os.path.join(run_dir, "markers.jsonl")),
             "(`htr.py resume --run %s --send --extend`) or take the ticket back by hand." % rid, ""]
    with open(os.path.join(run_dir, "escalation.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(text))


# ---------------------------------------------------------------- entry point
def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    verb = argv.pop(0)
    run_dir = None
    if "--run" in argv:
        i = argv.index("--run")
        run_dir = argv[i + 1] if i + 1 < len(argv) else None
    run_dir = run_dir or os.environ.get("HTR_RUN_DIR")
    if not run_dir or not os.path.isdir(run_dir):
        print("htr_hooks: no run directory (--run DIR or HTR_RUN_DIR)", file=sys.stderr)
        return 0 if verb != "evaluate" else 2
    run = read_json(os.path.join(run_dir, "run.json"), {})
    if verb == "evaluate":
        print(json.dumps(evaluate(run_dir, run), indent=2))
        return 0
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0
    if verb in ("post-tool-use", "post-tool-fail"):
        m = marker_for(payload, verb == "post-tool-fail")
        if m:
            append_marker(run_dir, m)
        return 0
    if verb == "pre-tool-use":
        why = touches_real_aws(payload, run)
        if why:
            append_marker(run_dir, {"kind": "aws-deny", "tool": payload.get("tool_name"), "why": why})
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse", "permissionDecision": "deny",
                "permissionDecisionReason": ("host-ticket-runner: %s. Launched agents never read the host's AWS "
                                             "credentials. This run already has the provisioned profile (AWS_PROFILE=%s); "
                                             "if a call is denied with it, record the exact call under 'Owner actions needed' "
                                             "in the PR body and continue.") % (why, run.get("aws_profile", "htr-agent"))}}))
        return 0
    if verb == "stop":
        out, marker = stop_decision(run_dir, payload, run)
        append_marker(run_dir, marker)
        if out:
            print(json.dumps(out))
        return 0
    print("htr_hooks: unknown verb %s" % verb, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
