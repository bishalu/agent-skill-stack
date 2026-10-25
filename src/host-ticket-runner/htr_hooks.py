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
# A single `&` (not `&&`, `2>&1`, `&>`) sends what precedes it to the background.
SEP = r"&&|\|\||\|&|;|\||(?<![&>])&(?![&>])|\n"
# A test or lint segment that names one of these is not a run of the suite: it prints a
# version or help, lists tests, or runs a hand-picked subset.
NOT_A_RUN = re.compile(r"(^|\s)(--version|-V|--help|-h|--collect-only|--co|--list|--listTests)(\s|=|$)")
SUBSET = re.compile(r"(^|\s)(-k|-t|--testNamePattern|--grep|-g|-run|--lf|--last-failed|--deselect|--only)(\s|=|$)|::")
DEFAULT_BUDGETS = {"stop_blocks": 8, "stalled_blocks": 2, "finishing_turns": 2}
LEAD_RE = re.compile(r"^(\s*(\w+=\S*|cd +\S+ *&&|time|env|command|exec|sudo +-E)\s+)*")

# The skills the lifecycle needs, by the name after any plugin namespace.
SKILL_STEPS = ["ce-plan", "ce-work", "ce-simplify-code", "ce-code-review", "ce-compound", "ce-commit-push-pr"]
ORDER = SKILL_STEPS[:-1] + ["tests", "lint", "ce-commit-push-pr", "pr"]

# The lifecycle phases, in order, and the steps each owns. A run.json with a "phases" list
# (launched since phases existed) runs one turn per phase; one without it is one turn for the
# whole cycle, as every run before them was. ce-debug is never a required step: when the agent
# uses it, it is judge work.
PHASES = ["build", "judge", "finish"]
PHASE_STEPS = {
    "build": ["ce-plan", "ce-work", "ce-simplify-code"],
    "judge": ["ce-debug", "ce-code-review"],
    "finish": ["ce-compound", "tests", "lint", "ce-commit-push-pr", "pr"],
}

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


HEREDOC = re.compile(r"<<-?[ \t]*(['\"]?)(\w+)\1[^\n]*\n(?:.*?\n)?[ \t]*\2[ \t]*(?=\n|$)", re.S)


def without_heredocs(command):
    """A heredoc's body is input, not commands: `pytest` written into a file is not a test run."""
    return HEREDOC.sub(lambda m: m.group(0).split("\n", 1)[0], command or "")


QUOTED = re.compile(r"'[^']*'|\"(?:\\.|[^\"\\])*\"")


def plain(command):
    """The command with heredoc bodies dropped and separators inside quotes blanked:
    `pgrep -f "pytest|vitest"` is one pgrep, not a pipe into vitest."""
    return QUOTED.sub(lambda m: re.sub(SEP, " ", m.group(0)), without_heredocs(command))


def segments(command):
    return [s.strip() for s in re.split(SEP, plain(command)) if s.strip()]


def classify(command, test_re=TEST_RE, lint_re=LINT_RE):
    """The set of classes (test, lint) a Bash command is evidence for."""
    kinds = set()
    for seg in segments(command):
        seg = LEAD_RE.sub("", seg)
        if NOT_A_RUN.search(seg):
            continue
        if re.match(r"(%s)" % test_re, seg) and not SUBSET.search(seg):
            kinds.add("test")
        if re.match(r"(%s)" % lint_re, seg):
            kinds.add("lint")
    return kinds


RUNNER_PREFIX = re.compile(r"^((uv|poetry|pipenv|hatch|pdm) +run +)?(python3? +-m +)?")
GATE_KEY = re.compile(r"^((just|make|task) +(gate|check)|(npm|pnpm|yarn|bun)( +-C +\S+)?( +run)? +gate)\b")


def suites(command, kind, test_re=TEST_RE, lint_re=LINT_RE):
    """The suites a Bash command runs for `kind`, each named by the words that matched.

    `uv run pytest` and `pytest` are one suite; `pnpm -C web test` and `pnpm test` are two,
    since they can run from different folders. After the last edit every suite is judged by
    its own latest run, so a green web run after a red Python run does not stand in for it;
    before it, only a suite whose latest run failed still counts."""
    pattern = test_re if kind == "test" else lint_re
    out = []
    for seg in segments(command):
        seg = LEAD_RE.sub("", seg)
        if kind not in classify(seg, test_re, lint_re):
            continue
        m = re.match(r"(%s)" % pattern, seg)
        if m:
            out.append(RUNNER_PREFIX.sub("", " ".join(m.group(0).split())))
    return out


