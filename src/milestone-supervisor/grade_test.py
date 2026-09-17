"""Tests for grade.py: grade records, typed events and the decision report.

Run: uv run --with mlflow --with pytest pytest -q src/milestone-supervisor/grade_test.py

Every fixture is built in a temp dir from small excerpts shaped like a real
chain.log, run.json, transcript and events ledger. Nothing reads a live project,
and MLflow always points at a temp SQLite store (or an unreachable URI).
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
GRADE = HERE / "grade.py"


def _load():
    spec = importlib.util.spec_from_file_location("grade", GRADE)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["grade"] = mod
    spec.loader.exec_module(mod)
    return mod


grade = _load()


# ---------------------------------------------------------------- helpers


@pytest.fixture(autouse=True)
def _temp_mlflow(tmp_path, monkeypatch):
    # Safety net: no test may reach the default store under ~/.local/share.
    monkeypatch.setenv("MLFLOW_TRACKING_URI", f"sqlite:///{tmp_path / 'mlflow-safety.db'}")


def make_project(tmp_path: Path, chain: str, config: str = "") -> Path:
    root = tmp_path / "proj"
    (root / "logs" / "milestones").mkdir(parents=True)
    (root / ".milestones").mkdir()
    (root / "logs" / "milestones" / "chain.log").write_text(chain)
    (root / ".milestones" / "config").write_text(config)
    return root


def write_run(runs: Path, sandbox: str, containers: list[dict], transcript_lines: list[dict] | None = None,
              subagent_lines: list[dict] | None = None) -> None:
    d = runs / sandbox
    d.mkdir(parents=True, exist_ok=True)
    (d / "run.json").write_text(json.dumps({"sandbox_id": sandbox, "containers": containers,
                                            "started_at": containers[-1]["started_at"] if containers else None}))
    proj = d / "agent-home" / "claude" / "projects" / "-workspace"
    proj.mkdir(parents=True, exist_ok=True)
    if transcript_lines is not None:
        (proj / "sess-1.jsonl").write_text("".join(json.dumps(x) + "\n" for x in transcript_lines))
    if subagent_lines is not None:
        sub = proj / "sess-1" / "subagents"
        sub.mkdir(parents=True, exist_ok=True)
        (sub / "agent-a1.jsonl").write_text("".join(json.dumps(x) + "\n" for x in subagent_lines))


def assistant(msg_id, ts, inp=0, cw=0, cr=0, out=0, model="claude-opus-5", block="text"):
    line = {"type": "assistant", "timestamp": ts,
            "message": {"model": model, "role": "assistant", "content": [{"type": block}],
                        "usage": {"input_tokens": inp, "cache_creation_input_tokens": cw,
                                  "cache_read_input_tokens": cr, "output_tokens": out}}}
    if msg_id is not None:
        line["message"]["id"] = msg_id
    return line


def container(start, end, cmd="claude"):
    return {"container": f"c-{start}", "command": [cmd], "started_at": start, "finished_at": end,
            "exit_code": 0, "status": "completed"}


def read_jsonl(p: Path) -> list[dict]:
    return [json.loads(x) for x in p.read_text().splitlines() if x.strip()]


def run(argv: list[str]) -> int:
    return grade.main(argv)


# A chain.log excerpt shaped like the driver's lines (names neutralised).
CHAIN_M7 = """\
=== launch milestone 7 as milestone-demo-7-20260914T082117: 2026-09-14T08:21:17-05:00 ===
unit: milestone-demo-7-20260914T082117 (RuntimeMaxSec=45300, --memory 8g --cpus 6)
unit log: /x/logs/milestones/unit-milestone-demo-7-20260914T082117.out
sandbox: demo-aaaa1111
=== milestone 7 in demo-aaaa1111 (unit milestone-demo-7-20260914T082117): 2026-09-14T08:21:33-05:00 ===
milestone 7: gate FAILED (exit 1), see /x/logs/milestones/milestone-7.gate.log and the sandbox transcript; unit stops
=== launch continue 7 in demo-aaaa1111 as milestone-demo-7-20260914T100000: 2026-09-14T10:00:00-05:00 ===
unit: milestone-demo-7-20260914T100000 (RuntimeMaxSec=43500, --memory 8g --cpus 6)
=== continue in demo-aaaa1111 (unit milestone-demo-7-20260914T100000): 2026-09-14T10:00:01-05:00 ===
continue done 2026-09-14T10:40:00-05:00: /x/logs/milestones/continue-20260914T100000.log
=== launch gate 7 in demo-aaaa1111 as milestone-demo-7-20260914T104100: 2026-09-14T10:41:00-05:00 ===
=== gate only, milestone 7 in demo-aaaa1111 (unit milestone-demo-7-20260914T104100): 2026-09-14T10:41:00-05:00 ===
gate pass exit=0 milestone=7 sha=1296b5ca2448 where=sandbox setup=yes env="catalog 3d86 tracks=106" at=2026-09-14T10:45:00-05:00
milestone 7: gate passed 2026-09-14T10:45:00-05:00
=== integrate milestone 7 from agent-sandbox/demo-aaaa1111: 2026-09-14T11:00:00-05:00 ===
  pre-merge 88fae2d687751fb03265818b7ffd931f92849d2f
  merged agent-sandbox/demo-aaaa1111 as d3ba2390e232
  weakening hits all listed in docs/reports/milestone-7.md: removed-assert tests/test_a.py;skip-marker tests/conftest.py;
