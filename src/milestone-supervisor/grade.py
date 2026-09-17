#!/usr/bin/env python3
"""Grade records, typed events and a decision report for supervised changes.

Run through uv so nothing needs installing:

    uv run --with mlflow grade.py <subcommand> [--project ROOT] ...

Subcommands
-----------
record N [--started ISO] [--accepted ISO] [--runs-dir DIR] [--merge REF | --range A..B] [--units N]
record --change ID --started ISO --accepted ISO [--range A..B | --merge REF] [--units N]
    Write (or replace) the change's line in .milestones/grades.jsonl, then log it to MLflow.
    Owner amendments, on the existing line without recomputing automatic fields:
        --owner-minutes specify=10,intervene=5,review=15,repair=0
        --missed "[stage: ]text"        repeatable, appends
        --regression "[stage: ]text"    repeatable, appends
    --refresh recomputes automatic fields on an existing line and keeps owner fields.
event TYPE --change ID [key=value ...] [--json OBJECT]
    Validate and append one typed event to .milestones/events.jsonl. Exit 2 on a
    validation error, with nothing written.
report [--last N] [--json]
    Answer the R17 decisions over the last N changes, and log a summary run tagged
    window=last:N to MLflow. A driver-written finding (stage gate, title "gate FAIL ...")
    counts as a gate failure, not a catch; stage events finishing-turn, budget and push
    are bookkeeping and stay out of the per-stage statistics.
Every subcommand takes --project ROOT (default: cwd) and --no-mlflow.

Inputs (read only): <root>/logs/milestones/chain.log, <root>/.milestones/config and
config.local (a key=value parse, never sourced), <runs-dir>/<sandbox>/run.json and
<runs-dir>/<sandbox>/agent-home/claude/projects/**/*.jsonl (subagent transcripts
included), <root>/.milestones/evaluation-N.md, mutations/N.jsonl, acceptance/N.json.
runs-dir defaults to $AGENT_SANDBOX_HOME/runs, else ~/agent-sandbox/runs.

grades.jsonl line (one per change; null means unknown, never estimated)
-----------------------------------------------------------------------
change_id            "milestone:<N>" | "host:<id>"
project              basename of the project root
kind                 "milestone" | "host-change"
milestone            "<N>" | null
sandboxes            [sandbox id, ...] in first-seen order
started_at, accepted_at   ISO 8601 (accepted_at: the push, else --accepted, else null)
elapsed_minutes      accepted_at - started_at
container_minutes    sum(finished_at - started_at) over run.json containers[] that start in
                     the window and, in a reused sandbox, after this milestone's latest launch
tokens_input, tokens_cache_write, tokens_cache_read, tokens_output
                     usage counted once per message.id (last line wins), lines without id ignored
cost_usd_estimate    per-model price table; null when any priced usage has an unknown model
price_table          PRICE_TABLE_VERSION
files_changed, lines_changed   git diff --shortstat of the merge (REF^1..REF) or --range
units                --units, else null
machinery_lines      line count of run-milestones.sh + SKILL.md + grade.py beside this script
config_keys          distinct keys set in .milestones/config and config.local
path                 "direct" | "single" | "single+evaluator" | "lanes"
gate_attempts, gate_failures   gate verdicts outside integrate runs (chain.log)
integrate_attempts, integrate_failures   integrate runs, and those that did not push
finishing_turns      continue launches
weakening_hits       hits reported by the last integrate run's scan
evaluation           "none" | "met" | "findings:<n>"
mutations_caught, mutations_caught_static, mutations_missed, mutations_inconclusive
criteria_without_patch   [criterion ids] (needs acceptance/N.json), else null
integrate_where      where the passing integrate gate ran
owner_entered        false until an owner amendment
owner_minutes_specify, owner_minutes_intervene, owner_minutes_review, owner_minutes_repair
missed_at_completion, regressions_later   null, or [{"text", "stage"|null, "at"}]
recorded_at          when automatic fields were last computed

events.jsonl line (append only; aligned with the seeded ledger)
---------------------------------------------------------------
Every event: type, change_id, at (filled with now when absent). Per type, see EVENT_SPECS:
finding        stage (one of STAGES), title, confirmation (executable|reviewer|owner);
               optional reviewer, severity, outcome, raised_stage, step, bundle, detail, minutes, tokens.
               Findings with the same change_id and title are one issue: its raising stage
               is the earliest event's (or raised_stage), and it is executable only when
               some event says executable. Reviewer agreement never upgrades it.
integrate      where, result (pass|fail); failure_class (code|report|environment|parity|conflict)
               required on a fail unless the rule table can derive it from failed_step /
               signal (setup-failed|missing-tool|screenshot|scan-refusal|merge-abort) /
               sandbox_gate_passed_sha. A given failure_class is the supervisor's override.
intervention   actor (supervisor|owner|agent), intervention_class (environment|context|
               reconciliation|spec), detail, minutes (required unless actor=owner).
push           sha; optional first_failed_integrate, recovery_minutes, branch, remote.
stage          stage (free text); optional applied, skipped, note, minutes, tokens.
acceptance     criterion, verdict (evidence|waived|unmet); evidence_kind (bundle-step|
               mutation|owner-approval) unless unmet; bundle-step needs bundle, step,
               test_ids; mutation needs mutation; owner-approval needs approval.
               Optional criterion_text, evaluator (reviewer-grade context, never evidence).
approval       item_kind (criterion-waiver|weakening|gate-config|gate-definition|budget),
               approval (the approvals entry); optional path, blob, hash, criterion.
budget         budget (failed_gates|finishing_turns|wall_hours), limit, count, action
               (warning|exhausted|extra-attempt); optional events_count, chain_count, approval.
control-proof  control, exit_code, outcome_line (verbatim), demonstrated; optional
               gate_hash, live_gate_hash.
Evidence identity and eligibility fields, optional on integrate, push, acceptance and
control-proof: sha, tree, gate_hash, approved_gate_hash, seal (sha256 of evidence.json),
bundle, where, dirty, not_run, steps, produced_by (integrate|gate|check|mutate).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent

# ---------------------------------------------------------------- prices

PRICE_TABLE_VERSION = "anthropic-api-2026-06-24 (estimate)"
# USD per million tokens: input, output, cache read. Cache writes are 1.25x input for the
# 5-minute TTL and 2x for the 1-hour TTL. A model absent here has no price: cost is null.
PRICES = {
    "claude-fable-5-1": (10.0, 50.0, 0.25),
    "claude-fable-5": (10.0, 50.0, 1.0),
    "claude-mythos-5": (10.0, 50.0, 1.0),
    "claude-opus-5": (5.0, 25.0, 0.5),
    "claude-opus-4-8": (5.0, 25.0, 0.5),
    "claude-opus-4-7": (5.0, 25.0, 0.5),
    "claude-opus-4-6": (5.0, 25.0, 0.5),
    "claude-sonnet-5": (2.0, 10.0, 0.2),
    "claude-sonnet-4-6": (3.0, 15.0, 0.3),
    "claude-haiku-4-5": (1.0, 5.0, 0.1),
}
FAST_MULTIPLIER = {"claude-opus-5": 2.0}  # fast mode: $10/$50 on Opus 5; unknown elsewhere


def normalise_model(model: str | None) -> str | None:
    if not model:
        return None
    m = re.sub(r"\[.*?\]$", "", model.strip())
    m = re.sub(r"-\d{8}$", "", m)
    m = re.sub(r"^(us\.|eu\.|global\.)?anthropic\.", "", m)
    return m


def message_cost(model: str | None, usage: dict) -> float | None:
    m = normalise_model(model)
    if m not in PRICES:
        return None
    inp, out, read = PRICES[m]
    mult = 1.0
    if usage.get("speed") == "fast":
        if m not in FAST_MULTIPLIER:
            return None
        mult = FAST_MULTIPLIER[m]
    cw = usage.get("cache_write", 0)
    w1h = min(usage.get("cache_write_1h", 0), cw)
    w5m = cw - w1h
    total = (usage.get("input", 0) * inp + usage.get("output", 0) * out + usage.get("cache_read", 0) * read
             + w5m * inp * 1.25 + w1h * inp * 2.0)
    return total * mult / 1e6


# ---------------------------------------------------------------- time

ISO = r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})"


def parse_iso(s) -> dt.datetime | None:
    if not s or not isinstance(s, str):
        return None
    try:
        t = dt.datetime.fromisoformat(s.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.astimezone()


def now_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def minutes_between(a, b) -> float | None:
    ta, tb = parse_iso(a) if isinstance(a, str) else a, parse_iso(b) if isinstance(b, str) else b
    if ta is None or tb is None:
        return None
    return round((tb - ta).total_seconds() / 60.0, 2)


def warn(msg: str) -> None:
    print(f"grade.py: warning: {msg}", file=sys.stderr)


# ---------------------------------------------------------------- config

_KEY_RE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def _config_value(rest: str) -> str:
    rest = rest.lstrip()
    if rest[:1] in ("'", '"'):
        q, out, i = rest[0], [], 1
        while i < len(rest):
            c = rest[i]
            if q == '"' and c == "\\" and i + 1 < len(rest):
                out.append(rest[i + 1])
                i += 2
                continue
            if c == q:
                break
            out.append(c)
            i += 1
        return "".join(out)
    m = re.match(r"[^\s#]*", rest)
    return m.group(0) if m else ""


def parse_config(path: Path) -> dict:
    """KEY=value lines of a shell config, read as text. Nothing is expanded or executed."""
    vals: dict[str, str] = {}
    try:
        text = path.read_text()
    except OSError:
        return vals
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        m = _KEY_RE.match(line)
        if m:
            vals[m.group(1)] = _config_value(m.group(2))
    return vals


def project_config(root: Path) -> tuple[dict, int]:
    base = parse_config(root / ".milestones" / "config")
    local = parse_config(root / ".milestones" / "config.local")
    return {**base, **local}, len(set(base) | set(local))


# ---------------------------------------------------------------- chain.log

RE_LAUNCH = re.compile(rf"^=== launch (milestone|continue|gate) (\S+)(?: in (\S+))? as (\S+): ({ISO}) ===")
RE_TURN = re.compile(rf"^=== milestone (\S+) in (\S+) \(unit (\S+)\): ({ISO}) ===")
RE_GATE_ONLY = re.compile(rf"^=== gate only, milestone (\S+) in (\S+) \(unit (\S+)\): ({ISO}) ===")
RE_CONTINUE = re.compile(rf"^=== continue in (\S+)(?: \(unit (\S+)\))?: ({ISO}) ===")
RE_INTEGRATE = re.compile(rf"^=== integrate milestone (\S+) from (\S+): ({ISO}) ===")
RE_HEADER = re.compile(r"^=== ")
RE_SANDBOX = re.compile(r"^sandbox: (\S+)\s*$")
RE_EVIDENCE = re.compile(r"^gate (pass|FAIL) exit=(\d+) milestone=(\S+)(.*)$")
RE_SUMMARY = re.compile(r"^milestone (\S+): gate (passed|FAILED)")
RE_PUSHED = re.compile(rf"^integrate milestone (\S+): pushed .*?({ISO})\s*$")
RE_PUSHED_FREE = re.compile(rf"^milestone (\S+) PUSHED ({ISO})")
RE_INTEGRATE_END_FAIL = re.compile(r"^integrate milestone (\S+): (refused|host gate FAILED|push failed)")
RE_MERGED = re.compile(r"^\s+merged (\S+) as ([0-9a-f]{7,40})\b")
RE_WEAK_LISTED = re.compile(r"^\s+weakening hits all listed in \S+: (.*)$")
RE_WEAK_NONE = re.compile(r"^\s+weakening scan: no hits")
RE_WEAK_REFUSED = re.compile(r"refused: test weakening not listed")
RE_WEAK_ITEM = re.compile(r"^ {4}(\S+) (\S+)\s*$")
RE_UNIT_N = re.compile(r"-([A-Za-z0-9]+)-\d{8}T\d{6}$")
RE_KV = re.compile(r'(\w+)=("[^"]*"|\S+)')


class Chain:
    """What chain.log says about each milestone."""

    def __init__(self, text: str):
        self.segments: dict[str, list[tuple[dt.datetime, str]]] = defaultdict(list)  # sandbox -> (ts, milestone)
        self.times: dict[str, list[dt.datetime]] = defaultdict(list)
        self.sandboxes: dict[str, list[str]] = defaultdict(list)
        self.starts: dict[str, dt.datetime] = {}
        self.pushes: dict[str, dt.datetime] = {}
        self.gates: dict[str, list[dict]] = defaultdict(list)  # {result, where, integrate, paired}
        self.turn_units: dict[str, set] = defaultdict(set)
        self.integrates: dict[str, list[dict]] = defaultdict(list)
        self.merges: dict[str, str] = {}
        self.weakening: dict[str, int] = {}
        self.local_checks: list[dict] = []
        self._parse(text)

    def _sb(self, n, sb, ts):
        if sb and sb not in self.sandboxes[n]:
            self.sandboxes[n].append(sb)
        if sb and ts:
            self.segments[sb].append((ts, n))

    def _touch(self, n, ts, start=False):
        if ts is None:
            return
        self.times[n].append(ts)
        if start and (n not in self.starts or ts < self.starts[n]):
            self.starts[n] = ts

    def _parse(self, text: str) -> None:
        last_ts = None
        pending: list[str] = []  # launches of kind milestone without a sandbox, FIFO
        integ_n = None
        weak_refused_n = None
        for raw in text.splitlines():
            line = raw.rstrip("\n")
            found = re.findall(ISO, line)
            ts = parse_iso(found[-1]) if found else None
            if ts:
                last_ts = ts
            if weak_refused_n is not None:
                m = RE_WEAK_ITEM.match(line)
                if m:
                    self.weakening[weak_refused_n] = self.weakening.get(weak_refused_n, 0) + 1
                    continue
                weak_refused_n = None
            if RE_HEADER.match(line):
                integ_n = None
            m = RE_LAUNCH.match(line)
            if m:
                kind, n, sb, unit, t = m.group(1), m.group(2), m.group(3), m.group(4), parse_iso(m.group(5))
                self._touch(n, t, start=(kind == "milestone"))
                if kind == "continue":
                    self.turn_units[n].add(unit)
                if sb:
                    self._sb(n, sb, t)
                elif kind == "milestone":
                    pending.append(n)
                continue
            m = RE_TURN.match(line)
            if m:
                n, sb, t = m.group(1), m.group(2), parse_iso(m.group(4))
                self._touch(n, t, start=True)
                self._sb(n, sb, t)
                if n in pending:
                    pending.remove(n)
                continue
            m = RE_GATE_ONLY.match(line)
            if m:
                n, sb, t = m.group(1), m.group(2), parse_iso(m.group(4))
                self._touch(n, t)
                self._sb(n, sb, t)
                continue
            m = RE_CONTINUE.match(line)
            if m:
                sb, unit, t = m.group(1), m.group(2), parse_iso(m.group(3))
                um = RE_UNIT_N.search(unit or "")
                if um:
                    n = um.group(1)
                    self.turn_units[n].add(unit)
                    self._touch(n, t)
                    self._sb(n, sb, t)
                continue
            m = RE_SANDBOX.match(line)
            if m and pending:
                n = pending.pop(0)
                self._sb(n, m.group(1), last_ts)
                continue
            m = RE_INTEGRATE.match(line)
            if m:
                integ_n, t = m.group(1), parse_iso(m.group(3))
                self._touch(integ_n, t)
                self.integrates[integ_n].append({"at": t, "pushed": False, "where": None})
                continue
            m = RE_EVIDENCE.match(line)
            if m:
                result, n, rest = m.group(1), m.group(3), m.group(4)
                kv = {k: v.strip('"') for k, v in RE_KV.findall(rest)}
                t = parse_iso(kv.get("at")) or last_ts
                where = kv.get("where")
                if where == "local":
                    self.local_checks.append({"at": t, "result": result})
                    continue
                in_integ = integ_n == n
                self._touch(n, t)
                self.gates[n].append({"result": result, "where": where, "integrate": in_integ, "paired": False})
                if in_integ and self.integrates[n]:
                    self.integrates[n][-1]["where"] = where
                continue
            m = RE_SUMMARY.match(line)
            if m:
                n, result = m.group(1), "pass" if m.group(2) == "passed" else "FAIL"
                self._touch(n, ts or last_ts)
                prev = self.gates[n][-1] if self.gates[n] else None
                if prev and not prev["paired"] and prev["result"] == result and not prev["integrate"] \
                        and prev.get("summary") is None:
                    prev["paired"] = True
                else:
                    self.gates[n].append({"result": result, "where": None, "integrate": integ_n == n,
                                          "paired": True, "summary": True})
                continue
            m = RE_MERGED.match(line)
            if m and integ_n:
                self.merges[integ_n] = m.group(2)
                continue
            m = RE_WEAK_LISTED.match(line)
            if m and integ_n:
                self.weakening[integ_n] = len([x for x in m.group(1).split(";") if x.strip()])
                continue
            if RE_WEAK_NONE.match(line) and integ_n:
                self.weakening[integ_n] = 0
                continue
            m = RE_PUSHED.match(line) or RE_PUSHED_FREE.match(line)
            if m:
                n, t = m.group(1), parse_iso(m.group(2))
                self._touch(n, t)
                self.pushes[n] = t
                if self.integrates[n]:
                    self.integrates[n][-1]["pushed"] = True
                continue
            m = RE_INTEGRATE_END_FAIL.match(line)
            if m:
                n = m.group(1)
                if RE_WEAK_REFUSED.search(line):
                    self.weakening[n] = 0
                    weak_refused_n = n
                continue

    def owner_at(self, sandbox: str, t: dt.datetime) -> str | None:
        segs = sorted(self.segments.get(sandbox, []), key=lambda x: x[0])
        if not segs:
            return None
        owner = segs[0][1]
        for ts, n in segs:
            if ts <= t:
                owner = n
        return owner

    def window(self, n: str) -> tuple[dt.datetime | None, dt.datetime | None]:
        times = self.times.get(n)
        if not times:
            return None, None
        return self.starts.get(n, min(times)), self.pushes.get(n, max(times))

    def overlaps_other_sandbox(self, n: str, start, end) -> bool:
        if start is None:
            return False
        end = end or dt.datetime.max.replace(tzinfo=dt.timezone.utc)
        mine = set(self.sandboxes.get(n, []))
        for other in self.times:
            if other == n:
                continue
            o_start, o_end = self.window(other)
            if o_start is None:
                continue
            theirs = set(self.sandboxes.get(other, []))
            if theirs and mine and theirs <= mine:
                continue  # the same sandbox reused serially is not a lane
            if o_start < end and start < o_end:
                return True
        return False


def read_chain(root: Path) -> Chain:
    p = root / "logs" / "milestones" / "chain.log"
    try:
        return Chain(p.read_text(errors="replace"))
    except OSError:
        return Chain("")


# ---------------------------------------------------------------- sandbox records


def runs_dir_default() -> Path:
    home = os.environ.get("AGENT_SANDBOX_HOME")
    return Path(home) / "runs" if home else Path.home() / "agent-sandbox" / "runs"


def in_window(t, start, end) -> bool:
    return t is not None and (start is None or t >= start) and (end is None or t <= end)


def container_minutes(run_json: Path, chain: Chain, n: str, sandbox: str, start, end) -> float | None:
    try:
        data = json.loads(run_json.read_text())
    except (OSError, ValueError):
        return None
    total = 0.0
    for c in data.get("containers") or []:
        s, f = parse_iso(c.get("started_at")), parse_iso(c.get("finished_at"))
        if s is None or f is None or not in_window(s, start, end):
            continue
        owner = chain.owner_at(sandbox, s)
        if owner is not None and owner != n:
            continue
        total += (f - s).total_seconds() / 60.0
    return total


def stream_usage(projects_dir: Path) -> dict:
    """message.id -> {ts, model, input, cache_write, cache_write_1h, cache_read, output, speed}; last line wins."""
    msgs: dict[str, dict] = {}
    if not projects_dir.is_dir():
        return msgs
    for f in sorted(projects_dir.rglob("*.jsonl")):
        try:
            fh = f.open("r", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                msg = d.get("message") if isinstance(d, dict) else None
                if not isinstance(msg, dict):
                    continue
                mid, usage = msg.get("id"), msg.get("usage")
                if not mid or not isinstance(usage, dict):
                    continue
                cc = usage.get("cache_creation") or {}
                msgs[mid] = {
                    "ts": parse_iso(d.get("timestamp")),
                    "model": msg.get("model"),
                    "input": int(usage.get("input_tokens") or 0),
                    "cache_write": int(usage.get("cache_creation_input_tokens") or 0),
                    "cache_write_1h": int(cc.get("ephemeral_1h_input_tokens") or 0) if isinstance(cc, dict) else 0,
                    "cache_read": int(usage.get("cache_read_input_tokens") or 0),
                    "output": int(usage.get("output_tokens") or 0),
                    "speed": usage.get("speed"),
                }
    return msgs


# ---------------------------------------------------------------- size and machinery


def git_shortstat(root: Path, a: str, b: str) -> tuple[int | None, int | None]:
    try:
        p = subprocess.run(["git", "-C", str(root), "diff", "--shortstat", a, b], capture_output=True, text=True,
                           timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None, None
    if p.returncode != 0:
        return None, None
    out = p.stdout
    files = re.search(r"(\d+) files? changed", out)
    ins = re.search(r"(\d+) insertions?", out)
    dels = re.search(r"(\d+) deletions?", out)
    if not out.strip():
        return 0, 0
    return (int(files.group(1)) if files else 0,
            (int(ins.group(1)) if ins else 0) + (int(dels.group(1)) if dels else 0))


def machinery_lines() -> int | None:
    total, seen = 0, False
    for name in ("run-milestones.sh", "SKILL.md", "grade.py"):
        try:
            with (HERE / name).open("rb") as fh:
                total += sum(1 for _ in fh)
            seen = True
        except OSError:
            pass
    return total if seen else None


def size_bucket(files, lines) -> str:
    if lines is None:
        return "unknown"
    if lines <= 150 and (files or 0) <= 10:
        return "small"
    if lines <= 1500:
        return "medium"
    return "large"


# ---------------------------------------------------------------- milestone files


def evaluation_result(root: Path, n: str) -> str:
    p = root / ".milestones" / f"evaluation-{n}.md"
    try:
        text = p.read_text()
    except OSError:
        return "none"
    k = sum(1 for ln in text.splitlines()
            if re.search(r"\bnot met\b|\bunmet\b|^\s*[-*]?\s*finding\b", ln, re.IGNORECASE))
    return "met" if k == 0 else f"findings:{k}"


def mutation_results(root: Path, n: str) -> dict:
    out = {"mutations_caught": None, "mutations_caught_static": None, "mutations_missed": None,
           "mutations_inconclusive": None, "criteria_without_patch": None}
    p = root / ".milestones" / "mutations" / f"{n}.jsonl"
    records = []
    if p.exists():
        for ln in p.read_text().splitlines():
            try:
                records.append(json.loads(ln))
            except ValueError:
                continue
        counts = defaultdict(int)
        for r in records:
            counts[str(r.get("verdict"))] += 1
        out.update(mutations_caught=counts["caught"], mutations_caught_static=counts["caught-static"],
                   mutations_missed=counts["missed"], mutations_inconclusive=counts["inconclusive"])
    acc = root / ".milestones" / "acceptance" / f"{n}.json"
    try:
        criteria = json.loads(acc.read_text()).get("criteria")
    except (OSError, ValueError, AttributeError):
        criteria = None
    if isinstance(criteria, list):
        cited = {str(r.get("criterion")) for r in records}
        ids = []
        for i, c in enumerate(criteria, 1):
            cid = str(c.get("id", c.get("index", i))) if isinstance(c, dict) else str(i)
            if cid not in cited:
                ids.append(cid)
        out["criteria_without_patch"] = ids
    return out


# ---------------------------------------------------------------- ledgers


def milestones_dir(root: Path) -> Path:
    return root / ".milestones"


def read_ledger(path: Path, what: str) -> list[dict]:
    out = []
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return out
    for i, ln in enumerate(lines, 1):
        if not ln.strip():
            continue
        try:
            d = json.loads(ln)
        except ValueError:
            warn(f"{path.name} line {i}: not JSON, skipped")
            continue
        if isinstance(d, dict):
            out.append(d)
    return out


def write_grades(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".jsonl.tmp")
    tmp.write_text("".join(json.dumps(r) + "\n" for r in records))
    os.replace(tmp, path)


# ---------------------------------------------------------------- record

OWNER_MINUTE_KEYS = ("specify", "intervene", "review", "repair")
STAGES = ("spec-clarification", "plan-doc-review", "code-review", "supervisor-review", "evaluator", "gate", "mutate",
          "integrate", "owner")


def owner_defaults() -> dict:
    d = {"owner_entered": False}
    for k in OWNER_MINUTE_KEYS:
        d[f"owner_minutes_{k}"] = None
    d["missed_at_completion"] = None
    d["regressions_later"] = None
    return d


def compute_record(root: Path, args) -> dict:
    project = root.name
    chain = read_chain(root)
    cfg, config_keys = project_config(root)
    rec: dict = {}
    if args.change:
        cid = f"host:{args.change}"
        start, end = parse_iso(args.started), parse_iso(args.accepted)
        if start is None or end is None:
            raise UsageError("record --change needs --started and --accepted as ISO 8601 times")
        checks = [c for c in chain.local_checks if in_window(c["at"], start, end)]
        rec.update(change_id=cid, project=project, kind="host-change", milestone=None, sandboxes=[],
                   started_at=start.isoformat(), accepted_at=end.isoformat(),
                   elapsed_minutes=minutes_between(start, end), container_minutes=None,
                   tokens_input=None, tokens_cache_write=None, tokens_cache_read=None, tokens_output=None,
                   cost_usd_estimate=None, price_table=PRICE_TABLE_VERSION)
        path = "direct"
        gates = {"gate_attempts": len(checks) if checks else None,
                 "gate_failures": sum(1 for c in checks if c["result"] == "FAIL") if checks else None,
                 "integrate_attempts": None, "integrate_failures": None, "finishing_turns": None,
                 "weakening_hits": None, "evaluation": "none"}
        muts = {"mutations_caught": None, "mutations_caught_static": None, "mutations_missed": None,
                "mutations_inconclusive": None, "criteria_without_patch": None}
        integrate_where = None
        merge = args.merge
    else:
        n = str(args.milestone)
        cid = f"milestone:{n}"
        c_start, _ = chain.window(n)
        start = parse_iso(args.started) or c_start
        end = parse_iso(args.accepted) or chain.pushes.get(n)
        if start is None:
            raise UsageError(f"chain.log has no launch for milestone {n}; pass --started")
        sandboxes = list(chain.sandboxes.get(n, []))
        runs = Path(args.runs_dir) if args.runs_dir else runs_dir_default()
        cmin, usage_known = None, False
        tok = {"input": 0, "cache_write": 0, "cache_read": 0, "output": 0}
        cost, cost_unknown = 0.0, False
        for sb in sandboxes:
            rj = runs / sb / "run.json"
            if rj.exists():
                m = container_minutes(rj, chain, n, sb, start, end)
                if m is not None:
                    cmin = (cmin or 0.0) + m
            pdir = runs / sb / "agent-home" / "claude" / "projects"
            if pdir.is_dir():
                usage_known = True
                for u in stream_usage(pdir).values():
                    if not in_window(u["ts"], start, end):
                        continue
                    owner = chain.owner_at(sb, u["ts"])
                    if owner is not None and owner != n:
                        continue
                    for k in tok:
                        tok[k] += u[k]
                    if u["input"] + u["cache_write"] + u["cache_read"] + u["output"] == 0:
                        continue
                    c = message_cost(u["model"], u)
                    if c is None:
                        cost_unknown = True
                    else:
                        cost += c
        rec.update(change_id=cid, project=project, kind="milestone", milestone=n, sandboxes=sandboxes,
                   started_at=start.isoformat(), accepted_at=end.isoformat() if end else None,
                   elapsed_minutes=minutes_between(start, end) if end else None,
                   container_minutes=round(cmin, 2) if cmin is not None else None)
        if usage_known:
            rec.update(tokens_input=tok["input"], tokens_cache_write=tok["cache_write"],
                       tokens_cache_read=tok["cache_read"], tokens_output=tok["output"],
                       cost_usd_estimate=None if cost_unknown else round(cost, 6))
        else:
            rec.update(tokens_input=None, tokens_cache_write=None, tokens_cache_read=None, tokens_output=None,
                       cost_usd_estimate=None)
        rec["price_table"] = PRICE_TABLE_VERSION
        if chain.overlaps_other_sandbox(n, start, end):
            path = "lanes"
        elif cfg.get(f"EVALUATE_{n}") == "1":
            path = "single+evaluator"
        else:
            path = "single"
        verdicts = [g for g in chain.gates.get(n, []) if not g["integrate"]]
        integ = chain.integrates.get(n, [])
        known = bool(chain.times.get(n))
        gates = {"gate_attempts": len(verdicts) if known else None,
                 "gate_failures": sum(1 for g in verdicts if g["result"] == "FAIL") if known else None,
                 "integrate_attempts": len(integ) if known else None,
                 "integrate_failures": sum(1 for i in integ if not i["pushed"]) if known else None,
                 "finishing_turns": len(chain.turn_units.get(n, ())) if known else None,
                 "weakening_hits": chain.weakening.get(n),
                 "evaluation": evaluation_result(root, n)}
        muts = mutation_results(root, n)
        integrate_where = None
        for e in read_ledger(milestones_dir(root) / "events.jsonl", "events"):
            if e.get("type") == "integrate" and e.get("change_id") == cid and e.get("result") == "pass":
                integrate_where = e.get("where")
        if integrate_where is None:
            passed = [i["where"] for i in integ if i["where"]]
            integrate_where = passed[-1] if passed else None
        merge = args.merge or chain.merges.get(n)

    files = lines = None
    if args.range:
        a, _, b = args.range.partition("..")
        files, lines = git_shortstat(root, a, b or "HEAD")
    elif merge:
        files, lines = git_shortstat(root, f"{merge}^1", merge)
    rec.update(files_changed=files, lines_changed=lines, units=args.units, machinery_lines=machinery_lines(),
               config_keys=config_keys, path=path)
    rec.update(gates)
    rec.update(muts)
    rec["integrate_where"] = integrate_where
    rec.update(owner_defaults())
    rec["recorded_at"] = now_iso()
    return rec


def split_stage(text: str) -> dict:
    m = re.match(r"^\s*([a-z-]+)\s*:\s*(.+)$", text, re.DOTALL)
    if m and m.group(1) in STAGES:
        return {"text": m.group(2).strip(), "stage": m.group(1), "at": now_iso()}
    return {"text": text.strip(), "stage": None, "at": now_iso()}


def apply_amendments(rec: dict, args) -> bool:
    changed = False
    if args.owner_minutes:
        for part in args.owner_minutes.split(","):
            if not part.strip():
                continue
            k, sep, v = part.partition("=")
            k = k.strip()
            if not sep or k not in OWNER_MINUTE_KEYS:
                raise UsageError(f"--owner-minutes takes {','.join(k2 + '=N' for k2 in OWNER_MINUTE_KEYS)}; got {part!r}")
            try:
                num = float(v)
            except ValueError:
                raise UsageError(f"--owner-minutes {k}: {v!r} is not a number") from None
            rec[f"owner_minutes_{k}"] = int(num) if num.is_integer() else num
        changed = True
    for flag, key in ((args.missed, "missed_at_completion"), (args.regression, "regressions_later")):
        if flag:
            rec[key] = list(rec.get(key) or []) + [split_stage(t) for t in flag]
            changed = True
    if changed:
        rec["owner_entered"] = True
        rec["owner_amended_at"] = now_iso()
    return changed


def cmd_record(root: Path, args) -> int:
    if bool(args.change) == (args.milestone is not None):
        raise UsageError("record takes a milestone number or --change <id>, not both")
    if args.change and not re.fullmatch(r"[A-Za-z0-9._-]+", args.change):
        raise UsageError("--change id: letters, digits, . _ - only")
    if args.milestone is not None and not re.fullmatch(r"[A-Za-z0-9._-]+", str(args.milestone)):
        raise UsageError("milestone: letters, digits, . _ - only")
    cid = f"host:{args.change}" if args.change else f"milestone:{args.milestone}"
    gpath = milestones_dir(root) / "grades.jsonl"
    records = read_ledger(gpath, "grades")
    idx = next((i for i, r in enumerate(records) if r.get("change_id") == cid), None)
    amending = bool(args.owner_minutes or args.missed or args.regression)
    if idx is not None and amending and not args.refresh:
        rec = dict(records[idx])
    else:
        rec = compute_record(root, args)
        if idx is not None:
            old = records[idx]
            for k in owner_defaults():
                rec[k] = old.get(k, rec[k])
            if "owner_amended_at" in old:
                rec["owner_amended_at"] = old["owner_amended_at"]
    apply_amendments(rec, args)
    if idx is None:
        records.append(rec)
    else:
        records[idx] = rec
    write_grades(gpath, records)
    print(f"grade.py: {cid} written to {gpath}")
    if not args.no_mlflow:
        mlflow_log_record(rec, root.name)
    return 0


# ---------------------------------------------------------------- events

CONFIRMATIONS = ("executable", "reviewer", "owner")
FAILURE_CLASSES = ("code", "report", "environment", "parity", "conflict")
IDENTITY = {"sha": "str", "tree": "str", "gate_hash": "str", "approved_gate_hash": "str", "seal": "hex64",
            "bundle": "str", "dirty": "bool", "not_run": "int", "steps": "str",
            "produced_by": ("enum", ("integrate", "gate", "check", "mutate"))}

EVENT_SPECS: dict[str, dict] = {
    "finding": {
        "required": {"stage": ("enum", STAGES), "title": "str", "confirmation": ("enum", CONFIRMATIONS)},
        "optional": {"reviewer": "str", "severity": "str", "outcome": "str", "raised_stage": ("enum", STAGES),
                     "step": "str", "bundle": "str", "detail": "str", "minutes": "num?", "tokens": "int?"},
    },
    "integrate": {
        "required": {"where": "str", "result": ("enum", ("pass", "fail"))},
        "optional": {"failure_class": ("enum", FAILURE_CLASSES), "failed_step": "str",
                     "signal": ("enum", ("setup-failed", "missing-tool", "screenshot", "scan-refusal", "merge-abort")),
                     "sandbox_gate_passed_sha": "str", "detail": "str", "failure_class_source": "str", **IDENTITY},
    },
    "intervention": {
        "required": {"actor": ("enum", ("supervisor", "owner", "agent")),
                     "intervention_class": ("enum", ("environment", "context", "reconciliation", "spec")),
                     "detail": "str"},
        "optional": {"minutes": "num?"},
    },
    "push": {
        "required": {"sha": "str"},
        "optional": {"first_failed_integrate": "iso", "recovery_minutes": "num?", "branch": "str", "remote": "str",
                     "detail": "str", **{k: v for k, v in IDENTITY.items() if k != "sha"}},
    },
    "stage": {
        "required": {"stage": "str"},
        "optional": {"applied": "int", "skipped": "int", "note": "str", "minutes": "num?", "tokens": "int?"},
    },
    "acceptance": {
        "required": {"criterion": "id", "verdict": ("enum", ("evidence", "waived", "unmet"))},
        "optional": {"evidence_kind": ("enum", ("bundle-step", "mutation", "owner-approval")), "criterion_text": "str",
                     "step": "str", "test_ids": "list", "mutation": "str", "approval": "str", "evaluator": "str",
                     **IDENTITY},
    },
    "approval": {
        "required": {"item_kind": ("enum", ("criterion-waiver", "weakening", "gate-config", "gate-definition",
                                            "budget")),
                     "approval": "str"},
        "optional": {"path": "str", "blob": "str", "hash": "str", "criterion": "id", "confirmed_at": "iso",
                     "detail": "str"},
    },
    "budget": {
        "required": {"budget": ("enum", ("failed_gates", "finishing_turns", "wall_hours")), "limit": "num",
                     "count": "num", "action": ("enum", ("warning", "exhausted", "extra-attempt"))},
        "optional": {"events_count": "int", "chain_count": "int", "approval": "str", "detail": "str"},
    },
    "control-proof": {
        "required": {"control": "str", "exit_code": "int", "outcome_line": "str", "demonstrated": "bool"},
        "optional": {"live_gate_hash": "str", "attempt": "str", **IDENTITY},
    },
}
CHANGE_ID_RE = re.compile(r"^(milestone|host):[A-Za-z0-9._-]+$")


def _coerce(spec, raw):
    """Turn a CLI string into the spec's type. Raises ValueError."""
    nullable = isinstance(spec, str) and spec.endswith("?")
    kind = spec[:-1] if nullable else spec
    if nullable and raw in ("null", ""):
        return None
    if isinstance(kind, tuple):
        return raw
    if kind in ("str", "iso", "hex64"):
        return raw
    if kind == "int":
        return int(raw)
    if kind == "num":
        f = float(raw)
        return int(f) if f.is_integer() else f
    if kind == "bool":
        low = raw.lower()
        if low in ("true", "yes", "1"):
            return True
        if low in ("false", "no", "0"):
            return False
        raise ValueError(f"{raw!r} is not a boolean")
    if kind == "list":
        if raw.startswith("["):
            return json.loads(raw)
        return [x.strip() for x in raw.split(",") if x.strip()]
    if kind == "id":
        return int(raw) if re.fullmatch(r"\d+", raw) else raw
    return raw