def masked(command, kind=None, test_re=TEST_RE, lint_re=LINT_RE):
    """Whether the command's exit code can hide the failure of its last `kind` segment.

    The exit code is that segment's own only when everything after it is chained with
    `&&`: a `;`, a newline, a pipe or `||` after it (`pytest; echo $?`, `ruff | tail`,
    `pytest || true`) hands the exit code to something else, and a `&` after it
    (`pytest &`) sends it to the background."""
    parts = re.split("(%s)" % SEP, plain(command))
    segs, seps = parts[0::2], parts[1::2]
    last = None
    for i, seg in enumerate(segs):
        k = classify(seg, test_re, lint_re)
        if (kind in k) if kind else k:
            last = i
    if last is None:
        return False
    return any(sep == "&" or (sep != "&&" and segs[j + 1].strip()) for j, sep in enumerate(seps) if j >= last)


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
        # A command sent to the background (asked for, or moved there by the harness when it
        # ran long) reports success when it starts, not when it ends: no exit code to trust.
        resp = payload.get("tool_response")
        background = bool(ti.get("run_in_background")) or (
            isinstance(resp, dict) and any(resp.get(k) for k in ("backgroundTaskId", "background_task_id", "backgroundedByUser")))
        if background and not failed:
            code = None
        return dict(base, kind="bash", command=cmd[:2000], exit=code, background=background,
                    interrupted=bool(payload.get("is_interrupt")))
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


# macOS and Windows file systems are case-insensitive by default: ~/.AWS is ~/.aws.
FOLD = str.lower if sys.platform in ("darwin", "win32") else (lambda s: s)
SEARCH_TOOLS = {"Grep", "Glob"}


def _forms(p):
    out = {FOLD(os.path.normcase(os.path.abspath(p)))}
    try:
        out.add(FOLD(os.path.normcase(os.path.realpath(p))))
    except OSError:
        pass
    return {o.rstrip("/\\") or o for o in out}


def _within(child, parent):
    return child == parent or child.startswith(parent.rstrip("/\\") + os.sep) or child.startswith(parent.rstrip("/\\") + "/")


def _same_or_under(p, d):
    """Whether p is d or inside it, by name (case-folded where the file system folds case)
    and by file identity for any existing ancestor of p (another spelling or a hard link)."""
    if any(_within(c, x) for c in _forms(p) for x in _forms(d)):
        return True
    if not os.path.exists(d):
        return False
    cur = os.path.abspath(p)
    while True:
        try:
            if os.path.exists(cur) and os.path.samefile(cur, d):
                return True
        except OSError:
            pass
        up = os.path.dirname(cur)
        if up == cur:
            return False
        cur = up


def _bash_reaches_real_aws(cmd, run):
    """The reason a Bash command reaches the real ~/.aws, or None. This reads command text,
    so it catches the spellings below and not every possible one."""
    text = cmd.replace("\\\\", "\\")
    home = re.escape(os.path.expanduser("~").replace("\\", "/"))
    homes = r"(~|\$HOME|\$\{HOME\}|%USERPROFILE%|\$env:USERPROFILE|" + home + r")"
    checks = [
        (homes + r"[/\\]+\.aws\b", "the command names the real ~/.aws"),
        (r"(^|[\s'\"=:/\\(])\.aws([/\\'\"\s)]|$)", "the command names a .aws directory"),
        # Without the runner's AWS_* variables the CLI and SDKs fall back to ~/.aws.
        (r"\benv\b[^;&|\n]*\s(-i|--ignore-environment|-u\s*AWS_\w*|--unset[=\s]*AWS_\w*)\b", "the command drops the runner's AWS environment"),
        (r"\bunset\b[^;&|\n]*\bAWS_", "the command unsets the runner's AWS environment"),
        (r"\bAWS_(SHARED_CREDENTIALS_FILE|CONFIG_FILE)\s*=", "the command repoints the AWS credential or config file"),
        # A recursive search or copy from home or the root walks into ~/.aws.
        (r"\b(grep|egrep|rg|ag|ack|find|fd|tar|zip|rsync|cp|scp|du)\b[^;&|\n]*\s['\"]?(" + homes[1:-1] +
         r"|/|/Users|/home|[A-Za-z]:)[/\\]?['\"]?(\s|$)", "the command searches or copies from home or the root, which includes ~/.aws"),
    ]
    for pat, why in checks:
        if re.search(pat, text, re.IGNORECASE):
            return why
    m = re.search(r"\bAWS_(DEFAULT_)?PROFILE\s*=\s*['\"]?([\w.-]*)", text)
    if m and m.group(2) != (run or {}).get("aws_profile", "htr-agent"):
        return "the command switches to AWS profile %r, not the runner's" % m.group(2)
    return None


