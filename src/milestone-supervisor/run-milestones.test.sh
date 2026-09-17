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
cat > "$FAKE_DIR/bin/agent-sandbox" <<'EOF'
#!/usr/bin/env bash
# One line per call; a multi-line bash -lc script has its newlines shown as \n.
all="$*"; printf '%s\n' "${all//$'\n'/\\n}" >> "$FAKE_DIR/agent-sandbox.calls"
case "$1" in
  status) cat "$FAKE_DIR/status.json" ;;
  run)    echo "[agent-sandbox] effective budget 16 GiB (config), floor 8 GiB (config)" >&2
          echo '{"sandbox_id": "'"${FAKE_RUN_ID:-proj-deadbeef}"'", "status": "completed", "exit_code": 0}' ;;
  enter)  rc="${FAKE_ENTER_RC:-0}"
          if [[ "$rc" == 3 ]]; then
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
assert_grep '^enter proj-deadbeef --timeout 30m --memory 12g --cpus 4 --tag unit=milestone-proj-6-T --tag milestone=6 --json -- bash -lc .*true.*test -s docs/reports/milestone-6.md' "$FAKE_DIR/agent-sandbox.calls" "gate tagged as a second call"
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
export FAKE_WS_ROOT="$T/gws"
GWS="$FAKE_WS_ROOT/proj-1a2b3c4d"; mkdir -p "$GWS/docs/reports"
git -C "$GWS" init -q -b main
echo "# Milestone 6 report" > "$GWS/docs/reports/milestone-6.md"
git -C "$GWS" add -A && git -C "$GWS" -c user.name=t -c user.email=t@t commit -q -m "milestone 6 report"
GSHA="$(git -C "$GWS" rev-parse HEAD | cut -c1-12)"
gate_inside() {  # run the gate-only unit body against proj-1a2b3c4d; its exit code in GRC
  set +e
  (cd "$PROJ" && FAKE_ENTER_EXEC=1 "$DRIVER" --inside 6 --sandbox proj-1a2b3c4d --unit u --gate "$@") > "$T/gate.out" 2>&1; GRC=$?
  set -e
}
GATELOG="$PROJ/logs/milestones/milestone-6.gate.log"

# ================================================================ 10. setup, then gate, then report check
scenario "GATE_SETUP runs before GATE before the report check, in one bash -lc"
reset; config_with 'GATE_SETUP="echo setup"' 'GATE="echo gate"'
gate_inside
assert_eq "$GRC" 0 "gate passes"
assert_eq "$(grep -c '^enter ' "$FAKE_DIR/agent-sandbox.calls")" 1 "one enter call"
assert_grep '^enter proj-1a2b3c4d .* -- bash -lc .*echo setup.*echo gate.*test -s docs/reports/milestone-6.md' "$FAKE_DIR/agent-sandbox.calls" "setup before gate before report check"
assert_eq "$(grep -Ex 'setup|gate' "$FAKE_DIR/runs/proj-1a2b3c4d/stdout.log" | tr '\n' ' ')" "setup gate " "setup ran before gate in the same shell"
assert_grep "^gate pass exit=0 milestone=6 sha=$GSHA where=sandbox setup=yes env=\"-\" at=[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$CHAIN" "evidence line in chain.log"
assert_grep "^gate pass exit=0 milestone=6 sha=$GSHA where=sandbox setup=yes " "$GATELOG" "evidence line appended to the gate log"

# ================================================================ 11. no setup
scenario "no GATE_SETUP: gate then report check, evidence says setup=none"
reset; config_with 'GATE="echo gate"'
gate_inside
assert_eq "$GRC" 0 "gate passes"
assert_grep '^enter proj-1a2b3c4d .* -- bash -lc .*echo gate.*test -s docs/reports/milestone-6.md' "$FAKE_DIR/agent-sandbox.calls" "gate then report check"
assert_not_grep 'echo setup' "$FAKE_DIR/agent-sandbox.calls" "no setup in the command"
assert_grep "^gate pass exit=0 milestone=6 sha=[0-9a-f]{12} where=sandbox setup=none " "$CHAIN" "setup=none, 12-character sha, where=sandbox"

# ================================================================ 12. GATE_ENV probe
scenario "GATE_ENV output lands in the evidence line"
reset; config_with 'GATE="echo gate"' 'GATE_ENV="echo catalog abc123; echo second line"'
gate_inside
assert_eq "$GRC" 0 "gate passes"
assert_grep "^gate pass exit=0 milestone=6 sha=$GSHA where=sandbox setup=none env=\"catalog abc123\" at=" "$CHAIN" "env carries the probe's first line"

