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
assert_grep() { grep -Eq -- "$1" "$2" && pass "$3" || { echo "--- $2:" >&2; cat "$2" >&2; fail "$3 (no match for '$1')"; }; }
assert_not_grep() { grep -Eq -- "$1" "$2" && { echo "--- $2:" >&2; cat "$2" >&2; fail "$3 (unexpected match for '$1')"; } || pass "$3"; }
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

echo
(( FAILS == 0 )) || { echo "$FAILS ASSERTIONS FAILED" >&2; exit 1; }
echo "ALL $N SCENARIOS PASSED"
