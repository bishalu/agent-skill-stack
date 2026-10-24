#!/usr/bin/env python3
"""host-ticket-runner: one GitHub issue, one headless Claude Code agent, the Compound
Engineering lifecycle enforced by per-run hooks. For light macOS and Windows hosts: no
container, no sandbox, bypass permissions. Standard library only, Python 3.9 or later.

Usage: htr.py <verb> [options]        htr.py <verb> --help for each verb's options

Verbs:
  preflight   check the host (claude, gh, git, the AWS profile); --agent also proves the
              AWS scrubbing inside a short launched agent
  route       print the tier, model, effort, route and criteria a ticket resolves to
  prompt      build a ticket's brief and print it, launching nothing
  launch      worktree, brief, hooks, detached agent; returns as soon as it is running
  status      every run (or one) with its state, missing steps and PR
  resume      the finishing turn for a run that ended without its PR; --send sends it
  clean       remove a finished run's worktree (and its launchd job)
  aws-keys    install the provisioned access key for launched agents, read from stdin

Examples:
  htr.py preflight
  htr.py route --repo vibesetai/vibeset-dj --issue 21
  htr.py launch --repo vibesetai/vibeset-dj --issue 21 --checkout ~/src/vibeset-dj
  htr.py launch --repo vibesetai/vibeset-dj --issue 22 --tier heavy --effort xhigh
  htr.py status
  htr.py resume --run vibesetai-vibeset-dj-21-20261024T101500 --send
  aws iam create-access-key --user-name vibeset-dj-ticket-agent | htr.py aws-keys

State lives under HTR_HOME (default ~/.local/state/host-ticket-runner, or
%LOCALAPPDATA%\\host-ticket-runner on Windows): runs/<id>/ (run.json, ticket.md, prompt.md,
settings.json, markers.jsonl, agent.log, exit.json, complete.json, escalation.md),
worktrees/<id>/, clones/, aws/. Nothing is written into the owner's Claude settings.

Exit codes: 0 done, 1 a command it ran failed, 2 refused (bad input, budget, cap, state).
"""
import argparse
import datetime as _dt
import json
import os
import re
import shlex
import shutil
import string
import subprocess
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import htr_hooks as hooks  # noqa: E402

SELF = os.path.abspath(__file__)
IS_WIN = os.name == "nt"
IS_MAC = sys.platform == "darwin"

# ---------------------------------------------------------------- routing table
# The table SKILL.md shows; htr_test.py fails when the two disagree.
TIERS = {
    "light":    {"model": "sonnet", "effort": "medium"},
    "standard": {"model": "opus",   "effort": "medium"},
    "heavy":    {"model": "opus",   "effort": "high"},
}
LIGHT_LABELS = {"docs", "documentation", "typo", "chore", "trivial", "size:xs", "size:s", "good first issue"}
HEAVY_LABELS = {"size:l", "size:xl", "risk", "risky", "security", "infra", "infrastructure", "migration", "breaking", "cross-boundary"}
RISK_RE = re.compile(r"\b(auth|authn|authz|authenticat\w*|authori[sz]\w*|oauth|login|passwords?|credentials?|secrets?|iam|permissions? boundar\w*|payments?|billing|"
                     r"stripe|migrations?|migrate|schema change|database schema|terraform|deploy\w*|security|encrypt\w*|"
                     r"concurren\w*|race condition|breaking change|public api|multi-tenant\w*|tenancy)\b", re.IGNORECASE)
LIGHT_MAX_CHARS, HEAVY_MIN_CHARS, LIGHT_MAX_CRITERIA, HEAVY_MIN_CRITERIA = 1500, 6000, 3, 9

# The Opus cap (the owner's CLAUDE.md): nothing above Opus, whatever the session runs on.
MODEL_OK = re.compile(r"^(haiku|sonnet|opus|claude-(haiku|sonnet|opus)-[a-z0-9.-]+)(\[1m\])?$")
EFFORTS = ("low", "medium", "high", "xhigh", "max")

CRITERIA_HEADING = re.compile(r"^\s*(#{1,6}\s*|\*\*)\s*(acceptance criteria|acceptance|done when|definition of done|"
                              r"exit criteria|success criteria|criteria)\b[^\n]*$", re.IGNORECASE)
LIFECYCLE = ["ce-work", "ce-simplify-code", "ce-code-review", "tests", "lint", "ce-compound", "ce-commit-push-pr", "pr"]
DEFAULT_BUDGETS = {"stop_blocks": 8, "stalled_blocks": 2, "finishing_turns": 2}
AWS_PROFILE = "htr-agent"
# Ambient variables the agent must not inherit. Every AWS_* goes (named keys and the
# non-standard copies people keep, like AWS_SEC); the parent Claude session's own wiring
# goes too, so the run is its own session rather than a child of the launcher's.
CLAUDE_KEEP = {"CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"}
LOGIN_WARNING = ("A host /login (or `claude auth login`) while a run is live revokes the token the agent is using; "
                 "its next call fails with a 401 and the run ends. Log in again only when `htr.py status` shows nothing running.")


def die(msg, code=2, example=None):
    print("htr: " + msg, file=sys.stderr)
    if example:
        print("  " + example, file=sys.stderr)
    sys.exit(code)


def now_stamp():
    return _dt.datetime.now().strftime("%Y%m%dT%H%M%S")


def htr_home():
    h = os.environ.get("HTR_HOME")
    if not h:
        if IS_WIN:
            h = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "host-ticket-runner")
        else:
            h = os.path.join(os.path.expanduser("~"), ".local", "state", "host-ticket-runner")
    return os.path.abspath(h)


def run(cmd, cwd=None, check=True, env=None, timeout=300):
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env, timeout=timeout)
    except FileNotFoundError:
        die("%s is not on PATH" % cmd[0], 1)
    except subprocess.TimeoutExpired:
        die("timed out after %ss: %s" % (timeout, " ".join(cmd)), 1)
    if check and r.returncode != 0:
        die("%s exited %d: %s" % (" ".join(shlex.quote(c) for c in cmd), r.returncode, (r.stderr or r.stdout).strip()[-800:]), 1)
    return r


