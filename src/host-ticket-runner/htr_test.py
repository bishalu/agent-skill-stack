#!/usr/bin/env python3
"""Tests for htr.py and htr_hooks.py. `claude` and `gh` are fakes on PATH that record what
they were given; git is real; no agent, network call or AWS call happens.

  python3 htr_test.py          (or: python3 -m unittest htr_test -v)
"""
import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import htr  # noqa: E402
import htr_hooks as hooks  # noqa: E402

PY = sys.executable
HTR = os.path.join(HERE, "htr.py")
HOOKS = os.path.join(HERE, "htr_hooks.py")


class Args:
    def __init__(self, **kw):
        self.tier = self.model = self.effort = self.cycle = self.judge_model = self.judge_effort = None
        self.route = "auto"
        self.repo, self.issue = "o/r", 7
        self.__dict__.update(kw)


def slurp(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def git(cwd, *a):
    return subprocess.run(["git", "-C", cwd] + list(a), check=True, capture_output=True, text=True).stdout.strip()


def init_repo(path):
    os.makedirs(path)
    git(path, "init", "-q", "-b", "main")
    git(path, "config", "user.email", "t@example.com")
    git(path, "config", "user.name", "t")
    with open(os.path.join(path, "README.md"), "w") as f:
        f.write("hello\n")
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "init")


# ---------------------------------------------------------------- criteria and routing
class Criteria(unittest.TestCase):
    def test_list_under_heading(self):
        body = "Intro.\n\n## Acceptance criteria\n\n- [ ] one thing\n  continues here\n- [x] two\n\n## Notes\n- not a criterion\n"
        crit, src = htr.extract_criteria(body)
        self.assertEqual(crit, ["one thing continues here", "two"])
        self.assertIn("Acceptance criteria", src)

    def test_paragraph_under_done_when(self):
        crit, _ = htr.extract_criteria("## Done when\n\nThe skill exists; a dry run passes. AWS is shown (`a. b`).\n")
        self.assertEqual(crit, ["The skill exists", "a dry run passes", "AWS is shown (`a. b`)"])

    def test_bold_heading_and_numbers(self):
        crit, _ = htr.extract_criteria("**Done when**\n1. alpha\n2) beta\n")
        self.assertEqual(crit, ["alpha", "beta"])

    def test_exit_paragraph(self):
        crit, src = htr.extract_criteria("Text\n\nExit: x is 3; y passes.\n")
        self.assertEqual((crit, src), (["x is 3", "y passes"], "Exit: paragraph"))

    def test_thin(self):
        self.assertEqual(htr.extract_criteria("Make the thing better.")[0], [])