def _check(spec, value) -> str | None:
    nullable = isinstance(spec, str) and spec.endswith("?")
    kind = spec[:-1] if nullable else spec
    if value is None:
        return None if nullable else "must not be null"
    if isinstance(kind, tuple):
        return None if value in kind[1] else f"must be one of {', '.join(kind[1])}"
    ok = {
        "str": isinstance(value, str) and value != "",
        "iso": parse_iso(value) is not None,
        "hex64": isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None,
        "int": isinstance(value, int) and not isinstance(value, bool),
        "num": isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value),
        "bool": isinstance(value, bool),
        "list": isinstance(value, list) and all(isinstance(x, str) for x in value),
        "id": (isinstance(value, int) and not isinstance(value, bool)) or (isinstance(value, str) and value != ""),
    }.get(kind, True)
    return None if ok else f"must be {kind}"


def classify_integrate_failure(ev: dict) -> str:
    """The rule table for an integrate failure's class (U4b)."""
    signal, step = ev.get("signal"), (ev.get("failed_step") or "")
    if signal == "merge-abort":
        return "conflict"
    if signal == "scan-refusal":
        return "report"
    if signal in ("setup-failed", "missing-tool") or step == "setup":
        return "environment"
    if signal == "screenshot" and ev.get("sha") and ev.get("sha") == ev.get("sandbox_gate_passed_sha"):
        return "parity"
    return "code"