gate pass exit=0 milestone=7 sha=d3ba2390e232 where=host setup=yes env="catalog 3d86 tracks=106" at=2026-09-14T11:10:00-05:00
integrate milestone 7: pushed main to origin as 1162e9a00000 (1162e9a000000000000000000000000000000000) 2026-09-14T11:21:17-05:00
"""


def m7_runs(tmp_path: Path) -> Path:
    runs = tmp_path / "runs"
    containers = [
        container("2026-09-14T12:00:00+00:00", "2026-09-14T12:30:00+00:00"),  # 07:00 CDT: before the launch
        container("2026-09-14T13:21:40+00:00", "2026-09-14T14:21:40+00:00"),  # 60 minutes, inside
        container("2026-09-14T15:41:10+00:00", "2026-09-14T15:51:10+00:00"),  # 10 minutes, inside
    ]
    lines = [
        {"type": "user", "timestamp": "2026-09-14T13:22:00.000Z", "message": {"role": "user", "content": "go"}},
        # One response written as three content-block lines, usage repeated on each.
        assistant("msg_01", "2026-09-14T13:22:01.000Z", 10, 500, 9000, 200, block="thinking"),
        assistant("msg_01", "2026-09-14T13:22:02.000Z", 10, 500, 9000, 200, block="text"),
        assistant("msg_01", "2026-09-14T13:22:03.000Z", 10, 500, 9000, 200, block="tool_use"),
        # A line with usage but no message id is ignored.
        assistant(None, "2026-09-14T13:22:04.000Z", 7, 7, 7, 7),
    ]
    write_run(runs, "demo-aaaa1111", containers, lines)
    return runs


# ---------------------------------------------------------------- U4: grade records


def test_record_counts_gates_turns_and_usage_once_per_message(tmp_path):
    root = make_project(tmp_path, CHAIN_M7)
    runs = m7_runs(tmp_path)
    assert run(["record", "7", "--project", str(root), "--runs-dir", str(runs), "--no-mlflow"]) == 0
    [rec] = read_jsonl(root / ".milestones" / "grades.jsonl")
    assert rec["change_id"] == "milestone:7"
    assert rec["kind"] == "milestone"
    assert rec["gate_attempts"] == 2
    assert rec["gate_failures"] == 1
    assert rec["finishing_turns"] == 1
    assert (rec["tokens_input"], rec["tokens_cache_write"], rec["tokens_cache_read"], rec["tokens_output"]) == (10, 500, 9000, 200)
    # opus-5: 5/MTok in, 6.25 5m write, 0.5 read, 25 out
    assert rec["cost_usd_estimate"] == pytest.approx((10 * 5 + 500 * 6.25 + 9000 * 0.5 + 200 * 25) / 1e6)
    assert rec["price_table"] == grade.PRICE_TABLE_VERSION
    assert rec["sandboxes"] == ["demo-aaaa1111"]
    assert rec["elapsed_minutes"] == pytest.approx(180.0)
    assert rec["weakening_hits"] == 2
    assert rec["integrate_where"] == "host"
    assert rec["path"] == "single"


def test_container_minutes_sum_only_containers_starting_in_window(tmp_path):
    root = make_project(tmp_path, CHAIN_M7)
    runs = m7_runs(tmp_path)
    run(["record", "7", "--project", str(root), "--runs-dir", str(runs), "--no-mlflow"])
    [rec] = read_jsonl(root / ".milestones" / "grades.jsonl")
    assert rec["container_minutes"] == pytest.approx(70.0)


def test_subagent_transcripts_are_counted(tmp_path):
    root = make_project(tmp_path, CHAIN_M7)
    runs = m7_runs(tmp_path)
    proj = runs / "demo-aaaa1111" / "agent-home" / "claude" / "projects" / "-workspace"
    sub = proj / "sess-1" / "subagents"
    sub.mkdir(parents=True)
    (sub / "agent-x.jsonl").write_text(json.dumps(assistant("msg_sub", "2026-09-14T13:30:00Z", 1, 0, 0, 5)) + "\n")
    run(["record", "7", "--project", str(root), "--runs-dir", str(runs), "--no-mlflow"])
    [rec] = read_jsonl(root / ".milestones" / "grades.jsonl")
    assert rec["tokens_output"] == 205
    assert rec["tokens_input"] == 11


def test_unknown_model_gives_null_cost_not_a_guess(tmp_path):
    root = make_project(tmp_path, CHAIN_M7)
    runs = m7_runs(tmp_path)
    proj = runs / "demo-aaaa1111" / "agent-home" / "claude" / "projects" / "-workspace"
    (proj / "other.jsonl").write_text(json.dumps(assistant("msg_x", "2026-09-14T13:40:00Z", 1, 0, 0, 5, model="some-new-model")) + "\n")
    run(["record", "7", "--project", str(root), "--runs-dir", str(runs), "--no-mlflow"])
    [rec] = read_jsonl(root / ".milestones" / "grades.jsonl")
    assert rec["cost_usd_estimate"] is None
    assert rec["tokens_output"] == 205


def test_fresh_record_has_null_owner_fields_and_flag_false(tmp_path):
    root = make_project(tmp_path, CHAIN_M7)
    run(["record", "7", "--project", str(root), "--runs-dir", str(m7_runs(tmp_path)), "--no-mlflow"])
    [rec] = read_jsonl(root / ".milestones" / "grades.jsonl")
    assert rec["owner_entered"] is False
    for k in ("owner_minutes_specify", "owner_minutes_intervene", "owner_minutes_review", "owner_minutes_repair",
              "missed_at_completion", "regressions_later"):
        assert rec[k] is None, k


def test_reused_sandbox_splits_usage_at_the_second_launch(tmp_path):
    chain = """\
