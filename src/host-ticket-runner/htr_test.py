#!/usr/bin/env python3
"""Tests for htr.py and htr_hooks.py. `claude` and `gh` are fakes on PATH that record what
they were given; git is real; no agent, network call or AWS call happens.

  python3 htr_test.py          (or: python3 -m unittest htr_test -v)
"""
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
        self.tier = self.model = self.effort = None
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

    def test_opus_cap(self):
        for bad in ("fable", "best", "claude-fable-1", "gpt-5"):
            with self.assertRaises(SystemExit) as cm:
                htr.resolve(self.ticket(), Args(model=bad))
            self.assertEqual(cm.exception.code, 2, bad)
        for ok in ("opus", "claude-opus-5-5", "sonnet", "opus[1m]"):
            self.assertEqual(htr.resolve(self.ticket(), Args(model=ok))["model"], ok)

    def test_skill_md_table_matches_code(self):
        text = slurp(os.path.join(HERE, "SKILL.md"))
        rows = re.findall(r"^\| \*\*(\w+)\*\* \|[^|]*\| `(\w+)` \| `(\w+)` \|", text, re.M)
        self.assertEqual({t: {"model": m, "effort": e} for t, m, e in rows}, htr.TIERS)


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

    def test_bash(self):
        for cmd in ("cat ~/.aws/credentials", "ls $HOME/.aws", "cat ${HOME}/.aws/config",
                    "cat %s/.aws/credentials" % self.home, "cd ~ && cat .aws/credentials", "tar c ~/.aws"):
            self.assertTrue(self.deny("Bash", {"command": cmd}), cmd)
        for cmd in ("aws sts get-caller-identity", "cat $AWS_SHARED_CREDENTIALS_FILE", "ls ~/.awsome"):
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
                  self.skill("ce-simplify-code"), self.skill("ce-code-review"),
                  {"kind": "bash", "command": "uv run pytest -q", "exit": 0},
                  {"kind": "bash", "command": "uv run ruff check src", "exit": 0},
                  self.skill("ce-compound"), self.skill("ce-commit-push-pr"))

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
        hooks.write_json(os.path.join(self.run_dir, "run.json"), self.run)
        self.full()
        self.assertEqual(hooks.evaluate(self.run_dir)["missing"][0]["step"], "ce-plan")
        self.mark(self.skill("ce-plan"))
        self.assertIn("before ce-plan", hooks.evaluate(self.run_dir)["missing"][0]["why"])

    def test_skipped_steps_are_not_required(self):
        self.run["required"] = htr.required_steps("work", ["lint"])
        hooks.write_json(os.path.join(self.run_dir, "run.json"), self.run)
        self.mark(self.skill("ce-work"), self.skill("ce-simplify-code"), self.skill("ce-code-review"),
                  {"kind": "bash", "command": "pytest", "exit": 0}, self.skill("ce-compound"), self.skill("ce-commit-push-pr"))
        self.assertEqual(hooks.evaluate(self.run_dir)["missing"], [])

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

    def test_launch_scrubs_env_installs_hooks_and_detaches(self):
        out, run_dir = self.launch("die")
        self.wait_exit(run_dir)
        self.assertEqual((out["tier"], out["model"], out["effort"], out["route"]), ("light", "sonnet", "medium", "work"))
        self.assertEqual(git(out["worktree"], "branch", "--show-current"), out["branch"])
        call = self.calls()[0]
        argv, env = call["argv"], call["env"]
        self.assertEqual(os.path.realpath(call["cwd"]), os.path.realpath(out["worktree"]))
        for flag in ("-p", "--dangerously-skip-permissions", "--settings", "--session-id"):
            self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index("--model") + 1], "sonnet")
        self.assertEqual(argv[argv.index("--effort") + 1], "medium")
        self.assertNotIn("AWS_ACCESS_KEY_ID", env)
        self.assertNotIn("AWS_SECRET_ACCESS_KEY", env)
        self.assertNotIn("AWS_SEC", env)
        self.assertNotIn("CLAUDECODE", env)
        self.assertNotIn("CLAUDE_CODE_SESSION_ID", env)
        self.assertEqual(env["AWS_PROFILE"], "htr-agent")
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

    def test_full_fake_run_is_blocked_once_then_completes(self):
        out, run_dir = self.launch("full")
        self.wait_exit(run_dir)
        stops = [m for m in hooks.read_markers(run_dir) if m.get("kind") == "stop"]
        self.assertEqual([s["decision"] for s in stops], ["block", "allow"])
        self.assertTrue(any(k.startswith("tests:") for k in stops[0]["missing"]))
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