def validate_event(ev: dict) -> tuple[bool, list[str]]:
    errors = []
    t = ev.get("type")
    spec = EVENT_SPECS.get(t)
    if spec is None:
        return False, [f"type must be one of {', '.join(EVENT_SPECS)}"]
    if not isinstance(ev.get("change_id"), str) or not CHANGE_ID_RE.match(ev["change_id"]):
        errors.append("change_id must be milestone:<N> or host:<id>")
    if parse_iso(ev.get("at")) is None:
        errors.append("at must be an ISO 8601 time")
    for k, s in spec["required"].items():
        if k not in ev:
            errors.append(f"{k} is required for {t}")
        else:
            e = _check(s, ev[k])
            if e:
                errors.append(f"{k} {e}")
    for k, s in spec["optional"].items():
        if k in ev:
            e = _check(s, ev[k])
            if e:
                errors.append(f"{k} {e}")
    if t == "integrate" and ev.get("result") == "fail" and "failure_class" not in ev:
        errors.append("failure_class is required for a failed integrate (or give failed_step / signal)")
    if t == "intervention" and ev.get("actor") != "owner" and not isinstance(ev.get("minutes"), (int, float)):
        errors.append("minutes is required for a supervisor or agent intervention")
    if t == "acceptance" and ev.get("verdict") in ("evidence", "waived"):
        kind = ev.get("evidence_kind")
        need = {"bundle-step": ("bundle", "step", "test_ids"), "mutation": ("mutation",),
                "owner-approval": ("approval",)}
        if kind is None:
            errors.append("evidence_kind is required unless verdict=unmet")
        else:
            for k in need.get(kind, ()):
                if not ev.get(k):
                    errors.append(f"{k} is required for evidence_kind={kind}")
            if ev.get("verdict") == "waived" and kind != "owner-approval":
                errors.append("a waived criterion needs evidence_kind=owner-approval")
            if kind == "bundle-step" and ev.get("test_ids") == []:
                errors.append("test_ids must name at least one test")
    return not errors, errors