def slug(text, n=40):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s[:n].strip("-") or "ticket"


# ---------------------------------------------------------------- tickets
def fetch_issue(repo, issue):
    if os.environ.get("HTR_FAKE_ISSUE"):   # tests: a JSON file standing in for `gh issue view`
        return hooks.read_json(os.environ["HTR_FAKE_ISSUE"])
    r = run(["gh", "issue", "view", str(issue), "-R", repo, "--json", "number,title,body,labels,state,url"])
    return json.loads(r.stdout)


def split_sentences(s):
    """milestone-supervisor's Exit: splitter: at semicolons and sentence ends, never inside
    (), [], {} or `code`."""
    s = re.sub(r"\s+", " ", s).strip()
    out, cur, depth, code = [], "", 0, False
    for i, c in enumerate(s):
        cur += c
        if c == "`":
            code = not code
        elif code:
            continue
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth = max(0, depth - 1)
        elif depth == 0 and (c == ";" or (c in ".!?" and re.match(r"\s*$|\s+[^a-z]", s[i + 1:]))):
            out.append(cur)
            cur = ""
    out.append(cur)
    return [x for x in (re.sub(r"[\s;.!?]+$", "", x).strip() for x in out) if x]


def extract_criteria(body):
    """(criteria texts, where they came from). A heading such as "Acceptance criteria" or
    "Done when": its list items, else its paragraph split into sentences. Else a paragraph
    starting "Exit:". Else none, and the ticket is thin."""
    lines = (body or "").replace("\r\n", "\n").split("\n")
    for i, line in enumerate(lines):
        if not CRITERIA_HEADING.match(line):
            continue
        level = len(re.match(r"^\s*(#*)", line).group(1)) or 7
        sec = []
        for l in lines[i + 1:]:
            m = re.match(r"^\s*(#{1,6})\s", l)
            if (m and len(m.group(1)) <= level) or (level == 7 and re.match(r"^\s*\*\*[^*]+\*\*\s*$", l)):
                break
            sec.append(l)
        items, cur = [], None
        for l in sec:
            m = re.match(r"^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.*)$", l)
            if m:
                if cur is not None:
                    items.append(cur)
                cur = m.group(1).strip()
            elif cur is not None and l.strip() and l.startswith((" ", "\t")):
                cur += " " + l.strip()
            elif cur is not None and not l.strip():
                items.append(cur)
                cur = None
        if cur is not None:
            items.append(cur)
        items = [re.sub(r"\s+", " ", x).strip() for x in items if x.strip()]
        if items:
            return items, "list under '%s'" % line.strip().strip("#* ")
        para = " ".join(l.strip() for l in sec if l.strip())
        if para:
            return split_sentences(para), "paragraph under '%s'" % line.strip().strip("#* ")
    for i, line in enumerate(lines):
        if re.match(r"^\s*Exit:", line):
            para = []
            for l in lines[i:]:
                if not l.strip() or l.startswith("#"):
                    break
                para.append(l.strip())
            crit = split_sentences(re.sub(r"^Exit:\s*", "", " ".join(para)))
            if crit:
                return crit, "Exit: paragraph"
    return [], "none"


def resolve(ticket, args):
    """Route, tier, model and effort for a ticket, each with its reason."""
    body = ticket.get("body") or ""
    labels = {str(l.get("name", l) if isinstance(l, dict) else l).lower() for l in ticket.get("labels") or []}
    crit, source = extract_criteria(body)
    issue = ticket.get("number")
    criteria = [{"id": "T%s.c%d" % (issue, i + 1), "text": t} for i, t in enumerate(crit)]
    route = getattr(args, "route", "auto") or "auto"
    if route == "auto":
        route = "work" if criteria else "plan-first"
        route_why = ("%d acceptance criteria (%s)" % (len(criteria), source)) if criteria else "no acceptance criteria found: ce-plan first"
    else:
        route_why = "--route %s" % route

    text = (ticket.get("title") or "") + "\n" + body
    risk = sorted({m.group(0).lower() for m in RISK_RE.finditer(text)})
    if args.tier:
        tier, why = args.tier, "--tier %s" % args.tier
    elif labels & HEAVY_LABELS:
        tier, why = "heavy", "label %s" % ", ".join(sorted(labels & HEAVY_LABELS))
    elif labels & LIGHT_LABELS and route == "work":
        tier, why = "light", "label %s" % ", ".join(sorted(labels & LIGHT_LABELS))
    elif risk:
        tier, why = "heavy", "risk words: %s" % ", ".join(risk[:6])
    elif len(body) >= HEAVY_MIN_CHARS or len(criteria) >= HEAVY_MIN_CRITERIA:
        tier, why = "heavy", "large ticket (%d chars, %d criteria)" % (len(body), len(criteria))
    elif route == "work" and len(body) <= LIGHT_MAX_CHARS and len(criteria) <= LIGHT_MAX_CRITERIA:
        tier, why = "light", "small ticket (%d chars, %d criteria, no risk words)" % (len(body), len(criteria))
    else:
        tier, why = "standard", "default (%d chars, %d criteria%s)" % (len(body), len(criteria), ", thin" if route == "plan-first" else "")
    model = args.model or TIERS[tier]["model"]
    effort = args.effort or TIERS[tier]["effort"]
    if not MODEL_OK.match(model):
        die("model %r is refused: launched agents run on Opus at most (haiku, sonnet, opus or a claude-haiku/sonnet/opus id)" % model,
            example="htr.py launch --repo %s --issue %s --model opus" % (args.repo, args.issue))
    if effort not in EFFORTS:
        die("effort %r is not one of %s" % (effort, ", ".join(EFFORTS)))
    return {"route": route, "route_why": route_why, "tier": tier, "tier_why": why, "model": model, "effort": effort,
            "criteria": criteria, "criteria_source": source, "labels": sorted(labels)}


def required_steps(route, skip):
    req = (["ce-plan"] if route == "plan-first" else []) + LIFECYCLE
    return [s for s in req if s not in skip]