=== launch milestone 3 as milestone-demo-3-20260914T010000: 2026-09-14T01:00:00-05:00 ===
sandbox: demo-bbbb2222
=== milestone 3 in demo-bbbb2222 (unit milestone-demo-3-20260914T010000): 2026-09-14T01:00:05-05:00 ===
milestone 3: gate passed 2026-09-14T02:00:00-05:00
=== launch continue 4 in demo-bbbb2222 as milestone-demo-4-20260914T030000: 2026-09-14T03:00:00-05:00 ===
=== continue in demo-bbbb2222 (unit milestone-demo-4-20260914T030000): 2026-09-14T03:00:01-05:00 ===
continue done 2026-09-14T04:00:00-05:00: /x/continue.log
milestone 3 PUSHED 2026-09-14T05:00:00-05:00: accepted
milestone 4 PUSHED 2026-09-14T05:00:00-05:00: accepted
"""
    root = make_project(tmp_path, chain)
    runs = tmp_path / "runs"
    write_run(runs, "demo-bbbb2222", [], [
        assistant("m_a", "2026-09-14T06:30:00Z", out=100),  # 01:30 CDT, milestone 3
        assistant("m_b", "2026-09-14T08:30:00Z", out=300),  # 03:30 CDT, milestone 4
    ])
    run(["record", "3", "--project", str(root), "--runs-dir", str(runs), "--no-mlflow"])
    run(["record", "4", "--project", str(root), "--runs-dir", str(runs), "--no-mlflow"])
    recs = {r["change_id"]: r for r in read_jsonl(root / ".milestones" / "grades.jsonl")}
    assert recs["milestone:3"]["tokens_output"] == 100
    assert recs["milestone:4"]["tokens_output"] == 300
    assert recs["milestone:4"]["finishing_turns"] == 1


def test_owner_amendment_keeps_automatic_fields_and_missed_appends(tmp_path):
    root = make_project(tmp_path, CHAIN_M7)
    runs = m7_runs(tmp_path)
    run(["record", "7", "--project", str(root), "--runs-dir", str(runs), "--no-mlflow"])
    [before] = read_jsonl(root / ".milestones" / "grades.jsonl")
    # Remove the runs so a recompute would change the automatic fields.
    import shutil
    shutil.rmtree(runs)
    assert run(["record", "7", "--project", str(root), "--owner-minutes", "review=15", "--missed", "gate: filter drops explicit",
                "--no-mlflow"]) == 0
    assert run(["record", "7", "--project", str(root), "--missed", "a second miss", "--no-mlflow"]) == 0
    [after] = read_jsonl(root / ".milestones" / "grades.jsonl")
    assert after["owner_entered"] is True
    assert after["owner_minutes_review"] == 15
    assert after["owner_minutes_specify"] is None
    for k in ("tokens_cache_read", "container_minutes", "gate_attempts", "cost_usd_estimate"):
        assert after[k] == before[k], k
    assert [m["text"] for m in after["missed_at_completion"]] == ["filter drops explicit", "a second miss"]
    assert after["missed_at_completion"][0]["stage"] == "gate"
    assert after["missed_at_completion"][1]["stage"] is None


def test_host_change_record_is_direct_with_size_from_git_range(tmp_path):
    root = make_project(tmp_path, "")
    g = ["git", "-C", str(root)]
    subprocess.run(g + ["init", "-q"], check=True)
    subprocess.run(g + ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base"], check=True)
    (root / "a.txt").write_text("".join(f"a{i}\n" for i in range(20)))
    (root / "b.txt").write_text("".join(f"b{i}\n" for i in range(10)))
    subprocess.run(g + ["add", "a.txt", "b.txt"], check=True)
    subprocess.run(g + ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "change"], check=True)
    assert run(["record", "--change", "tidy-flags", "--started", "2026-09-17T09:00:00-05:00",
                "--accepted", "2026-09-17T09:40:00-05:00", "--range", "HEAD~1..HEAD",
                "--project", str(root), "--no-mlflow"]) == 0
    [rec] = read_jsonl(root / ".milestones" / "grades.jsonl")
    assert rec["change_id"] == "host:tidy-flags"
    assert rec["kind"] == "host-change"
    assert rec["path"] == "direct"
    assert (rec["files_changed"], rec["lines_changed"]) == (2, 30)
    assert rec["elapsed_minutes"] == pytest.approx(40.0)
    assert rec["tokens_output"] is None and rec["cost_usd_estimate"] is None
    assert isinstance(rec["machinery_lines"], int) and rec["machinery_lines"] > 0
    rep = grade.build_report(root, last=20)
    assert rep["by_path_and_size"]["direct/small"]["changes"] == 1


def test_lane_parallel_milestone_records_lanes(tmp_path):
    chain = """\