def build_event(args) -> dict:
    t = args.type
    spec = EVENT_SPECS.get(t)
    if spec is None:
        raise UsageError(f"event type must be one of {', '.join(EVENT_SPECS)}")
    fields = {**spec["required"], **spec["optional"]}
    ev: dict = {"type": t, "change_id": args.change}
    if args.json:
        try:
            extra = json.loads(args.json)
        except ValueError as e:
            raise UsageError(f"--json: {e}") from None
        if not isinstance(extra, dict):
            raise UsageError("--json must be an object")
        ev.update(extra)
        ev["type"] = t
        if args.change:
            ev["change_id"] = args.change
    for pair in args.fields:
        k, sep, v = pair.partition("=")
        if not sep:
            raise UsageError(f"field {pair!r}: expected key=value")
        if k in ("type", "change_id"):
            raise UsageError(f"{k} comes from the subcommand and --change")
        if k == "at":
            ev["at"] = v
            continue
        try:
            ev[k] = _coerce(fields[k], v) if k in fields else _coerce_unknown(v)
        except (ValueError, TypeError) as e:
            raise UsageError(f"field {k}: {e}") from None
    if t == "integrate" and ev.get("result") == "fail":
        if "failure_class" in ev:
            ev.setdefault("failure_class_source", "given")
        elif ev.get("failed_step") or ev.get("signal"):
            ev["failure_class"] = classify_integrate_failure(ev)
            ev["failure_class_source"] = "rule"
    ev.setdefault("at", now_iso())
    at = ev.pop("at")
    ev["at"] = at
    return ev