class Routing(unittest.TestCase):
    def ticket(self, body="## Acceptance criteria\n- a\n", labels=(), title="t"):
        return {"number": 7, "title": title, "body": body, "labels": [{"name": l} for l in labels]}

    def test_small_ticket_is_light(self):
        r = htr.resolve(self.ticket(), Args())
        self.assertEqual((r["route"], r["tier"], r["model"], r["effort"]), ("work", "light", "sonnet", "medium"))
        self.assertEqual(r["criteria"], [{"id": "T7.c1", "text": "a"}])

    def test_docs_label_beats_risk_words(self):
        r = htr.resolve(self.ticket(body="## Done when\n- the auth doc reads well\n", labels=["docs"]), Args())
        self.assertEqual(r["tier"], "light")

    def test_risk_words_are_heavy(self):
        r = htr.resolve(self.ticket(body="## Done when\n- the migration runs\n"), Args())
        self.assertEqual((r["tier"], r["model"], r["effort"]), ("heavy", "opus", "high"))

    def test_authoring_is_not_auth(self):
        r = htr.resolve(self.ticket(body="## Done when\n- authoring docs exist\n"), Args())
        self.assertEqual(r["tier"], "light")

    def test_thin_ticket_plans_first_and_is_never_light(self):
        r = htr.resolve(self.ticket(body="Make it nicer."), Args())
        self.assertEqual((r["route"], r["tier"]), ("plan-first", "standard"))
        self.assertEqual(htr.required_steps(r["route"], [])[0], "ce-plan")

    def test_large_ticket_is_heavy(self):
        r = htr.resolve(self.ticket(body="## Done when\n" + "".join("- c%d\n" % i for i in range(9))), Args())
        self.assertEqual(r["tier"], "heavy")

    def test_overrides(self):
        r = htr.resolve(self.ticket(), Args(tier="heavy", effort="xhigh"))
        self.assertEqual((r["tier"], r["model"], r["effort"]), ("heavy", "opus", "xhigh"))

    def test_tier_label_sets_the_lifecycle(self):
        light = htr.resolve(self.ticket(labels=["tier:light"]), Args())
        self.assertEqual((light["tier"], light["model"], light["cycle"]), ("light", "sonnet", "lean"))
        steps = htr.required_steps(light["route"], [], light["cycle"])
        self.assertNotIn("ce-simplify-code", steps)
        self.assertNotIn("ce-compound", steps)
        for kept in ("ce-work", "ce-code-review", "tests", "lint", "ce-commit-push-pr", "pr"):
            self.assertIn(kept, steps)
        heavy = htr.resolve(self.ticket(labels=["tier:heavy"]), Args())
        self.assertEqual((heavy["tier"], heavy["route"], heavy["cycle"]), ("heavy", "work", "full"))
        planned = htr.resolve(self.ticket(labels=["plan:first"]), Args())
        self.assertEqual(planned["route"], "plan-first")
        self.assertTrue(planned["criteria"], "a planned ticket keeps its own criteria ids")

    def test_model_effort_and_cycle_are_separate_calls(self):
        r = htr.resolve(self.ticket(labels=["model:opus", "effort:high", "cycle:none"]), Args())
        self.assertEqual((r["model"], r["effort"], r["cycle"]), ("opus", "high", "none"))
        self.assertEqual(htr.required_steps(r["route"], [], r["cycle"]), ["tests", "lint", "pr"])
        info = {"repo": "o/r", "branch": "htr/7-t", "base": "main", "ticket_file": "/r/ticket.md",
                "required": htr.required_steps(r["route"], [], r["cycle"]), "port_base": 20000}
        text = htr.brief(self.ticket(labels=["cycle:none"]), r, info).split("## What checks you")[0]
        self.assertNotIn("ce-work", text)
        self.assertIn("gh pr create", text)
        self.assertEqual(htr.resolve(self.ticket(labels=["cycle:none"]), Args(cycle="full"))["cycle"], "full")

    def test_a_light_brief_asks_for_only_its_steps(self):
        t = self.ticket(labels=["tier:light"])
        r = htr.resolve(t, Args())
        info = {"repo": "o/r", "branch": "htr/7-t", "base": "main", "ticket_file": "/r/ticket.md",
                "required": htr.required_steps(r["route"], [], r["cycle"]), "port_base": 20000}
        text = htr.brief(t, r, info)
        self.assertNotIn("ce-simplify-code", text.split("## What checks you")[0])
        self.assertNotIn("ce-compound mode", text)
        self.assertIn("ce-code-review quick apply:local", text)

    def test_model_and_effort_labels_within_the_cap(self):
        r = htr.resolve(self.ticket(labels=["tier:standard", "model:sonnet", "effort:high"]), Args())
        self.assertEqual((r["model"], r["effort"]), ("sonnet", "high"))
        self.assertEqual(htr.resolve(self.ticket(labels=["model:sonnet"]), Args(model="opus"))["model"], "opus")
        with self.assertRaises(SystemExit):
            htr.resolve(self.ticket(labels=["model:fable"]), Args())

    def test_opus_cap(self):
        for bad in ("fable", "best", "claude-fable-1", "gpt-5"):
            with self.assertRaises(SystemExit) as cm:
                htr.resolve(self.ticket(), Args(model=bad))
            self.assertEqual(cm.exception.code, 2, bad)
        for ok in ("opus", "claude-opus-5-5", "sonnet", "opus[1m]"):
            self.assertEqual(htr.resolve(self.ticket(), Args(model=ok))["model"], ok)

    def test_skill_md_table_matches_code(self):
        text = slurp(os.path.join(HERE, "SKILL.md"))
        cell = r" `([\w.\[\]-]+)` / `(\w+)` \|"
        rows = re.findall(r"^\| \*\*(\w+)\*\* \|[^|]*\|" + cell * 3, text, re.M)
        self.assertEqual(len(rows), 3)
        table = {r[0]: {p: {"model": r[1 + 2 * i], "effort": r[2 + 2 * i]} for i, p in enumerate(htr.PHASES)} for r in rows}
        self.assertEqual(table, htr.TIERS)

    # ---- phases: the model and effort follow the lifecycle phase
    def phases(self, r):
        return {p: (r["phase_models"][p]["model"], r["phase_models"][p]["effort"]) for p in htr.PHASES}

    def test_each_tier_has_a_model_per_phase(self):
        self.assertEqual(self.phases(htr.resolve(self.ticket(), Args())),
                         {"build": ("sonnet", "medium"), "judge": ("opus", "medium"), "finish": ("sonnet", "low")})
        self.assertEqual(self.phases(htr.resolve(self.ticket(body="Make it nicer."), Args())),
                         {"build": ("sonnet", "medium"), "judge": ("opus", "high"), "finish": ("sonnet", "low")})
        heavy = htr.resolve(self.ticket(body="## Done when\n- the migration runs\n"), Args())
        self.assertEqual(self.phases(heavy), {"build": ("opus", "high"), "judge": ("opus", "high"), "finish": ("sonnet", "medium")})
        self.assertEqual((heavy["model"], heavy["effort"]), ("opus", "high"), "model and effort are the build phase's")

    def test_model_and_effort_overrides_set_the_build_phase_only(self):
        r = htr.resolve(self.ticket(labels=["model:opus", "effort:high"]), Args())
        self.assertEqual(self.phases(r), {"build": ("opus", "high"), "judge": ("opus", "high"), "finish": ("sonnet", "low")})
        r = htr.resolve(self.ticket(labels=["model:haiku"]), Args(effort="low"))
        self.assertEqual(self.phases(r), {"build": ("haiku", "low"), "judge": ("opus", "medium"), "finish": ("sonnet", "low")})

    def test_the_judge_is_opus_at_no_less_than_the_build_effort(self):
        r = htr.resolve(self.ticket(labels=["effort:xhigh"]), Args())
        self.assertEqual(self.phases(r)["judge"], ("opus", "xhigh"))
        self.assertEqual(self.phases(r)["finish"], ("sonnet", "low"))
        r = htr.resolve(self.ticket(), Args(tier="heavy", model="sonnet", effort="max"))
        self.assertEqual(self.phases(r)["judge"], ("opus", "max"))

    def test_judge_labels_and_flags_override_the_judge_phase(self):
        r = htr.resolve(self.ticket(labels=["judge-model:sonnet", "judge-effort:low"]), Args())
        self.assertEqual(self.phases(r)["judge"], ("sonnet", "low"))
        self.assertEqual(self.phases(r)["build"], ("sonnet", "medium"))
        r = htr.resolve(self.ticket(labels=["judge-model:sonnet", "judge-effort:low"]), Args(judge_model="opus", judge_effort="max"))
        self.assertEqual(self.phases(r)["judge"], ("opus", "max"))

    def test_opus_cap_holds_for_every_phase(self):
        for bad in ({"judge_model": "fable"}, {"judge_model": "claude-fable-1"}):
            with self.assertRaises(SystemExit) as cm:
                htr.resolve(self.ticket(), Args(**bad))
            self.assertEqual(cm.exception.code, 2, bad)
        with self.assertRaises(SystemExit):
            htr.resolve(self.ticket(labels=["judge-model:fable"]), Args())
        with self.assertRaises(SystemExit):
            htr.resolve(self.ticket(), Args(judge_effort="ludicrous"))
        for tier in htr.TIERS.values():
            for p in tier.values():
                self.assertRegex(p["model"], htr.MODEL_OK)

    def test_phase_plan_splits_the_required_steps(self):
        res = htr.resolve(self.ticket(), Args(cycle="full"))
        plan = htr.phase_plan(htr.required_steps("plan-first", [], "full"), res["phase_models"])
        self.assertEqual([(p["name"], p["steps"]) for p in plan], [
            ("build", ["ce-plan", "ce-work", "ce-simplify-code"]), ("judge", ["ce-code-review"]),
            ("finish", ["ce-compound", "tests", "lint", "ce-commit-push-pr", "pr"])])
        self.assertEqual((plan[1]["model"], plan[1]["effort"]), ("opus", "medium"))
        lean = htr.phase_plan(htr.required_steps("work", ["lint"], "lean"), res["phase_models"])
        self.assertEqual([(p["name"], p["steps"]) for p in lean], [
            ("build", ["ce-work"]), ("judge", ["ce-code-review"]), ("finish", ["tests", "ce-commit-push-pr", "pr"])])
        # cycle none has no build step to show, so the build turn carries the whole run, on the build model.
        none = htr.phase_plan(htr.required_steps("work", [], "none"), res["phase_models"])
        self.assertEqual([(p["name"], p["steps"], p["model"]) for p in none], [("build", ["tests", "lint", "pr"], "sonnet")])
        # With ce-plan too: the implementing follows the plan in the same build turn, not on the finish model.
        thin = htr.phase_plan(htr.required_steps("plan-first", [], "none"), res["phase_models"])
        self.assertEqual([(p["name"], p["steps"]) for p in thin], [("build", ["ce-plan", "tests", "lint", "pr"])])

    def test_a_refused_judge_model_names_its_own_flag(self):
        err = io.StringIO()
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(err):
            htr.resolve(self.ticket(), Args(judge_model="fable"))
        self.assertIn("judge-model 'fable' is refused", err.getvalue())
        self.assertIn("--judge-model opus", err.getvalue())

    def test_a_turn_refuses_a_model_over_the_cap_written_into_run_json(self):
        d = tempfile.mkdtemp(prefix="htr-turn-")
        self.addCleanup(shutil.rmtree, d, True)
        info = {"model": "sonnet", "effort": "medium", "session_id": "s", "worktree": d}
        self.assertEqual(htr.run_turn(d, info, 0, "phase", "p", {"name": "judge", "model": "fable", "effort": "high"}), 2)
        self.assertIn("refused 'fable'", slurp(os.path.join(d, "agent.log")))
        self.assertEqual(hooks.read_markers(d), [], "a refused turn starts nothing")

    def test_a_phased_brief_tells_the_agent_to_do_one_phase_per_turn(self):
        t = self.ticket()
        r = htr.resolve(t, Args())
        req = htr.required_steps(r["route"], [], r["cycle"])
        info = {"repo": "o/r", "branch": "htr/7-t", "base": "main", "ticket_file": "/r/ticket.md", "required": req,
                "port_base": 20000, "phases": htr.phase_plan(req, r["phase_models"])}
        text = htr.brief(t, r, info)
        self.assertIn("## Phases", text)
        self.assertIn("judge: ce-code-review, on opus / medium", text)
        self.assertIn("This turn is the build phase", text)
        self.assertIn("Leave ce-code-review to the judge phase", text)
        self.assertIn("Each phase ends with a stop", text)
        self.assertIn("Each phase runs as one headless turn", text)
        self.assertNotIn("Then stop.", text)
        info["phases"] = htr.phase_plan(htr.required_steps("work", [], "none"), r["phase_models"])
        self.assertNotIn("## Phases", htr.brief(t, r, info))