def brief(ticket, res, run_info):
    issue = ticket["number"]
    tf = run_info["ticket_file"]
    work_in = tf if res["route"] == "work" else "<the plan path ce-plan wrote>"
    steps = []
    if res["route"] == "plan-first":
        steps.append("ce-plan with the ticket file %s as the request. The ticket has no acceptance criteria, so the plan "
                     "is where they get written: take the Durable contract, ground it in docs/solutions/, and commit the plan." % tf)
    steps.append("ce-work mode:return-to-caller %s: implementation and local verification, unit-scoped commits." % work_in)
    steps.append("ce-simplify-code on the branch diff.")
    steps.append("ce-code-review apply:local plan:%s: it applies the findings it verifies; commit them. Keep the residual "
                 "findings for the PR body." % work_in)
    t = "the full test suite and the linters" if "tests" in run_info["required"] and "lint" in run_info["required"] else (
        "the full test suite" if "tests" in run_info["required"] else ("the linters" if "lint" in run_info["required"] else ""))
    if t:
        steps.append("Run %s (find them in the justfile, Makefile, package.json or pyproject.toml), after your last edit, "
                     "and get them green." % t)
    steps.append("ce-compound mode:non-interactive depth:lightweight for each non-obvious lesson this ticket produced. "
                 "When nothing qualifies it ends \"Documentation skipped\"; that is fine.")
    steps.append("ce-commit-push-pr mode:pipeline babysit:off: commit what remains, push %s and open the PR against %s." % (
        run_info["branch"], run_info["base"]))
    steps_text = "\n".join("%d. %s" % (i + 1, s) for i, s in enumerate(steps))
    if res["criteria"]:
        crit = "".join("  %s: %s\n" % (c["id"], c["text"]) for c in res["criteria"])
        rule = ("- every acceptance criterion by its id, with how you verified it. The ids, taken from the ticket:\n" + crit
                + "  Cite the ids rather than restating the criteria; the runner's record (acceptance.json) is the one copy of them;\n")
    else:
        rule = "- the acceptance criteria your plan wrote, each with how you verified it;\n"
    tpl = string.Template(open(os.path.join(HERE, "templates", "brief.md"), encoding="utf-8").read())
    return tpl.safe_substitute(repo=run_info["repo"], issue=issue, ticket_file=tf, branch=run_info["branch"],
                               base=run_info["base"], steps=steps_text, criteria_rule=rule, aws_profile=AWS_PROFILE,
                               title=ticket.get("title") or "", body=(ticket.get("body") or "").strip())


# ---------------------------------------------------------------- AWS
def aws_dir():
    return os.path.join(htr_home(), "aws")


def ensure_aws_files():
    """The runner-owned AWS config. Until the owner installs the provisioned key it holds a
    placeholder profile with no credentials, so every AWS call in a run fails closed."""
    d = aws_dir()
    os.makedirs(d, exist_ok=True)
    cfg, cred = os.path.join(d, "config"), os.path.join(d, "credentials")
    if not os.path.exists(cfg):
        with open(cfg, "w") as f:
            f.write("# Written by host-ticket-runner. The only AWS config a launched agent sees.\n"
                    "[profile %s]\nregion = %s\noutput = json\n" % (AWS_PROFILE, os.environ.get("HTR_AWS_REGION", "us-east-2")))
    if not os.path.exists(cred):
        with open(cred, "w") as f:
            f.write("# Placeholder: no key is provisioned yet, so AWS calls fail. Install one with\n"
                    "#   aws iam create-access-key --user-name <agent user> | htr.py aws-keys\n"
                    "[%s]\n" % AWS_PROFILE)
    for p in (d, cfg, cred):
        try:
            os.chmod(p, 0o700 if p == d else 0o600)
        except OSError:
            pass
    return cfg, cred


def aws_state():
    _, cred = ensure_aws_files()
    text = open(cred, encoding="utf-8").read()
    m = re.search(r"aws_access_key_id\s*=\s*(\S+)", text)
    return ("provisioned key %s...%s" % (m.group(1)[:4], m.group(1)[-4:])) if m else "placeholder (no key: AWS calls fail)"


def agent_env(run_info):
    env = {}
    for k, v in os.environ.items():
        u = k.upper()
        if u.startswith("AWS_"):
            continue
        if (u.startswith("CLAUDE_") or u == "CLAUDECODE") and u not in CLAUDE_KEEP:
            continue
        env[k] = v
    cfg, cred = ensure_aws_files()
    env.update({"AWS_CONFIG_FILE": cfg, "AWS_SHARED_CREDENTIALS_FILE": cred, "AWS_PROFILE": AWS_PROFILE,
                "AWS_SDK_LOAD_CONFIG": "1", "AWS_EC2_METADATA_DISABLED": "true",
                "HTR_RUN_DIR": run_info["run_dir"], "HTR_RUN_ID": run_info["id"]})
    return env


def do_aws_keys(args):
    """Reads `aws iam create-access-key` JSON, or two lines (key id, secret), from stdin."""
    if sys.stdin.isatty():
        die("aws-keys reads the key from stdin, never from arguments (they show in the process list)",
            example="aws iam create-access-key --user-name vibeset-dj-ticket-agent | htr.py aws-keys")
    raw = sys.stdin.read().strip()
    kid = sec = None
    try:
        j = json.loads(raw)
        ak = j.get("AccessKey", j)
        kid, sec = ak.get("AccessKeyId"), ak.get("SecretAccessKey")
    except ValueError:
        parts = raw.split()
        if len(parts) == 2:
            kid, sec = parts
    if not kid or not sec or not re.match(r"^A[KS]IA[A-Z0-9]{12,}$", kid):
        die("stdin is neither create-access-key JSON nor two lines (access key id, secret)")
    cfg, cred = ensure_aws_files()
    with open(cred, "w") as f:
        f.write("# Installed by htr.py aws-keys %s\n[%s]\naws_access_key_id = %s\naws_secret_access_key = %s\n" % (
            now_stamp(), AWS_PROFILE, kid, sec))
    try:
        os.chmod(cred, 0o600)
    except OSError:
        pass
    print("installed %s for profile %s in %s" % (kid, AWS_PROFILE, cred))
    print("check: AWS_CONFIG_FILE=%s AWS_SHARED_CREDENTIALS_FILE=%s AWS_PROFILE=%s aws sts get-caller-identity" % (cfg, cred, AWS_PROFILE))
    return 0