def _coerce_unknown(v: str):
    try:
        return json.loads(v)
    except ValueError:
        return v


def cmd_event(root: Path, args) -> int:
    ev = build_event(args)
    ok, errors = validate_event(ev)
    if not ok:
        for e in errors:
            print(f"grade.py: event {args.type}: {e}", file=sys.stderr)
        return 2
    p = milestones_dir(root) / "events.jsonl"
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a") as fh:
        fh.write(json.dumps(ev) + "\n")
    print(f"grade.py: {ev['type']} event for {ev['change_id']} appended to {p}")
    return 0


# ---------------------------------------------------------------- report


def _latest(*times) -> dt.datetime:
    parsed = [t for t in (parse_iso(x) for x in times) if t is not None]
    return max(parsed) if parsed else dt.datetime.min.replace(tzinfo=dt.timezone.utc)


# Stage names the driver writes for bookkeeping (a --continue launch, a budget, a push): not
# review stages, so they never enter the per-stage catch statistics.
BOOKKEEPING_STAGES = ("finishing-turn", "budget", "push")


def is_driver_gate_failure(e: dict) -> bool:
    return (e.get("type") == "finding" and e.get("stage") == "gate"
            and str(e.get("title") or "").startswith("gate FAIL"))


def build_report(root: Path, last: int = 20) -> dict:
    grades = read_ledger(milestones_dir(root) / "grades.jsonl", "grades")
    events = [e for e in read_ledger(milestones_dir(root) / "events.jsonl", "events")
              if isinstance(e.get("change_id"), str)]
    activity: dict[str, dt.datetime] = {}
    for g in grades:
        cid = g.get("change_id")
        if cid:
            activity[cid] = max(activity.get(cid, _latest()), _latest(g.get("accepted_at"), g.get("started_at")))
    for e in events:
        cid = e["change_id"]
        activity[cid] = max(activity.get(cid, _latest()), _latest(e.get("at")))
    window = [c for c, _ in sorted(activity.items(), key=lambda kv: kv[1])][-last:] if last > 0 else []
    win = set(window)
    grades = [g for g in grades if g.get("change_id") in win]
    events = sorted((e for e in events if e["change_id"] in win), key=lambda e: _latest(e.get("at")))

    # Findings: one issue per (change, title); the earliest event raises it. A "gate FAIL ..."
    # finding at stage gate is the driver's own record of a failed sandbox gate (it feeds the
    # failed_gates budget): a gate failure, counted apart, never a catch of a named defect.
    issues: dict[tuple, dict] = {}
    gate_failures: dict[str, int] = defaultdict(int)
    for e in events:
        if e.get("type") != "finding" or not e.get("title"):
            continue
        if is_driver_gate_failure(e):
            gate_failures[e["change_id"]] += 1
            continue
        key = (e["change_id"], re.sub(r"\s+", " ", str(e["title"]).strip().lower()))
        it = issues.setdefault(key, {"stage": e.get("raised_stage") or e.get("stage"), "confirmations": set()})
        if e.get("raised_stage"):
            it["stage"] = e["raised_stage"]
        it["confirmations"].add(e.get("confirmation"))
    stages: dict[str, dict] = {}

    def stage_row(s):
        return stages.setdefault(s, {"findings": 0, "caught": 0, "reviewer_only": 0, "owner": 0,
                                     "tokens": None, "minutes": None})

    for it in issues.values():
        row = stage_row(it["stage"] or "unknown")
        row["findings"] += 1
        if "executable" in it["confirmations"]:
            row["caught"] += 1
        elif "owner" in it["confirmations"]:
            row["owner"] += 1
        else:
            row["reviewer_only"] += 1
    for e in events:
        if is_driver_gate_failure(e) or e.get("stage") in BOOKKEEPING_STAGES:
            continue
        if e.get("type") in ("stage", "finding") and e.get("stage"):
            row = stage_row(e["stage"]) if e.get("type") == "stage" else stages.get(e["stage"])
            if row is None:
                continue
            for k in ("tokens", "minutes"):
                if isinstance(e.get(k), (int, float)) and not isinstance(e.get(k), bool):
                    row[k] = (row[k] or 0) + e[k]
    no_catch = sorted(s for s, r in stages.items() if r["caught"] == 0)
    not_observed = [s for s in STAGES if s not in stages and s != "owner"]

    escapes: dict[str, dict] = {}
    for g in grades:
        for key in ("missed_at_completion", "regressions_later"):
            for item in g.get(key) or []:
                s = (item.get("stage") if isinstance(item, dict) else None) or "unattributed"
                row = escapes.setdefault(s, {"missed_at_completion": 0, "regressions_later": 0})
                row[key] += 1

    classes: dict[str, int] = defaultdict(int)
    first_fail: dict[str, dt.datetime] = {}
    recovery: dict[str, float | None] = {}
    for e in events:
        cid = e["change_id"]
        if e.get("type") == "integrate" and e.get("result") == "fail":
            classes[e.get("failure_class") or "unclassified"] += 1
            t = parse_iso(e.get("at"))
            if t and cid not in first_fail:
                first_fail[cid] = t
        elif e.get("type") == "push" and cid not in recovery:
            t = parse_iso(e.get("at"))
            start = first_fail.get(cid) or parse_iso(e.get("first_failed_integrate"))
            if start and t:
                recovery[cid] = round((t - start).total_seconds() / 60.0, 2)
            elif isinstance(e.get("recovery_minutes"), (int, float)):
                recovery[cid] = e["recovery_minutes"]
    for cid in first_fail:
        recovery.setdefault(cid, None)  # failed and not pushed yet

    interventions: dict[str, dict] = {}
    for e in events:
        if e.get("type") != "intervention":
            continue
        row = interventions.setdefault(e.get("intervention_class") or "unclassified",
                                       {"count": 0, "minutes": 0, "minutes_unknown": 0})
        row["count"] += 1
        if isinstance(e.get("minutes"), (int, float)) and not isinstance(e.get("minutes"), bool):
            row["minutes"] += e["minutes"]
        else:
            row["minutes_unknown"] += 1

    cells: dict[str, dict] = {}
    for g in grades:
        key = f"{g.get('path') or 'unknown'}/{size_bucket(g.get('files_changed'), g.get('lines_changed'))}"
        c = cells.setdefault(key, {"changes": 0, "cost_usd": 0.0, "cost_unknown": 0, "elapsed_minutes": 0.0,
                                   "container_minutes": 0.0, "owner_minutes": 0.0, "owner_not_entered": 0,
                                   "tokens": 0})
        c["changes"] += 1
        if isinstance(g.get("cost_usd_estimate"), (int, float)):
            c["cost_usd"] = round(c["cost_usd"] + g["cost_usd_estimate"], 6)
        else:
            c["cost_unknown"] += 1
        for k in ("elapsed_minutes", "container_minutes"):
            if isinstance(g.get(k), (int, float)):
                c[k] = round(c[k] + g[k], 2)
        c["tokens"] += sum(g.get(k) or 0 for k in ("tokens_input", "tokens_cache_write", "tokens_cache_read",
                                                    "tokens_output"))
        if g.get("owner_entered"):
            c["owner_minutes"] += sum(g.get(f"owner_minutes_{k}") or 0 for k in OWNER_MINUTE_KEYS)
        else:
            c["owner_not_entered"] += 1

    return {
        "window": {"last": last, "changes": window},
        "stages": stages,
        "no_confirmed_catch": no_catch,
        "gate_failures": dict(gate_failures),
        "stages_not_observed": not_observed,
        "escapes": escapes,
        "integration": {"failure_classes": dict(classes), "recovery_minutes": recovery},
        "interventions": interventions,
        "by_path_and_size": cells,
    }