def touches_real_aws(payload, run):
    """The reason this tool call reaches into the real ~/.aws, or None."""
    tool = payload.get("tool_name") or ""
    ti = payload.get("tool_input") or {}
    if tool == "Bash":
        return _bash_reaches_real_aws(str(ti.get("command") or ""), run)
    cwd = payload.get("cwd") or os.getcwd()
    dirs = real_aws_dirs(run)
    paths = []
    for key in ("file_path", "path", "notebook_path"):
        v = ti.get(key)
        if v and isinstance(v, str):
            paths.append((key, os.path.join(cwd, os.path.expanduser(v))))
    if tool in SEARCH_TOOLS:
        base = os.path.join(cwd, os.path.expanduser(ti.get("path"))) if isinstance(ti.get("path"), str) and ti.get("path") else cwd
        root = base
        pat = os.path.expanduser(ti.get("pattern")) if tool == "Glob" and isinstance(ti.get("pattern"), str) else ""
        if pat:
            # A Glob pattern's fixed leading folders are where the walk starts.
            fixed = os.path.dirname(re.split(r"[*?\[{]", pat, 1)[0])
            root = os.path.join(base, fixed) if fixed else base
            paths.append(("pattern", os.path.join(base, pat)))
        # A search rooted at ~/.aws, or at any folder that contains it, walks into it.
        for d in dirs:
            if _same_or_under(d, root):
                return "%s from %s walks into the real ~/.aws" % (tool, root)
    for key, p in paths:
        for d in dirs:
            if _same_or_under(p, d):
                return "%s %s is inside the real ~/.aws" % (key, ti.get(key))
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

    outside = 0
    if run.get("phases") and "ce-code-review" in required:
        markers, outside = judged_reviews(markers)

    for step in [s for s in SKILL_STEPS if s in required]:
        if first_index(markers, is_skill(step)) < 0:
            miss(step, ("ce-code-review ran only outside the judge phase's turn; it counts only there, on the judge's "
                        "model" if step == "ce-code-review" and outside else "no %s skill call is recorded" % step))
        else:
            done.append(step)

    # Order: plan before work, work before review, review before the shipping call.
    w_last = last_index(markers, is_skill("ce-work"))
    if "ce-plan" in done and w_last >= 0 and w_last < first_index(markers, is_skill("ce-plan")):
        miss("ce-work", "ce-work ran only before ce-plan; run it again on the plan")
    r_last = last_index(markers, is_skill("ce-code-review"))
    changed_last = max(w_last, last_index(markers, is_skill("ce-simplify-code")))
    if "ce-code-review" in done and changed_last >= 0 and r_last < changed_last:
        miss("ce-code-review", "the last ce-code-review came before the last ce-work or ce-simplify-code; review the finished change")
    s_last = last_index(markers, is_skill("ce-commit-push-pr"))
    if "ce-commit-push-pr" in done and r_last >= 0 and s_last < r_last:
        miss("ce-commit-push-pr", "the last ce-code-review came after the last ce-commit-push-pr; ship the reviewed change")

    edit_last = last_index(markers, lambda m: m.get("kind") == "edit" and _inside(m.get("path"), worktree))
    for step, kind in (("tests", "test"), ("lint", "lint")):
        if step not in required:
            continue
        runs = [(i, m) for i, m in enumerate(markers) if m.get("kind") == "bash" and kind in classify(m.get("command"), test_re, lint_re)]
        if not runs:
            miss(step, "no %s command is recorded" % kind)
            continue
        latest = {}
        for i, m in runs:
            for key in suites(m.get("command"), kind, test_re, lint_re):
                latest[key] = (i, m)
        gate_after_edit = any(i > edit_last and m.get("exit") == 0 and not m.get("background")
                              and not masked(m.get("command"), kind, test_re, lint_re)
                              and any(GATE_KEY.match(k) for k in suites(m.get("command"), kind, test_re, lint_re))
                              for i, m in runs)
        problems = []
        last_i, last_m = runs[-1]
        if last_i < edit_last:
            problems.append("files changed after the last %s run; run it again" % kind)
        for key, (i, m) in sorted(latest.items(), key=lambda kv: kv[1][0]):
            cmd = m.get("command", "")[:160]
            if i < edit_last:
                # Before the last edit only a red suite still counts: it has not been shown green since.
                if m.get("exit") not in (0, None) and not gate_after_edit:
                    problems.append("the last `%s` run exited %s and it has not passed since: %s" % (key, m.get("exit"), cmd))
                continue
            if m.get("background"):
                problems.append("the last `%s` run went to the background, so its exit code is unknown; run it in the "
                                "foreground (a longer Bash timeout, not run_in_background): %s" % (key, cmd))
            elif m.get("exit") != 0:
                problems.append("the last `%s` run exited %s: %s" % (key, m.get("exit"), cmd))
            elif masked(m.get("command"), kind, test_re, lint_re):
                problems.append("the last `%s` run masks its exit code (%s); run it plainly" % (key, cmd))
        if problems:
            miss(step, "; ".join(problems))
        else:
            done.append(step)

    pr = None
    if "pr" in required and check_pr:
        problems = []
        code, head, err = git(worktree, "rev-parse", "HEAD")
        _, dirt, _ = git(worktree, "status", "--porcelain", "--untracked-files=normal")
        if code != 0:
            problems.append("cannot read the worktree HEAD: %s" % err)
        elif dirt:
            problems.append("the worktree has uncommitted changes: %s" % ", ".join(l[3:] for l in dirt.splitlines()[:5]))
        pr, why = pr_state(run)
        if why or not pr:
            problems.append(why or "no PR for %s" % run.get("branch"))
        else:
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
            do = (STEP_HELP["pr"].format(**fill) if not pr else
                  "fix this, then update the PR (git push, and `gh pr edit %s -R %s --body-file <file>` for the body)" % (run.get("branch"), run.get("repo")))
            missing.append({"step": "pr", "why": "; ".join(problems), "do": do})
        else:
            done.append("pr")
    # Report in the order the work is done: tests and lint come after ce-compound (its
    # learning is an edit) and before the shipping call.
    missing.sort(key=lambda m: ORDER.index(m["step"]) if m["step"] in ORDER else len(ORDER))
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