# ---------------------------------------------------------------- preflight
def do_preflight(args, quiet=False):
    problems, lines = [], []

    def line(ok, what, detail):
        lines.append("%-5s %-22s %s" % ("ok" if ok else "FAIL", what, detail))
        if not ok:
            problems.append(what)

    line(sys.version_info >= (3, 9), "python", sys.version.split()[0])
    for tool, ver in (("claude", ["claude", "--version"]), ("gh", ["gh", "--version"]), ("git", ["git", "--version"])):
        path = shutil.which(tool)
        if not path:
            line(False, tool, "not on PATH")
            continue
        r = subprocess.run(ver, capture_output=True, text=True)
        line(r.returncode == 0, tool, (r.stdout or r.stderr).strip().splitlines()[0] if (r.stdout or r.stderr).strip() else path)
    if shutil.which("gh"):
        r = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True)
        line(r.returncode == 0, "gh auth", "logged in" if r.returncode == 0 else (r.stderr or r.stdout).strip().splitlines()[-1:])
    line(True, "aws profile", "%s: %s" % (AWS_PROFILE, aws_state()))
    amb = sorted(k for k in os.environ if k.upper().startswith("AWS_"))
    line(True, "ambient AWS env", ("%s (scrubbed from every run)" % ", ".join(amb)) if amb else "none")
    line(True, "detach", "process%s" % (", launchd" if IS_MAC else (", schtasks" if IS_WIN else "")))
    running = [r for r in all_runs() if state_of(r)["state"] == "running"]
    line(True, "runs live", str(len(running)))
    if not quiet:
        print("\n".join(lines))
        print("\nwarning: " + LOGIN_WARNING)
    if getattr(args, "agent", False) and not problems:
        problems += agent_probe(args)
    if problems and not quiet:
        print("\npreflight failed: %s" % ", ".join(problems), file=sys.stderr)
    return problems


def agent_probe(args):
    """A short launched agent, with exactly a run's env and hooks, reporting what AWS it sees."""
    home = htr_home()
    d = os.path.join(home, "runs", "preflight-%s" % now_stamp())
    os.makedirs(d)
    info = {"id": os.path.basename(d), "run_dir": d, "repo": "-", "branch": "-", "worktree": d, "required": [],
            "aws_profile": AWS_PROFILE, "real_aws_dirs": [os.path.join(os.path.expanduser("~"), ".aws")]}
    hooks.write_json(os.path.join(d, "run.json"), info)
    hooks.write_json(os.path.join(d, "settings.json"), settings_for(d, stop=False))
    prompt = ("Run these as separate Bash calls and report each output verbatim, then stop: "
              "1) `env | grep '^AWS_' | sed 's/=.*//'`  2) `aws sts get-caller-identity`  3) `cat ~/.aws/credentials | head -3`.")
    cmd = ["claude", "-p", prompt, "--model", "haiku", "--dangerously-skip-permissions", "--settings",
           os.path.join(d, "settings.json"), "--output-format", "text"]
    r = subprocess.run(cmd, cwd=d, env=agent_env(info), capture_output=True, text=True, timeout=600)
    open(os.path.join(d, "agent.log"), "w").write(r.stdout + r.stderr)
    print("\n--- launched-agent AWS probe (%s) ---\n%s" % (d, r.stdout.strip()))
    denies = [m for m in hooks.read_markers(d) if m.get("kind") == "aws-deny"]
    print("--- PreToolUse denies recorded: %d" % len(denies))
    return [] if r.returncode == 0 else ["agent probe (claude exited %d)" % r.returncode]


# ---------------------------------------------------------------- runs on disk
def runs_dir():
    return os.path.join(htr_home(), "runs")


def all_runs():
    d = runs_dir()
    out = []
    if os.path.isdir(d):
        for name in sorted(os.listdir(d)):
            rj = hooks.read_json(os.path.join(d, name, "run.json"))
            if rj and rj.get("repo") not in (None, "-"):
                out.append(rj)
    return out


def load_run(rid):
    rj = hooks.read_json(os.path.join(runs_dir(), rid, "run.json"))
    if not rj:
        die("no run %s under %s" % (rid, runs_dir()), example="htr.py status")
    return rj


def pid_alive(pid):
    if not pid:
        return False
    if IS_WIN:
        r = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH"], capture_output=True, text=True)
        return str(pid) in r.stdout
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:   # a zombie (the launcher has not reaped it yet) is not running
        r = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
        return not r.stdout.strip().startswith("Z")
    except OSError:
        return True