def format_report(rep: dict) -> str:
    out = [f"Window: last {rep['window']['last']} changes ({len(rep['window']['changes'])} found)", ""]
    out.append("Stages with executable-confirmed catches (tokens, minutes where logged):")
    caught = {s: r for s, r in rep["stages"].items() if r["caught"]}
    out += [f"  {s}: {r['caught']} caught of {r['findings']} findings; tokens {r['tokens']}, minutes {r['minutes']}"
            for s, r in sorted(caught.items())] or ["  (none)"]
    out.append("")
    out.append("No confirmed catch in the window (candidates to drop or narrow):")
    out += [f"  {s}: {rep['stages'][s]['findings']} findings, {rep['stages'][s]['reviewer_only']} reviewer-only; "
            f"tokens {rep['stages'][s]['tokens']}, minutes {rep['stages'][s]['minutes']}"
            for s in rep["no_confirmed_catch"]] or ["  (none)"]
    if rep["stages_not_observed"]:
        out.append(f"  not observed (no events): {', '.join(rep['stages_not_observed'])}")
    out.append("")
    out.append("Gate failures (driver-written, not findings):")
    out += [f"  {cid}: {k}" for cid, k in sorted(rep.get("gate_failures", {}).items())] or ["  (none)"]
    out.append("")
    out.append("Escapes by the stage that should have caught them:")
    out += [f"  {s}: {r['missed_at_completion']} missed at completion, {r['regressions_later']} regressions later"
            for s, r in sorted(rep["escapes"].items())] or ["  (none recorded)"]
    out.append("")
    integ = rep["integration"]
    out.append("Integration failure classes: " + (", ".join(f"{k} {v}" for k, v in sorted(integ["failure_classes"].items()))
                                              or "(none)"))
    out += [f"  recovery {cid}: {'not pushed' if m is None else f'{m} min from first failed integrate to push'}"
            for cid, m in integ["recovery_minutes"].items()]
    out.append("")
    out.append("Interventions by class:")
    out += [f"  {c}: {r['count']} ({r['minutes']} min logged, {r['minutes_unknown']} without minutes)"
            for c, r in sorted(rep["interventions"].items())] or ["  (none)"]
    out.append("")
    out.append("Cost and minutes by path/size:")
    out += [f"  {k}: {c['changes']} changes, ${c['cost_usd']} est ({c['cost_unknown']} unknown), "
            f"{c['elapsed_minutes']} elapsed min, {c['container_minutes']} container min, "
            f"owner {c['owner_minutes']} min ({c['owner_not_entered']} not entered)"
            for k, c in sorted(rep["by_path_and_size"].items())] or ["  (no grade records)"]
    return "\n".join(out)