# ---------------------------------------------------------------- markers
class Classify(unittest.TestCase):
    def test_kinds(self):
        c = hooks.classify
        self.assertEqual(c("uv run pytest -q -x"), {"test"})
        self.assertEqual(c("just gate"), {"test", "lint"})
        self.assertEqual(c("cd web && pnpm test"), {"test"})
        self.assertEqual(c("FOO=1 uv run ruff check src tests"), {"lint"})
        self.assertEqual(c("python3 -m unittest htr_test"), {"test"})
        self.assertEqual(c("bash scripts/bootstrap.test.sh"), {"test"})
        self.assertEqual(c("cat pytest.ini"), set())
        self.assertEqual(c("git commit -m 'run pytest'"), set())

    def test_a_heredoc_body_is_not_a_run(self):
        c = hooks.classify
        self.assertEqual(c("python3 - <<'EOF'\nopen('pr.md', 'w').write('pytest -q passed')\npytest -q\ntsc clean\nEOF"), set())
        self.assertEqual(c("cat > notes.md <<EOF\nuv run pytest -q\nEOF\nuv run pytest -q"), {"test"})
        self.assertFalse(hooks.masked("cat > n.md <<-EOF\n\tpytest | tail\n\tEOF\nuv run pytest -q"))

    def test_separators_inside_quotes_do_not_split(self):
        c = hooks.classify
        self.assertEqual(c('pgrep -fl "pytest|vitest|tsc" | head'), set())
        self.assertEqual(c("grep -E 'a;pytest' log && uv run pytest -q"), {"test"})
        self.assertFalse(hooks.masked('uv run pytest -q && echo "done | ok"'))
        self.assertTrue(hooks.masked('uv run pytest -q | grep "passed"'))

    def test_masked(self):
        self.assertTrue(hooks.masked("uv run pytest | tail -5"))
        self.assertTrue(hooks.masked("pytest || true"))
        self.assertFalse(hooks.masked("uv run pytest -q && uv run ruff check"))
        self.assertTrue(hooks.masked('uv run ruff check . ; echo "ruff exit $?"', "lint"))
        self.assertTrue(hooks.masked("pytest; true", "test"))
        self.assertTrue(hooks.masked("pytest\necho done", "test"))
        self.assertFalse(hooks.masked("cd web; npm ci; npm test", "test"))
        self.assertFalse(hooks.masked("ls | wc -l; uv run pytest -q 2>&1", "test"))
        self.assertTrue(hooks.masked("uv run pytest -q && uv run ruff check; echo $?", "test"))
        self.assertTrue(hooks.masked("uv run pytest -q &", "test"))
        self.assertTrue(hooks.masked("uv run pytest -q & wait", "test"))
        self.assertFalse(hooks.masked("uv run pytest -q > out.txt 2>&1", "test"))

    def test_not_a_suite_run(self):
        c = hooks.classify
        for cmd in ("pytest --version", "uv run pytest --collect-only -q", "pytest --co", "pytest -k test_one",
                    "pytest tests/test_x.py::test_one", "npx vitest -t 'one case'", "go test -run TestOne ./...",
                    "ruff --version", "pytest --help"):
            self.assertEqual(c(cmd), set(), cmd)
        self.assertEqual(c("python3 -m pytest -q"), {"test"})
        self.assertEqual(c("uv run pytest -m 'not slow'"), {"test"})

    def test_marker_for(self):
        m = hooks.marker_for({"tool_name": "Skill", "tool_input": {"skill": "compound-engineering:ce-work", "args": "x"}}, False)
        self.assertEqual((m["kind"], m["skill"]), ("skill", "ce-work"))
        m = hooks.marker_for({"tool_name": "Bash", "tool_input": {"command": "pytest"}, "error": "Exit code 3"}, True)
        self.assertEqual((m["kind"], m["exit"]), ("bash", 3))
        m = hooks.marker_for({"tool_name": "Bash", "tool_input": {"command": "true"}, "tool_response": {}}, False)
        self.assertEqual(m["exit"], 0)
        self.assertEqual(hooks.marker_for({"tool_name": "Write", "tool_input": {"file_path": "/x"}}, False)["kind"], "edit")
        self.assertIsNone(hooks.marker_for({"tool_name": "Read", "tool_input": {}}, False))


class AwsDeny(unittest.TestCase):
    def setUp(self):
        self.home = os.path.expanduser("~")

    def deny(self, tool, ti, cwd="/tmp"):
        return hooks.touches_real_aws({"tool_name": tool, "tool_input": ti, "cwd": cwd}, {})

    def test_file_tools(self):
        self.assertTrue(self.deny("Read", {"file_path": os.path.join(self.home, ".aws", "credentials")}))
        self.assertTrue(self.deny("Read", {"file_path": "~/.aws/config"}))
        self.assertTrue(self.deny("Read", {"file_path": ".aws/credentials"}, cwd=self.home))
        self.assertTrue(self.deny("Grep", {"pattern": "key", "path": os.path.join(self.home, ".aws")}))
        self.assertTrue(self.deny("Glob", {"pattern": "**/*", "path": os.path.join(self.home, ".aws")}))
        self.assertFalse(self.deny("Read", {"file_path": os.path.join(self.home, ".awsome")}))
        self.assertFalse(self.deny("Read", {"file_path": "/tmp/htr/aws/credentials"}))

    @unittest.skipUnless(sys.platform in ("darwin", "win32"), "case-insensitive file systems only")
    def test_other_case_spellings(self):
        self.assertTrue(self.deny("Read", {"file_path": os.path.join(self.home, ".AWS", "credentials")}))
        self.assertTrue(self.deny("Read", {"file_path": "~/.Aws/Config"}))

    def test_searches_that_walk_into_it(self):
        self.assertTrue(self.deny("Grep", {"pattern": "aws_secret", "path": self.home}))
        self.assertTrue(self.deny("Grep", {"pattern": "aws_secret"}, cwd=self.home))
        self.assertTrue(self.deny("Glob", {"pattern": "**/credentials", "path": "/"}))
        self.assertTrue(self.deny("Glob", {"pattern": os.path.join(self.home, "**", "credentials")}))
        self.assertFalse(self.deny("Grep", {"pattern": "aws_secret", "path": "/tmp"}))
        self.assertFalse(self.deny("Glob", {"pattern": "src/**/*.py"}, cwd="/tmp"))

    def test_bash(self):
        for cmd in ("cat ~/.aws/credentials", "ls $HOME/.aws", "cat ${HOME}/.aws/config",
                    "cat %s/.aws/credentials" % self.home, "cd ~ && cat .aws/credentials", "tar c ~/.aws",
                    "cd ~ && ls .aws", "env -i aws sts get-caller-identity", "env -u AWS_PROFILE aws s3 ls",
                    "unset AWS_SHARED_CREDENTIALS_FILE; aws s3 ls", "AWS_SHARED_CREDENTIALS_FILE=/x aws s3 ls",
                    "AWS_PROFILE=admin aws sts get-caller-identity", "grep -r aws_secret ~", "find ~ -name credentials",
                    "rg -uu key $HOME", "find / -name credentials"):
            self.assertTrue(self.deny("Bash", {"command": cmd}), cmd)
        for cmd in ("aws sts get-caller-identity", "cat $AWS_SHARED_CREDENTIALS_FILE", "ls ~/.awsome",
                    "AWS_PROFILE=htr-agent aws s3 ls", "grep -r key src", "find . -name '*.py'", "env | grep '^AWS_'",
                    "cp -r build /tmp/out"):
            self.assertFalse(self.deny("Bash", {"command": cmd}), cmd)

    def test_bash_windows_spellings(self):
        for cmd in (r"type %USERPROFILE%\.aws\credentials", r"Get-Content $env:USERPROFILE\.aws\config",
                    r"type C:\Users\owner\.aws\credentials", r"cat ~\\.aws\\credentials"):
            self.assertTrue(self.deny("Bash", {"command": cmd}), cmd)