def state_of(rj, check_pr=False):
    d = rj["run_dir"]
    sup = hooks.read_json(os.path.join(d, "supervise.json"), {})
    ex = hooks.read_json(os.path.join(d, "exit.json"))
    complete = os.path.exists(os.path.join(d, "complete.json"))
    esc = os.path.exists(os.path.join(d, "escalation.md"))
    alive = pid_alive(sup.get("pid")) and not (ex and ex.get("turn") == sup.get("turn"))
    tail = ""
    try:
        with open(os.path.join(d, "agent.log"), "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 4000))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        pass
    if alive:
        st = "running"
    elif complete:
        st = "complete"
    elif esc:
        st = "escalated"
    elif re.search(r"(^|\D)401(\D|$)|authentication_error|OAuth token (has )?expired|invalid_grant|Please run /login", tail):
        st = "auth-expired"
    elif ex:
        st = "ended-incomplete"
    elif sup:
        st = "dead"
    else:
        st = "not-started"
    ev = hooks.evaluate(d, rj, check_pr=check_pr) if st != "complete" else {"missing": [], "done": [], "pr": None}
    last = [l for l in tail.splitlines() if l.strip()]
    return {"state": st, "missing": [m["step"] for m in ev["missing"]], "missing_detail": ev["missing"],
            "pr": (hooks.read_json(os.path.join(d, "complete.json"), {}) or {}).get("pr") or ((ev.get("pr") or {}).get("url")),
            "last": last[-1][:120] if last else "", "exit": (ex or {}).get("code"), "pid": sup.get("pid")}


def do_status(args):
    rows = all_runs()
    if args.run:
        rows = [load_run(args.run)]
    if args.issue:
        rows = [r for r in rows if str(r["issue"]) == str(args.issue)]
    out = []
    for rj in rows:
        s = state_of(rj, check_pr=args.pr)
        out.append(dict(id=rj["id"], repo=rj["repo"], issue=rj["issue"], tier=rj["tier"], model=rj["model"],
                        effort=rj["effort"], route=rj["route"], worktree=rj["worktree"], branch=rj["branch"], **s))
    if args.json:
        print(json.dumps(out, indent=2))
        return 0
    if not out:
        print("no runs under %s" % runs_dir())
        return 0
    print("%-44s %-17s %-16s %-26s %s" % ("RUN", "STATE", "MODEL/EFFORT", "MISSING", "PR / LAST OUTPUT"))
    for r in out:
        miss = ",".join(r["missing"])[:26] or "-"
        print("%-44s %-17s %-16s %-26s %s" % (r["id"], r["state"], "%s/%s" % (r["model"], r["effort"]), miss, r["pr"] or r["last"]))
    return 0


# ---------------------------------------------------------------- hooks per run
def settings_for(run_dir, stop=True):
    """The run's own settings file, passed with --settings: the hooks and nothing else.
    Exec form (command + args), so no shell quoting on any platform."""
    def h(verb, timeout=30):
        return {"type": "command", "command": sys.executable, "args": [os.path.join(HERE, "htr_hooks.py"), verb, "--run", run_dir],
                "timeout": timeout}
    s = {"hooks": {
        "PreToolUse": [{"matcher": "Read|Grep|Glob|Bash|Edit|Write|MultiEdit|NotebookEdit", "hooks": [h("pre-tool-use")]}],
        "PostToolUse": [{"matcher": "Skill|Bash|Edit|Write|MultiEdit|NotebookEdit", "hooks": [h("post-tool-use")]}],
        "PostToolUseFailure": [{"matcher": "Skill|Bash", "hooks": [h("post-tool-fail")]}],
    }}
    if stop:
        s["hooks"]["Stop"] = [{"hooks": [h("stop", 180)]}]
    return s


# ---------------------------------------------------------------- launch
def resolve_checkout(repo, checkout):
    if checkout:
        top = run(["git", "-C", os.path.expanduser(checkout), "rev-parse", "--show-toplevel"]).stdout.strip()
        return top
    r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if r.returncode == 0:
        top = r.stdout.strip()
        url = subprocess.run(["git", "-C", top, "remote", "get-url", "origin"], capture_output=True, text=True).stdout
        if re.search(r"[:/]%s(\.git)?/?\s*$" % re.escape(repo), url.strip(), re.IGNORECASE):
            return top
    clone = os.path.join(htr_home(), "clones", repo.replace("/", "__"))
    if not os.path.isdir(os.path.join(clone, ".git")):
        os.makedirs(os.path.dirname(clone), exist_ok=True)
        run(["gh", "repo", "clone", repo, clone], timeout=1800)
    return clone


def active_run_for(repo, issue):
    for rj in all_runs():
        if rj["repo"] == repo and str(rj["issue"]) == str(issue):
            st = state_of(rj)["state"]
            if st in ("running", "complete"):
                return rj, st
    return None, None


def common_args(p):
    p.add_argument("--repo", required=True, help="owner/name of the GitHub repository")
    p.add_argument("--issue", required=True, type=int, help="the issue number")
    p.add_argument("--tier", choices=sorted(TIERS), help="override the routing table's tier")
    p.add_argument("--model", help="override the tier's model (Opus at most: haiku, sonnet, opus or a claude-* id)")
    p.add_argument("--effort", help="override the tier's effort (%s)" % ", ".join(EFFORTS))
    p.add_argument("--route", choices=["auto", "work", "plan-first"], default="auto",
                   help="auto: ce-work when the ticket has acceptance criteria, ce-plan first when it has none")
    p.add_argument("--json", action="store_true", help="print JSON")


def plan_launch(args):
    ticket = fetch_issue(args.repo, args.issue)
    if not ticket or not ticket.get("number"):
        die("could not read issue %s#%s" % (args.repo, args.issue), 1)
    res = resolve(ticket, args)
    return ticket, res


def do_route(args):
    ticket, res = plan_launch(args)
    if args.json:
        print(json.dumps(res, indent=2))
        return 0
    print("ticket:   %s#%s %s" % (args.repo, ticket["number"], ticket.get("title")))
    print("route:    %s (%s)" % (res["route"], res["route_why"]))
    print("tier:     %s (%s)" % (res["tier"], res["tier_why"]))
    print("model:    %s" % res["model"])
    print("effort:   %s" % res["effort"])
    for c in res["criteria"]:
        print("  %s: %s" % (c["id"], c["text"]))
    return 0


def do_prompt(args):
    ticket, res = plan_launch(args)
    rid = "%s-%s-%s" % (args.repo.replace("/", "-"), args.issue, "PREVIEW")
    info = {"repo": args.repo, "branch": "htr/%s-%s" % (args.issue, slug(ticket.get("title") or "")), "base": args.base or "<default branch>",
            "ticket_file": os.path.join(runs_dir(), rid, "ticket.md"), "required": required_steps(res["route"], args.skip_step or [])}
    print(brief(ticket, res, info))
    return 0


def do_launch(args):
    problems = do_preflight(args, quiet=True)
    if problems:
        die("preflight failed: %s (run htr.py preflight)" % ", ".join(problems), 1)
    ticket, res = plan_launch(args)
    if (ticket.get("state") or "OPEN").upper() != "OPEN" and not args.allow_closed:
        die("issue %s#%s is %s; pass --allow-closed to run it anyway" % (args.repo, args.issue, ticket.get("state")))
    prev, st = active_run_for(args.repo, args.issue)
    if prev and not args.again:
        print("already %s: %s (htr.py status --run %s); --again launches another" % (st, prev["id"], prev["id"]))
        return 0

    checkout = resolve_checkout(args.repo, args.checkout)
    base = args.base
    if not base:
        if os.environ.get("HTR_FAKE_ISSUE"):
            base = "main"
        else:
            base = run(["gh", "repo", "view", args.repo, "--json", "defaultBranchRef", "-q", ".defaultBranchRef.name"]).stdout.strip() or "main"
    rid = "%s-%s-%s" % (args.repo.replace("/", "-"), args.issue, now_stamp())
    home = htr_home()
    run_dir = os.path.join(home, "runs", rid)
    worktree = os.path.join(home, "worktrees", rid)
    branch = "htr/%s-%s" % (args.issue, slug(ticket.get("title") or ""))
    if subprocess.run(["git", "-C", checkout, "rev-parse", "--verify", "-q", "refs/heads/" + branch], capture_output=True).returncode == 0:
        branch += "-" + now_stamp()
    skip = args.skip_step or []
    info = {"id": rid, "run_dir": run_dir, "repo": args.repo, "issue": ticket["number"], "title": ticket.get("title"),
            "url": ticket.get("url"), "checkout": checkout, "worktree": worktree, "branch": branch, "base": base,
            "ticket_file": os.path.join(run_dir, "ticket.md"), "required": required_steps(res["route"], skip),
            "skipped": skip, "session_id": str(uuid.uuid4()), "detach": args.detach, "aws_profile": AWS_PROFILE,
            "real_aws_dirs": [os.path.join(os.path.expanduser("~"), ".aws")],
            "budgets": {"stop_blocks": args.max_stop_blocks, "stalled_blocks": DEFAULT_BUDGETS["stalled_blocks"],
                        "finishing_turns": args.max_finishing_turns},
            "test_regex": args.test_regex, "lint_regex": args.lint_regex, "launched_at": now_stamp(),
            "finishing_turns": 0, "extensions": []}
    info.update({k: res[k] for k in ("route", "route_why", "tier", "tier_why", "model", "effort", "criteria", "criteria_source")})
    info["work_input"] = info["ticket_file"] if res["route"] == "work" else None

    if args.dry_run:
        print(json.dumps(info, indent=2))
        print("\n(dry run: nothing created, nothing launched)")
        return 0

    os.makedirs(run_dir)
    run(["git", "-C", checkout, "fetch", "origin", base], timeout=600)
    os.makedirs(os.path.dirname(worktree), exist_ok=True)
    run(["git", "-C", checkout, "worktree", "add", "-b", branch, worktree, "origin/" + base])
    with open(info["ticket_file"], "w", encoding="utf-8") as f:
        f.write("# %s\n\n%s\n" % (ticket.get("title") or "", (ticket.get("body") or "").strip()))
    hooks.write_json(os.path.join(run_dir, "acceptance.json"),
                     {"ticket": "%s#%s" % (args.repo, ticket["number"]), "source": res["criteria_source"], "criteria": res["criteria"]})
    with open(os.path.join(run_dir, "prompt.md"), "w", encoding="utf-8") as f:
        f.write(brief(ticket, res, info))
    hooks.write_json(os.path.join(run_dir, "settings.json"), settings_for(run_dir))
    hooks.write_json(os.path.join(run_dir, "run.json"), info)
    pid = spawn(info, [])
    out = {"run": rid, "pid": pid, "worktree": worktree, "branch": branch, "base": base, "route": res["route"],
           "tier": res["tier"], "model": res["model"], "effort": res["effort"], "criteria": len(res["criteria"]),
           "log": os.path.join(run_dir, "agent.log"), "markers": os.path.join(run_dir, "markers.jsonl")}
    if args.json:
        print(json.dumps(out, indent=2))
    else:
        print("launched %s#%s as %s (pid %s, %s)" % (args.repo, ticket["number"], rid, pid, args.detach))
        print("route: %s (%s)" % (res["route"], res["route_why"]))
        print("tier:  %s -> %s / %s (%s)" % (res["tier"], res["model"], res["effort"], res["tier_why"]))
        print("worktree: %s  branch: %s" % (worktree, branch))
        print("log: %s" % out["log"])
        print("watch: %s status --run %s" % (SELF, rid))
        print("warning: " + LOGIN_WARNING)
    return 0


def spawn(info, extra):
    """Start `_supervise` so it outlives this process and the session that ran it."""
    d = info["run_dir"]
    argv = [sys.executable, SELF, "_supervise", "--run", d] + extra
    sup_log = open(os.path.join(d, "supervisor.log"), "a")
    mode = info.get("detach", "process")
    if mode == "launchd":
        if not IS_MAC:
            die("--detach launchd is macOS only")
        label = "ai.vibeset.htr.%s" % re.sub(r"[^A-Za-z0-9.-]", "-", info["id"])
        plist = os.path.join(d, "launchd.plist")
        import plistlib
        with open(plist, "wb") as f:
            plistlib.dump({"Label": label, "ProgramArguments": argv, "WorkingDirectory": info["worktree"], "RunAtLoad": True,
                           "StandardOutPath": os.path.join(d, "supervisor.log"), "StandardErrorPath": os.path.join(d, "supervisor.log"),
                           "EnvironmentVariables": {"PATH": os.environ.get("PATH", ""), "HOME": os.path.expanduser("~"),
                                                    "HTR_HOME": htr_home()}}, f)
        subprocess.run(["launchctl", "bootout", "gui/%d/%s" % (os.getuid(), label)], capture_output=True)
        run(["launchctl", "bootstrap", "gui/%d" % os.getuid(), plist])
        info["launchd_label"] = label
        hooks.write_json(os.path.join(d, "run.json"), info)
        return "launchd:" + label
    if mode == "schtasks":
        if not IS_WIN:
            die("--detach schtasks is Windows only")
        name = "htr-%s" % info["id"]
        cmdfile = os.path.join(d, "supervise.cmd")
        with open(cmdfile, "w") as f:
            f.write("@echo off\r\nset HTR_HOME=%s\r\n%s >> \"%s\" 2>&1\r\n" % (
                htr_home(), subprocess.list2cmdline(argv), os.path.join(d, "supervisor.log")))
        run(["schtasks", "/Create", "/F", "/TN", name, "/SC", "ONCE", "/ST", "23:59", "/TR", '"%s"' % cmdfile])
        run(["schtasks", "/Run", "/TN", name])
        info["schtask"] = name
        hooks.write_json(os.path.join(d, "run.json"), info)
        return "schtasks:" + name
    kw = {"stdin": subprocess.DEVNULL, "stdout": sup_log, "stderr": subprocess.STDOUT, "cwd": info["worktree"], "close_fds": True}
    if IS_WIN:
        flags = 0x00000008 | 0x00000200   # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
        try:
            p = subprocess.Popen(argv, creationflags=flags | 0x01000000, **kw)   # | CREATE_BREAKAWAY_FROM_JOB
        except OSError:
            p = subprocess.Popen(argv, creationflags=flags, **kw)   # the parent's job forbids breakaway
    else:
        p = subprocess.Popen(argv, start_new_session=True, **kw)
    return p.pid


def do_supervise(args):
    """Internal: runs one claude turn in the run's worktree and records how it ended."""
    d = args.run
    info = hooks.read_json(os.path.join(d, "run.json"))
    turn = (info.get("finishing_turns") or 0) if args.resume_text else 0
    hooks.write_json(os.path.join(d, "supervise.json"), {"pid": os.getpid(), "started_at": now_stamp(), "turn": turn,
                                                         "kind": "finishing" if args.resume_text else "launch"})
    base = ["claude", "-p", "--dangerously-skip-permissions", "--settings", os.path.join(d, "settings.json"),
            "--model", info["model"], "--effort", info["effort"], "--output-format", "text"]
    if args.resume_text:
        cmd = base + ["--resume", info["session_id"], args.resume_text]
    else:
        cmd = base + ["--session-id", info["session_id"], open(os.path.join(d, "prompt.md"), encoding="utf-8").read()]
    hooks.append_marker(d, {"kind": "turn", "turn": turn, "event": "start", "model": info["model"], "effort": info["effort"]})
    code = 1
    with open(os.path.join(d, "agent.log"), "a", encoding="utf-8") as log:
        log.write("\n=== turn %d (%s) %s: %s / %s ===\n" % (turn, "finishing" if args.resume_text else "launch", now_stamp(),
                                                         info["model"], info["effort"]))
        log.flush()
        try:
            p = subprocess.Popen(cmd, cwd=info["worktree"], env=agent_env(info), stdin=subprocess.DEVNULL, stdout=log,
                                 stderr=subprocess.STDOUT)
            code = p.wait()
        except OSError as e:
            log.write("could not start claude: %s\n" % e)
    hooks.write_json(os.path.join(d, "exit.json"), {"code": code, "turn": turn, "ended_at": now_stamp()})
    hooks.append_marker(d, {"kind": "turn", "turn": turn, "event": "end", "exit": code})
    return 0


# ---------------------------------------------------------------- resume
def finishing_text(rj, st):
    lines = ["The previous turn of this ticket (%s#%s) ended before the run was complete (%s). Read `git status` and "
             "`git log` in the worktree first. Then finish, in order:" % (rj["repo"], rj["issue"], st["state"])]
    for i, m in enumerate(st["missing_detail"], 1):
        lines.append("%d. %s: %s. Do: %s." % (i, m["step"], m["why"], m["do"]))
    lines.append("Work inline, commit each step as it passes, and stop when the PR is open.")
    return "\n".join(lines)


def do_resume(args):
    rows = [load_run(args.run)] if args.run else all_runs()
    any_row = False
    for rj in rows:
        st = state_of(rj, check_pr=True)
        if st["state"] in ("running", "complete", "not-started"):
            if args.run:
                print("%s is %s: nothing to resume" % (rj["id"], st["state"]))
            continue
        if st["state"] == "ended-incomplete" and not st["missing"]:
            # The work is all shown; only the Stop hook never got to say so.
            hooks.write_json(os.path.join(rj["run_dir"], "complete.json"), {"at": now_stamp(), "pr": st["pr"], "by": "resume"})
            print("%s: every step is shown now; marked complete (%s)" % (rj["id"], st["pr"]))
            continue
        any_row = True
        used, limit = rj.get("finishing_turns", 0), rj["budgets"]["finishing_turns"] + len(rj.get("extensions") or [])
        text = finishing_text(rj, st)
        print("=== %s (%s): missing %s" % (rj["id"], st["state"], ", ".join(st["missing"]) or "-"))
        if st["state"] == "auth-expired":
            print("  owner: the agent's token was revoked (a host /login does that). Log in again, then issue this.")
        if st["state"] == "escalated" and not args.extend:
            print("  escalated (%s): resuming needs --extend, which the owner or orchestrator grants deliberately" %
                  os.path.join(rj["run_dir"], "escalation.md"))
        print("  finishing turn %d of %d:\n    %s" % (used + 1, limit, text.replace("\n", "\n    ")))
        if not args.send:
            continue
        if args.extend:
            rj.setdefault("extensions", []).append({"at": now_stamp(), "by": args.by})
            limit += 1
        elif st["state"] == "escalated":
            continue
        if used >= limit:
            hooks.write_escalation(rj["run_dir"], rj, st["missing_detail"], "the finishing-turn budget (%d) is spent" % limit, {})
            print("  refused: finishing-turn budget spent (%d of %d); escalation written. --extend grants one more" % (used, limit))
            sys.exit(2)
        for f in ("exit.json", "escalation.md"):
            p = os.path.join(rj["run_dir"], f)
            if os.path.exists(p):
                os.replace(p, p + ".%s" % now_stamp())
        rj["finishing_turns"] = used + 1
        hooks.write_json(os.path.join(rj["run_dir"], "run.json"), rj)
        pid = spawn(rj, ["--resume-text", text])
        print("  issued: pid %s" % pid)
    if not any_row and not args.run:
        print("nothing to resume")
    elif not args.send and any_row:
        print("(printed only; add --send to send it)")
    return 0


def do_clean(args):
    rj = load_run(args.run)
    st = state_of(rj)
    if st["state"] == "running":
        die("%s is running" % rj["id"])
    if st["state"] != "complete" and not args.force:
        die("%s is %s; --force removes its worktree anyway (the branch stays)" % (rj["id"], st["state"]))
    if rj.get("launchd_label"):
        subprocess.run(["launchctl", "bootout", "gui/%d/%s" % (os.getuid(), rj["launchd_label"])], capture_output=True)
    if rj.get("schtask"):
        subprocess.run(["schtasks", "/Delete", "/F", "/TN", rj["schtask"]], capture_output=True)
    if os.path.isdir(rj["worktree"]):
        run(["git", "-C", rj["checkout"], "worktree", "remove", "--force", rj["worktree"]])
    print("removed worktree %s (branch %s and the run record stay)" % (rj["worktree"], rj["branch"]))
    return 0


# ---------------------------------------------------------------- CLI
def main(argv=None):
    p = argparse.ArgumentParser(prog="htr.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="verb")

    def verb(name, help_, examples):
        return sub.add_parser(name, help=help_, description=help_, epilog="Examples:\n  " + "\n  ".join(examples),
                              formatter_class=argparse.RawDescriptionHelpFormatter)

    q = verb("preflight", "check the host before a launch", ["htr.py preflight", "htr.py preflight --agent"])
    q.add_argument("--agent", action="store_true", help="also launch a short haiku agent with a run's env and hooks and show what AWS it sees")

    q = verb("route", "the tier, model, effort, route and criteria a ticket resolves to",
             ["htr.py route --repo vibesetai/vibeset-dj --issue 21", "htr.py route --repo o/r --issue 3 --json"])
    common_args(q)

    q = verb("prompt", "print a ticket's brief without launching", ["htr.py prompt --repo vibesetai/vibeset-dj --issue 21"])
    common_args(q)
    q.add_argument("--base")
    q.add_argument("--skip-step", action="append", choices=["tests", "lint"])

    q = verb("launch", "launch one ticket's agent, detached", [
        "htr.py launch --repo vibesetai/vibeset-dj --issue 21",
        "htr.py launch --repo vibesetai/vibeset-dj --issue 21 --checkout ~/src/vibeset-dj --detach launchd",
        "htr.py launch --repo o/r --issue 7 --tier heavy --effort xhigh",
        "htr.py launch --repo o/r --issue 8 --skip-step lint --dry-run"])
    common_args(q)
    q.add_argument("--checkout", help="a local clone of --repo (default: the current repo if it is that one, else a clone under HTR_HOME)")
    q.add_argument("--base", help="the branch the worktree starts from and the PR targets (default: the repo's default branch)")
    q.add_argument("--detach", choices=["process", "launchd", "schtasks"], default="process",
                   help="process (default, every platform), launchd (macOS) or schtasks (Windows)")
    q.add_argument("--skip-step", action="append", choices=["tests", "lint"], help="a step the Stop hook does not require (repeatable)")
    q.add_argument("--test-regex", help="replace the pattern a Bash command must start with to count as a test run")
    q.add_argument("--lint-regex", help="replace the pattern a Bash command must start with to count as a lint run")
    q.add_argument("--max-stop-blocks", type=int, default=DEFAULT_BUDGETS["stop_blocks"], help="Stop-hook blocks before it escalates (default 8)")
    q.add_argument("--max-finishing-turns", type=int, default=DEFAULT_BUDGETS["finishing_turns"], help="resume turns before escalation (default 2)")
    q.add_argument("--again", action="store_true", help="launch even when a run of this issue is running or complete")
    q.add_argument("--allow-closed", action="store_true", help="launch a closed issue")
    q.add_argument("--dry-run", action="store_true", help="resolve everything and print the run record; create and launch nothing")

    q = verb("status", "every run, or one, with its state", ["htr.py status", "htr.py status --run ID --pr", "htr.py status --json"])
    q.add_argument("--run")
    q.add_argument("--issue")
    q.add_argument("--pr", action="store_true", help="also ask GitHub about each run's PR (slower)")
    q.add_argument("--json", action="store_true")

    q = verb("resume", "the finishing turn for runs that ended without their PR", [
        "htr.py resume", "htr.py resume --run ID --send", "htr.py resume --run ID --send --extend --by owner"])
    q.add_argument("--run")
    q.add_argument("--send", action="store_true", help="send the finishing turn (default: print it)")
    q.add_argument("--extend", action="store_true", help="grant one finishing turn past the budget, or resume an escalated run")
    q.add_argument("--by", default="orchestrator", help="who granted --extend (recorded in run.json)")

    q = verb("clean", "remove a finished run's worktree", ["htr.py clean --run ID", "htr.py clean --run ID --force"])
    q.add_argument("--run", required=True)
    q.add_argument("--force", action="store_true")

    verb("aws-keys", "install the provisioned AWS key for launched agents (stdin)",
         ["aws iam create-access-key --user-name vibeset-dj-ticket-agent | htr.py aws-keys"])

    q = sub.add_parser("_supervise")
    q.add_argument("--run", required=True)
    q.add_argument("--resume-text")

    args = p.parse_args(argv)
    if not args.verb:
        p.print_help()
        return 0
    if args.verb == "preflight":
        return 1 if do_preflight(args) else 0
    return {"route": do_route, "prompt": do_prompt, "launch": do_launch, "status": do_status, "resume": do_resume,
            "clean": do_clean, "aws-keys": do_aws_keys, "_supervise": do_supervise}[args.verb](args)


if __name__ == "__main__":
    sys.exit(main())