# ---------------------------------------------------------------- phases
def is_turn_start(m):
    return m.get("kind") == "turn" and m.get("event") == "start"


def judged_reviews(markers):
    """(markers, how many reviews were set aside): a phased run's ce-code-review calls outside a
    judge-phase turn are marked not ok, so they do not count. The judge phase is the turn on
    the judge's model; a review on the build or finish model is not the one the tier routes."""
    out, phase, outside = [], None, 0
    for m in markers:
        if is_turn_start(m):
            phase = m.get("phase")
        if m.get("kind") == "skill" and m.get("skill") == "ce-code-review" and m.get("ok", True) and phase != "judge":
            m, outside = dict(m, ok=False), outside + 1
        out.append(m)
    return out, outside


def step_lines(missing):
    """The numbered missing-step lines a block, a phase turn and a finishing turn all show."""
    return ["%d. %s: %s. Do: %s." % (i, m.get("step"), m.get("why", ""), m.get("do", "")) for i, m in enumerate(missing, 1)]


def phase_index(run, step):
    phases = run.get("phases") or []
    for i, p in enumerate(phases):
        if step in (p.get("steps") or []):
            return i
    return len(phases) - 1


def first_missing_phase(run, missing):
    phases = run.get("phases") or []
    if not phases:
        return None
    return phases[phase_index(run, missing[0]["step"])] if missing else phases[-1]


def missing_through(run, missing, idx):
    """(due, later): the missing steps of phase `idx` or an earlier one, and the rest."""
    due = [m for m in missing if phase_index(run, m["step"]) <= idx]
    return due, [m for m in missing if phase_index(run, m["step"]) > idx]


def current_phase_index(run, markers, missing):
    """The phase of the turn now ending, from its start marker; else that of the first missing
    step (`missing` is not empty)."""
    names = [p.get("name") for p in run.get("phases") or []]
    start = last_index(markers, is_turn_start)
    name = markers[start].get("phase") if start >= 0 else None
    return names.index(name) if name in names else phase_index(run, missing[0]["step"])