=== launch milestone 11 as milestone-demo-11-20260917T103312: 2026-09-17T10:33:12-05:00 ===
=== launch milestone 12 as milestone-demo-12-20260917T103312: 2026-09-17T10:33:12-05:00 ===
sandbox: demo-cccc0011
=== milestone 11 in demo-cccc0011 (unit milestone-demo-11-20260917T103312): 2026-09-17T10:33:22-05:00 ===
sandbox: demo-cccc0012
=== milestone 12 in demo-cccc0012 (unit milestone-demo-12-20260917T103312): 2026-09-17T10:33:23-05:00 ===
milestone 11 PUSHED 2026-09-17T14:00:00-05:00: accepted
"""
    root = make_project(tmp_path, chain)
    run(["record", "11", "--project", str(root), "--runs-dir", str(tmp_path / "none"), "--no-mlflow"])
    [rec] = read_jsonl(root / ".milestones" / "grades.jsonl")
    assert rec["path"] == "lanes"
    assert rec["sandboxes"] == ["demo-cccc0011"]
    assert rec["container_minutes"] is None  # no run record: unknown, not zero


def test_evaluate_n_in_config_records_single_plus_evaluator(tmp_path):
    config = 'GATE="make check"   # a comment with EVALUATE_7=0 inside\nEVALUATE_7=1   # independent evaluation\nLANE_7=main\n'
    root = make_project(tmp_path, CHAIN_M7, config)
    run(["record", "7", "--project", str(root), "--runs-dir", str(m7_runs(tmp_path)), "--no-mlflow"])
    [rec] = read_jsonl(root / ".milestones" / "grades.jsonl")
    assert rec["path"] == "single+evaluator"
    assert rec["config_keys"] == 3


def test_config_parse_never_executes_shell(tmp_path):
    marker = tmp_path / "pwned"
    cfg = tmp_path / "config"
    cfg.write_text(f'X=$(touch {marker})\nY="`touch {marker}`"\nEVALUATE_2=1\n')
    vals = grade.parse_config(cfg)
    assert vals["EVALUATE_2"] == "1"
    assert not marker.exists()


# ---------------------------------------------------------------- MLflow


def test_mlflow_run_tagged_with_change_id_and_amendment_updates_same_run(tmp_path, monkeypatch):
    uri = f"sqlite:///{tmp_path / 'mlflow.db'}"
    monkeypatch.setenv("MLFLOW_TRACKING_URI", uri)
    root = make_project(tmp_path, CHAIN_M7)
    runs = m7_runs(tmp_path)
    assert run(["record", "7", "--project", str(root), "--runs-dir", str(runs)]) == 0
    from mlflow.tracking import MlflowClient

    client = MlflowClient(tracking_uri=uri)
    exp = client.get_experiment_by_name("agent-system/proj")
    assert exp is not None
    found = client.search_runs([exp.experiment_id], filter_string="tags.change_id = 'milestone:7'")
    assert len(found) == 1
    r0 = found[0]
    assert r0.data.metrics["tokens_cache_read"] == 9000
    assert r0.data.params["path"] == "single"
    assert not any(k.startswith("owner_") for k in r0.data.metrics)

    assert run(["record", "7", "--project", str(root), "--owner-minutes", "review=15,repair=0"]) == 0
    found = client.search_runs([exp.experiment_id], filter_string="tags.change_id = 'milestone:7'")
    assert len(found) == 1
    assert found[0].info.run_id == r0.info.run_id
    assert found[0].data.metrics["owner_minutes_review"] == 15
    assert found[0].data.metrics["owner_minutes_repair"] == 0
    assert "owner_minutes_specify" not in found[0].data.metrics


def test_unreachable_tracking_uri_writes_jsonl_and_exits_zero_fast(tmp_path):
    root = make_project(tmp_path, CHAIN_M7)
    runs = m7_runs(tmp_path)
    env = dict(os.environ, MLFLOW_TRACKING_URI="http://127.0.0.1:9")
    env.pop("MLFLOW_HTTP_REQUEST_MAX_RETRIES", None)
    env.pop("MLFLOW_HTTP_REQUEST_TIMEOUT", None)
    t0 = time.monotonic()
    p = subprocess.run([sys.executable, str(GRADE), "record", "7", "--project", str(root), "--runs-dir", str(runs)],
                       env=env, capture_output=True, text=True, timeout=60, check=False)
    elapsed = time.monotonic() - t0
    assert p.returncode == 0, p.stderr
    assert "warning" in p.stderr.lower()
    assert elapsed < 30
    assert len(read_jsonl(root / ".milestones" / "grades.jsonl")) == 1


# ---------------------------------------------------------------- U4b: events


def ev(root, *args) -> int:
    return run(["event", *args, "--project", str(root)])


def test_event_validation_refuses_missing_fields_and_writes_nothing(tmp_path, capsys):
    root = make_project(tmp_path, "")
    assert ev(root, "finding", "--change", "milestone:7", "stage=code-review", "title=x") == 2
    assert ev(root, "finding", "--change", "milestone:7", "stage=nonsense", "title=x", "confirmation=reviewer") == 2
    assert ev(root, "intervention", "--change", "milestone:7", "actor=supervisor", "intervention_class=environment",
              "detail=x") == 2  # supervisor minutes required
    assert ev(root, "acceptance", "--change", "milestone:7", "criterion=2", "verdict=waived",
              "evidence_kind=owner-approval") == 2  # a waiver needs the approval entry
    assert ev(root, "finding", "--change", "bad id", "stage=gate", "title=x", "confirmation=reviewer") == 2
    assert not (root / ".milestones" / "events.jsonl").exists()
    assert ev(root, "acceptance", "--change", "milestone:7", "criterion=2", "verdict=evidence",
              "evidence_kind=bundle-step", "bundle=logs/milestones/evidence/7-host-integrate-x", "step=engine",
              "test_ids=tests/test_a.py::test_one,tests/test_a.py::test_two", "tree=abc123", "seal=" + "0" * 64) == 0
    [line] = read_jsonl(root / ".milestones" / "events.jsonl")
    assert line["type"] == "acceptance" and line["test_ids"] == ["tests/test_a.py::test_one", "tests/test_a.py::test_two"]
    assert line["criterion"] == 2 and "at" in line


def test_every_event_type_has_a_valid_minimal_form(tmp_path):
    root = make_project(tmp_path, "")
    minimal = {
        "finding": ["stage=gate", "title=t", "confirmation=executable"],
        "integrate": ["where=host-integrate", "result=pass", "sha=abc"],
        "intervention": ["actor=supervisor", "intervention_class=context", "minutes=5", "detail=d"],
        "push": ["sha=abc"],
        "stage": ["stage=simplify"],
        "acceptance": ["criterion=1", "verdict=unmet"],
        "approval": ["item_kind=budget", "approval=.milestones/approvals/7.md#3"],
        "budget": ["budget=failed_gates", "limit=3", "count=3", "action=exhausted"],
        "control-proof": ["control=stale-evidence", "exit_code=2", "outcome_line=refused: stale", "demonstrated=true"],
    }
    assert set(minimal) == set(grade.EVENT_SPECS)
    for t, fields in minimal.items():
        assert ev(root, t, "--change", "milestone:7", *fields) == 0, t
    assert len(read_jsonl(root / ".milestones" / "events.jsonl")) == len(minimal)


def test_integrate_failure_class_rule_table(tmp_path):
    root = make_project(tmp_path, "")
    assert ev(root, "integrate", "--change", "milestone:7", "where=host-integrate", "result=fail", "failed_step=setup",
              "at=2026-09-17T10:00:00-05:00") == 0
    assert ev(root, "integrate", "--change", "milestone:7", "where=host-integrate", "result=fail", "failed_step=web-e2e",
              "signal=screenshot", "sha=8c44282eb25a", "sandbox_gate_passed_sha=8c44282eb25a",
              "at=2026-09-17T10:10:00-05:00") == 0
    assert ev(root, "integrate", "--change", "milestone:7", "where=host-integrate", "result=fail", "signal=scan-refusal",
              "at=2026-09-17T10:12:00-05:00") == 0
    assert ev(root, "integrate", "--change", "milestone:7", "where=host-integrate", "result=fail", "signal=merge-abort",
              "at=2026-09-17T10:13:00-05:00") == 0
    assert ev(root, "integrate", "--change", "milestone:7", "where=host-integrate", "result=fail", "failed_step=engine",
              "failure_class=environment", "at=2026-09-17T10:14:00-05:00") == 0  # supervisor override
    assert ev(root, "integrate", "--change", "milestone:7", "where=host-integrate", "result=fail", "failed_step=engine",
              "at=2026-09-17T10:15:00-05:00") == 0
    assert ev(root, "integrate", "--change", "milestone:7", "where=sandbox-integration", "result=pass",
              "at=2026-09-17T10:20:00-05:00") == 0
    assert ev(root, "push", "--change", "milestone:7", "sha=1162e9a", "at=2026-09-17T10:25:00-05:00") == 0
    lines = read_jsonl(root / ".milestones" / "events.jsonl")
    classes = [x.get("failure_class") for x in lines if x["type"] == "integrate" and x["result"] == "fail"]
    assert classes == ["environment", "parity", "report", "conflict", "environment", "code"]
    # screenshot failure without a passing sandbox gate on the same sha is code, not parity
    assert grade.classify_integrate_failure({"signal": "screenshot", "sha": "a", "sandbox_gate_passed_sha": "b"}) == "code"
    rep = grade.build_report(root, last=20)
    integ = rep["integration"]
    assert integ["failure_classes"] == {"environment": 2, "parity": 1, "report": 1, "conflict": 1, "code": 1}
    assert integ["recovery_minutes"]["milestone:7"] == pytest.approx(25.0)


def test_reviewer_only_finding_not_caught_and_executable_counted_for_raising_stage(tmp_path):
    root = make_project(tmp_path, "")
    # Two reviewers on one issue, no failing check.
    ev(root, "finding", "--change", "milestone:7", "stage=code-review", "reviewer=adversarial", "title=Race in lock",
       "confirmation=reviewer", "at=2026-09-17T10:00:00-05:00")
    ev(root, "finding", "--change", "milestone:7", "stage=code-review", "reviewer=correctness", "title=race in lock",
       "confirmation=reviewer", "at=2026-09-17T10:01:00-05:00")
    # Raised by plan-doc-review, confirmed later by a failing gate step.
    ev(root, "finding", "--change", "milestone:7", "stage=plan-doc-review", "title=weak scan misses deletes",
       "confirmation=reviewer", "at=2026-09-17T09:00:00-05:00")
    ev(root, "finding", "--change", "milestone:7", "stage=gate", "title=weak scan misses deletes",
       "confirmation=executable", "step=engine", "at=2026-09-17T11:00:00-05:00")
    ev(root, "stage", "--change", "milestone:7", "stage=code-review", "minutes=12", "tokens=40000")
    rep = grade.build_report(root, last=20)
    st = rep["stages"]
    assert st["plan-doc-review"]["caught"] == 1
    assert st["code-review"]["caught"] == 0
    assert st["code-review"]["findings"] == 1  # one issue, not two
    assert st["code-review"]["reviewer_only"] == 1
    assert "gate" not in st or st["gate"]["caught"] == 0
    assert st["code-review"]["minutes"] == 12 and st["code-review"]["tokens"] == 40000
    assert "code-review" in rep["no_confirmed_catch"]
    assert "plan-doc-review" not in rep["no_confirmed_catch"]


def test_report_lists_escapes_and_interventions(tmp_path):
    root = make_project(tmp_path, CHAIN_M7)
    run(["record", "7", "--project", str(root), "--runs-dir", str(m7_runs(tmp_path)), "--no-mlflow"])
    run(["record", "7", "--project", str(root), "--regression", "integrate: host screenshot drift", "--missed", "x",
         "--no-mlflow"])
    ev(root, "intervention", "--change", "milestone:7", "actor=supervisor", "intervention_class=environment", "minutes=4",
       "detail=installed a browser")
    ev(root, "intervention", "--change", "milestone:7", "actor=owner", "intervention_class=spec", "detail=clarified")
    rep = grade.build_report(root, last=5)
    assert rep["escapes"]["integrate"]["regressions_later"] == 1
    assert rep["escapes"]["unattributed"]["missed_at_completion"] == 1
    assert rep["interventions"]["environment"] == {"count": 1, "minutes": 4, "minutes_unknown": 0}
    assert rep["interventions"]["spec"]["minutes_unknown"] == 1
    assert rep["by_path_and_size"]  # the milestone has a cell even with unknown size


SEEDED_EVENTS = """\
{"type": "finding", "change_id": "host:gated-integration", "stage": "plan-doc-review", "reviewer": "adversarial", "title": "same-lane lock does not serialize lifecycles", "severity": "P1", "confirmation": "reviewer", "outcome": "applied-to-plan", "at": "2026-09-17T09:50:00-05:00"}
{"type": "finding", "change_id": "host:gated-integration", "stage": "code-review", "reviewer": "adversarial", "title": "merge silently overwrites gitignored host files", "severity": "P1", "confirmation": "executable", "outcome": "fix-dispatched", "at": "2026-09-17T10:55:00-05:00"}
{"type": "finding", "change_id": "host:gated-integration", "stage": "code-review", "reviewer": "security", "title": "settings snippet allows prompt-free host exec", "severity": "P1", "confirmation": "reviewer", "outcome": "fix-dispatched", "at": "2026-09-17T10:55:00-05:00"}
{"type": "stage", "change_id": "host:gated-integration", "stage": "simplify", "applied": 5, "skipped": 6, "note": "no defects found; clarity only", "at": "2026-09-17T10:40:00-05:00"}
{"type": "integrate", "change_id": "milestone:10", "where": "host", "result": "fail", "failure_class": "report", "detail": "scan refused 3 unlisted test changes", "at": "2026-09-17T10:13:43-05:00"}
{"type": "integrate", "change_id": "milestone:10", "where": "host", "result": "fail", "failure_class": "environment", "detail": "fresh worktree had no extras", "at": "2026-09-17T10:14:29-05:00"}
{"type": "integrate", "change_id": "milestone:10", "where": "host", "result": "fail", "failure_class": "environment", "detail": "host had no browser", "at": "2026-09-17T10:18:13-05:00"}
{"type": "integrate", "change_id": "milestone:10", "where": "host", "result": "fail", "failure_class": "parity", "detail": "10 screenshot diffs", "at": "2026-09-17T10:25:08-05:00"}
{"type": "integrate", "change_id": "milestone:10", "where": "sandbox-integration", "result": "pass", "sha": "8c44282eb25a", "detail": "fresh sandbox of the merge", "at": "2026-09-17T10:32:28-05:00"}
{"type": "push", "change_id": "milestone:10", "sha": "1162e9a", "first_failed_integrate": "2026-09-17T10:13:43-05:00", "recovery_minutes": 20, "at": "2026-09-17T10:33:00-05:00"}
{"type": "intervention", "change_id": "milestone:10", "actor": "supervisor", "intervention_class": "environment", "minutes": 3, "detail": "installed a task runner on host", "at": "2026-09-17T10:35:00-05:00"}
{"type": "intervention", "change_id": "milestone:10", "actor": "supervisor", "intervention_class": "context", "minutes": 5, "detail": "read three test expectation changes", "at": "2026-09-17T10:35:00-05:00"}
"""


def test_seeded_events_shape_produces_a_report(tmp_path, capsys):
    root = make_project(tmp_path, "")
    (root / ".milestones" / "events.jsonl").write_text(SEEDED_EVENTS + "not json\n")
    for line in SEEDED_EVENTS.splitlines():
        ok, errors = grade.validate_event(json.loads(line))
        assert ok, errors
    assert run(["report", "--last", "20", "--project", str(root), "--no-mlflow"]) == 0
    out = capsys.readouterr().out
    assert "no confirmed catch" in out.lower()
    rep = grade.build_report(root, last=20)
    assert rep["integration"]["failure_classes"] == {"report": 1, "environment": 2, "parity": 1}
    assert rep["integration"]["recovery_minutes"]["milestone:10"] == pytest.approx(19.28, abs=0.01)
    assert rep["stages"]["code-review"]["caught"] == 1
    assert "plan-doc-review" in rep["no_confirmed_catch"]
    assert rep["interventions"]["environment"]["minutes"] == 3


def test_report_logs_summary_run_tagged_window(tmp_path, monkeypatch):
    uri = f"sqlite:///{tmp_path / 'mlflow.db'}"
    monkeypatch.setenv("MLFLOW_TRACKING_URI", uri)
    root = make_project(tmp_path, "")
    (root / ".milestones" / "events.jsonl").write_text(SEEDED_EVENTS)
    assert run(["report", "--last", "20", "--project", str(root)]) == 0
    from mlflow.tracking import MlflowClient

    client = MlflowClient(tracking_uri=uri)
    exp = client.get_experiment_by_name("agent-system/proj")
    runs = client.search_runs([exp.experiment_id], filter_string="tags.window = 'last:20'")
    assert len(runs) == 1
    assert runs[0].data.metrics["integrate_failures.environment"] == 2