# ================================================================ 13. failing gate and failing setup
scenario "a failing enter writes gate FAIL exit=1 and the unit fails"
reset; config_with 'GATE="echo gate"'
set +e; (cd "$PROJ" && FAKE_ENTER_RC=1 "$DRIVER" --inside 6 --sandbox proj-1a2b3c4d --unit u --gate) > /dev/null 2>&1; rc=$?; set -e
[[ "$rc" != 0 ]] && pass "unit exits non-zero ($rc)" || fail "failed gate exited 0"
assert_grep '^gate FAIL exit=1 milestone=6 sha=[0-9a-f]{12} where=sandbox setup=none ' "$CHAIN" "FAIL evidence line"
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
    sb_do "$1" "printf '%s\n' \"\$REPORT_BODY\" > docs/reports/milestone-$2.md" "milestone $2 report"
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
assert_grep "^gate pass exit=0 milestone=7 sha=$M12 where=host setup=none env=\"-\" at=" "$ICHAIN" "host evidence line for the merge"
assert_grep "^gate pass exit=0 milestone=7 sha=$M12 where=host " "$IR/logs/milestones/milestone-7.gate.log" "evidence in the gate log"
assert_eq "$(g show --name-only --format= HEAD)" ".milestones/STATUS.md" "the last commit touches only STATUS.md"
g show HEAD:.milestones/STATUS.md > "$T/st" 2>/dev/null || : > "$T/st"
assert_grep '^\| Milestone \| Lane \| Sandbox \| Merged \| Gate \| Unmet criteria \| Open blockers \| Next action \|$' "$T/st" "STATUS.md created with its header"
assert_grep "^\| 7 \| main \| irepo-0000000a \| $M12 \| pass $M12 [0-9]{4}-[0-9]{2}-[0-9]{2} \| - \| - \| - \|$" "$T/st" "row for milestone 7"
assert_eq "$(remote_head)" "$(g rev-parse HEAD)" "the remote's main equals the local head"
assert_grep "pushed .*$(g rev-parse --short=12 HEAD)" "$ICHAIN" "the pushed sha is logged"
assert_grep "pre-merge $PRE" "$ICHAIN" "the pre-merge sha is logged"

# ================================================================ U3.2 gate failure
scenario "integrate: a failing gate keeps the merge local and pushes nothing"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE="false"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
PRE="$(g rev-parse HEAD)"; RPRE="$(remote_head)"
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "integrate exits non-zero ($IRC)" || fail "failed gate exited 0"
assert_eq "$(remote_head)" "$RPRE" "the remote is unchanged"
assert_grep '^gate FAIL exit=1 milestone=7 sha=[0-9a-f]{12} where=host setup=none ' "$ICHAIN" "gate FAIL evidence"
assert_grep "pre-merge $PRE" "$ICHAIN" "the pre-merge sha is logged"
assert_grep "git reset --hard $PRE" "$ICHAIN" "the reset hint is logged"
assert_eq "$(g rev-list --merges --count origin/main..HEAD)" 1 "the merge commit stays local"
[[ -f "$IR/.milestones/STATUS.md" ]] && fail "STATUS.md written on a failed gate" || pass "no STATUS.md on a failed gate"

# ================================================================ U3.3 setup failure
scenario "integrate: a failing GATE_SETUP refuses the push and names setup"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE_SETUP="false"' 'GATE="touch gate-ran"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
RPRE="$(remote_head)"
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "integrate exits non-zero ($IRC)" || fail "setup failure exited 0"
assert_eq "$(remote_head)" "$RPRE" "the remote is unchanged"
assert_grep '^gate FAIL exit=1 milestone=7 .* where=host setup=yes ' "$ICHAIN" "FAIL evidence with setup=yes"
assert_grep 'milestone 7: host gate FAILED .*setup' "$ICHAIN" "the log names setup"

# ================================================================ U3.4 re-run after a fix
scenario "integrate: a re-run on the already-merged branch pushes without a second merge"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE="false"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "first run fails its gate" || fail "first run passed"
echo "fix" >> "$IR/app.txt"; g commit -q -am "fix forward on the integration branch"
iconfig 'GATE="true"'
run_int irepo-0000000a
assert_eq "$IRC" 0 "the re-run exits 0 ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
assert_eq "$(git --git-dir="$BARE" rev-list --merges --count main)" 1 "exactly one merge commit reached the remote"
assert_eq "$(remote_head)" "$(g rev-parse HEAD)" "the remote's main equals the local head"
assert_grep 'already merged' "$ICHAIN" "the re-run says the branch is already merged"
assert_grep "^gate pass exit=0 milestone=7 sha=$(g rev-parse --short=12 HEAD^) where=host " "$ICHAIN" "the gated sha is the fix commit under the STATUS commit"