def cmd_report(root: Path, args) -> int:
    rep = build_report(root, args.last)
    print(json.dumps(rep, indent=2, default=str) if args.json else format_report(rep))
    if not args.no_mlflow:
        mlflow_log_report(rep, root.name, args.last)
    return 0


# ---------------------------------------------------------------- MLflow

RECORD_PARAMS = ("kind", "milestone", "path", "price_table", "integrate_where", "evaluation", "project")


def tracking_uri() -> str:
    uri = os.environ.get("MLFLOW_TRACKING_URI")
    if uri:
        return uri
    db = Path.home() / ".local" / "share" / "milestone-supervisor" / "mlflow.db"
    db.parent.mkdir(parents=True, exist_ok=True)
    return f"sqlite:///{db}"


def _mlflow_client():
    os.environ.setdefault("MLFLOW_HTTP_REQUEST_MAX_RETRIES", "0")
    os.environ.setdefault("MLFLOW_HTTP_REQUEST_TIMEOUT", "10")
    from mlflow.tracking import MlflowClient

    uri = tracking_uri()
    return MlflowClient(tracking_uri=uri), uri


def _experiment(client, name: str, uri: str) -> str:
    exp = client.get_experiment_by_name(name)
    if exp is not None:
        return exp.experiment_id
    loc = None
    if uri.startswith("sqlite:///"):
        loc = (Path(uri[len("sqlite:///"):]).parent / "mlflow-artifacts").as_uri()
    return client.create_experiment(name, artifact_location=loc)


