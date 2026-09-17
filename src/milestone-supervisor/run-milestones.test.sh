#!/usr/bin/env bash
# Tests for run-milestones.sh with fakes on PATH: agent-sandbox, systemd-run and
# systemctl are shell stubs that record their argv; git is real. No sandbox, container
# or systemd unit is started. Exits non-zero at the first failing assertion.
#
#   bash run-milestones.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/run-milestones.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/run-milestones-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export FAKE_DIR="$T/fake"; mkdir -p "$FAKE_DIR/bin"
export PATH="$FAKE_DIR/bin:$PATH"
UID_NOW="$(id -u)"

# ---------------------------------------------------------------- fakes
cat > "$FAKE_DIR/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/systemd-run.argv"
{ echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}"; echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-}"; } > "$FAKE_DIR/systemd-run.env"
echo x >> "$FAKE_DIR/systemd-run.count"
EOF
cat > "$FAKE_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_DIR/units" 2>/dev/null || true
EOF
# The driver's agent-sandbox layout fallbacks (worktrees/<id>, runs/<id>) resolve into the
# fakes, never into the real ~/agent-sandbox.
export AGENT_SANDBOX_HOME="$FAKE_DIR"
export FAKE_WS_ROOT="$FAKE_DIR/worktrees"
cat > "$FAKE_DIR/bin/agent-sandbox" <<'EOF'
#!/usr/bin/env bash
# One line per call; a multi-line bash -lc script has its newlines shown as \n.
all="$*"; printf '%s\n' "${all//$'\n'/\\n}" >> "$FAKE_DIR/agent-sandbox.calls"
case "$1" in
  status) cat "$FAKE_DIR/status.json" ;;
  run)    echo "[agent-sandbox] effective budget 16 GiB (config), floor 8 GiB (config)" >&2
          id="${FAKE_RUN_ID:-proj-deadbeef}"; ws="${FAKE_WS_ROOT:-/nonexistent}/$id"; runs="$FAKE_DIR/runs/$id"
          # FAKE_RUN_CLONE=1: the new sandbox's worktree is a clone of the repo argument,
          # detached at FAKE_RUN_AT (default HEAD), like `run <repo> --new` from its HEAD.
          if [[ -n "${FAKE_RUN_CLONE:-}" ]]; then
            at="$(git -C "$2" rev-parse "${FAKE_RUN_AT:-HEAD}")"
            git clone -q "$2" "$ws" > /dev/null 2>&1 && git -C "$ws" checkout -q --detach "$at" > /dev/null 2>&1
            mkdir -p "$runs"
          fi
          echo '{"sandbox_id": "'"$id"'", "worktree": "'"$ws"'", "status": "completed", "exit_code": 0,'
          echo ' "logs": {"dir": "'"$runs"'", "stdout": "'"$runs"'/stdout.log", "stderr": "'"$runs"'/stderr.log"}}' ;;
  rm)     [[ -n "${2:-}" ]] || { echo "agent-sandbox: refusing an empty id" >&2; exit 2; }
          rm -rf "${FAKE_WS_ROOT:?}/$2"; echo "removed $2" ;;
  enter)  rc="${FAKE_ENTER_RC:-0}"
          # FAKE_ENTER_NOADMIT=1: exit 3 is the command's own exit, with an ordinary result JSON.
          if [[ "$rc" == 3 && -z "${FAKE_ENTER_NOADMIT:-}" ]]; then
            echo "[agent-sandbox] effective budget 16 GiB (config), request 12g (flag)" >&2
            cat <<'JSON'
{
  "admission": "refused",
  "message": "refused: 12 GiB requested, 3 GiB of headroom",
  "reasons": [
    "committed 13 GiB of a 16 GiB budget",
    "MemAvailable 7.2 GiB is under the 8 GiB floor"
  ],
  "numbers": {"budget": 17179869184, "committed": 13958643712},
  "remedy": "stop a container or wait; agent-sandbox status shows what is running"
}
JSON
            exit 3
          fi
          id="$2"; ws="${FAKE_WS_ROOT:-/nonexistent}/$id"; runs="$FAKE_DIR/runs/$id"; mkdir -p "$runs"
          # FAKE_ENTER_EXEC=1: a bash -lc command really runs, in the fake worktree, with
          # its stdout going only to the run's stdout.log (what --json does for real).
          if [[ -n "${FAKE_ENTER_EXEC:-}" ]]; then
            while (($#)) && [[ "$1" != -- ]]; do shift; done; shift
            if [[ "$1" == bash ]]; then
              rc=0; (cd "$ws" && bash -c "$3") >> "$runs/stdout.log" 2>> "$runs/stderr.log" || rc=$?
            fi
          fi
          echo '{"sandbox_id": "'"$id"'", "worktree": "'"$ws"'", "status": "completed", "exit_code": '"$rc"','
          echo ' "admission": {"verdict": "admitted", "reasons": []},'
          echo ' "logs": {"dir": "'"$runs"'", "stdout": "'"$runs"'/stdout.log", "stderr": "'"$runs"'/stderr.log"}}'
          exit "$rc" ;;
esac
EOF
cat > "$FAKE_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/docker.calls"
EOF
chmod +x "$FAKE_DIR"/bin/*

# ---------------------------------------------------------------- the project
PROJ="$T/proj"; mkdir -p "$PROJ/.milestones" "$PROJ/docs/spec"
cat > "$PROJ/.milestones/config" <<'EOF'
MILESTONES_FILE=docs/spec/11-milestones.md
REPORT_DIR=docs/reports
GATE="true"
DEPLOY_MILESTONES="7"
TIMEOUT=2h
MEMORY=8g
CPUS=4
MEMORY_6=12g
EOF
printf '## Milestone 5\n\nfive.\n\n## Milestone 6\n\nsix.\n\n## Milestone 7\n\nseven.\n' > "$PROJ/docs/spec/11-milestones.md"
CHAIN="$PROJ/logs/milestones/chain.log"
# Sandbox worktrees the gate reads on the host: the gated commit and the report.
mk_gws() {  # id [report]
  local ws="$FAKE_WS_ROOT/$1"
  mkdir -p "$ws/docs/reports"; git -C "$ws" init -q -b main
  [[ "${2:-}" == report ]] && echo "# Milestone 6 report" > "$ws/docs/reports/milestone-6.md"
  git -C "$ws" add -A && git -C "$ws" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "milestone 6 report"
}
mk_gws proj-deadbeef report
mk_gws proj-1a2b3c4d report

# ---------------------------------------------------------------- assertions
N=0
scenario() { N=$((N + 1)); echo; echo "--- scenario $N: $*"; }
pass() { echo "PASS: $*"; }
FAILS=0
# KEEP_GOING=1 records a failure and carries on, to see every red scenario in one run.
fail() { echo "FAIL: $*" >&2; [[ -n "${KEEP_GOING:-}" ]] || exit 1; FAILS=$((FAILS + 1)); }
assert_grep() { grep -Eq -- "$1" "$2" && pass "$3" || { echo "--- $2:" >&2; cat "$2" >&2 || true; fail "$3 (no match for '$1')"; }; }
assert_not_grep() { grep -Eq -- "$1" "$2" && { echo "--- $2:" >&2; cat "$2" >&2 || true; fail "$3 (unexpected match for '$1')"; } || pass "$3"; }
assert_eq() { [[ "$1" == "$2" ]] && pass "$3" || fail "$3 (got '$1', want '$2')"; }
reset() { rm -rf "$FAKE_DIR"/systemd-run.* "$FAKE_DIR/agent-sandbox.calls" "$FAKE_DIR/docker.calls" "$FAKE_DIR/units" "$FAKE_DIR/runs" "$CHAIN" "$PROJ/logs/milestones"/*.log "$PROJ/.milestones/STATUS.md" "$PROJ/.milestones/config.local"; }
argv_line() { tr '\n' ' ' < "$FAKE_DIR/systemd-run.argv" > "$FAKE_DIR/argv.line"; echo "$FAKE_DIR/argv.line"; }
run_driver() { (cd "$PROJ" && "$DRIVER" "$@"); }

# ================================================================ 1. launch milestone 6
scenario "milestone 6 with MEMORY_6=12g launches one systemd-run unit"
reset
run_driver 6 > "$T/out1" 2>&1 || fail "launch exited $? : $(cat "$T/out1")"
A="$(argv_line)"
assert_grep '^--user --collect --unit=milestone-proj-6-[0-9]{8}T[0-9]{6} ' "$A" "unit name carries project, milestone and stamp"
assert_grep '--property=RuntimeMaxSec=9300 ' "$A" "RuntimeMaxSec = 7200 + 1800 + 300"
assert_grep "--property=StandardOutput=append:$PROJ/logs/milestones/unit-milestone-proj-6-" "$A" "stdout appended under logs/milestones/"
assert_grep "--property=StandardError=append:$PROJ/logs/milestones/unit-milestone-proj-6-" "$A" "stderr appended to the same file"
assert_grep '--memory 12g --cpus 4 ' "$A" "per-milestone MEMORY_6 wins over MEMORY; CPUS falls back"
assert_grep '--tag unit=milestone-proj-6-[0-9T]+ --tag milestone=6' "$A" "unit and milestone tags"
assert_grep "-- $DRIVER --inside 6 --unit milestone-proj-6-" "$A" "the unit runs this script under --inside"
assert_grep '--setenv=PATH=.* --setenv=HOME=' "$A" "PATH and HOME exported into the unit"
assert_grep '^unit: milestone-proj-6-' "$T/out1" "driver prints the unit name"
assert_grep "^unit log: $PROJ/logs/milestones/unit-milestone-proj-6-" "$T/out1" "driver prints the log path"
assert_eq "$(wc -l < "$FAKE_DIR/systemd-run.count")" 1 "exactly one unit created"
[[ -f "$FAKE_DIR/agent-sandbox.calls" ]] && fail "the outer driver must not call agent-sandbox" || pass "outer driver made no agent-sandbox call"

# ================================================================ 2. several milestones refused
scenario "run-milestones.sh 5 6 is refused"
reset
set +e; run_driver 5 6 > "$T/out2" 2>&1; rc=$?; set -e
assert_eq "$rc" 2 "exit 2"
assert_grep 'reviews between milestones' "$T/out2" "message names the review between milestones"
[[ -f "$FAKE_DIR/systemd-run.count" ]] && fail "a unit was created" || pass "no unit created"

# ================================================================ 3. resource fallback
scenario "no per-milestone key: MEMORY/CPUS, then nothing"
reset
run_driver 5 > /dev/null 2>&1
A="$(argv_line)"
assert_grep '--memory 8g --cpus 4 ' "$A" "milestone 5 falls back to MEMORY and CPUS"
assert_grep '--property=RuntimeMaxSec=9300 ' "$A" "milestone 5 gets the same ceiling"
cp "$PROJ/.milestones/config" "$T/config.bak"
grep -v -E '^(MEMORY|CPUS)' "$T/config.bak" > "$PROJ/.milestones/config"
reset
run_driver 5 > /dev/null 2>&1
A="$(argv_line)"
assert_not_grep '--memory|--cpus' "$A" "no MEMORY/CPUS keys: no --memory/--cpus passed"
cp "$T/config.bak" "$PROJ/.milestones/config"

# ================================================================ 4. bus variables
scenario "XDG_RUNTIME_DIR unset in the caller"
reset
(cd "$PROJ" && env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS "$DRIVER" 6 > /dev/null 2>&1)
assert_grep "^XDG_RUNTIME_DIR=/run/user/$UID_NOW\$" "$FAKE_DIR/systemd-run.env" "XDG_RUNTIME_DIR set from the uid"
assert_grep "^DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_NOW/bus\$" "$FAKE_DIR/systemd-run.env" "bus address set from the uid"

# ================================================================ 5. --continue through a unit
scenario "--continue launches through a unit with timeout + 300"
reset
run_driver 6 --sandbox proj-1a2b3c4d --continue "the owner did X; re-take the readings" > "$T/out5" 2>&1
A="$(argv_line)"
assert_grep '--property=RuntimeMaxSec=7500 ' "$A" "RuntimeMaxSec = 7200 + 300"
assert_grep '--unit=milestone-proj-6-' "$A" "continue unit named for the milestone"
assert_grep '--inside 6 --unit .* --sandbox proj-1a2b3c4d --continue the owner did X; re-take the readings' "$A" "body carries --sandbox and --continue"
assert_grep '--tag unit=milestone-proj-6-.* --tag milestone=6' "$A" "continue turn is tagged too"
reset
set +e; run_driver --sandbox x --continue "y" 5 6 > "$T/out5b" 2>&1; rc=$?; set -e
assert_eq "$rc" 2 "--continue with two milestones refused"

# ================================================================ 6. inside: refused admission
scenario "inside the unit, an admission refusal lands in chain.log and exits non-zero"
reset
set +e
(cd "$PROJ" && FAKE_ENTER_RC=3 "$DRIVER" --inside 6 --sandbox proj-1a2b3c4d --unit milestone-proj-6-T --memory 12g --cpus 4 --tag unit=milestone-proj-6-T --tag milestone=6) > "$T/out6" 2>&1; rc=$?
set -e
assert_eq "$rc" 3 "unit body exits 3"
assert_grep 'admission refused .*refused: 12 GiB requested, 3 GiB of headroom; committed 13 GiB of a 16 GiB budget; MemAvailable 7.2 GiB is under the 8 GiB floor' "$CHAIN" "reasons in chain.log"
assert_grep 'stop a container or wait' "$CHAIN" "remedy in chain.log"
assert_grep 'milestone 6: not admitted; unit stops' "$CHAIN" "the stop is recorded"
assert_eq "$(grep -c '^enter ' "$FAKE_DIR/agent-sandbox.calls")" 1 "the gate does not run after a refusal"
rm -f "$CHAIN"
set +e
(cd "$PROJ" && RUN_MILESTONES_NO_JQ=1 FAKE_ENTER_RC=3 "$DRIVER" --inside 6 --sandbox proj-1a2b3c4d --unit u) > /dev/null 2>&1; rc=$?
set -e
assert_eq "$rc" 3 "same without jq (python path)"
assert_grep 'MemAvailable 7.2 GiB is under the 8 GiB floor' "$CHAIN" "reasons parsed by python too"

# ================================================================ 7. status matrix
scenario "status labels crashed sandboxes from unit, report and 401 segment"
RUNS="$T/runs"; WS="$T/ws"; mkdir -p "$RUNS" "$WS"
mk_ws() {  # id with-report
  local id="$1" ws="$WS/$1"
  mkdir -p "$ws/docs/reports"
  git -C "$ws" init -q -b main
  git -C "$ws" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  if [[ "$2" == report ]]; then
    echo "# Milestone 6 report" > "$ws/docs/reports/milestone-6.md"
    git -C "$ws" add -A && git -C "$ws" -c user.name=t -c user.email=t@t commit -q -m "milestone 6 report"
  fi
  mkdir -p "$RUNS/$id"
}
mk_ws proj-aaaa0001 none     # vanished
mk_ws proj-aaaa0002 report   # finished-unrecorded
mk_ws proj-aaaa0003 none     # auth-expired: 401 inside the segment
mk_ws proj-aaaa0004 none     # vanished: 401 only before the segment
mk_ws proj-aaaa0005 none     # orphaned
mkdir -p "$RUNS/other-bbbb0001" "$RUNS/proj-aaaa0006"; : > "$RUNS/proj-aaaa0006/stdout.log"   # finished, untagged, empty log
printf 'turn one fine\nturn two: reading the spec\nlast line of one\n' > "$RUNS/proj-aaaa0001/stdout.log"
printf 'turn one fine\nreport written and committed\n' > "$RUNS/proj-aaaa0002/stdout.log"
printf 'turn one fine\n' > "$RUNS/proj-aaaa0003/stdout.log"; S3=$(stat -c %s "$RUNS/proj-aaaa0003/stdout.log")
printf 'turn two\nAPI Error: 401 {"type":"error","error":{"type":"authentication_error"}}\n' >> "$RUNS/proj-aaaa0003/stdout.log"
printf 'old turn\nAPI Error: 401 authentication_error\n' > "$RUNS/proj-aaaa0004/stdout.log"; S4=$(stat -c %s "$RUNS/proj-aaaa0004/stdout.log")
printf 'new turn, clean\nstill working\n' >> "$RUNS/proj-aaaa0004/stdout.log"
printf 'working\n' > "$RUNS/proj-aaaa0005/stdout.log"
row() {  # id state status evidence container start end unit
  local start="$6" end="$7"
  cat <<EOF
{"sandbox_id": "$1", "state": "$2", "status": "$3",
 "newest": {"status": "$3", "state": "$2", "evidence": "$4", "container": "$5", "pid": 4242,
            "stdout_offset_start": $start, "stdout_offset_end": $end},
 "tags": {"unit": "$8", "milestone": "6"}, "corrections": 0,
 "workspace": "$WS/$1", "branch": "agent-sandbox/$1",
 "logs": {"dir": "$RUNS/$1", "stdout": "$RUNS/$1/stdout.log", "stderr": "$RUNS/$1/stderr.log"}}
EOF
}
{
  echo "["
  row proj-aaaa0001 crashed running "entry says running, container as-1 not found by docker inspect" as-1 0 null milestone-proj-6-A; echo ","
  row proj-aaaa0002 crashed running "entry says running, container as-2 not found by docker inspect" as-2 0 null milestone-proj-6-B; echo ","
  row proj-aaaa0003 crashed running "entry says running, container as-3 not found by docker inspect" as-3 "$S3" null milestone-proj-6-C; echo ","
  row proj-aaaa0004 crashed running "entry says running, container as-4 not found by docker inspect" as-4 "$S4" null milestone-proj-6-D; echo ","
  row proj-aaaa0005 orphaned running "container as-5 up, launcher pid 4242 gone" as-5 0 null milestone-proj-6-E; echo ","
  cat <<EOF
{"sandbox_id": "proj-aaaa0006", "state": "finished", "status": "completed",
 "newest": {"status": "completed", "state": "finished", "evidence": "completed, exit 0", "container": "as-6", "pid": null,
            "stdout_offset_start": null, "stdout_offset_end": null},
 "tags": {}, "corrections": 0,
 "workspace": "$WS/proj-aaaa0006", "branch": "agent-sandbox/proj-aaaa0006",
 "logs": {"stdout": "$RUNS/proj-aaaa0006/stdout.log"}},
EOF
  cat <<EOF
{"sandbox_id": "other-bbbb0001", "state": "crashed", "status": "running",
 "newest": {"status": "running", "state": "crashed", "evidence": "gone", "container": "o-1", "pid": 1,
            "stdout_offset_start": null, "stdout_offset_end": null},
 "tags": {"unit": "milestone-other-2-Z", "milestone": "2"}, "corrections": 0,
 "workspace": "$WS/other-bbbb0001", "branch": "agent-sandbox/other-bbbb0001",
 "logs": {"stdout": "$RUNS/other-bbbb0001/stdout.log"}}
]
EOF
} > "$FAKE_DIR/status.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$FAKE_DIR/status.json" || fail "fixture JSON invalid"

for mode in jq python; do
  reset
  [[ $mode == python ]] && export RUN_MILESTONES_NO_JQ=1 || unset RUN_MILESTONES_NO_JQ
  echo "  ($mode)"
  run_driver status > "$T/status.$mode" 2>&1 || fail "status exited $?: $(cat "$T/status.$mode")"
  assert_grep '^proj-aaaa0001 +6 +crashed +gone +none +no +vanished ' "$T/status.$mode" "crashed, no unit, no report: vanished"
  assert_grep '^proj-aaaa0002 +6 +crashed +gone +committed +no +finished-unrecorded ' "$T/status.$mode" "report committed: finished-unrecorded"
  assert_grep '^proj-aaaa0003 +6 +crashed +gone +none +yes +auth-expired ' "$T/status.$mode" "401 inside the segment: auth-expired"
  assert_grep '^proj-aaaa0004 +6 +crashed +gone +none +no +vanished ' "$T/status.$mode" "401 only before the segment: vanished"
  assert_grep '^proj-aaaa0005 +6 +orphaned +gone +none +no +orphaned ' "$T/status.$mode" "orphaned stays orphaned"
  assert_grep 'vanished +last line of one$' "$T/status.$mode" "last output line shown from the segment"
  assert_grep '^proj-aaaa0006 +- +finished +gone +- +no +finished *$' "$T/status.$mode" "an untagged finished sandbox with an empty log: finished, no crash"

  run_driver resume > "$T/resume.$mode" 2>&1 || fail "resume exited $?"
  assert_grep "finish: \(cd $PROJ && $DRIVER 6 --sandbox proj-aaaa0001 --continue " "$T/resume.$mode" "vanished: the --continue form"
  assert_grep "finish: \(cd $PROJ && $DRIVER 6 --sandbox proj-aaaa0002 --gate\)" "$T/resume.$mode" "finished-unrecorded: a gate run"
  assert_grep 'owner: the token this agent held was revoked.*Log in again on the host before issuing:' "$T/resume.$mode" "auth-expired: the re-login note"
  assert_grep "$DRIVER 6 --sandbox proj-aaaa0003 --continue " "$T/resume.$mode" "auth-expired: then the --continue form"
  assert_grep "finish: .*docker.+stop.+as-5.+agent-sandbox.+status.+--reconcile.+proj-aaaa0005\)" "$T/resume.$mode" "orphaned: docker stop plus reconcile"
  assert_grep 'add --issue to run them' "$T/resume.$mode" "resume prints only without --issue"
  assert_eq "$(grep -c '^=== resume' "$CHAIN")" 5 "every resume block also in chain.log"
  [[ -f "$FAKE_DIR/systemd-run.count" ]] && fail "resume without --issue launched something" || pass "nothing issued without --issue"
done
unset RUN_MILESTONES_NO_JQ

# ================================================================ 8. project filter
scenario "status prints only this project's sandboxes"
assert_not_grep 'other-bbbb0001' "$T/status.jq" "another project's sandbox is absent (jq)"
assert_not_grep 'other-bbbb0001' "$T/status.python" "another project's sandbox is absent (python)"
assert_eq "$(grep -c '^proj-aaaa' "$T/status.jq")" 6 "all six of this project's sandboxes listed"

# ================================================================ 9. inside: happy path, unit alive, --issue
scenario "inside the unit: tagged turn then tagged gate; a live unit shows running; resume --issue launches"
reset
(cd "$PROJ" && "$DRIVER" --inside 6 --unit milestone-proj-6-T --memory 12g --cpus 4 --tag unit=milestone-proj-6-T --tag milestone=6) > "$T/out9" 2>&1 || fail "inside exited $?: $(cat "$T/out9")"
assert_grep '^run .* --new --memory 12g --cpus 4 --tag unit=milestone-proj-6-T --tag milestone=6 --json -- true$' "$FAKE_DIR/agent-sandbox.calls" "no --sandbox: the sandbox is created inside the unit, tagged"
assert_grep '^sandbox: proj-deadbeef$' "$CHAIN" "the new id read from the result JSON"
assert_grep '^enter proj-deadbeef --timeout 2h --memory 12g --cpus 4 --tag unit=milestone-proj-6-T --tag milestone=6 --json -- claude ' "$FAKE_DIR/agent-sandbox.calls" "milestone turn tagged with resources"
assert_grep '^enter proj-deadbeef --timeout 1[78][0-9]{2}s --memory 12g --cpus 4 --tag unit=milestone-proj-6-T --tag milestone=6 --json -- bash -lc .*true' "$FAKE_DIR/agent-sandbox.calls" "gate tagged as a second call, bounded by GATE_TIMEOUT's 1800 seconds"
assert_eq "$(grep -c '^enter ' "$FAKE_DIR/agent-sandbox.calls")" 2 "exactly two enter calls"
assert_grep 'milestone 6: gate passed' "$CHAIN" "gate result in chain.log"
assert_grep 'Milestone 6 of docs/spec/11-milestones.md' "$PROJ/logs/milestones/milestone-6.prompt" "prompt assembled"
assert_grep '^six\.$' "$PROJ/logs/milestones/milestone-6.prompt" "prompt holds the milestone section"

reset
(cd "$PROJ" && FAKE_ENTER_RC=1 "$DRIVER" --inside 6 --sandbox proj-1a2b3c4d --unit u) > /dev/null 2>&1 && fail "failed gate must exit non-zero" || pass "failed gate exits non-zero"
assert_grep 'milestone 6: claude exited 1' "$CHAIN" "claude's exit recorded"
assert_grep 'milestone 6: gate FAILED' "$CHAIN" "gate failure recorded"

reset
echo "milestone-proj-6-A.service loaded active running /path/run-milestones.sh --inside 6" > "$FAKE_DIR/units"
python3 - "$FAKE_DIR/status.json" <<'EOF'
import json, sys
p = sys.argv[1]; rows = json.load(open(p))
for r in rows:
    if r["sandbox_id"] == "proj-aaaa0001":
        r["state"] = "running"; r["newest"]["state"] = "running"
json.dump(rows, open(p, "w"))
EOF
run_driver status > "$T/status9" 2>&1
assert_grep '^proj-aaaa0001 +6 +running +up +none +no +running ' "$T/status9" "a live unit and a running entry show running"
run_driver resume --issue > "$T/resume9" 2>&1 || fail "resume --issue exited $?: $(cat "$T/resume9")"
assert_eq "$(wc -l < "$FAKE_DIR/systemd-run.count")" 3 "--issue launched the gate and two --continue units (orphaned uses docker, not a unit)"
assert_grep '^stop as-5$' "$FAKE_DIR/docker.calls" "--issue stopped the orphaned container (fake docker)"
assert_grep '^status --reconcile proj-aaaa0005$' "$FAKE_DIR/agent-sandbox.calls" "--issue reconciled the orphaned record"
assert_grep 'issuing ' "$CHAIN" "issue recorded in chain.log"
assert_not_grep 'resume proj-aaaa0001' "$T/resume9" "the running sandbox is not resumed"

# ================================================================ U2 fixtures
cp "$PROJ/.milestones/config" "$T/config.base"
config_with() {  # the base config plus KEY=value lines; GATE removed with -GATE
  local l; cp "$T/config.base" "$PROJ/.milestones/config"
  for l in "$@"; do
    if [[ "$l" == -* ]]; then grep -v "^${l#-}=" "$PROJ/.milestones/config" > "$T/cfg.tmp"; cp "$T/cfg.tmp" "$PROJ/.milestones/config"
    else printf '%s\n' "$l" >> "$PROJ/.milestones/config"; fi
  done
}
GWS="$FAKE_WS_ROOT/proj-1a2b3c4d"
GSHA="$(git -C "$GWS" rev-parse HEAD | cut -c1-12)"
EVLINE='tree=[0-9a-f]{12} def=[0-9a-f]{12}'   # the identity fields between sha= and dirty=
gate_inside() {  # run the gate-only unit body against proj-1a2b3c4d; its exit code in GRC
  set +e
  (cd "$PROJ" && FAKE_ENTER_EXEC=1 "$DRIVER" --inside 6 --sandbox proj-1a2b3c4d --unit u --gate "$@") > "$T/gate.out" 2>&1; GRC=$?
  set -e
}
GATELOG="$PROJ/logs/milestones/milestone-6.gate.log"

# ================================================================ 10. setup, then gate, then report check
scenario "GATE_SETUP runs as step setup before GATE, each its own enter, then the host checks the report"
reset; config_with 'GATE_SETUP="echo setup"' 'GATE="echo gate"'
gate_inside
assert_eq "$GRC" 0 "gate passes"
assert_eq "$(grep -c '^enter ' "$FAKE_DIR/agent-sandbox.calls")" 2 "one enter call per step"
assert_grep '^enter proj-1a2b3c4d .* -- bash -lc .*echo setup' <(grep '^enter ' "$FAKE_DIR/agent-sandbox.calls" | sed -n 1p) "the first enter runs setup"
assert_grep '^enter proj-1a2b3c4d .* -- bash -lc .*echo gate' <(grep '^enter ' "$FAKE_DIR/agent-sandbox.calls" | sed -n 2p) "the second enter runs the gate"
assert_not_grep 'test -s docs/reports' "$FAKE_DIR/agent-sandbox.calls" "the report check runs on the host, not in the container"
assert_eq "$(grep -Ex 'setup|gate' "$FAKE_DIR/runs/proj-1a2b3c4d/stdout.log" | tr '\n' ' ')" "setup gate " "setup ran before gate, in the same worktree"
assert_grep "^gate pass exit=0 milestone=6 sha=$GSHA $EVLINE dirty=no where=sandbox setup=yes steps=integration:0/0 replay:0/0 static:2/2 skipped:sandbox-only:0 env=\"-\" evidence=logs/milestones/evidence/6-sandbox-[0-9T.]+ at=[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$CHAIN" "evidence line in chain.log"
assert_grep "^gate pass exit=0 milestone=6 sha=$GSHA $EVLINE dirty=no where=sandbox setup=yes " "$GATELOG" "evidence line appended to the gate log"

# ================================================================ 11. no setup
scenario "no GATE_SETUP: gate then report check, evidence says setup=none"
reset; config_with 'GATE="echo gate"'
gate_inside
assert_eq "$GRC" 0 "gate passes"
assert_grep '^enter proj-1a2b3c4d .* -- bash -lc .*echo gate' "$FAKE_DIR/agent-sandbox.calls" "the gate step"
assert_not_grep 'echo setup' "$FAKE_DIR/agent-sandbox.calls" "no setup in the command"
assert_grep "^gate pass exit=0 milestone=6 sha=[0-9a-f]{12} $EVLINE dirty=no where=sandbox setup=none " "$CHAIN" "setup=none, 12-character sha, where=sandbox"

# ================================================================ 12. GATE_ENV probe
scenario "GATE_ENV output lands in the evidence line"
reset; config_with 'GATE="echo gate"' 'GATE_ENV="echo catalog abc123; echo second line"'
gate_inside
assert_eq "$GRC" 0 "gate passes"
assert_grep "^gate pass exit=0 milestone=6 sha=$GSHA $EVLINE dirty=no where=sandbox setup=none steps=[^ ]+ [^ ]+ [^ ]+ [^ ]+ env=\"catalog abc123\" evidence=[^ ]+ at=" "$CHAIN" "env carries the probe's first line"

# ================================================================ 13. failing gate and failing setup
scenario "a failing enter writes gate FAIL exit=1 and the unit fails"
reset; config_with 'GATE="echo gate"'
set +e; (cd "$PROJ" && FAKE_ENTER_RC=1 "$DRIVER" --inside 6 --sandbox proj-1a2b3c4d --unit u --gate) > /dev/null 2>&1; rc=$?; set -e
[[ "$rc" != 0 ]] && pass "unit exits non-zero ($rc)" || fail "failed gate exited 0"
assert_grep "^gate FAIL exit=1 milestone=6 sha=[0-9a-f]{12} $EVLINE dirty=no where=sandbox setup=none " "$CHAIN" "FAIL evidence line"
reset; config_with 'GATE_SETUP="exit 4"' 'GATE="echo gate"'
gate_inside
assert_eq "$GRC" 1 "a setup failure fails the unit"
assert_grep '^gate FAIL exit=4 milestone=6 .* setup=yes ' "$CHAIN" "setup failure is a gate FAIL with setup's exit"
assert_grep 'milestone 6: gate FAILED .*setup' "$CHAIN" "the chain line names setup"
assert_not_grep '^gate$' "$FAKE_DIR/runs/proj-1a2b3c4d/stdout.log" "the gate did not run after setup failed"

# ================================================================ 14. no GATE configured
scenario "gating with no GATE in config dies naming GATE"
reset; config_with -GATE
set +e; run_driver 6 --sandbox proj-1a2b3c4d --gate > "$T/out14" 2>&1; rc=$?; set -e
assert_eq "$rc" 2 "--gate exits 2"
assert_grep '\bGATE\b' "$T/out14" "the message names GATE"
[[ -f "$FAKE_DIR/systemd-run.count" ]] && fail "a unit was created" || pass "no unit created"
set +e; run_driver 6 > "$T/out14b" 2>&1; rc=$?; set -e
assert_eq "$rc" 2 "a milestone launch (which gates) exits 2 too"
assert_grep '\bGATE\b' "$T/out14b" "and names GATE"
gate_inside
assert_eq "$GRC" 2 "the unit body refuses too"
[[ -f "$FAKE_DIR/agent-sandbox.calls" ]] && fail "the body called agent-sandbox without a GATE" || pass "no agent-sandbox call"

# ================================================================ 15. config verb
scenario "config N prints resolved keys"
reset; config_with 'EVALUATE_16=1' 'EVALUATE_TARGET_16="pnpm dev"' 'MEMORY_16=10g' 'LANE_16=library' 'GATE_SETUP="just replay"' 'MODEL=opus' 'EFFORT_16=max'
run_driver config 16 > "$T/cfg16" 2>&1 || fail "config 16 exited $?: $(cat "$T/cfg16")"
run_driver config 15 > "$T/cfg15" 2>&1 || fail "config 15 exited $?: $(cat "$T/cfg15")"
assert_grep '^EVALUATE=1$' "$T/cfg16" "EVALUATE_16=1 prints EVALUATE=1"
assert_grep '^EVALUATE=0$' "$T/cfg15" "no EVALUATE_15 prints EVALUATE=0"
assert_grep '^MEMORY=10g$' "$T/cfg16" "MEMORY_16 wins"
assert_grep '^MEMORY=8g$' "$T/cfg15" "15 falls back to MEMORY"
assert_grep '^CPUS=4$' "$T/cfg16" "CPUS falls back"
assert_grep '^MODEL=opus$' "$T/cfg15" "MODEL"
assert_grep '^EFFORT=max$' "$T/cfg16" "EFFORT_16"
assert_grep '^EFFORT=$' "$T/cfg15" "unset EFFORT prints empty"
assert_grep '^LANE=library$' "$T/cfg16" "LANE_16"
assert_grep '^LANE=main$' "$T/cfg15" "LANE defaults to main"
assert_grep '^EVALUATE_TARGET=pnpm dev$' "$T/cfg16" "EVALUATE_TARGET_16"
assert_grep '^GATE_SETUP=just replay$' "$T/cfg15" "GATE_SETUP"
assert_grep '^GATE=true$' "$T/cfg15" "GATE"
[[ -f "$FAKE_DIR/systemd-run.count" ]] && fail "config launched a unit" || pass "config launches nothing"

# ================================================================ 16. lane tag
scenario "every launch carries --tag lane=<lane>"
reset; config_with 'LANE_12=library'
run_driver 12 > /dev/null 2>&1 || fail "launch 12 failed"
A="$(argv_line)"
assert_grep '--tag unit=milestone-proj-12-[0-9T]+ --tag milestone=12 --tag lane=library' "$A" "LANE_12=library tags lane=library"
reset; config_with 'LANE_12=library'
run_driver 13 > /dev/null 2>&1 || fail "launch 13 failed"
A="$(argv_line)"
assert_grep '--tag milestone=13 --tag lane=main' "$A" "no LANE_13: lane=main"
reset; config_with 'GATE="echo gate"'
(cd "$PROJ" && "$DRIVER" --inside 6 --sandbox proj-1a2b3c4d --unit u) > /dev/null 2>&1 || fail "inside without tags failed"
assert_eq "$(grep -c -- '--tag milestone=6 --tag lane=main' "$FAKE_DIR/agent-sandbox.calls")" 2 "an untagged body tags both enters with lane=main"

# ================================================================ 17. creation logs per launch
scenario "two creations each read their own sandbox id"
reset; config_with 'GATE="echo gate"'
(cd "$PROJ" && FAKE_RUN_ID=proj-00000012 "$DRIVER" --inside 12 --unit u12) > /dev/null 2>&1 || true
(cd "$PROJ" && FAKE_RUN_ID=proj-00000013 "$DRIVER" --inside 13 --unit u13) > /dev/null 2>&1 || true
assert_grep '^sandbox: proj-00000012$' "$CHAIN" "milestone 12's id"
assert_grep '^sandbox: proj-00000013$' "$CHAIN" "milestone 13's id"
ls "$PROJ"/logs/milestones/create-12-*.log > /dev/null 2>&1 && pass "create-12-<stamp>.log" || fail "no create-12-<stamp>.log"
grep -q proj-00000013 "$PROJ"/logs/milestones/create-13-*.log && pass "create-13 log holds 13's id" || fail "create-13 log lacks 13's id"
[[ -e "$PROJ/logs/milestones/create.log" ]] && fail "a shared create.log was written" || pass "no shared create.log"

# ================================================================ 18. lane lifecycle rule
scenario "a launch refuses while an unpushed STATUS.md row holds the same lane"
reset; config_with 'LANE_12=library'
cat > "$PROJ/.milestones/STATUS.md" <<'EOF'
# Milestone status

| Milestone | Lane | Sandbox | Merged | Gate | Unmet criteria | Open blockers | Next action |
|---|---|---|---|---|---|---|---|
| 12 | library | proj-00000012 | 1a2b3c4d5e6f | gate pass | - | - | - |
| 13 | main | proj-00000013 | - | - | - | - | integrate |
EOF
set +e; run_driver 14 > "$T/out18" 2>&1; rc=$?; set -e
assert_eq "$rc" 2 "milestone 14 in lane main refused"
assert_grep 'milestone 13' "$T/out18" "the refusal names milestone 13"
[[ -f "$FAKE_DIR/systemd-run.count" ]] && fail "a unit was created" || pass "no unit created"
run_driver 13 > /dev/null 2>&1 && pass "relaunching 13 itself is not refused by its own row" || fail "13 refused by its own row"
rm -f "$FAKE_DIR/systemd-run.count"
set +e; (cd "$PROJ" && "$DRIVER" 15 > /dev/null 2>&1); rc=$?; set -e
assert_eq "$rc" 2 "milestone 15 in lane main refused too"
config_with 'LANE_12=library' 'LANE_15=library'
run_driver 15 > /dev/null 2>&1 && pass "milestone 15 in lane library proceeds (12 is pushed)" || fail "15 in library refused"
sed -i 's/^| 13 | main | proj-00000013 | - |/| 13 | main | proj-00000013 | 9f8e7d6c5b4a |/' "$PROJ/.milestones/STATUS.md"
run_driver 14 > /dev/null 2>&1 && pass "milestone 14 proceeds once 13 records a push" || fail "14 still refused after the push"

# ================================================================ 19. config.local
scenario ".milestones/config.local overrides config"
reset; config_with
echo 'MEMORY=16g' > "$PROJ/.milestones/config.local"
run_driver config 5 > "$T/cfg19" 2>&1 || fail "config 5 exited $?"
assert_grep '^MEMORY=16g$' "$T/cfg19" "config.local's MEMORY wins"
cp "$T/config.base" "$PROJ/.milestones/config"; rm -f "$PROJ/.milestones/config.local"

# ================================================================ 20. continue resolves the milestone from the sandbox
scenario "--sandbox ID --continue without a number takes the sandbox's milestone tag, else refuses"
reset; cp "$T/config.base" "$PROJ/.milestones/config"
echo '[{"sandbox_id": "proj-1a2b3c4d", "tags": {"milestone": "6", "lane": "main"}}, {"sandbox_id": "proj-00000bad", "tags": {}}]' > "$FAKE_DIR/status.json"
set +e; run_driver --sandbox proj-1a2b3c4d --continue "the owner did X" > "$T/out20" 2>&1; rc=$?; set -e
assert_eq "$rc" 0 "continue without a number launches ($(tail -n 2 "$T/out20" | tr '\n' ' '))"
if [[ -f "$FAKE_DIR/systemd-run.argv" ]]; then
  A="$(argv_line)"
  assert_grep '--unit=milestone-proj-6-' "$A" "the unit is named for the tagged milestone"
  assert_grep '--inside 6 .*--tag milestone=6 ' "$A" "the body and its tag carry milestone 6"
  assert_not_grep 'milestone=continue|--inside continue' "$A" "no milestone called continue"
else fail "no unit launched"; fi
reset
set +e; run_driver --sandbox proj-00000bad --continue "y" > "$T/out20b" 2>&1; rc=$?; set -e
assert_eq "$rc" 2 "an untagged sandbox with no number refuses"
assert_grep 'no milestone tag.*proj-00000bad|proj-00000bad.*no milestone tag' "$T/out20b" "the refusal says the sandbox has no milestone tag"
[[ -f "$FAKE_DIR/systemd-run.count" ]] && fail "a unit was created" || pass "no unit created"

# ================================================================ 21. exit 3 without an admission payload is a gate failure
scenario "a command exiting 3 with an ordinary result is not an admission refusal"
reset; cp "$T/config.base" "$PROJ/.milestones/config"
set +e; (cd "$PROJ" && FAKE_ENTER_RC=3 FAKE_ENTER_NOADMIT=1 "$DRIVER" --inside 6 --sandbox proj-1a2b3c4d --unit u --gate) > "$T/out21" 2>&1; rc=$?; set -e
assert_eq "$rc" 1 "a gate exiting 3 fails the unit with 1"
assert_grep '^gate FAIL exit=3 milestone=6 ' "$CHAIN" "the evidence line records exit 3"
assert_grep 'milestone 6: gate FAILED \(exit 3' "$CHAIN" "the chain says the gate failed"
assert_not_grep 'admission refused|not admitted' "$CHAIN" "no admission refusal is claimed"
reset
set +e; (cd "$PROJ" && FAKE_ENTER_RC=3 FAKE_ENTER_NOADMIT=1 "$DRIVER" --inside 6 --sandbox proj-1a2b3c4d --unit u) > "$T/out21b" 2>&1; rc=$?; set -e
assert_eq "$rc" 1 "a turn and a gate exiting 3: the unit fails at the gate"
assert_grep 'milestone 6: claude exited 3' "$CHAIN" "the turn's exit 3 is claude's exit"
assert_eq "$(grep -c '^enter ' "$FAKE_DIR/agent-sandbox.calls")" 2 "the gate still ran after the turn"
assert_not_grep 'admission refused|not admitted' "$CHAIN" "no admission refusal is claimed"

# ================================================================ 22. three-digit milestones
scenario "a milestone number of any length is accepted"
reset
set +e; run_driver config 100 > "$T/out22" 2>&1; rc=$?; set -e
assert_eq "$rc" 0 "config 100 exits 0 ($(head -n 1 "$T/out22"))"
assert_grep '^LANE=main$' "$T/out22" "config 100 prints its keys"
set +e; run_driver config 1x > "$T/out22b" 2>&1; rc=$?; set -e
assert_eq "$rc" 2 "a token that is not all digits is still refused"


# ================================================================ U3 fixtures: integrate
# A real repository with a bare remote. Sandbox branches are made with `git switch` in
# the host checkout, so the only worktree an integrate may add is its temporary one.
IR="$T/irepo"; BARE="$T/iremote.git"; ITMP="$T/itmp"
ICHAIN="$IR/logs/milestones/chain.log"
REAL_GIT="$(command -v git)"
g() { git -C "$IR" "$@"; }
iconfig() { printf '%s\n' 'REPORT_DIR=docs/reports' 'GATE="true"' "$@" > "$IR/.milestones/config"; }
mk_irepo() {
  rm -rf "$IR" "$BARE" "$ITMP"; mkdir -p "$ITMP"
  git init -q --bare -b main "$BARE"
  git init -q -b main "$IR"
  g config user.name t; g config user.email t@t
  mkdir -p "$IR/.milestones" "$IR/docs/reports" "$IR/tests" "$IR/web/__snapshots__" "$IR/data"
  printf 'logs/\n.milestones/config\n.milestones/config.local\ndata/\n' > "$IR/.gitignore"
  printf 'def test_a():\n    x = 3\n    assert x == 3\n' > "$IR/tests/test_a.py"
  printf 'exports[`x`] = `one`;\n' > "$IR/web/__snapshots__/x.snap"
  printf 'app v1\n' > "$IR/app.txt"
  g add -A; g commit -q -m init
  g remote add origin "$BARE"; g push -q -u origin main 2>/dev/null
  echo seed > "$IR/data/seed.txt"
  iconfig
}
istatus() {  # id:milestone ... (an empty milestone leaves the record untagged)
  local rows=() e
  for e in "$@"; do
    if [[ -n "${e#*:}" ]]; then rows+=("{\"sandbox_id\": \"${e%%:*}\", \"tags\": {\"milestone\": \"${e#*:}\", \"lane\": \"main\"}}")
    else rows+=("{\"sandbox_id\": \"${e%%:*}\", \"tags\": {}}"); fi
  done
  (IFS=,; echo "[${rows[*]}]") > "$FAKE_DIR/status.json"
}
sb_branch() { g rev-parse -q --verify "refs/heads/agent-sandbox/$1" > /dev/null || g branch -q "agent-sandbox/$1" origin/main; }
sb_do() {  # id "shell in the checkout" message: one commit on agent-sandbox/<id>
  sb_branch "$1"; g switch -q "agent-sandbox/$1"
  (cd "$IR" && bash -c "$2") && g add -A && g commit -q -m "$3"
  g switch -q main
}
sb_report() {  # id milestone [extra markdown]
  REPORT_BODY="$(printf '# Milestone %s report\n\nDone.\n%s' "$2" "${3:-}")" \
    sb_do "$1" "mkdir -p docs/reports && printf '%s\n' \"\$REPORT_BODY\" > docs/reports/milestone-$2.md" "milestone $2 report"
}
run_int() {  # integrate <args>; exit code in IRC; asserts no temporary worktree is left
  set +e; (cd "$IR" && TMPDIR="$ITMP" "$DRIVER" integrate "$@") > "$T/int.out" 2>&1; IRC=$?; set -e
  [[ "$(g worktree list | wc -l)" == 1 ]] && [[ -z "$(ls -A "$ITMP")" ]] && pass "no temporary worktree left" \
    || { g worktree list >&2; ls -A "$ITMP" >&2; fail "a temporary worktree or directory was left"; }
}
remote_head() { git --git-dir="$BARE" rev-parse main; }
int_out() { cat "$T/int.out" "$ICHAIN" 2>/dev/null > "$T/int.all"; echo "$T/int.all"; }

# ================================================================ U3.1 happy path
scenario "integrate: a passing host gate merges, records STATUS.md and pushes"
mk_irepo; istatus irepo-0000000a:7
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
sb_report irepo-0000000a 7
echo scratch > "$IR/notes.tmp"   # untracked, not ignored: allowed
PRE="$(g rev-parse HEAD)"
run_int irepo-0000000a
assert_eq "$IRC" 0 "integrate exits 0 ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
MERGE="$(g rev-list --merges -n 1 HEAD)"; M12="${MERGE:0:12}"
[[ -n "$MERGE" ]] && pass "a merge commit exists" || fail "no merge commit"
assert_eq "$(g rev-parse HEAD^)" "$MERGE" "the STATUS commit sits directly on the merge"
assert_eq "$(g rev-parse "$MERGE^1")" "$PRE" "the merge's first parent is the pre-merge head"
assert_grep "irepo-0000000a" <(g log -1 --format=%B "$MERGE") "the merge message names the sandbox"
assert_grep "milestone 7" <(g log -1 --format=%B "$MERGE") "the merge message names the milestone"
assert_grep "^gate pass exit=0 milestone=7 sha=$M12 $EVLINE dirty=no where=host-integrate setup=none steps=integration:0/0 replay:0/0 static:1/1 skipped:sandbox-only:0 env=\"-\" evidence=logs/milestones/evidence/7-host-integrate-[0-9T.]+ at=" "$ICHAIN" "host evidence line for the merge"
assert_grep "^gate pass exit=0 milestone=7 sha=$M12 $EVLINE dirty=no where=host-integrate " "$IR/logs/milestones/milestone-7.gate.log" "evidence in the gate log"
assert_eq "$(g show --name-only --format= HEAD)" ".milestones/STATUS.md" "the last commit touches only STATUS.md"
g show HEAD:.milestones/STATUS.md > "$T/st" 2>/dev/null || : > "$T/st"
assert_grep '^\| Milestone \| Lane \| Sandbox \| Merged \| Gate \| Unmet criteria \| Open blockers \| Next action \|$' "$T/st" "STATUS.md created with its header"
assert_grep "^\| 7 \| main \| irepo-0000000a \| $M12 \| pass $M12 $EVLINE integration:0/0 replay:0/0 static:1/1 skipped:sandbox-only:0 [0-9]{4}-[0-9]{2}-[0-9]{2} \| - \| - \| - \|$" "$T/st" "row for milestone 7"
assert_eq "$(remote_head)" "$(g rev-parse HEAD)" "the remote's main equals the local head"
assert_grep "pushed .*$(g rev-parse --short=12 HEAD)" "$ICHAIN" "the pushed sha is logged"
assert_grep "pre-merge $PRE" "$ICHAIN" "the pre-merge sha is logged"

# ================================================================ U3.2 gate failure
scenario "integrate: a failing gate keeps the merge local and pushes nothing"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE="false"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
PRE="$(g rev-parse HEAD)"; RPRE="$(remote_head)"
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "integrate exits non-zero ($IRC)" || fail "failed gate exited 0"
assert_eq "$(remote_head)" "$RPRE" "the remote is unchanged"
assert_grep "^gate FAIL exit=1 milestone=7 sha=[0-9a-f]{12} $EVLINE dirty=no where=host-integrate setup=none " "$ICHAIN" "gate FAIL evidence"
assert_grep "pre-merge $PRE" "$ICHAIN" "the pre-merge sha is logged"
assert_grep "git reset --hard $PRE" "$ICHAIN" "the reset hint is logged"
assert_eq "$(g rev-list --merges --count origin/main..HEAD)" 1 "the merge commit stays local"
[[ -f "$IR/.milestones/STATUS.md" ]] && fail "STATUS.md written on a failed gate" || pass "no STATUS.md on a failed gate"

# ================================================================ U3.3 setup failure
scenario "integrate: a failing GATE_SETUP refuses the push and names setup"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE_SETUP="false"' 'GATE="touch gate-ran"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
RPRE="$(remote_head)"
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "integrate exits non-zero ($IRC)" || fail "setup failure exited 0"
assert_eq "$(remote_head)" "$RPRE" "the remote is unchanged"
assert_grep '^gate FAIL exit=1 milestone=7 .* where=host-integrate setup=yes ' "$ICHAIN" "FAIL evidence with setup=yes"
assert_grep 'milestone 7: host gate FAILED .*setup' "$ICHAIN" "the log names setup"

# ================================================================ U3.4 re-run after a fix
scenario "integrate: a re-run on the already-merged branch pushes without a second merge"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE="false"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "first run fails its gate" || fail "first run passed"
echo "fix" >> "$IR/app.txt"; g commit -q -am "fix forward on the integration branch"
iconfig 'GATE="true"'
run_int irepo-0000000a
assert_eq "$IRC" 0 "the re-run exits 0 ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
assert_eq "$(git --git-dir="$BARE" rev-list --merges --count main)" 1 "exactly one merge commit reached the remote"
assert_eq "$(remote_head)" "$(g rev-parse HEAD)" "the remote's main equals the local head"
assert_grep 'already merged' "$ICHAIN" "the re-run says the branch is already merged"
assert_grep "^gate pass exit=0 milestone=7 sha=$(g rev-parse --short=12 HEAD^) $EVLINE dirty=no where=host-integrate " "$ICHAIN" "the gated sha is the fix commit under the STATUS commit"

# ================================================================ U3.5 merge conflict
scenario "integrate: a merge conflict aborts, leaves a clean tree, pushes nothing"
mk_irepo; istatus irepo-0000000a:7
sb_do irepo-0000000a "echo 'app sandbox' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
echo 'app host' > "$IR/app.txt"; g commit -q -am "host change"; g push -q 2>/dev/null
PRE="$(g rev-parse HEAD)"; RPRE="$(remote_head)"
run_int irepo-0000000a
assert_eq "$IRC" 2 "integrate refuses with 2"
assert_eq "$(g status --porcelain --untracked-files=no)" "" "the working tree is clean"
[[ -e "$IR/.git/MERGE_HEAD" ]] && fail "a merge is still in progress" || pass "no merge in progress"
assert_eq "$(g rev-parse HEAD)" "$PRE" "HEAD is the pre-merge head"
assert_eq "$(remote_head)" "$RPRE" "the remote is unchanged"
assert_grep 'conflict' "$(int_out)" "the refusal names the conflict"

# ================================================================ U3.6 dirty host tree
scenario "integrate: a modified tracked file refuses before merging"
mk_irepo; istatus irepo-0000000a:7
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
PRE="$(g rev-parse HEAD)"; echo "local edit" >> "$IR/tests/test_a.py"
run_int irepo-0000000a
assert_eq "$IRC" 2 "integrate refuses with 2"
assert_eq "$(g rev-parse HEAD)" "$PRE" "nothing merged"
assert_grep 'tracked changes' "$(int_out)" "the refusal names tracked changes"

# ================================================================ U3.7 wrong branch
scenario "integrate: INTEGRATION_BRANCH=main while on another branch refuses"
mk_irepo; istatus irepo-0000000a:7; iconfig 'INTEGRATION_BRANCH=main'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
g switch -q -c feature; g push -q -u origin feature 2>/dev/null
PRE="$(g rev-parse HEAD)"
run_int irepo-0000000a
assert_eq "$IRC" 2 "integrate refuses with 2"
assert_eq "$(g rev-parse HEAD)" "$PRE" "nothing merged"
assert_grep "INTEGRATION_BRANCH.*main" "$(int_out)" "the refusal names the integration branch"

# ================================================================ U3.8 weakening: skip marker
scenario "integrate: an added skip marker needs its path in the report's expectation-changes section"
for variant in none other listed; do
  mk_irepo; istatus irepo-0000000a:7
  sb_do irepo-0000000a "sed -i '1i import pytest\n@pytest.mark.skip' tests/test_a.py" "skip a test"
  case "$variant" in
    none)   sb_report irepo-0000000a 7 ;;
    other)  sb_report irepo-0000000a 7 $'\n## Notes\n\ntests/test_a.py was touched.\n\n## Test expectation changes\n\n- tests/test_b.py: reason\n\n## After\n\nnothing\n' ;;
    listed) sb_report irepo-0000000a 7 $'\n## Test expectation changes\n\n- tests/test_a.py: skipped because the fixture moved\n' ;;
  esac
  RPRE="$(remote_head)"
  run_int irepo-0000000a
  if [[ "$variant" == listed ]]; then
    assert_eq "$IRC" 0 "($variant) the listed path proceeds ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
    assert_eq "$(remote_head)" "$(g rev-parse HEAD)" "($variant) pushed"
  else
    assert_eq "$IRC" 2 "($variant) refused with 2"
    assert_grep '^    skip-marker tests/test_a\.py$' "$T/int.out" "($variant) the refusal names the skip marker's file"
    assert_eq "$(remote_head)" "$RPRE" "($variant) nothing pushed"
    assert_grep "pre-merge [0-9a-f]{40}" "$ICHAIN" "($variant) the pre-merge sha is logged"
  fi
done

# ================================================================ U3.9 loosened assertion
scenario "integrate: rewriting assert x == 3 to assert x >= 3 is a hit through the removed line"
mk_irepo; istatus irepo-0000000a:7
sb_do irepo-0000000a "sed -i 's/assert x == 3/assert x >= 3/' tests/test_a.py" "loosen"
sb_report irepo-0000000a 7
run_int irepo-0000000a
assert_eq "$IRC" 2 "refused with 2"
assert_grep '^    removed-assert tests/test_a\.py$' "$T/int.out" "the refusal names the file as a removed assertion"

# ================================================================ U3.10 deleted test
scenario "integrate: deleting tests/test_a.py is a hit"
mk_irepo; istatus irepo-0000000a:7
sb_do irepo-0000000a "git rm -q tests/test_a.py" "drop a test"
sb_report irepo-0000000a 7
run_int irepo-0000000a
assert_eq "$IRC" 2 "refused with 2"
assert_grep '^    deleted-test tests/test_a\.py$' "$T/int.out" "the refusal names the deleted test"

# ================================================================ U3.11 re-run scan
scenario "integrate: a re-run scans the whole unpushed range, fix commits included"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE="false"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
sb_report irepo-0000000a 7
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "first run fails its gate" || fail "first run passed"
sed -i '1i import pytest\n@pytest.mark.skip' "$IR/tests/test_a.py"; g commit -q -am "fix: skip the flaky test"
iconfig 'GATE="true"'; RPRE="$(remote_head)"
run_int irepo-0000000a
assert_eq "$IRC" 2 "the re-run refuses"
assert_grep '^    skip-marker tests/test_a\.py$' "$T/int.out" "the refusal names the fix commit's skip marker"
assert_eq "$(remote_head)" "$RPRE" "nothing pushed"
assert_not_grep 'git reset --hard' "$T/int.out" "an already-merged re-run offers no reset (it would drop the fix-forward commit)"
assert_grep "git log --oneline $RPRE\.\.HEAD" "$T/int.out" "an already-merged re-run shows what is unpushed instead"

# ================================================================ U3.12 another milestone's kept merge
scenario "integrate: milestone 8 refuses while milestone 7's failed merge is kept"
mk_irepo; istatus irepo-0000000a:7 irepo-0000000b:8; iconfig 'GATE="false"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
sb_do irepo-0000000b "echo 'other' > other.txt" "milestone 8 work"; sb_report irepo-0000000b 8
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "milestone 7 fails its gate" || fail "milestone 7 passed"
HEADA="$(g rev-parse HEAD)"; iconfig 'GATE="true"'
run_int irepo-0000000b
assert_eq "$IRC" 2 "milestone 8 refused with 2"
assert_eq "$(g rev-parse HEAD)" "$HEADA" "HEAD unchanged"
g merge-base --is-ancestor agent-sandbox/irepo-0000000b HEAD && fail "milestone 8 was merged" || pass "milestone 8 not merged"
assert_grep 'ahead of' "$(int_out)" "the refusal says the branch is ahead of its upstream"

# ================================================================ U3.13 seed isolation
scenario "integrate: GATE_SETUP writes only the temporary worktree's seed copy"
mk_irepo; istatus irepo-0000000a:7
iconfig 'SEED_PATHS="data/seed.txt data/missing"' 'GATE_SETUP="echo more >> data/seed.txt"' 'GATE="grep -q more data/seed.txt"' 'GATE_ENV="head -c 4 data/seed.txt; echo"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
cp "$IR/data/seed.txt" "$T/seed.before"
run_int irepo-0000000a
assert_eq "$IRC" 0 "integrate exits 0 ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
cmp -s "$T/seed.before" "$IR/data/seed.txt" && pass "the host's seed file is byte-identical" || fail "the host's seed file changed"
assert_grep '^gate pass exit=0 milestone=7 .* where=host-integrate setup=yes steps=integration:0/0 replay:0/0 static:2/2 skipped:sandbox-only:0 env="seed" ' "$ICHAIN" "setup ran on the copy and GATE_ENV was probed there"

# ================================================================ U3.14 snapshot
scenario "integrate: a changed snapshot baseline is a hit"
mk_irepo; istatus irepo-0000000a:7
sb_do irepo-0000000a "echo 'exports[\`x\`] = \`two\`;' > web/__snapshots__/x.snap" "rebaseline"
sb_report irepo-0000000a 7
run_int irepo-0000000a
assert_eq "$IRC" 2 "refused with 2"
assert_grep '^    snapshot web/__snapshots__/x\.snap$' "$T/int.out" "the refusal names the snapshot"

# ================================================================ U3.15 evaluation record
scenario "integrate: EVALUATE_7=1 needs a committed evaluation-7.md with no owner action left"
for variant in missing owner present; do
  mk_irepo; istatus irepo-0000000a:7; iconfig 'EVALUATE_7=1'
  sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
  case "$variant" in
    owner)   # the supervisor's record on the integration branch: a sandbox may not author .milestones/
             printf '# Evaluation 7\n\n- criterion 3: Owner Action Required (Spotify sign-in)\n' > "$IR/.milestones/evaluation-7.md"
             g add .milestones/evaluation-7.md; g commit -q -m "evaluation 7" ;;
    present) # the supervisor's record committed on the integration branch: a .milestones/-only commit
             printf '# Evaluation 7\n\n- criterion 3: reproduced, passes\n' > "$IR/.milestones/evaluation-7.md"
             g add .milestones/evaluation-7.md; g commit -q -m "evaluation 7" ;;
  esac
  RPRE="$(remote_head)"
  run_int irepo-0000000a
  if [[ "$variant" == present ]]; then
    assert_eq "$IRC" 0 "($variant) proceeds ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
    assert_eq "$(remote_head)" "$(g rev-parse HEAD)" "($variant) pushed"
  else
    assert_eq "$IRC" 2 "($variant) refused with 2"
    assert_grep 'evaluation-7\.md' "$T/int.out" "($variant) the refusal names the evaluation record"
    assert_eq "$(remote_head)" "$RPRE" "($variant) nothing pushed"
  fi
done

# ================================================================ U3.16 STATUS upsert
scenario "integrate: an existing row keeps the supervisor's cells while the gate cells update"
mk_irepo; istatus irepo-0000000a:7
cat > "$IR/.milestones/STATUS.md" <<'EOF'
# Milestone status

| Milestone | Lane | Sandbox | Merged | Gate | Unmet criteria | Open blockers | Next action |
|---|---|---|---|---|---|---|---|
| 6 | main | irepo-00000006 | 0123456789ab | pass 0123456789ab 2026-09-01 | - | - | - |
| 7 | main | irepo-old00007 | - | - | criterion 2 | owner: sign in to Spotify | review report |
EOF
g add .milestones/STATUS.md; g commit -q -m "supervisor review of 7"
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
run_int irepo-0000000a
assert_eq "$IRC" 0 "integrate exits 0 ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
M12="$(g rev-parse --short=12 HEAD^)"
g show HEAD:.milestones/STATUS.md > "$T/st" 2>/dev/null || : > "$T/st"
assert_grep "^\| 7 \| main \| irepo-0000000a \| $M12 \| pass $M12 $EVLINE [^|]+ [0-9-]{10} \| criterion 2 \| owner: sign in to Spotify \| review report \|$" "$T/st" "row 7 updated, supervisor cells kept"
assert_grep '^\| 6 \| main \| irepo-00000006 \| 0123456789ab \| pass 0123456789ab 2026-09-01 \| - \| - \| - \|$' "$T/st" "row 6 untouched"
assert_eq "$(grep -c '^| 7 ' "$T/st")" 1 "one row for milestone 7"
assert_eq "$(remote_head)" "$(g rev-parse HEAD)" "pushed"

# ================================================================ U3.17 id checks before git
scenario "integrate: a missing, empty or malformed id is refused before any git command"
mk_irepo; istatus irepo-0000000a:7
mkdir -p "$T/gitspy"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/gitspy.calls"\nexec "%s" "$@"\n' "$T" "$REAL_GIT" > "$T/gitspy/git"; chmod +x "$T/gitspy/git"
for bad in NONE "" "../x" "a..b" "a;b" "-x" "$(printf 'a%.0s' {1..129})"; do
  rm -f "$T/gitspy.calls"
  set +e
  if [[ "$bad" == NONE ]]; then (cd "$IR" && PATH="$T/gitspy:$PATH" "$DRIVER" integrate) > "$T/int.out" 2>&1; rc=$?
  else (cd "$IR" && PATH="$T/gitspy:$PATH" "$DRIVER" integrate "$bad") > "$T/int.out" 2>&1; rc=$?; fi
  set -e
  assert_eq "$rc" 2 "id '${bad:0:12}' refused with 2"
  assert_grep 'sandbox id' "$T/int.out" "id '${bad:0:12}': the refusal names the sandbox id"
  [[ -f "$T/gitspy.calls" ]] && fail "id '${bad:0:12}': git ran: $(cat "$T/gitspy.calls")" || pass "id '${bad:0:12}': no git command ran"
done

# ================================================================ U3.18 milestone number source
scenario "integrate: the milestone comes from the sandbox tag, else the positional number, else refuse"
mk_irepo; istatus irepo-0000000a: irepo-0000000c:9
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone work"; sb_report irepo-0000000a 5
run_int irepo-0000000a
assert_eq "$IRC" 2 "no tag and no number: refused"
assert_grep 'milestone' "$T/int.out" "the refusal asks for the milestone"
run_int irepo-0000000c 8
assert_eq "$IRC" 2 "a positional number that contradicts the tag is refused"
set +e; (cd "$IR" && RUN_MILESTONES_NO_JQ=1 TMPDIR="$ITMP" "$DRIVER" integrate irepo-0000000a 5) > "$T/int.out" 2>&1; IRC=$?; set -e
assert_eq "$IRC" 0 "untagged with a positional 5 proceeds (python path) ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
assert_grep '^gate pass exit=0 milestone=5 .* where=host-integrate ' "$ICHAIN" "evidence names milestone 5"

# ================================================================ U3.19 missing host tool
scenario "integrate: a gate calling a tool the host lacks fails with exit 127"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE="no-such-tool-u3 check"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "integrate exits non-zero" || fail "exited 0"
assert_grep '^gate FAIL exit=127 milestone=7 .* where=host-integrate ' "$ICHAIN" "FAIL exit=127"

# ================================================================ U3.20 gate timeout
scenario "integrate: GATE_TIMEOUT bounds the host gate"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE_TIMEOUT=1s' 'GATE="sleep 10"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "integrate exits non-zero" || fail "exited 0"
assert_grep '^gate FAIL exit=124 milestone=7 .* where=host-integrate ' "$ICHAIN" "FAIL exit=124"

# ================================================================ U3.21 other preconditions
scenario "integrate: no GATE, no upstream, behind upstream and an unknown branch refuse before merging"
mk_irepo; istatus irepo-0000000a:7
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
printf '%s\n' 'REPORT_DIR=docs/reports' > "$IR/.milestones/config"
PRE="$(g rev-parse HEAD)"
run_int irepo-0000000a
assert_eq "$IRC" 2 "no GATE refused"; assert_grep '\bGATE\b' "$T/int.out" "names GATE"
assert_eq "$(g rev-parse HEAD)" "$PRE" "nothing merged"
iconfig; g branch -q --unset-upstream
run_int irepo-0000000a
assert_eq "$IRC" 2 "no upstream refused"; assert_grep 'upstream' "$T/int.out" "names the upstream"
g branch -q -u origin/main
git clone -q "$BARE" "$T/other" && git -C "$T/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m elsewhere && git -C "$T/other" push -q 2>/dev/null
g fetch -q; rm -rf "$T/other"
run_int irepo-0000000a
assert_eq "$IRC" 2 "behind upstream refused"; assert_grep 'behind' "$T/int.out" "says behind"
assert_eq "$(g rev-parse HEAD)" "$PRE" "nothing merged"
g merge -q --ff-only origin/main
run_int irepo-0000000z 7
assert_eq "$IRC" 2 "a sandbox with no branch refused"; assert_grep 'agent-sandbox/irepo-0000000z' "$T/int.out" "names the branch"

# ================================================================ U3.22 push failure
scenario "integrate: a rejected push exits non-zero and says so"
mk_irepo; istatus irepo-0000000a:7
printf '#!/bin/sh\necho denied >&2\nexit 1\n' > "$BARE/hooks/pre-receive"; chmod +x "$BARE/hooks/pre-receive"
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
RPRE="$(remote_head)"
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "integrate exits non-zero ($IRC)" || fail "a rejected push exited 0"
assert_eq "$(remote_head)" "$RPRE" "the remote is unchanged"
assert_grep 'push failed' "$ICHAIN" "chain.log says the push failed"

# ================================================================ U3.23 ignored host files
scenario "integrate: a sandbox branch that force-adds a path ignored on the host refuses before merging"
mk_irepo; istatus irepo-0000000a:7
sb_do irepo-0000000a "echo sandbox-copy > data/seed.txt && git add -f data/seed.txt" "force-add an ignored file"; sb_report irepo-0000000a 7
mkdir -p "$IR/data"; echo host-secret > "$IR/data/seed.txt"
PRE="$(g rev-parse HEAD)"; RPRE="$(remote_head)"
run_int irepo-0000000a
assert_eq "$IRC" 2 "refused with 2"
assert_grep 'ignored.*data/seed\.txt|data/seed\.txt.*ignored' "$(int_out)" "the refusal names the ignored path"
assert_eq "$(cat "$IR/data/seed.txt")" "host-secret" "the host's ignored file is untouched"
assert_eq "$(g rev-parse HEAD)" "$PRE" "nothing merged"
assert_eq "$(remote_head)" "$RPRE" "nothing pushed"

# ================================================================ U3.24 large test diff
scenario "integrate: a skip marker opening a test diff over 64 KB is still a hit"
mk_irepo; istatus irepo-0000000a:7
sb_do irepo-0000000a "mkdir -p web && { echo \"it.skip('first', () => {});\"; for i in \$(seq 1 2500); do echo \"it('case \$i with padding padding padding', () => { expect(\$i).toBe(\$i); });\"; done; } > web/big.test.js" "a big test file"; sb_report irepo-0000000a 7
[[ "$(g show agent-sandbox/irepo-0000000a:web/big.test.js | wc -c)" -gt 65536 ]] && pass "the test file is over 64 KB" || fail "the fixture is under 64 KB"
run_int irepo-0000000a
assert_eq "$IRC" 2 "refused with 2"
assert_grep '^    skip-marker web/big\.test\.js$' "$T/int.out" "the refusal names the big file's skip marker"

# ================================================================ U3.25 commits during the gate
scenario "integrate: a commit landing on the host branch during the gate is not pushed"
mk_irepo; istatus irepo-0000000a:7; iconfig "GATE=\"git -C $IR commit -q --allow-empty -m sneaky\""
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
RPRE="$(remote_head)"
run_int irepo-0000000a
assert_eq "$IRC" 2 "refused with 2"
assert_eq "$(remote_head)" "$RPRE" "the remote is unchanged"
assert_grep 'gated' "$(int_out)" "the refusal says HEAD is not the gated commit"
assert_eq "$(g log -1 --format=%s)" "sneaky" "the extra commit stays local, with no STATUS commit on it"

# ================================================================ U3.26 supervisor files from a sandbox
scenario "integrate: a sandbox branch touching .milestones/ refuses before merging"
mk_irepo; istatus irepo-0000000a:7; iconfig 'EVALUATE_7=1'
sb_do irepo-0000000a "printf '# Evaluation 7\n\n- all criteria pass\n' > .milestones/evaluation-7.md" "self-evaluation"; sb_report irepo-0000000a 7
PRE="$(g rev-parse HEAD)"; RPRE="$(remote_head)"
run_int irepo-0000000a
assert_eq "$IRC" 2 "refused with 2"
assert_grep '\.milestones/evaluation-7\.md' "$(int_out)" "the refusal names the supervisor file"
assert_eq "$(g rev-parse HEAD)" "$PRE" "nothing merged"
assert_eq "$(remote_head)" "$RPRE" "nothing pushed"

# ================================================================ U3.27 report required
scenario "integrate: a sandbox branch without a non-empty report refuses"
for variant in empty-branch empty-report; do
  mk_irepo; istatus irepo-0000000a:7
  case "$variant" in
    empty-branch) sb_branch irepo-0000000a ;;
    empty-report) sb_do irepo-0000000a "echo 'app v2' > app.txt && : > docs/reports/milestone-7.md" "work, empty report" ;;
  esac
  PRE="$(g rev-parse HEAD)"; RPRE="$(remote_head)"
  run_int irepo-0000000a
  assert_eq "$IRC" 2 "($variant) refused with 2"
  assert_grep 'docs/reports/milestone-7\.md' "$(int_out)" "($variant) the refusal names the report"
  assert_eq "$(g rev-parse HEAD)" "$PRE" "($variant) nothing merged"
  assert_eq "$(remote_head)" "$RPRE" "($variant) nothing pushed"
done

# ================================================================ U3.28 gate definition changes
scenario "integrate: a change to a gate definition file is a gate-config hit"
for variant in none listed; do
  mk_irepo; istatus irepo-0000000a:7
  sb_do irepo-0000000a "printf 'check:\n\tpytest -k fast\n' > justfile && mkdir -p .github/workflows && echo 'on: push' > .github/workflows/ci.yml" "narrow the gate"
  case "$variant" in
    none)   sb_report irepo-0000000a 7 ;;
    listed) sb_report irepo-0000000a 7 $'\n## Test expectation changes\n\n- justfile: the slow suite moved to nightly\n- .github/workflows/ci.yml: new\n' ;;
  esac
  RPRE="$(remote_head)"
  run_int irepo-0000000a
  if [[ "$variant" == listed ]]; then
    assert_eq "$IRC" 0 "($variant) listed gate-config changes proceed ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
  else
    assert_eq "$IRC" 2 "($variant) refused with 2"
    assert_grep '^    gate-config justfile$' "$T/int.out" "($variant) the refusal names justfile"
    assert_grep '^    gate-config \.github/workflows/ci\.yml$' "$T/int.out" "($variant) the refusal names the workflow"
    assert_eq "$(remote_head)" "$RPRE" "($variant) nothing pushed"
  fi
done

# ================================================================ U3.29 listed paths match whole
scenario "integrate: a listed path must match the hit's path whole, not as a substring"
for variant in longer backtick; do
  mk_irepo; istatus irepo-0000000a:7
  sb_do irepo-0000000a "printf 'func TestA(t *testing.T) { t.Skip(\"later\") }\n' > a_test.go" "skip a go test"
  case "$variant" in
    longer)   sb_report irepo-0000000a 7 $'\n## Test expectation changes\n\n- pkg/a_test.go: skipped\n- a_test.go.orig: removed\n' ;;
    backtick) sb_report irepo-0000000a 7 $'\n## Test expectation changes\n\nSkipped `a_test.go` until the fixture lands, see a_test.go.\n' ;;
  esac
  run_int irepo-0000000a
  if [[ "$variant" == backtick ]]; then
    assert_eq "$IRC" 0 "($variant) the path named whole proceeds ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
  else
    assert_eq "$IRC" 2 "($variant) a path containing the hit's path is not a listing"
    assert_grep '^    skip-marker a_test\.go$' "$T/int.out" "($variant) the refusal names a_test.go"
  fi
done

# ================================================================ U3.30 push timeout
scenario "integrate: GATE_TIMEOUT bounds the push"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE_TIMEOUT=2s'
printf '#!/bin/sh\nsleep 8\n' > "$BARE/hooks/pre-receive"; chmod +x "$BARE/hooks/pre-receive"
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
RPRE="$(remote_head)"
run_int irepo-0000000a
assert_eq "$IRC" 1 "a push past GATE_TIMEOUT fails with 1"
assert_grep 'push (failed|timed out)' "$ICHAIN" "chain.log says the push failed"
assert_eq "$(remote_head)" "$RPRE" "the remote is unchanged"
assert_grep 'timeout "\$GATE_TIMEOUT" git push .*</dev/null' "$DRIVER" "the push runs under timeout with stdin closed"

# ================================================================ U3.31 seed path guard
scenario "integrate: absolute and .. SEED_PATHS entries are skipped; a valid one is still seeded"
mk_irepo; istatus irepo-0000000a:7
iconfig 'SEED_PATHS="/etc/hostname ../outside data/seed.txt"' 'GATE="test -f data/seed.txt && test ! -e ../outside && test ! -e etc"'
echo outside > "$IR/../outside"
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
run_int irepo-0000000a
rm -f "$IR/../outside"
assert_eq "$IRC" 0 "integrate exits 0 ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
assert_grep "seed path '/etc/hostname' skipped: not a path inside the repository" "$ICHAIN" "the absolute entry is skipped with its message"
assert_grep "seed path '\.\./outside' skipped: not a path inside the repository" "$ICHAIN" "the .. entry is skipped with its message"
assert_grep '^  seeded data/seed\.txt$' "$ICHAIN" "the valid entry is seeded"

# ================================================================ U2 step runner and evidence bundle
bundle_of() { { sed -n 's/^gate .* evidence=\([^ ]*\) at=.*/\1/p' "$1" 2>/dev/null || true; } | tail -n 1; }   # the last gate line's bundle
seal_in() { awk -v b="$2" '$1 == "seal" && $3 == b { s = $2 } END { print s }' "$1" 2>/dev/null || true; }   # chain.log bundle
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# ================================================================ U2.1 three kinds on the host
scenario "gate steps: integration, replay and static pass on the host; evidence.json, kind counts, identity and seal"
mk_irepo; istatus irepo-0000000a:7
U21_STEPS='GATE_STEPS=("integration|db|echo db-ran" "replay|rec|echo rec-ran" "static|lint|echo \"tmp=\$TMPDIR ports=\$GATE_PORT_1 \$GATE_PORT_2 \$GATE_PORT_3 \$GATE_PORT_4\"")'
iconfig 'GATE=""' "$U21_STEPS"
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
run_int irepo-0000000a
assert_eq "$IRC" 0 "integrate exits 0 ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
MERGE="$(g rev-parse HEAD^ 2>/dev/null || true)"; M12="${MERGE:0:12}"; TREE="$(g rev-parse "$MERGE^{tree}" 2>/dev/null || true)"
assert_grep "^gate pass exit=0 milestone=7 sha=$M12 tree=${TREE:0:12} def=[0-9a-f]{12} dirty=no where=host-integrate setup=none steps=integration:1/1 replay:1/1 static:1/1 skipped:sandbox-only:0 env=\"-\" evidence=logs/milestones/evidence/7-host-integrate-[0-9T.]+ at=" "$ICHAIN" "the evidence line carries tree, definition, dirty, kind counts and the bundle"
REL="$(bundle_of "$ICHAIN")"; B="$IR/$REL"; EJ="$B/evidence.json"
[[ -f "$EJ" ]] && pass "evidence.json written in the host bundle" || fail "no $EJ"
assert_eq "$(jq -r '[.steps[] | "\(.kind):\(.name):\(.status):\(.exit)"] | join(" ")' "$EJ" 2>/dev/null)" "integration:db:pass:0 replay:rec:pass:0 static:lint:pass:0" "three steps with kind, name, status and exit"
assert_eq "$(jq -r '[.steps[] | (.duration_ms | type)] | join(" ")' "$EJ" 2>/dev/null)" "number number number" "each step has a duration"
assert_eq "$(jq -r '[.verdict, .exit, .where, .sha, .tree, .dirty] | map(tostring) | join(" ")' "$EJ" 2>/dev/null)" "pass 0 host-integrate $MERGE $TREE false" "verdict and identity in evidence.json"
DEF="$(jq -r .definition_hash "$EJ" 2>/dev/null || true)"
[[ "$DEF" =~ ^[0-9a-f]{64}$ ]] && grep -q "def=${DEF:0:12} " "$ICHAIN" && pass "the definition hash is a sha256 and the line carries its prefix" || fail "definition hash '$DEF'"
for s in 1-db 2-rec 3-lint; do [[ -f "$B/steps/$s.log" ]] && pass "step log $s.log kept after the worktree's removal" || fail "no $B/steps/$s.log"; done
assert_grep '^db-ran$' "$B/steps/1-db.log" "the step's output is in its log"
LINT="$(cat "$B/steps/3-lint.log" 2>/dev/null || true)"
[[ "$LINT" =~ ^tmp=(/[^ ]+)\ ports=([0-9]+)\ ([0-9]+)\ ([0-9]+)\ ([0-9]+)$ ]] && pass "TMPDIR and GATE_PORT_1..4 exported to the step" || fail "step env: '$LINT'"
GTMP="${BASH_REMATCH[1]:-}"
[[ -n "$GTMP" && "$GTMP" != "$ITMP" && ! -e "$GTMP" ]] && pass "the per-run TMPDIR was fresh and is removed" || fail "per-run TMPDIR '$GTMP'"
assert_eq "$(printf '%s\n' "${BASH_REMATCH[@]:2:4}" | sort -u | wc -l)" 4 "four distinct ports"
assert_eq "$(grep -c '^[0-9]' "$IR/logs/milestones/ports.registry" 2>/dev/null || true)" 0 "the ports are released after the run"
assert_eq "$(seal_in "$ICHAIN" "$REL")" "$(sha_of "$EJ")" "chain.log's seal is the sha256 of evidence.json"
g show HEAD:.milestones/STATUS.md > "$T/st" 2>/dev/null || : > "$T/st"
assert_grep "^\| 7 \| main \| irepo-0000000a \| $M12 \| pass $M12 tree=${TREE:0:12} def=${DEF:0:12} integration:1/1 replay:1/1 static:1/1 skipped:sandbox-only:0 [0-9-]{10} \|" "$T/st" "the STATUS gate cell carries identity and kind counts"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE=""' "$U21_STEPS"
sb_do irepo-0000000a "echo 'app v3' > app.txt" "other milestone 7 work"; sb_report irepo-0000000a 7
run_int irepo-0000000a
assert_eq "$IRC" 0 "a second project with the same definition exits 0"
assert_eq "$(sed -n 's/^gate pass .* def=\([0-9a-f]*\) .*/\1/p' "$ICHAIN" 2>/dev/null | tail -n 1)" "${DEF:0:12}" "the same definition gives the same hash on a different tree"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE=""' "$U21_STEPS"
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
echo 'MAX_GATE_FAILURES=3' > "$IR/.milestones/config.local"
run_int irepo-0000000a
assert_eq "$IRC" 0 "a run with a budget key exits 0"
[[ "$(sed -n 's/^gate pass .* def=\([0-9a-f]*\) .*/\1/p' "$ICHAIN" 2>/dev/null | tail -n 1)" != "${DEF:0:12}" ]] && pass "config.local and a budget key change the definition hash" || fail "definition hash unchanged"

# ================================================================ U2.2 a failing step stops the run
scenario "gate steps: the second step exits 3; FAIL exit 3, the third not run, its log kept"
mk_irepo; istatus irepo-0000000a:7; rm -f "$T/c-ran"
iconfig 'GATE=""' "GATE_STEPS=(\"static|a|echo a-ran\" \"replay|b|echo b-out; exit 3\" \"integration|c|touch $T/c-ran\")"
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
RPRE="$(remote_head)"
run_int irepo-0000000a
assert_eq "$IRC" 1 "integrate exits 1"
assert_eq "$(remote_head)" "$RPRE" "nothing pushed"
assert_grep "^gate FAIL exit=3 milestone=7 .* steps=integration:0/1 replay:0/1 static:1/1 skipped:sandbox-only:0 " "$ICHAIN" "FAIL with the step's own exit and the counts"
assert_grep 'milestone 7: host gate FAILED at b' "$ICHAIN" "the failing step is named"
REL="$(bundle_of "$ICHAIN")"; B="$IR/$REL"; EJ="$B/evidence.json"
assert_eq "$(jq -r '[.steps[] | "\(.status):\(.exit)"] | join(",")' "$EJ" 2>/dev/null)" "pass:0,fail:3,not run:null" "statuses: pass, fail 3, not run"
assert_eq "$(jq -r '[.verdict, .exit, .failed_step] | map(tostring) | join(" ")' "$EJ" 2>/dev/null)" "fail 3 b" "verdict fail, exit 3, failed step b"
[[ -e "$T/c-ran" ]] && fail "the third step ran" || pass "the third step did not run"
assert_grep '^b-out$' "$B/steps/2-b.log" "the failed step's log survives the worktree's removal"
assert_eq "$(seal_in "$ICHAIN" "$REL")" "$(sha_of "$EJ")" "a failed run is sealed too"

# ================================================================ U2.3 sandbox-only
scenario "gate steps: a sandbox-only step is not run on the host and runs in the sandbox"
mk_irepo; istatus irepo-0000000a:7; rm -f "$T/pg-ran"
iconfig 'GATE=""' "GATE_STEPS=(\"static|a|true\" \"integration|pg|touch $T/pg-ran|sandbox-only\")"
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
run_int irepo-0000000a
assert_eq "$IRC" 0 "the host gate passes on the other steps ($(tail -n 2 "$T/int.out" | tr '\n' ' '))"
assert_grep "^gate pass exit=0 milestone=7 .* steps=integration:0/1 replay:0/0 static:1/1 skipped:sandbox-only:1 " "$ICHAIN" "the skip is counted, not passed"
EJ="$IR/$(bundle_of "$ICHAIN")/evidence.json"
assert_eq "$(jq -r '.steps[1] | "\(.name):\(.status):\(.exit):\(.sandbox_only)"' "$EJ" 2>/dev/null)" "pg:not run: sandbox-only:null:true" "recorded not run: sandbox-only"
[[ -e "$T/pg-ran" ]] && fail "the sandbox-only step ran on the host" || pass "the sandbox-only step did not run on the host"
reset; config_with 'GATE=""' "GATE_STEPS=(\"static|a|true\" \"integration|pg|touch $T/pg-ran|sandbox-only\")"
gate_inside
assert_eq "$GRC" 0 "the sandbox gate passes"
[[ -e "$T/pg-ran" ]] && pass "the sandbox-only step ran in the sandbox" || fail "the sandbox-only step did not run in the sandbox"
assert_grep "^gate pass exit=0 milestone=6 .* where=sandbox setup=none steps=integration:1/1 replay:0/0 static:1/1 skipped:sandbox-only:0 " "$CHAIN" "counted as passed in the sandbox"

# ================================================================ U2.4 dirty tree
scenario "gate: a dirty sandbox worktree gives dirty=yes and a dirty.patch that reproduces it, without ignored or seeded files"
reset; config_with 'GATE="echo gate"' 'SEED_PATHS="seeded.cfg"'
printf 'secret.env\n' > "$GWS/.gitignore"; echo 'app v1' > "$GWS/app.txt"
git -C "$GWS" add -A && git -C "$GWS" -c user.name=t -c user.email=t@t commit -q -m "app and ignores"
DSHA="$(git -C "$GWS" rev-parse HEAD)"
echo 'app v2' > "$GWS/app.txt"; echo 'brand new' > "$GWS/new.txt"
echo 'SECRET-VALUE-1' > "$GWS/secret.env"; echo 'SEED-VALUE-1' > "$GWS/seeded.cfg"
gate_inside
assert_eq "$GRC" 0 "a dirty tree does not fail the --gate run"
assert_grep "^gate pass exit=0 milestone=6 sha=${DSHA:0:12} $EVLINE dirty=yes where=sandbox " "$CHAIN" "dirty=yes"
B="$PROJ/$(bundle_of "$CHAIN")"
assert_eq "$(jq -r '[.dirty, .dirty_tracked, .dirty_untracked] | map(tostring) | join(" ")' "$B/evidence.json" 2>/dev/null)" "true true true" "tracked and untracked dirt recorded"
assert_eq "$(cat "$B/untracked.txt" 2>/dev/null)" "new.txt" "untracked.txt lists only the untracked, unignored, unseeded file"
assert_not_grep 'SECRET-VALUE|secret\.env|SEED-VALUE|seeded\.cfg' "$B/dirty.patch" "dirty.patch holds neither the ignored secret nor the seeded file"
assert_not_grep 'secret\.env|seeded\.cfg' "$B/untracked.txt" "untracked.txt names neither"
rm -rf "$T/replay"; git clone -q "$GWS" "$T/replay"; git -C "$T/replay" checkout -q --detach "$DSHA"
git -C "$T/replay" apply "$B/dirty.patch" 2>/dev/null && pass "dirty.patch applies to the recorded sha" || fail "dirty.patch does not apply"
cmp -s "$GWS/app.txt" "$T/replay/app.txt" && cmp -s "$GWS/new.txt" "$T/replay/new.txt" && pass "the patch reproduces the tracked and untracked changes" || fail "the replayed tree differs"

# ================================================================ U2.5 clean tree and seed_kept
scenario "gate: a clean worktree gives dirty=no and an empty patch; a kept seeded path makes it dirty"
reset; config_with 'GATE="echo gate"' 'SEED_PATHS="seeded.cfg"'
git -C "$GWS" checkout -q -- app.txt; rm -f "$GWS/new.txt"   # the ignored secret and the seeded file stay
gate_inside
assert_eq "$GRC" 0 "gate passes"
assert_grep "^gate pass exit=0 milestone=6 .* dirty=no where=sandbox " "$CHAIN" "dirty=no"
B="$PROJ/$(bundle_of "$CHAIN")"
[[ -f "$B/dirty.patch" && ! -s "$B/dirty.patch" && -f "$B/untracked.txt" && ! -s "$B/untracked.txt" ]] && pass "empty dirty.patch and untracked.txt" || fail "patch or untracked list not empty"
reset; config_with 'GATE="echo gate"' 'SEED_PATHS="seeded.cfg"'
mkdir -p "$FAKE_DIR/runs/proj-1a2b3c4d"; echo '{"sandbox_id": "proj-1a2b3c4d", "seed_kept": ["data/catalog.db"]}' > "$FAKE_DIR/runs/proj-1a2b3c4d/run.json"
gate_inside
assert_grep "^gate pass exit=0 milestone=6 .* dirty=yes where=sandbox " "$CHAIN" "a seeded path the run kept makes the bundle dirty"
B="$PROJ/$(bundle_of "$CHAIN")"
assert_eq "$(jq -c '[.seed_kept, .dirty_tracked, .dirty_untracked]' "$B/evidence.json" 2>/dev/null)" '[["data/catalog.db"],false,false]' "evidence.json names the kept path"

# ================================================================ U2.6 GATE alone, and the report check
scenario "gate: a config with only GATE is one static step named gate; a missing report fails the sandbox gate"
reset; config_with 'GATE="echo gate"'
gate_inside
EJ="$PROJ/$(bundle_of "$CHAIN")/evidence.json"
assert_eq "$(jq -r '[.steps[] | "\(.kind)|\(.name)|\(.command)"] | join(";")' "$EJ" 2>/dev/null)" "static|gate|echo gate" "one step: static, gate, the GATE command"
assert_grep "steps=integration:0/0 replay:0/0 static:1/1 skipped:sandbox-only:0 " "$CHAIN" "counted as one static step"
assert_eq "$(jq -r .report "$EJ" 2>/dev/null)" "present" "the report is recorded present"
mk_gws proj-00000a0b
set +e; (cd "$PROJ" && FAKE_ENTER_EXEC=1 "$DRIVER" --inside 6 --sandbox proj-00000a0b --unit u --gate) > "$T/norep.out" 2>&1; rc=$?; set -e
assert_eq "$rc" 1 "no report: the unit fails"
assert_grep '^gate FAIL exit=1 milestone=6 ' "$CHAIN" "FAIL evidence line"
assert_grep 'milestone 6: gate FAILED .*report' "$CHAIN" "the chain names the report"
assert_eq "$(jq -r '[.report, .failed_step, .steps[0].status] | join(" ")' "$PROJ/$(bundle_of "$CHAIN")/evidence.json" 2>/dev/null)" "missing report pass" "the steps passed and the report is missing"

# ================================================================ U2.7 pipelines
scenario "gate: a step whose pipeline fails early (false | true) fails, on the host and in the sandbox"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE="false | true"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
run_int irepo-0000000a
assert_eq "$IRC" 1 "the host gate fails"
assert_grep '^gate FAIL exit=1 milestone=7 .* where=host-integrate ' "$ICHAIN" "host FAIL exit=1"
reset; config_with 'GATE="false | true"'
gate_inside
assert_eq "$GRC" 1 "the sandbox gate fails"
assert_grep '^gate FAIL exit=1 milestone=6 .* where=sandbox ' "$CHAIN" "sandbox FAIL exit=1"

# ================================================================ U2.8 forged evidence
scenario "gate: a step that forges evidence.json cannot change the verdict, and a later forgery breaks the seal"
mk_irepo; istatus irepo-0000000a:7; rm -f "$T/forge-go" "$T/forged"
cat > "$T/forge.sh" <<EOF
forge() { for d in "$IR"/logs/milestones/evidence/*/; do printf '{"verdict": "pass", "exit": 0}\n' > "\${d}evidence.json"; done; }
forge
( for i in \$(seq 300); do [ -e "$T/forge-go" ] && break; sleep 0.1; done; forge; touch "$T/forged" ) > /dev/null 2>&1 < /dev/null &
exit 1
EOF
iconfig "GATE=\"bash $T/forge.sh\""
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
RPRE="$(remote_head)"
run_int irepo-0000000a
assert_eq "$IRC" 1 "integrate fails"
assert_eq "$(remote_head)" "$RPRE" "nothing pushed"
assert_grep '^gate FAIL exit=1 milestone=7 ' "$ICHAIN" "the driver's verdict is FAIL"
REL="$(bundle_of "$ICHAIN")"; EJ="$IR/$REL/evidence.json"
assert_eq "$(jq -r '"\(.verdict) \(.exit)"' "$EJ" 2>/dev/null)" "fail 1" "evidence.json is the driver's, written after the step"
SEAL="$(seal_in "$ICHAIN" "$REL")"
assert_eq "$SEAL" "$(sha_of "$EJ")" "the seal matches before the late forgery"
touch "$T/forge-go"
for i in $(seq 100); do [[ -e "$T/forged" ]] && break; sleep 0.1; done
assert_grep '"verdict": "pass"' "$EJ" "the late forgery landed"
[[ -n "$SEAL" && "$SEAL" != "$(sha_of "$EJ")" ]] && pass "the logged seal no longer matches the forged file" || fail "the seal matches a forged file"

# ================================================================ U2.9 integrate in a sandbox
scenario "integrate with INTEGRATE_GATE_WHERE=sandbox gates a fresh sandbox of the merge commit and removes it"
SBX_STEPS="GATE_STEPS=(\"static|lint|test -f app.txt && git rev-parse HEAD > $T/sbx-head\" \"integration|pg|touch $T/sbx-pg|sandbox-only\")"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE=""' 'INTEGRATE_GATE_WHERE=sandbox' "$SBX_STEPS"
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
rm -f "$FAKE_DIR/agent-sandbox.calls" "$T/sbx-head" "$T/sbx-pg"
export FAKE_RUN_CLONE=1 FAKE_RUN_ID=irepo-5b5b5b5b FAKE_ENTER_EXEC=1
run_int irepo-0000000a
unset FAKE_RUN_CLONE FAKE_RUN_ID FAKE_ENTER_EXEC
assert_eq "$IRC" 0 "integrate exits 0 ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
MERGE="$(g rev-parse HEAD^ 2>/dev/null || true)"
assert_grep '^run [^ ]*/irepo --new --tag milestone=7 --tag lane=main --tag purpose=integration-gate --json -- true$' "$FAKE_DIR/agent-sandbox.calls" "a fresh, tagged sandbox from the repo"
assert_eq "$(grep -c '^enter irepo-5b5b5b5b ' "$FAKE_DIR/agent-sandbox.calls")" 2 "each step through its own enter"
assert_eq "$(cat "$T/sbx-head" 2>/dev/null)" "$MERGE" "the steps ran on the merge commit"
[[ -e "$T/sbx-pg" ]] && pass "the sandbox-only step ran" || fail "the sandbox-only step did not run"
assert_grep "^gate pass exit=0 milestone=7 sha=${MERGE:0:12} $EVLINE dirty=no where=sandbox-integration setup=none steps=integration:1/1 replay:0/0 static:1/1 skipped:sandbox-only:0 " "$ICHAIN" "where=sandbox-integration"
assert_grep '^rm irepo-5b5b5b5b( --force)?$' "$FAKE_DIR/agent-sandbox.calls" "the sandbox is removed after a pass"
[[ -e "$FAKE_WS_ROOT/irepo-5b5b5b5b" ]] && fail "the sandbox worktree is still there" || pass "the sandbox worktree is gone"
assert_eq "$(remote_head)" "$(g rev-parse HEAD)" "a sandbox-integration pass pushes"

mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE="false"' 'INTEGRATE_GATE_WHERE=sandbox'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
rm -f "$FAKE_DIR/agent-sandbox.calls"; RPRE="$(remote_head)"
export FAKE_RUN_CLONE=1 FAKE_RUN_ID=irepo-5b5b5b5b FAKE_ENTER_EXEC=1
run_int irepo-0000000a
unset FAKE_RUN_CLONE FAKE_RUN_ID FAKE_ENTER_EXEC
assert_eq "$IRC" 1 "a failing sandbox-integration gate exits 1"
assert_grep '^gate FAIL exit=1 milestone=7 .* where=sandbox-integration ' "$ICHAIN" "FAIL where=sandbox-integration"
assert_grep '^rm irepo-5b5b5b5b( --force)?$' "$FAKE_DIR/agent-sandbox.calls" "the sandbox is removed after a failure"
[[ -e "$FAKE_WS_ROOT/irepo-5b5b5b5b" ]] && fail "the sandbox worktree is still there" || pass "the sandbox worktree is gone"
assert_eq "$(remote_head)" "$RPRE" "nothing pushed"

mk_irepo; istatus irepo-0000000a:7; iconfig 'INTEGRATE_GATE_WHERE=sandbox'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
rm -f "$FAKE_DIR/agent-sandbox.calls"; RPRE="$(remote_head)"
export FAKE_RUN_CLONE=1 FAKE_RUN_ID=irepo-5b5b5b5b FAKE_ENTER_EXEC=1 FAKE_RUN_AT='HEAD^'
run_int irepo-0000000a
unset FAKE_RUN_CLONE FAKE_RUN_ID FAKE_ENTER_EXEC FAKE_RUN_AT
assert_eq "$IRC" 2 "a sandbox not at the merge commit is refused with 2"
assert_grep 'not the merge' "$(int_out)" "the refusal says the sandbox is not at the merge commit"
assert_not_grep '^enter ' "$FAKE_DIR/agent-sandbox.calls" "no step ran"
assert_grep '^rm irepo-5b5b5b5b( --force)?$' "$FAKE_DIR/agent-sandbox.calls" "the sandbox is removed after the refusal"
assert_eq "$(remote_head)" "$RPRE" "nothing pushed"

mk_irepo; istatus irepo-0000000a:7; iconfig 'INTEGRATE_GATE_WHERE=sandbox'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
rm -f "$FAKE_DIR/agent-sandbox.calls"
export FAKE_RUN_ID='../evil'
run_int irepo-0000000a
unset FAKE_RUN_ID
[[ "$IRC" != 0 ]] && pass "an unreadable sandbox id fails ($IRC)" || fail "an invalid id exited 0"
assert_not_grep '^rm' "$FAKE_DIR/agent-sandbox.calls" "an invalid id is never passed to rm"
mk_irepo; istatus irepo-0000000a:7; iconfig 'INTEGRATE_GATE_WHERE=elsewhere'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
PRE="$(g rev-parse HEAD)"
run_int irepo-0000000a
assert_eq "$IRC" 2 "an unknown INTEGRATE_GATE_WHERE is refused"
assert_eq "$(g rev-parse HEAD)" "$PRE" "before merging"

# ================================================================ U2.10 concurrent port allocation
scenario "ports: two host gates at once hold different registered ports before either binds"
mk_irepo; istatus irepo-0000000a:7
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
IR2="$T/irepo2"; BARE2="$T/iremote2.git"; ITMP2="$T/itmp2"
rm -rf "$IR2" "$BARE2" "$ITMP2" "$T"/ports.? "$T"/registry.?; mkdir -p "$ITMP2" "$IR/logs/milestones"
cp -a "$IR" "$IR2"; cp -a "$BARE" "$BARE2"; git -C "$IR2" remote set-url origin "$BARE2"
rm -rf "$IR2/logs"; ln -s "$IR/logs" "$IR2/logs"   # one project's logs, so one registry
cat > "$T/portstep.sh" <<EOF
echo "\$GATE_PORT_1 \$GATE_PORT_2 \$GATE_PORT_3 \$GATE_PORT_4" > "$T/ports.\$1"
for i in \$(seq 300); do [ -e "$T/ports.\$2" ] && break; sleep 0.1; done
cp "$IR/logs/milestones/ports.registry" "$T/registry.\$1"
for i in \$(seq 300); do [ -e "$T/registry.\$2" ] && break; sleep 0.1; done   # neither ends before both looked
test -e "$T/ports.\$2"
EOF
iconfig "GATE=\"bash $T/portstep.sh a b\"" 'GATE_PORT_RANGE=41100-41139'
printf '%s\n' 'REPORT_DIR=docs/reports' "GATE=\"bash $T/portstep.sh b a\"" 'GATE_PORT_RANGE=41100-41139' > "$IR2/.milestones/config"
set +e
(cd "$IR" && TMPDIR="$ITMP" "$DRIVER" integrate irepo-0000000a) > "$T/pa.out" 2>&1 & PA=$!
(cd "$IR2" && TMPDIR="$ITMP2" "$DRIVER" integrate irepo-0000000a) > "$T/pb.out" 2>&1 & PB=$!
wait "$PA"; RA=$?; wait "$PB"; RB=$?
set -e
assert_eq "$RA $RB" "0 0" "both gates pass ($(tail -n 2 "$T/pa.out" | tr '\n' ' ') / $(tail -n 2 "$T/pb.out" | tr '\n' ' '))"
ALL="$(cat "$T/ports.a" "$T/ports.b" 2>/dev/null | tr ' ' '\n' | grep -c . || true)"
assert_eq "$ALL" 8 "eight ports handed out"
assert_eq "$(cat "$T/ports.a" "$T/ports.b" 2>/dev/null | tr ' ' '\n' | grep . | sort -u | wc -l)" 8 "no port handed to both runs"
assert_eq "$(cat "$T/ports.a" "$T/ports.b" 2>/dev/null | tr ' ' '\n' | grep . | awk '$1 < 41100 || $1 > 41139' | wc -l)" 0 "all inside GATE_PORT_RANGE"
assert_eq "$(cat "$T/registry.a" "$T/registry.b" 2>/dev/null | grep -c '^[0-9]' || true)" 16 "while both ran, the registry held all eight, seen from each run"
assert_eq "$(grep -c '^[0-9]' "$IR/logs/milestones/ports.registry" 2>/dev/null || true)" 0 "both released their ports"

# ================================================================ U2.11 bound and registered ports
scenario "ports: a bound port and a live registration are skipped; a dead holder's registration is pruned"
mk_irepo; istatus irepo-0000000a:7
iconfig "GATE=\"echo \\\$GATE_PORT_1 \\\$GATE_PORT_2 \\\$GATE_PORT_3 \\\$GATE_PORT_4 > $T/ports.c\"" 'GATE_PORT_RANGE=41150-41155'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"; sb_report irepo-0000000a 7
rm -f "$T/ports.c" "$T/bound"
python3 -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 41150)); s.listen(1)
open(sys.argv[1], "w").close(); time.sleep(60)' "$T/bound" & LISTENER=$!
for i in $(seq 50); do [[ -e "$T/bound" ]] && break; sleep 0.1; done
true & DEAD=$!; wait "$DEAD"
mkdir -p "$IR/logs/milestones"
printf '41151 other-run %s 2026-09-17T00:00:00\n41152 dead-run %s 2026-09-17T00:00:00\n' "$$" "$DEAD" > "$IR/logs/milestones/ports.registry"
run_int irepo-0000000a
kill "$LISTENER" 2>/dev/null || true; wait "$LISTENER" 2>/dev/null || true
assert_eq "$IRC" 0 "the gate passes ($(tail -n 2 "$T/int.out" | tr '\n' ' '))"
assert_eq "$(tr ' ' '\n' < "$T/ports.c" 2>/dev/null | grep . | sort | tr '\n' ' ')" "41152 41153 41154 41155 " "the bound 41150 and the live 41151 are skipped; the dead holder's 41152 is reused"
assert_eq "$(grep '^[0-9]' "$IR/logs/milestones/ports.registry" | cut -d' ' -f1-2)" "41151 other-run" "only the live registration remains"

# ================================================================ U8 init
NR_="$T/newrepo"
mk_newrepo() { rm -rf "$NR_" "$FAKE_DIR"/systemd-run.*; git init -q -b main "$NR_"; }
run_init() {  # init <args> from <dir>; output in $T/init.out, exit code in INRC
  local dir="$1"; shift
  set +e; (cd "$dir" && "$DRIVER" init "$@") > "$T/init.out" 2>&1; INRC=$?; set -e
}
INIT_TARGETS=(.milestones/config .milestones/standing-rules.md .milestones/STATUS.md .compound-engineering/config.yaml compound-packs/milestones/README.md .gitignore)

scenario "init in an empty git repo writes every target, and config 1 reads the template"
mk_newrepo
run_init "$NR_"
assert_eq "$INRC" 0 "init exits 0"
for f in "${INIT_TARGETS[@]}"; do
  [[ -s "$NR_/$f" ]] && pass "$f written" || fail "$f missing or empty"
done
assert_grep '^wrote \.milestones/config$' "$T/init.out" "reports config as wrote"
assert_grep '^wrote compound-packs/milestones/README\.md$' "$T/init.out" "reports the pack README as wrote"
assert_grep 'MILESTONES_FILE' "$T/init.out" "the owner is told to fill MILESTONES_FILE"
assert_grep '\bGATE\b' "$T/init.out" "the owner is told to fill GATE"
assert_grep 'SEED_PATHS' "$T/init.out" "the owner is told about SEED_PATHS"
assert_grep 'compound-packs/milestones' "$T/init.out" "the owner is told to write the pack's rules"
assert_eq "$(grep -cx 'logs/' "$NR_/.gitignore")" 1 "logs/ ignored once"
assert_eq "$(grep -cx '.milestones/config.local' "$NR_/.gitignore")" 1 ".milestones/config.local ignored once"
assert_grep '^packs:' "$NR_/.compound-engineering/config.yaml" "CE config names packs"
assert_grep 'source: compound-packs/milestones' "$NR_/.compound-engineering/config.yaml" "CE config points at the milestones pack"
HDR="$(sed -n 's/^#   \(| Milestone | Lane .*|\)$/\1/p' "$DRIVER")"
[[ -n "$HDR" ]] && grep -Fqx -- "$HDR" "$NR_/.milestones/STATUS.md" && pass "STATUS.md header matches the driver's" || fail "STATUS.md header differs from the driver's ('$HDR')"
assert_grep 'Test expectation changes' "$NR_/.milestones/standing-rules.md" "standing rules carry the test-integrity rule"
assert_grep 'gate pass' "$NR_/.milestones/standing-rules.md" "standing rules carry the evidence-line rule"
assert_grep 'ce-work mode:return-to-caller' "$NR_/.milestones/standing-rules.md" "standing rules carry the CE sequence with headless tokens"
assert_grep 'nobody to ask' "$NR_/.milestones/standing-rules.md" "standing rules say there is nobody to ask"
assert_grep 'Owner actions needed' "$NR_/.milestones/standing-rules.md" "standing rules carry the report contract"
assert_grep '[Ii]nline' "$NR_/.milestones/standing-rules.md" "standing rules carry the inline-work rule"
set +e; (cd "$NR_" && "$DRIVER" config 1) > "$T/init.cfg" 2>&1; rc=$?; set -e
assert_eq "$rc" 0 "config 1 exits 0 after init"
assert_grep '^MODEL=opus$' "$T/init.cfg" "config 1 prints MODEL=opus from the template"
assert_grep '^LANE=main$' "$T/init.cfg" "config 1 prints LANE=main"
assert_grep '^GATE=$' "$T/init.cfg" "the template's GATE is empty until the owner sets it"
set +e; (cd "$NR_" && "$DRIVER" 1 --sandbox "$(basename "$NR_")-00000000" --gate) > "$T/init.gate" 2>&1; rc=$?; set -e
assert_eq "$rc" 2 "an un-edited template GATE refuses --gate"
assert_grep '\bGATE\b' "$T/init.gate" "and names GATE"

scenario "init keeps an existing .milestones/config byte-identical"
mk_newrepo; mkdir -p "$NR_/.milestones"
printf 'GATE="make check"\n# mine\n' > "$NR_/.milestones/config"
SUM="$(sha256sum < "$NR_/.milestones/config")"
run_init "$NR_"
assert_eq "$INRC" 0 "init exits 0"
assert_eq "$(sha256sum < "$NR_/.milestones/config")" "$SUM" "config byte-identical"
assert_grep '^kept \.milestones/config$' "$T/init.out" "reports config as kept"
assert_grep '^wrote \.milestones/standing-rules\.md$' "$T/init.out" "the absent targets are still written"

scenario "init twice adds no duplicate ignore lines and keeps everything"
mk_newrepo; printf 'node_modules' > "$NR_/.gitignore"   # no trailing newline
run_init "$NR_"; run_init "$NR_"
assert_eq "$INRC" 0 "second init exits 0"
assert_eq "$(grep -cx 'logs/' "$NR_/.gitignore")" 1 "logs/ once"
assert_eq "$(grep -cx '.milestones/config.local' "$NR_/.gitignore")" 1 ".milestones/config.local once"
assert_eq "$(grep -cx 'node_modules' "$NR_/.gitignore")" 1 "the existing last line stays whole"
assert_not_grep '^wrote ' "$T/init.out" "the second run writes nothing"
assert_grep '^kept \.compound-engineering/config\.yaml$' "$T/init.out" "the second run reports kept"

scenario "init outside a git top-level refuses"
mk_newrepo; mkdir -p "$NR_/sub"
run_init "$NR_/sub"
assert_eq "$INRC" 2 "a subdirectory of a repo refuses"
assert_grep 'top level|top-level' "$T/init.out" "the message names the top level"
[[ -e "$NR_/sub/.milestones" || -e "$NR_/.milestones" ]] && fail "init wrote .milestones outside the top level" || pass "nothing written"
mkdir -p "$T/notgit"
run_init "$T/notgit"
assert_eq "$INRC" 2 "a directory outside any repo refuses"
[[ -e "$T/notgit/.milestones" ]] && fail "init wrote into a non-repo" || pass "nothing written"
set +e; (cd "$NR_/sub" && "$DRIVER" status) > "$T/init.nom" 2>&1; rc=$?; set -e
assert_eq "$rc" 2 "other verbs still need .milestones/"
assert_grep 'no \.milestones/' "$T/init.nom" "with the old message"

scenario "after init, a one-milestone spec and a GATE: prompt 1 prints the assembled prompt; --gate without --sandbox still dies"
mk_newrepo; run_init "$NR_"
mkdir -p "$NR_/docs"
printf '# Milestones\n\n## Milestone 1\n\nBuild the first thing. Exit: one count.\n\n## Milestone 2\n\nsecond.\n' > "$NR_/docs/milestones.md"
sed -i 's#^MILESTONES_FILE=.*#MILESTONES_FILE=docs/milestones.md#; s#^GATE=.*#GATE="true"#' "$NR_/.milestones/config"
set +e; (cd "$NR_" && "$DRIVER" prompt 1) > "$T/init.prompt" 2> "$T/init.prompt.err"; rc=$?; set -e
assert_eq "$rc" 0 "prompt 1 exits 0"
assert_grep '^Milestone 1 of docs/milestones\.md\.' "$T/init.prompt" "pointer to the spec section"
assert_grep '^## Milestone 1$' "$T/init.prompt" "the spec section, verbatim"
assert_grep 'Build the first thing' "$T/init.prompt" "the section's body"
assert_not_grep 'second\.' "$T/init.prompt" "only milestone 1's section"
assert_grep 'ce-work mode:return-to-caller' "$T/init.prompt" "the standing rules"
assert_grep 'docs/reports/milestone-1\.md' "$T/init.prompt" "REPORT_DIR and milestone-N substituted"
assert_not_grep 'milestone-N' "$T/init.prompt" "no unsubstituted milestone-N"
assert_grep '^When the exit criteria are met, or you have measured why one is not, stop\.$' "$T/init.prompt" "the stop rule last"
assert_eq "$(tail -n 1 "$T/init.prompt")" "When the exit criteria are met, or you have measured why one is not, stop." "stop rule is the last line"
cmp -s "$T/init.prompt" "$NR_/logs/milestones/milestone-1.prompt" && pass "the same prompt written to logs/milestones/milestone-1.prompt" || fail "logs/milestones/milestone-1.prompt differs or is missing"
[[ -f "$FAKE_DIR/systemd-run.count" ]] && fail "prompt launched a unit" || pass "prompt launches nothing"
set +e; (cd "$NR_" && "$DRIVER" prompt 3) > "$T/init.p3" 2>&1; rc=$?; set -e
assert_eq "$rc" 2 "prompt for a milestone with no section refuses"
assert_grep '## Milestone 3' "$T/init.p3" "and names the missing section"
set +e; (cd "$NR_" && "$DRIVER" 1 --gate) > "$T/init.g" 2>&1; rc=$?; set -e
assert_eq "$rc" 2 "--gate without --sandbox dies"
assert_grep '--gate needs --sandbox' "$T/init.g" "with the existing message"
[[ -f "$FAKE_DIR/systemd-run.count" ]] && fail "a unit was created" || pass "no unit created"
echo
(( FAILS == 0 )) || { echo "$FAILS ASSERTIONS FAILED" >&2; exit 1; }
echo "ALL $N SCENARIOS PASSED"