# ================================================================ U3.5 merge conflict
scenario "integrate: a merge conflict aborts, leaves a clean tree, pushes nothing"
mk_irepo; istatus irepo-0000000a:7
sb_do irepo-0000000a "echo 'app sandbox' > app.txt" "milestone 7 work"
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
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
PRE="$(g rev-parse HEAD)"; echo "local edit" >> "$IR/tests/test_a.py"
run_int irepo-0000000a
assert_eq "$IRC" 2 "integrate refuses with 2"
assert_eq "$(g rev-parse HEAD)" "$PRE" "nothing merged"
assert_grep 'tracked changes' "$(int_out)" "the refusal names tracked changes"

# ================================================================ U3.7 wrong branch
scenario "integrate: INTEGRATION_BRANCH=main while on another branch refuses"
mk_irepo; istatus irepo-0000000a:7; iconfig 'INTEGRATION_BRANCH=main'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
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

# ================================================================ U3.12 another milestone's kept merge
scenario "integrate: milestone 8 refuses while milestone 7's failed merge is kept"
mk_irepo; istatus irepo-0000000a:7 irepo-0000000b:8; iconfig 'GATE="false"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
sb_do irepo-0000000b "echo 'other' > other.txt" "milestone 8 work"
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
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
cp "$IR/data/seed.txt" "$T/seed.before"
run_int irepo-0000000a
assert_eq "$IRC" 0 "integrate exits 0 ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
cmp -s "$T/seed.before" "$IR/data/seed.txt" && pass "the host's seed file is byte-identical" || fail "the host's seed file changed"
assert_grep '^gate pass exit=0 milestone=7 .* where=host setup=yes env="seed" ' "$ICHAIN" "setup ran on the copy and GATE_ENV was probed there"

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
  sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
  case "$variant" in
    owner)   sb_do irepo-0000000a "printf '# Evaluation 7\n\n- criterion 3: Owner Action Required (Spotify sign-in)\n' > .milestones/evaluation-7.md" "evaluation" ;;
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
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
run_int irepo-0000000a
assert_eq "$IRC" 0 "integrate exits 0 ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
M12="$(g rev-parse --short=12 HEAD^)"
g show HEAD:.milestones/STATUS.md > "$T/st" 2>/dev/null || : > "$T/st"
assert_grep "^\| 7 \| main \| irepo-0000000a \| $M12 \| pass $M12 [0-9-]{10} \| criterion 2 \| owner: sign in to Spotify \| review report \|$" "$T/st" "row 7 updated, supervisor cells kept"
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
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone work"
run_int irepo-0000000a
assert_eq "$IRC" 2 "no tag and no number: refused"
assert_grep 'milestone' "$T/int.out" "the refusal asks for the milestone"
run_int irepo-0000000c 8
assert_eq "$IRC" 2 "a positional number that contradicts the tag is refused"
set +e; (cd "$IR" && RUN_MILESTONES_NO_JQ=1 TMPDIR="$ITMP" "$DRIVER" integrate irepo-0000000a 5) > "$T/int.out" 2>&1; IRC=$?; set -e
assert_eq "$IRC" 0 "untagged with a positional 5 proceeds (python path) ($(tail -n 3 "$T/int.out" | tr '\n' ' '))"
assert_grep '^gate pass exit=0 milestone=5 .* where=host ' "$ICHAIN" "evidence names milestone 5"

# ================================================================ U3.19 missing host tool
scenario "integrate: a gate calling a tool the host lacks fails with exit 127"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE="no-such-tool-u3 check"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "integrate exits non-zero" || fail "exited 0"
assert_grep '^gate FAIL exit=127 milestone=7 .* where=host ' "$ICHAIN" "FAIL exit=127"

# ================================================================ U3.20 gate timeout
scenario "integrate: GATE_TIMEOUT bounds the host gate"
mk_irepo; istatus irepo-0000000a:7; iconfig 'GATE_TIMEOUT=1s' 'GATE="sleep 10"'
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "integrate exits non-zero" || fail "exited 0"
assert_grep '^gate FAIL exit=124 milestone=7 .* where=host ' "$ICHAIN" "FAIL exit=124"

# ================================================================ U3.21 other preconditions
scenario "integrate: no GATE, no upstream, behind upstream and an unknown branch refuse before merging"
mk_irepo; istatus irepo-0000000a:7
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
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
sb_do irepo-0000000a "echo 'app v2' > app.txt" "milestone 7 work"
RPRE="$(remote_head)"
run_int irepo-0000000a
[[ "$IRC" != 0 ]] && pass "integrate exits non-zero ($IRC)" || fail "a rejected push exited 0"
assert_eq "$(remote_head)" "$RPRE" "the remote is unchanged"
assert_grep 'push failed' "$ICHAIN" "chain.log says the push failed"
echo
(( FAILS == 0 )) || { echo "$FAILS ASSERTIONS FAILED" >&2; exit 1; }
echo "ALL $N SCENARIOS PASSED"