def _metric_key(k: str) -> str:
    return re.sub(r"[^A-Za-z0-9_\-. /]", "_", k)


def mlflow_log_record(rec: dict, project: str) -> None:
    try:
        from mlflow.entities import Metric, Param, RunTag

        client, uri = _mlflow_client()
        exp_id = _experiment(client, f"agent-system/{project}", uri)
        cid = rec["change_id"]
        found = client.search_runs([exp_id], filter_string=f"tags.change_id = '{cid}'", max_results=1)
        if found:
            run = found[0]
            run_id, existing = run.info.run_id, dict(run.data.params)
        else:
            run_id, existing = client.create_run(exp_id, run_name=cid, tags={"change_id": cid}).info.run_id, {}
        ts = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)
        params, tags = [], [RunTag("change_id", cid)]
        for k in RECORD_PARAMS:
            v = "" if rec.get(k) is None else str(rec.get(k))
            if k not in existing:
                params.append(Param(k, v))
            elif existing[k] != v:
                tags.append(RunTag(f"current.{k}", v))  # params are immutable in MLflow
        metrics = []
        for k, v in rec.items():
            if k.startswith("owner_") or not isinstance(v, (int, float)) or isinstance(v, bool):
                continue
            metrics.append(Metric(_metric_key(k), float(v), ts, 0))
        if rec.get("owner_entered"):
            for k in OWNER_MINUTE_KEYS:
                v = rec.get(f"owner_minutes_{k}")
                if isinstance(v, (int, float)):
                    metrics.append(Metric(f"owner_minutes_{k}", float(v), ts, 0))
            metrics.append(Metric("missed_at_completion_count", float(len(rec.get("missed_at_completion") or [])), ts, 0))
            metrics.append(Metric("regressions_later_count", float(len(rec.get("regressions_later") or [])), ts, 0))
            tags.append(RunTag("owner_entered", "true"))
        client.log_batch(run_id, metrics=metrics, params=params, tags=tags)
    except Exception as e:  # noqa: BLE001 - MLflow is best effort; the jsonl is the record
        warn(f"MLflow logging failed ({type(e).__name__}: {str(e)[:200]}); {rec.get('change_id')} is in grades.jsonl")


def mlflow_log_report(rep: dict, project: str, last: int) -> None:
    try:
        from mlflow.entities import Metric, RunTag

        client, uri = _mlflow_client()
        exp_id = _experiment(client, f"agent-system/{project}", uri)
        window = f"last:{last}"
        run_id = client.create_run(exp_id, run_name=f"report {window} {now_iso()}", tags={"window": window}).info.run_id
        ts = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)
        metrics = [Metric("changes", float(len(rep["window"]["changes"])), ts, 0)]
        for s, r in rep["stages"].items():
            metrics.append(Metric(_metric_key(f"caught.{s}"), float(r["caught"]), ts, 0))
        metrics.append(Metric("gate_failures", float(sum(rep.get("gate_failures", {}).values())), ts, 0))
        for c, v in rep["integration"]["failure_classes"].items():
            metrics.append(Metric(_metric_key(f"integrate_failures.{c}"), float(v), ts, 0))
        rec = [m for m in rep["integration"]["recovery_minutes"].values() if isinstance(m, (int, float))]
        if rec:
            metrics.append(Metric("recovery_minutes_mean", sum(rec) / len(rec), ts, 0))
        for c, r in rep["interventions"].items():
            metrics.append(Metric(_metric_key(f"intervention_minutes.{c}"), float(r["minutes"]), ts, 0))
        for cell, c in rep["by_path_and_size"].items():
            metrics.append(Metric(_metric_key(f"cost_usd.{cell}"), float(c["cost_usd"]), ts, 0))
            metrics.append(Metric(_metric_key(f"elapsed_minutes.{cell}"), float(c["elapsed_minutes"]), ts, 0))
        tags = [RunTag("window", window), RunTag("no_confirmed_catch", ",".join(rep["no_confirmed_catch"])[:4000])]
        client.log_batch(run_id, metrics=metrics, tags=tags)
    except Exception as e:  # noqa: BLE001
        warn(f"MLflow summary run failed ({type(e).__name__}: {str(e)[:200]}); the report above stands")


# ---------------------------------------------------------------- CLI


class UsageError(Exception):
    pass


def parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--project", default=".", help="project root (default: cwd)")
    common.add_argument("--no-mlflow", action="store_true", help="write the ledger only")
    p = argparse.ArgumentParser(prog="grade.py", description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("record", parents=[common], help="write or amend a change's grade record",
                       epilog="examples:\n  grade.py record 10\n  grade.py record 10 --owner-minutes review=15 "
                              "--missed 'gate: filter ignores explicit'\n  grade.py record --change tidy-flags "
                              "--started 2026-09-17T09:00-05:00 --accepted 2026-09-17T09:40-05:00 --range main~1..main",
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    r.add_argument("milestone", nargs="?")
    r.add_argument("--change", help="a host change id (no sandbox); record is host:<id>")
    r.add_argument("--started")
    r.add_argument("--accepted")
    r.add_argument("--runs-dir", help="agent-sandbox runs dir (default $AGENT_SANDBOX_HOME/runs or ~/agent-sandbox/runs)")
    r.add_argument("--merge", help="the change's merge commit; size is REF^1..REF")
    r.add_argument("--range", help="A..B; size is git diff --shortstat A B")
    r.add_argument("--units", type=int)
    r.add_argument("--owner-minutes", help="specify=N,intervene=N,review=N,repair=N (any subset)")
    r.add_argument("--missed", action="append", help="'[stage: ]text', repeatable, appends")
    r.add_argument("--regression", action="append", help="'[stage: ]text', repeatable, appends")
    r.add_argument("--refresh", action="store_true", help="recompute automatic fields, keep owner fields")

    e = sub.add_parser("event", parents=[common], help="append a typed event",
                       epilog="examples:\n  grade.py event finding --change milestone:10 stage=code-review "
                              "title='race in lock' confirmation=reviewer reviewer=adversarial\n"
                              "  grade.py event integrate --change milestone:10 where=host-integrate result=fail "
                              "failed_step=setup\n  grade.py event intervention --change milestone:10 actor=supervisor "
                              "intervention_class=environment minutes=6 detail='installed host browser'",
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    e.add_argument("type", choices=sorted(EVENT_SPECS))
    e.add_argument("--change", required=True, help="milestone:<N> or host:<id>")
    e.add_argument("--json", help="fields as a JSON object (key=value pairs override)")
    e.add_argument("fields", nargs="*", help="key=value")

    rp = sub.add_parser("report", parents=[common], help="decision report over a window of changes")
    rp.add_argument("--last", type=int, default=20)
    rp.add_argument("--json", action="store_true")
    return p


def main(argv: list[str] | None = None) -> int:
    p = parser()
    # key=value fields may sit on either side of --change/--project: argparse cannot
    # split one positional list around options, so the leftovers are collected here.
    args, extra = p.parse_known_args(argv)
    if args.cmd == "event":
        args.fields = list(args.fields) + [x for x in extra if not x.startswith("-")]
        extra = [x for x in extra if x.startswith("-")]
    if extra:
        p.error(f"unrecognized arguments: {' '.join(extra)}")
    root = Path(args.project).resolve()
    try:
        if args.cmd == "record":
            return cmd_record(root, args)
        if args.cmd == "event":
            return cmd_event(root, args)
        return cmd_report(root, args)
    except UsageError as e:
        print(f"grade.py: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