# ---------------------------------------------------------------- evaluation and the Stop hook
class StopHook(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="htr-test-")
        self.wt = os.path.join(self.t, "wt")
        init_repo(self.wt)
        self.run_dir = os.path.join(self.t, "run")
        os.makedirs(self.run_dir)
        self.run = {"id": "r", "run_dir": self.run_dir, "repo": "o/r", "issue": 7, "branch": "htr/7-x", "worktree": self.wt,
                    "ticket_file": os.path.join(self.run_dir, "ticket.md"), "work_input": os.path.join(self.run_dir, "ticket.md"),
                    "required": htr.required_steps("work", []), "criteria": [{"id": "T7.c1", "text": "a"}],
                    "budgets": {"stop_blocks": 3, "stalled_blocks": 2}}
        hooks.write_json(os.path.join(self.run_dir, "run.json"), self.run)
        self.pr = os.path.join(self.t, "pr.json")
        os.environ["HTR_FAKE_PR"] = self.pr
        self.write_pr()

    def tearDown(self):
        os.environ.pop("HTR_FAKE_PR", None)
        shutil.rmtree(self.t, ignore_errors=True)

    def write_pr(self, body="Closes #7\n\nT7.c1: verified by pytest\n\n## Review findings\nnone residual\n", head=None):
        hooks.write_json(self.pr, {"url": "https://github.com/o/r/pull/1", "state": "OPEN", "body": body,
                                   "headRefOid": head or git(self.wt, "rev-parse", "HEAD")})

    def mark(self, *ms):
        for m in ms:
            hooks.append_marker(self.run_dir, m)

    def skill(self, name):
        return {"kind": "skill", "skill": name, "ok": True}

    def full(self):
        self.mark(self.skill("ce-work"), {"kind": "edit", "path": os.path.join(self.wt, "README.md")},
                  self.skill("ce-simplify-code"), self.skill("ce-code-review"), self.skill("ce-compound"),
                  {"kind": "bash", "command": "uv run pytest -q", "exit": 0},
                  {"kind": "bash", "command": "uv run ruff check src", "exit": 0},
                  self.skill("ce-commit-push-pr"))

    def stop(self, active=False):
        out, marker = hooks.stop_decision(self.run_dir, {"stop_hook_active": active, "last_assistant_message": "done"})
        hooks.append_marker(self.run_dir, marker)
        return out, marker

    def test_nothing_done_blocks_with_every_step(self):
        out, marker = self.stop()
        self.assertEqual(out["decision"], "block")
        for step in ("ce-work", "ce-simplify-code", "ce-code-review", "tests", "lint", "ce-compound", "ce-commit-push-pr"):
            self.assertIn(step + ":", out["reason"])
        self.assertEqual(marker["decision"], "block")

    def test_full_lifecycle_allows_and_records_completion(self):
        self.full()
        out, marker = self.stop()
        self.assertIsNone(out)
        self.assertEqual(marker["decision"], "allow")
        self.assertEqual(hooks.read_json(os.path.join(self.run_dir, "complete.json"))["pr"], "https://github.com/o/r/pull/1")

    def test_edit_after_tests_needs_a_rerun(self):
        self.full()
        self.mark({"kind": "edit", "path": os.path.join(self.wt, "x.py")})
        steps = [m["step"] for m in hooks.evaluate(self.run_dir)["missing"]]
        self.assertEqual(steps, ["tests", "lint"])
        self.mark({"kind": "edit", "path": "/elsewhere/notes.md"})   # outside the worktree: not a code change
        self.mark({"kind": "bash", "command": "just gate", "exit": 0})
        self.assertEqual(hooks.evaluate(self.run_dir)["missing"], [])

    def test_failed_and_masked_test_runs_do_not_count(self):
        self.full()
        self.mark({"kind": "bash", "command": "uv run pytest", "exit": 1})
        self.assertIn("exited 1", hooks.evaluate(self.run_dir)["missing"][0]["why"])
        self.mark({"kind": "bash", "command": "uv run pytest | tail -3", "exit": 0})
        self.assertIn("masks", hooks.evaluate(self.run_dir)["missing"][0]["why"])

    def test_a_green_suite_does_not_stand_in_for_a_red_one(self):
        # #39's run: the Python suite exited 1 after the last edit, then the web suite passed.
        self.full()
        self.mark({"kind": "bash", "command": "cd /w; uv run pytest -q -p no:cacheprovider", "exit": 1},
                  {"kind": "bash", "command": "pnpm -C web test", "exit": 0})
        why = [m for m in hooks.evaluate(self.run_dir)["missing"] if m["step"] == "tests"][0]["why"]
        self.assertIn("`pytest` run exited 1", why)
        self.mark({"kind": "bash", "command": "pytest -q", "exit": 0})   # same suite, other spelling
        self.assertEqual(hooks.evaluate(self.run_dir)["missing"], [])

    def test_a_red_suite_stays_red_across_an_edit_until_it_or_a_gate_passes(self):
        self.full()
        self.mark({"kind": "bash", "command": "uv run pytest -q", "exit": 1},
                  {"kind": "edit", "path": os.path.join(self.wt, "x.py")},
                  {"kind": "bash", "command": "pnpm -C web test", "exit": 0},
                  {"kind": "bash", "command": "uv run ruff check .", "exit": 0})
        why = [m for m in hooks.evaluate(self.run_dir)["missing"] if m["step"] == "tests"][0]["why"]
        self.assertIn("has not passed since", why)
        self.mark({"kind": "bash", "command": "just gate", "exit": 0})
        self.assertEqual(hooks.evaluate(self.run_dir)["missing"], [])

    def test_exploratory_runs_before_the_last_edit_do_not_block(self):
        self.full()
        self.mark({"kind": "bash", "command": "pnpm test > /tmp/o.txt 2>&1; echo $?", "exit": 0},
                  {"kind": "bash", "command": "grep -rn 'just gate\\|x' . | head", "exit": 0},
                  {"kind": "edit", "path": os.path.join(self.wt, "x.py")},
                  {"kind": "bash", "command": "uv run pytest -q", "exit": 0},
                  {"kind": "bash", "command": "uv run ruff check .", "exit": 0})
        self.assertEqual(hooks.evaluate(self.run_dir)["missing"], [])

    def test_suites_are_named_by_the_words_that_matched(self):
        self.assertEqual(hooks.suites("cd /w; uv run pytest -q && pnpm -C web test", "test"), ["pytest", "pnpm -C web test"])
        self.assertEqual(hooks.suites("pnpm -C web typecheck && pnpm -C web lint", "lint"),
                         ["pnpm -C web typecheck", "pnpm -C web lint"])
        self.assertEqual(hooks.suites("python3 -m pytest", "test"), ["pytest"])

    def test_background_test_run_does_not_count(self):
        self.full()
        m = hooks.marker_for({"tool_name": "Bash", "tool_input": {"command": "uv run pytest -q"},
                              "tool_response": {"backgroundTaskId": "b1", "stdout": ""}}, failed=False)
        self.assertIsNone(m["exit"])
        self.mark(m)
        self.assertIn("background", hooks.evaluate(self.run_dir)["missing"][0]["why"])
        asked = hooks.marker_for({"tool_name": "Bash", "tool_input": {"command": "ruff check .", "run_in_background": True}}, False)
        self.assertTrue(asked["background"])

    def test_review_after_shipping_is_missing(self):
        self.full()
        self.mark(self.skill("ce-code-review"))
        miss = hooks.evaluate(self.run_dir)["missing"]
        self.assertEqual([m["step"] for m in miss], ["ce-commit-push-pr"])

    def test_work_after_the_last_review_needs_another_review(self):
        self.full()
        self.mark(self.skill("ce-work"))
        miss = hooks.evaluate(self.run_dir)["missing"]
        self.assertEqual(miss[0]["step"], "ce-code-review")
        self.assertIn("before the last ce-work", miss[0]["why"])

    def test_missing_steps_come_in_working_order(self):
        steps = [m["step"] for m in hooks.evaluate(self.run_dir, check_pr=False)["missing"]]
        self.assertEqual(steps, ["ce-work", "ce-simplify-code", "ce-code-review", "ce-compound", "tests", "lint", "ce-commit-push-pr"])

    def test_no_pr_points_at_the_shipping_skill(self):
        self.full()
        os.remove(self.pr)
        hooks.write_json(self.pr, None)
        miss = hooks.evaluate(self.run_dir)["missing"]
        self.assertEqual(miss[-1]["step"], "pr")

    def test_unreadable_run_json_escalates_not_completes(self):
        os.remove(os.path.join(self.run_dir, "run.json"))
        out, marker = self.stop()
        self.assertEqual(marker["decision"], "escalate")
        self.assertFalse(os.path.exists(os.path.join(self.run_dir, "complete.json")))

    def test_block_budget_is_per_turn(self):
        self.run["budgets"]["stop_blocks"] = 1
        hooks.write_json(os.path.join(self.run_dir, "run.json"), self.run)
        self.mark({"kind": "turn", "event": "start", "turn": 0})
        self.assertEqual(self.stop()[1]["decision"], "block")
        self.mark({"kind": "bash", "command": "echo working", "exit": 0})
        self.assertEqual(self.stop(active=True)[1]["decision"], "escalate")
        self.mark({"kind": "turn", "event": "start", "turn": 1})   # a finishing turn
        self.assertEqual(self.stop()[1]["decision"], "block")

    def test_pr_must_match_head_cite_ids_and_carry_review(self):
        self.full()
        self.write_pr(body="Closes #7", head="0" * 40)
        why = hooks.evaluate(self.run_dir)["missing"][0]["why"]
        self.assertIn("not the worktree HEAD", why)
        self.assertIn("T7.c1", why)
        self.assertIn("review", why)
        with open(os.path.join(self.wt, "dirty.txt"), "w") as f:
            f.write("x")
        self.assertIn("uncommitted", hooks.evaluate(self.run_dir)["missing"][0]["why"])

    def test_block_budget_escalates_instead_of_looping(self):
        decisions = []
        for i in range(4):
            out, m = self.stop(active=i > 0)
            decisions.append(m["decision"])
            self.mark({"kind": "bash", "command": "echo working", "exit": 0})   # progress every time: no stall
        self.assertEqual(decisions, ["block", "block", "block", "escalate"])
        esc = slurp(os.path.join(self.run_dir, "escalation.md"))
        self.assertIn("blocked 3 times", esc)
        self.assertIn("ce-commit-push-pr", esc)
        self.assertIn("> done", esc)   # the agent's last message is kept for the reader

    def test_stall_escalates_after_two_idle_stops(self):
        decisions = [self.stop(active=i > 0)[1]["decision"] for i in range(3)]
        self.assertEqual(decisions, ["block", "block", "escalate"])
        self.assertIn("nothing done in between", slurp(os.path.join(self.run_dir, "escalation.md")))

    def test_plan_first_requires_plan_before_work(self):
        self.run["required"] = htr.required_steps("plan-first", [])
        self.run["work_input"] = htr.PLAN_PATH
        hooks.write_json(os.path.join(self.run_dir, "run.json"), self.run)
        self.full()
        self.assertEqual(hooks.evaluate(self.run_dir)["missing"][0]["step"], "ce-plan")
        self.mark(self.skill("ce-plan"))
        miss = hooks.evaluate(self.run_dir)["missing"][0]
        self.assertIn("before ce-plan", miss["why"])
        self.assertIn("ce-work mode:return-to-caller %s" % htr.PLAN_PATH, miss["do"])
        # A second ce-work after the plan, then a review of it and the shipping call, clears it.
        self.mark(self.skill("ce-work"), self.skill("ce-code-review"), self.skill("ce-commit-push-pr"))
        self.assertEqual(hooks.evaluate(self.run_dir)["missing"], [])

    def test_skipped_steps_are_not_required(self):
        self.run["required"] = htr.required_steps("work", ["lint"])
        hooks.write_json(os.path.join(self.run_dir, "run.json"), self.run)
        self.mark(self.skill("ce-work"), self.skill("ce-simplify-code"), self.skill("ce-code-review"),
                  {"kind": "bash", "command": "pytest", "exit": 0}, self.skill("ce-compound"), self.skill("ce-commit-push-pr"))
        self.assertEqual(hooks.evaluate(self.run_dir)["missing"], [])

    # ---- phased runs: the hook ends a turn once its own phase is shown
    def phased(self, cycle="full"):
        res = htr.resolve({"number": 7, "title": "t", "body": "## Done when\n- a\n", "labels": []}, Args(cycle=cycle))
        self.run["required"] = htr.required_steps("work", [], cycle)
        self.run["phases"] = htr.phase_plan(self.run["required"], res["phase_models"])
        hooks.write_json(os.path.join(self.run_dir, "run.json"), self.run)

    def turn(self, phase, n=0):
        self.mark({"kind": "turn", "turn": n, "event": "start", "phase": phase})

    def test_a_phased_turn_is_blocked_only_for_its_own_steps(self):
        self.phased()
        self.turn("build")
        out, marker = self.stop()
        self.assertEqual(out["decision"], "block")
        self.assertIn("build phase", out["reason"])
        self.assertEqual(sorted(k.split(":")[0] for k in marker["missing"]), ["ce-simplify-code", "ce-work"])
        self.assertNotIn("tests:", out["reason"])
        self.mark(self.skill("ce-work"), {"kind": "edit", "path": os.path.join(self.wt, "README.md")}, self.skill("ce-simplify-code"))
        out, marker = self.stop(active=True)
        self.assertIsNone(out, "the build phase is shown: the turn may end")
        self.assertEqual((marker["decision"], marker["phase"], marker["next"]), ("phase-done", "build", "judge"))
        self.assertFalse(os.path.exists(os.path.join(self.run_dir, "complete.json")))

    def test_each_phase_ends_in_turn_and_the_last_completes(self):
        self.phased()
        self.turn("build")
        self.mark(self.skill("ce-work"), {"kind": "edit", "path": os.path.join(self.wt, "README.md")}, self.skill("ce-simplify-code"))
        self.assertEqual(self.stop()[1]["decision"], "phase-done")
        self.turn("judge")
        self.assertEqual(self.stop()[1]["decision"], "block")
        self.mark(self.skill("ce-code-review"))
        self.assertEqual(self.stop(active=True)[1]["next"], "finish")
        self.turn("finish")
        out, marker = self.stop()
        self.assertEqual(out["decision"], "block")
        self.assertIn("ce-compound:", out["reason"])
        self.mark(self.skill("ce-compound"), {"kind": "bash", "command": "just gate", "exit": 0}, self.skill("ce-commit-push-pr"))
        out, marker = self.stop(active=True)
        self.assertEqual(marker["decision"], "allow")
        self.assertTrue(os.path.exists(os.path.join(self.run_dir, "complete.json")))

    def test_a_judge_turn_whose_fix_up_calls_ce_work_needs_another_review(self):
        self.phased()
        self.turn("build")
        self.mark(self.skill("ce-work"), self.skill("ce-simplify-code"))
        self.turn("judge")
        self.mark(self.skill("ce-code-review"), self.skill("ce-work"))
        out, marker = self.stop()
        self.assertEqual(marker["decision"], "block")
        self.assertIn("before the last ce-work", out["reason"])

    def test_a_review_outside_the_judge_turn_does_not_count(self):
        self.phased()
        self.turn("build")
        self.mark(self.skill("ce-work"), self.skill("ce-simplify-code"), self.skill("ce-code-review"))
        out, marker = self.stop()
        self.assertEqual((marker["decision"], marker["next"]), ("phase-done", "judge"), "the judge turn still runs")
        self.turn("judge")
        out, marker = self.stop()
        self.assertEqual(marker["decision"], "block")
        self.assertIn("outside the judge phase's turn", out["reason"])

    def test_a_finish_turn_that_reopens_the_review_ends_for_the_judge(self):
        self.phased()
        self.turn("build")
        self.mark(self.skill("ce-work"), self.skill("ce-simplify-code"))
        self.turn("judge")
        self.mark(self.skill("ce-code-review"))
        self.turn("finish")
        self.mark(self.skill("ce-work"))
        out, marker = self.stop()
        self.assertIsNone(out, "a review on the finish model would not count, so the turn ends")
        self.assertEqual((marker["decision"], marker["phase"], marker["next"]), ("phase-done", "finish", "judge"))
        self.assertIsNone(htr.next_phase(self.run_dir, self.run["phases"], self.run["phases"][2])[0],
                          "the supervisor goes forward only; resume routes to the judge")
        self.assertEqual(hooks.first_missing_phase(self.run, hooks.evaluate(self.run_dir)["missing"])["name"], "judge")

    def test_a_finish_turn_is_blocked_for_an_earlier_build_step_still_missing(self):
        # Reached when a turn ends some other way (a hook timeout, say) and a later phase runs.
        self.phased()
        self.turn("build")
        self.mark(self.skill("ce-work"))
        self.turn("judge")
        self.mark(self.skill("ce-code-review"))
        self.turn("finish")
        out, marker = self.stop()
        self.assertEqual(marker["decision"], "block")
        self.assertIn("finish phase", out["reason"])
        self.assertIn("ce-simplify-code:", out["reason"])
        self.assertNotIn("later phases", out["reason"], "finish is the last phase")

    def test_a_one_turn_phased_run_names_no_later_phases(self):
        self.phased("none")
        self.turn("build")
        out, marker = self.stop()
        self.assertEqual(marker["decision"], "block")
        self.assertNotIn("later phases", out["reason"])

    def test_legacy_run_json_keeps_one_turn_for_the_whole_cycle(self):
        # A run.json written before phases existed, as htr.py launch wrote it then: no "phases" key,
        # and its turn markers carry no phase. The hook holds the stop until the whole cycle is shown.
        legacy = {"id": "o-r-7-20261024T101500", "run_dir": self.run_dir, "repo": "o/r", "issue": 7, "title": "t", "url": "u",
                  "checkout": self.wt, "worktree": self.wt, "branch": "htr/7-x", "base": "main",
                  "ticket_file": os.path.join(self.run_dir, "ticket.md"), "required": htr.required_steps("work", []),
                  "skipped": [], "session_id": "11111111-2222-3333-4444-555555555555", "detach": "process",
                  "aws_profile": "htr-agent", "real_aws_dirs": [], "budgets": {"stop_blocks": 8, "stalled_blocks": 2, "finishing_turns": 2},
                  "test_regex": None, "lint_regex": None, "launched_at": "20261024T101500", "finishing_turns": 0, "extensions": [],
                  "port_base": 20000, "copied_in": [], "route": "work", "route_why": "1 acceptance criteria", "tier": "standard",
                  "tier_why": "default", "model": "opus", "effort": "medium", "criteria": [{"id": "T7.c1", "text": "a"}],
                  "criteria_source": "list", "work_input": os.path.join(self.run_dir, "ticket.md")}
        hooks.write_json(os.path.join(self.run_dir, "run.json"), legacy)
        self.mark({"kind": "turn", "turn": 0, "event": "start", "model": "opus", "effort": "medium"})
        self.mark(self.skill("ce-work"), {"kind": "edit", "path": os.path.join(self.wt, "README.md")}, self.skill("ce-simplify-code"))
        out, marker = self.stop()
        self.assertEqual(marker["decision"], "block", "a legacy run never ends a turn early")
        self.assertNotIn("phase", marker)
        for step in ("ce-code-review", "ce-compound", "tests", "lint", "ce-commit-push-pr"):
            self.assertIn(step + ":", out["reason"])
        self.assertIn("this run cannot end yet", out["reason"])
        self.mark(self.skill("ce-code-review"))
        self.assertEqual(self.stop(active=True)[1]["decision"], "block")

    def test_hook_entry_points(self):
        def call(verb, payload):
            return subprocess.run([PY, HOOKS, verb, "--run", self.run_dir], input=json.dumps(payload),
                                  capture_output=True, text=True, env=dict(os.environ))
        r = call("post-tool-use", {"tool_name": "Skill", "tool_input": {"skill": "compound-engineering:ce-work"}})
        self.assertEqual(r.returncode, 0)
        r = call("post-tool-fail", {"tool_name": "Bash", "tool_input": {"command": "pytest"}, "error": "Exit code 2"})
        ms = hooks.read_markers(self.run_dir)
        self.assertEqual([(m["kind"], m.get("skill"), m.get("exit")) for m in ms], [("skill", "ce-work", None), ("bash", None, 2)])
        r = call("pre-tool-use", {"tool_name": "Read", "tool_input": {"file_path": "~/.aws/credentials"}, "cwd": self.wt})
        self.assertEqual(json.loads(r.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")
        r = call("pre-tool-use", {"tool_name": "Read", "tool_input": {"file_path": "README.md"}, "cwd": self.wt})
        self.assertEqual(r.stdout.strip(), "")
        r = call("stop", {"stop_hook_active": False})
        self.assertEqual(json.loads(r.stdout)["decision"], "block")
        r = call("post-tool-use", "not an object")
        self.assertEqual(r.returncode, 0)


# ---------------------------------------------------------------- launch, status and resume with fakes
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
d = os.environ["FAKE_DIR"]
with open(os.path.join(d, "claude.calls"), "a") as f:
    f.write(json.dumps({"argv": sys.argv[1:], "env": dict(os.environ), "cwd": os.getcwd()}) + "\n")
if "--version" in sys.argv:
    print("9.9.9 (Claude Code)"); sys.exit(0)
mode = os.environ.get("FAKE_CLAUDE_MODE", "die")
run_dir = os.environ["HTR_RUN_DIR"]
hooks = os.environ["FAKE_HOOKS"]
def hook(verb, payload):
    return subprocess.run([sys.executable, hooks, verb, "--run", run_dir], input=json.dumps(payload),
                          capture_output=True, text=True).stdout
if mode == "die":
    print("partial work, then the turn ended"); sys.exit(1)
if mode == "hang":
    import time; time.sleep(60); sys.exit(1)
if mode == "full":
    for s in ("ce-work", "ce-simplify-code", "ce-code-review"):
        hook("post-tool-use", {"tool_name": "Skill", "tool_input": {"skill": "compound-engineering:" + s}})
    open("CHANGE.md", "w").write("x\n")
    hook("post-tool-use", {"tool_name": "Write", "tool_input": {"file_path": os.path.abspath("CHANGE.md")}})
    out = hook("stop", {"stop_hook_active": False})
    print("stop 1:", out)
    hook("post-tool-use", {"tool_name": "Bash", "tool_input": {"command": "just gate"}, "tool_response": {}})
    subprocess.run(["git", "add", "-A"]); subprocess.run(["git", "commit", "-qm", "change"])
    for s in ("ce-compound", "ce-commit-push-pr"):
        hook("post-tool-use", {"tool_name": "Skill", "tool_input": {"skill": s}})
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    json.dump({"url": "https://github.com/o/r/pull/9", "state": "OPEN", "headRefOid": head,
               "body": "Closes #7\nT7.c1 ok\n## Review findings\nnone"}, open(os.environ["HTR_FAKE_PR"], "w"))
    out = hook("stop", {"stop_hook_active": True})
    print("stop 2:", out or "allowed")
if mode == "phased":
    # Does what the turn's phase asks, read from the turn marker the supervisor wrote.
    starts = [json.loads(l) for l in open(os.path.join(run_dir, "markers.jsonl")) if '"event": "start"' in l]
    phase = starts[-1].get("phase")
    print("phase", phase)
    if phase == "build":
        print("early stop:", hook("stop", {"stop_hook_active": False}))
        hook("post-tool-use", {"tool_name": "Skill", "tool_input": {"skill": "compound-engineering:ce-work"}})
        open("CHANGE.md", "w").write("x\n")
        hook("post-tool-use", {"tool_name": "Write", "tool_input": {"file_path": os.path.abspath("CHANGE.md")}})
        subprocess.run(["git", "add", "-A"]); subprocess.run(["git", "commit", "-qm", "change"])
    elif phase == "judge":
        hook("post-tool-use", {"tool_name": "Skill", "tool_input": {"skill": "ce-code-review"}})
    elif phase == "finish":
        hook("post-tool-use", {"tool_name": "Bash", "tool_input": {"command": "just gate"}, "tool_response": {}})
        hook("post-tool-use", {"tool_name": "Skill", "tool_input": {"skill": "ce-commit-push-pr"}})
        head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        json.dump({"url": "https://github.com/o/r/pull/9", "state": "OPEN", "headRefOid": head,
                   "body": "Closes #7\nT7.c1 ok\n## Review findings\nnone"}, open(os.environ["HTR_FAKE_PR"], "w"))
    print("stop:", hook("stop", {"stop_hook_active": False}) or "allowed")
    sys.exit(int(os.environ.get("FAKE_EXIT", "0")))
'''

FAKE_GH = r'''#!/usr/bin/env python3
import sys
if sys.argv[1:2] == ["--version"]: print("gh version 9.9.9")
sys.exit(0)
'''


class Launch(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="htr-launch-")
        self.fake = os.path.join(self.t, "fake")
        os.makedirs(os.path.join(self.fake, "bin"))
        for name, body in (("claude", FAKE_CLAUDE), ("gh", FAKE_GH)):
            p = os.path.join(self.fake, "bin", name)
            with open(p, "w") as f:
                f.write(body)
            os.chmod(p, 0o755)
        self.origin = os.path.join(self.t, "origin")
        init_repo(self.origin)
        self.checkout = os.path.join(self.t, "checkout")
        subprocess.run(["git", "clone", "-q", self.origin, self.checkout], check=True)
        self.issue = os.path.join(self.t, "issue.json")
        hooks.write_json(self.issue, {"number": 7, "title": "Fix a typo in the README", "state": "OPEN", "url": "u",
                                      "body": "## Acceptance criteria\n- the typo is gone\n", "labels": [{"name": "docs"}]})
        self.env = dict(os.environ, PATH=os.path.join(self.fake, "bin") + os.pathsep + os.environ["PATH"],
                        HTR_HOME=os.path.join(self.t, "home"), HTR_FAKE_ISSUE=self.issue, FAKE_DIR=self.fake,
                        FAKE_HOOKS=HOOKS, HTR_FAKE_PR=os.path.join(self.t, "pr.json"),
                        AWS_ACCESS_KEY_ID="AKIAADMINADMINADMIN", AWS_SECRET_ACCESS_KEY="s", AWS_PROFILE="admin",
                        AWS_SEC="also-secret", CLAUDECODE="1", CLAUDE_CODE_SESSION_ID="parent")

    def tearDown(self):
        shutil.rmtree(self.t, ignore_errors=True)

    def htr(self, *a, **kw):
        env = dict(self.env, **kw.pop("env", {}))
        return subprocess.run([PY, HTR] + list(a), capture_output=True, text=True, env=env, cwd=self.t,
                              stdin=subprocess.DEVNULL)

    def wait_exit(self, run_dir, n=1):
        for _ in range(200):
            ends = [m for m in hooks.read_markers(run_dir) if m.get("kind") == "turn" and m.get("event") == "end"]
            if len(ends) >= n:
                return
            time.sleep(0.05)
        self.fail("the supervised turn never ended")

    def launch(self, mode, *extra):
        r = self.htr("launch", "--repo", "o/r", "--issue", "7", "--checkout", self.checkout, "--base", "main", "--json",
                     *extra, env={"FAKE_CLAUDE_MODE": mode})
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        out = json.loads(r.stdout)
        run_dir = os.path.join(self.t, "home", "runs", out["run"])
        return out, run_dir

    def calls(self):
        with open(os.path.join(self.fake, "claude.calls")) as f:
            return [json.loads(l) for l in f if "--version" not in l]

    def test_copy_in_puts_an_untracked_file_in_the_worktree_and_names_it(self):
        os.makedirs(os.path.join(self.checkout, "data"))
        with open(os.path.join(self.checkout, "data", "catalog.sqlite"), "w") as f:
            f.write("rows")
        out, run_dir = self.launch("die", "--copy-in", "data/catalog.sqlite")
        self.wait_exit(run_dir)
        self.assertEqual(slurp(os.path.join(out["worktree"], "data", "catalog.sqlite")), "rows")
        self.assertIn("`data/catalog.sqlite`", slurp(os.path.join(run_dir, "prompt.md")))
        for bad in ("missing.sqlite", "../outside", "/etc/hosts"):
            r = self.htr("launch", "--repo", "o/r", "--issue", "7", "--checkout", self.checkout, "--base", "main",
                         "--again", "--copy-in", bad)
            self.assertNotEqual(r.returncode, 0, bad)

    def test_launch_scrubs_env_installs_hooks_and_detaches(self):
        out, run_dir = self.launch("die")
        self.wait_exit(run_dir)
        self.assertEqual((out["tier"], out["model"], out["effort"], out["route"]), ("light", "sonnet", "medium", "work"))
        self.assertEqual(git(out["worktree"], "branch", "--show-current"), out["branch"])
        call = self.calls()[0]
        argv, env = call["argv"], call["env"]
        self.assertEqual(os.path.realpath(call["cwd"]), os.path.realpath(out["worktree"]))
        for flag in ("-p", "--dangerously-skip-permissions", "--settings", "--session-id", "--strict-mcp-config"):
            self.assertIn(flag, argv)
        self.assertEqual(hooks.read_json(argv[argv.index("--mcp-config") + 1]), {"mcpServers": {}})
        self.assertEqual(argv[argv.index("--model") + 1], "sonnet")
        self.assertEqual(argv[argv.index("--effort") + 1], "medium")
        self.assertNotIn("AWS_ACCESS_KEY_ID", env)
        self.assertNotIn("AWS_SECRET_ACCESS_KEY", env)
        self.assertNotIn("AWS_SEC", env)
        self.assertNotIn("CLAUDECODE", env)
        self.assertNotIn("CLAUDE_CODE_SESSION_ID", env)
        self.assertEqual(env["AWS_PROFILE"], "htr-agent")
        self.assertEqual(env["HTR_PORT_BASE"], "20000")          # the first free 100-port block
        self.assertIn("HTR_PORT_BASE`=20000", argv[-1])
        self.assertEqual(env["BASH_MAX_TIMEOUT_MS"], "2700000")
        self.assertIn("timeout: 2700000", argv[-1])
        self.assertTrue(env["AWS_SHARED_CREDENTIALS_FILE"].startswith(os.path.join(self.t, "home", "aws")))
        self.assertNotIn("aws_access_key_id", slurp(env["AWS_SHARED_CREDENTIALS_FILE"]).split("[htr-agent]")[1])
        settings = hooks.read_json(argv[argv.index("--settings") + 1])
        stop = settings["hooks"]["Stop"][0]["hooks"][0]
        self.assertEqual(stop["command"], PY)
        self.assertEqual(stop["args"][1:], ["stop", "--run", run_dir])
        self.assertIn("Skill", settings["hooks"]["PostToolUse"][0]["matcher"])
        prompt = argv[-1]
        self.assertIn("T7.c1: the typo is gone", prompt)
        self.assertIn("ce-work mode:return-to-caller", prompt)
        self.assertIn("ce-commit-push-pr mode:pipeline", prompt)
        self.assertIn("Fix a typo in the README", prompt)

    def test_a_live_run_holds_its_port_block(self):
        _, first = self.launch("hang")
        for _ in range(200):   # wait until the run is live
            if hooks.read_json(os.path.join(first, "supervise.json")):
                break
            time.sleep(0.05)
        try:
            out = self.htr("launch", "--repo", "o/r", "--issue", "7", "--checkout", self.checkout, "--base", "main",
                           "--json", "--again", "--dry-run")
            self.assertEqual(json.loads(out.stdout.split("\n(dry run")[0])["port_base"], 20100, out.stderr)
        finally:
            sup = hooks.read_json(os.path.join(first, "supervise.json"), {})
            for pid in (sup.get("pid"),):
                if pid:
                    try:
                        os.killpg(os.getpgid(pid), 9)
                    except OSError:
                        pass

    def test_dead_turn_resumes_within_budget_then_escalates(self):
        out, run_dir = self.launch("die")
        self.wait_exit(run_dir)
        st = json.loads(self.htr("status", "--json").stdout)[0]
        self.assertEqual(st["state"], "ended-incomplete")
        self.assertIn("ce-work", st["missing"])
        r = self.htr("resume", "--run", out["run"])
        self.assertIn("finishing turn 1 of 2", r.stdout)
        self.assertIn("(printed only", r.stdout)
        for n in (2, 3):
            r = self.htr("resume", "--run", out["run"], "--send", env={"FAKE_CLAUDE_MODE": "die"})
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.wait_exit(run_dir, n)
        resumes = [c["argv"] for c in self.calls()][1:]
        sid = hooks.read_json(os.path.join(run_dir, "run.json"))["session_id"]
        self.assertTrue(all(a[a.index("--resume") + 1] == sid for a in resumes))
        r = self.htr("resume", "--run", out["run"], "--send")
        self.assertEqual(r.returncode, 2, r.stdout)
        self.assertIn("budget spent", r.stdout)
        self.assertTrue(os.path.exists(os.path.join(run_dir, "escalation.md")))
        r = self.htr("resume", "--run", out["run"], "--send")
        self.assertIn("needs --extend", r.stdout)

    def arg(self, argv, flag):
        return argv[argv.index(flag) + 1]

    def test_a_phased_run_switches_model_per_phase_in_one_session(self):
        out, run_dir = self.launch("phased")
        self.wait_exit(run_dir, 3)
        for _ in range(200):   # the supervisor writes exit.json after its last turn
            if os.path.exists(os.path.join(run_dir, "exit.json")):
                break
            time.sleep(0.05)
        calls = [c["argv"] for c in self.calls()]
        self.assertEqual([(self.arg(a, "--model"), self.arg(a, "--effort")) for a in calls],
                         [("sonnet", "medium"), ("opus", "medium"), ("sonnet", "low")])
        rj = hooks.read_json(os.path.join(run_dir, "run.json"))
        self.assertEqual(self.arg(calls[0], "--session-id"), rj["session_id"])
        self.assertTrue(all(self.arg(a, "--resume") == rj["session_id"] for a in calls[1:]))
        self.assertIn("judge phase", calls[1][-1])
        self.assertIn("ce-code-review", calls[1][-1])
        self.assertIn("git log", calls[1][-1])
        self.assertIn("finish phase", calls[2][-1])
        self.assertEqual(rj["finishing_turns"], 0, "phase turns are not finishing turns")
        stops = [m for m in hooks.read_markers(run_dir) if m.get("kind") == "stop"]
        self.assertEqual([s["decision"] for s in stops], ["block", "phase-done", "phase-done", "allow"])
        self.assertEqual([k.split(":")[0] for k in stops[0]["missing"]], ["ce-work"])
        starts = [m for m in hooks.read_markers(run_dir) if m.get("kind") == "turn" and m.get("event") == "start"]
        self.assertEqual([(m["phase"], m["model"], m["effort"]) for m in starts],
                         [("build", "sonnet", "medium"), ("judge", "opus", "medium"), ("finish", "sonnet", "low")])
        log = slurp(os.path.join(run_dir, "agent.log"))
        self.assertIn("judge: opus / medium", log)
        st = json.loads(self.htr("status", "--json").stdout)[0]
        self.assertEqual((st["state"], st["pr"]), ("complete", "https://github.com/o/r/pull/9"))
        self.assertEqual([(t["phase"], t["model"], t["effort"]) for t in st["turns"]],
                         [("build", "sonnet", "medium"), ("judge", "opus", "medium"), ("finish", "sonnet", "low")])
        self.assertIn("finish sonnet/low", self.htr("status").stdout)

    def test_resume_runs_on_the_phase_of_the_first_missing_step(self):
        out, run_dir = self.launch("die")
        self.wait_exit(run_dir)
        self.assertEqual(len(self.calls()), 1, "a failed turn starts no phase turn")
        hooks.append_marker(run_dir, {"kind": "skill", "skill": "ce-work", "ok": True})
        r = self.htr("resume", "--run", out["run"])
        self.assertIn("judge phase: opus / medium", r.stdout)
        self.assertNotIn("ce-commit-push-pr", r.stdout.split("finishing turn")[1], "a judge turn lists only its own steps")
        hooks.append_marker(run_dir, {"kind": "turn", "turn": 1, "event": "start", "phase": "judge"})
        hooks.append_marker(run_dir, {"kind": "skill", "skill": "ce-code-review", "ok": True})
        self.assertIn("finish phase: sonnet / low", self.htr("resume", "--run", out["run"]).stdout)
        r = self.htr("resume", "--run", out["run"], "--send", env={"FAKE_CLAUDE_MODE": "die"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.wait_exit(run_dir, 2)
        argv = self.calls()[-1]["argv"]
        self.assertEqual((self.arg(argv, "--model"), self.arg(argv, "--effort")), ("sonnet", "low"))
        self.assertIn("finish phase", argv[-1])
        self.assertEqual(hooks.read_json(os.path.join(run_dir, "run.json"))["finishing_turns"], 1)

    def test_a_resumed_phase_turn_goes_on_to_the_later_phases(self):
        out, run_dir = self.launch("die")
        self.wait_exit(run_dir)
        hooks.append_marker(run_dir, {"kind": "skill", "skill": "ce-work", "ok": True})
        r = self.htr("resume", "--run", out["run"], "--send", env={"FAKE_CLAUDE_MODE": "phased"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.wait_exit(run_dir, 3)
        for _ in range(200):
            if os.path.exists(os.path.join(run_dir, "exit.json")):
                break
            time.sleep(0.05)
        calls = [c["argv"] for c in self.calls()][1:]
        sid = hooks.read_json(os.path.join(run_dir, "run.json"))["session_id"]
        self.assertEqual([(self.arg(a, "--model"), self.arg(a, "--effort"), self.arg(a, "--resume")) for a in calls],
                         [("opus", "medium", sid), ("sonnet", "low", sid)])
        self.assertEqual(hooks.read_json(os.path.join(run_dir, "run.json"))["finishing_turns"], 1)
        self.assertEqual(json.loads(self.htr("status", "--json").stdout)[0]["state"], "complete")

    def test_a_turn_that_fails_after_its_phase_is_shown_starts_no_next_phase(self):
        # The build turn shows its phase (the hook writes phase-done), then claude exits non-zero.
        r = self.htr("launch", "--repo", "o/r", "--issue", "7", "--checkout", self.checkout, "--base", "main", "--json",
                     env={"FAKE_CLAUDE_MODE": "phased", "FAKE_EXIT": "1"})
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        run_dir = os.path.join(self.t, "home", "runs", json.loads(r.stdout)["run"])
        self.wait_exit(run_dir)
        for _ in range(200):
            if os.path.exists(os.path.join(run_dir, "exit.json")):
                break
            time.sleep(0.05)
        self.assertEqual(hooks.read_json(os.path.join(run_dir, "exit.json"))["code"], 1)
        self.assertEqual([m["decision"] for m in hooks.read_markers(run_dir) if m.get("kind") == "stop"][-1], "phase-done")
        self.assertEqual(len(self.calls()), 1, "a failed session is not resumed into the next phase")

    def test_a_legacy_run_resumes_on_its_one_model_with_no_phase_turns(self):
        out, run_dir = self.launch("die")
        self.wait_exit(run_dir)
        rj = hooks.read_json(os.path.join(run_dir, "run.json"))
        del rj["phases"]   # as every run launched before phases existed
        rj.update(model="opus", effort="medium")
        hooks.write_json(os.path.join(run_dir, "run.json"), rj)
        r = self.htr("resume", "--run", out["run"])
        self.assertNotIn("phase", r.stdout)
        self.assertIn("ce-commit-push-pr", r.stdout, "a legacy finishing turn lists every missing step")
        r = self.htr("resume", "--run", out["run"], "--send", env={"FAKE_CLAUDE_MODE": "phased"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.wait_exit(run_dir, 2)
        time.sleep(0.5)   # a phase turn, were one started, would be under way by now
        calls = [c["argv"] for c in self.calls()]
        self.assertEqual(len(calls), 2)
        self.assertEqual((self.arg(calls[1], "--model"), self.arg(calls[1], "--effort")), ("opus", "medium"))
        stops = [m for m in hooks.read_markers(run_dir) if m.get("kind") == "stop"]
        self.assertTrue(stops and all(s["decision"] == "block" for s in stops), stops)
        self.assertEqual(json.loads(self.htr("status", "--json").stdout)[0]["state"], "ended-incomplete")

    def test_route_prints_the_phase_table(self):
        r = self.htr("route", "--repo", "o/r", "--issue", "7", "--effort", "xhigh")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stdout, r"build +sonnet / xhigh +ce-work")
        self.assertRegex(r.stdout, r"judge +opus / xhigh +ce-code-review")
        self.assertRegex(r.stdout, r"finish +sonnet / low +tests, lint, ce-commit-push-pr, pr")
        r = self.htr("route", "--repo", "o/r", "--issue", "7", "--judge-model", "fable")
        self.assertEqual(r.returncode, 2)
        self.assertIn("Opus at most", r.stderr)
        r = self.htr("prompt", "--repo", "o/r", "--issue", "7")
        self.assertIn("judge: ce-code-review, on opus / medium", r.stdout)

    def test_a_build_turn_that_also_reviews_still_gets_its_judge_turn(self):
        # The fake does the whole lifecycle in each turn. The build turn's review does not count,
        # so the judge turn runs on Opus; its review does, and the run completes there.
        out, run_dir = self.launch("full")
        self.wait_exit(run_dir, 2)
        for _ in range(200):
            if os.path.exists(os.path.join(run_dir, "exit.json")):
                break
            time.sleep(0.05)
        stops = [m for m in hooks.read_markers(run_dir) if m.get("kind") == "stop"]
        self.assertEqual([(s["decision"], s.get("next")) for s in stops],
                         [("phase-done", "judge"), ("phase-done", "judge"), ("phase-done", "finish"), ("allow", None)])
        calls = [c["argv"] for c in self.calls()]
        self.assertEqual([(self.arg(a, "--model"), self.arg(a, "--effort")) for a in calls], [("sonnet", "medium"), ("opus", "medium")])
        st = json.loads(self.htr("status", "--json").stdout)[0]
        self.assertEqual((st["state"], st["pr"]), ("complete", "https://github.com/o/r/pull/9"))
        r = self.htr("launch", "--repo", "o/r", "--issue", "7", "--checkout", self.checkout, "--base", "main")
        self.assertIn("already complete", r.stdout)
        r = self.htr("clean", "--run", out["run"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.isdir(out["worktree"]))

    def test_dry_run_creates_nothing_and_refusals(self):
        r = self.htr("launch", "--repo", "o/r", "--issue", "7", "--checkout", self.checkout, "--base", "main", "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(os.path.isdir(os.path.join(self.t, "home", "runs")) and os.listdir(os.path.join(self.t, "home", "runs")))
        r = self.htr("launch", "--repo", "o/r", "--issue", "7", "--checkout", self.checkout, "--model", "fable")
        self.assertEqual(r.returncode, 2)
        self.assertIn("Opus at most", r.stderr)
        r = self.htr("launch", "--repo", "o/r", "--issue", "7", "--checkout", self.checkout, "--test-regex", "pytest(")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--test-regex is not a valid regular expression", r.stderr)
        r = self.htr("launch", "--repo", "o/r", "--issue", "7", "--checkout", self.checkout, "--base", "main", "--dry-run", "--json")
        self.assertEqual(json.loads(r.stdout)["work_input"].endswith("ticket.md"), True)
        r = self.htr("aws-keys", env={})
        self.assertNotEqual(r.returncode, 0)

    def test_aws_keys_from_create_access_key_json(self):
        key = {"AccessKey": {"AccessKeyId": "AKIAABCDEFGHIJKLMNOP", "SecretAccessKey": "sekrit"}}
        r = subprocess.run([PY, HTR, "aws-keys"], input=json.dumps(key), capture_output=True, text=True, env=self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        cred = os.path.join(self.t, "home", "aws", "credentials")
        self.assertIn("aws_access_key_id = AKIAABCDEFGHIJKLMNOP", slurp(cred))
        self.assertEqual(oct(os.stat(cred).st_mode & 0o777), "0o600")
        self.assertNotIn("sekrit", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