# ---------------------------------------------------------------- the Stop hook
def stop_decision(run_dir, payload, run=None, markers=None, ev=None):
    """(output dict or None, marker dict). None output means: let the run (or, in a phased
    run, this phase's turn) end."""
    run = run or read_json(os.path.join(run_dir, "run.json"), {})
    markers = read_markers(run_dir) if markers is None else markers
    ev = ev or evaluate(run_dir, run, markers)
    missing = ev["missing"]
    active = bool(payload.get("stop_hook_active"))
    phases = run.get("phases") or []
    phase, due, more = None, missing, False
    if phases and missing and run.get("required"):
        cur = current_phase_index(run, markers, missing)
        phase, more = phases[cur].get("name"), cur < len(phases) - 1
        due, later = missing_through(run, missing, cur)
        if phase != "judge" and any(m["step"] == "ce-code-review" for m in due):
            # A review reopened after the judge's turn counts only in a judge turn, so this turn
            # ends; the supervisor goes forward only, and `htr resume` routes to the judge.
            due, later = [], missing
        if not due:
            nxt = first_missing_phase(run, missing).get("name")
            # The next phase's turn opens with these, so the supervisor need not evaluate again.
            return None, {"kind": "stop", "decision": "phase-done", "stop_hook_active": active, "phase": phase,
                          "next": nxt, "missing_detail": later,
                          "reason": "every step of the %s phase is shown; %s comes next" % (phase, nxt)}
    budget = run.get("budgets") or {}
    max_blocks = int(budget.get("stop_blocks", DEFAULT_BUDGETS["stop_blocks"]))
    max_stall = int(budget.get("stalled_blocks", DEFAULT_BUDGETS["stalled_blocks"]))
    keys = sorted("%s: %s" % (m["step"], m["why"]) for m in due)

    if not run.get("required"):
        # An unreadable run.json leaves nothing to check; that is not a finished run.
        why = "run.json is missing, unreadable or lists no required steps"
        write_escalation(run_dir, run, missing, why, payload)
        return ({"systemMessage": "host-ticket-runner: escalated (%s); see %s" % (why, os.path.join(run_dir, "escalation.md"))},
                {"kind": "stop", "decision": "escalate", "stop_hook_active": active, "missing": keys, "reason": why})

    if not missing:
        write_json(os.path.join(run_dir, "complete.json"), {"at": now(), "done": ev["done"], "pr": (ev.get("pr") or {}).get("url")})
        return None, {"kind": "stop", "decision": "allow", "stop_hook_active": active, "reason": "every required step is shown"}

    # The block budget is per turn: a finishing turn (resume) starts with a fresh one.
    turn_start = last_index(markers, is_turn_start)
    blocks = [m for m in markers[turn_start + 1:] if m.get("kind") == "stop" and m.get("decision") == "block"]
    # A stall: the hook already blocked, the agent stopped again (stop_hook_active) with the
    # same steps missing and no tool call recorded in between.
    stalled = 0
    if active and blocks:
        last_block = last_index(markers, lambda m: m.get("kind") == "stop" and m.get("decision") == "block")
        progressed = any(m.get("kind") in ("skill", "bash", "edit") for m in markers[last_block + 1:])
        prev = markers[last_block]
        stalled = 0 if progressed or prev.get("missing") != keys else int(prev.get("stalled", 0)) + 1
    if len(blocks) >= max_blocks or stalled >= max_stall:
        why = ("the Stop hook has blocked %d times (budget %d)" % (len(blocks), max_blocks) if len(blocks) >= max_blocks
               else "the agent stopped %d times in a row with nothing done in between (budget %d)" % (stalled + 1, max_stall))
        write_escalation(run_dir, run, missing, why, payload)
        return ({"systemMessage": "host-ticket-runner: escalated (%s); see %s" % (why, os.path.join(run_dir, "escalation.md"))},
                {"kind": "stop", "decision": "escalate", "stop_hook_active": active, "missing": keys, "reason": why})

    what = "the %s phase of this run" % phase if phase else "this run"
    lines = ["host-ticket-runner: %s cannot end yet. The Stop hook reads what your tool calls recorded, "
             "not what you report. Still missing, in order:" % what]
    lines += step_lines(due)
    lines.append("Do them now, then stop.%s (Block %d of %d.)" % (
        " The later phases come in their own turns." if more else "", len(blocks) + 1, max_blocks))
    marker = {"kind": "stop", "decision": "block", "stop_hook_active": active, "missing": keys, "stalled": stalled}
    if phase:
        marker["phase"] = phase
    return {"decision": "block", "reason": "\n".join(lines)}, marker


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
