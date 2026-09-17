#!/usr/bin/env bash
# Take a fresh Linux or WSL machine to the full stack. Rerunnable: every step checks
# first and skips when already satisfied.
#
#   scripts/bootstrap.sh [--dry-run] [--with-sudo] [--phase N[,N]]...
#
#   --dry-run     print what each phase would do; change nothing
#   --with-sudo   run the sudo steps (apt packages, rootless Docker, linger) instead of
#                 printing them; only honoured when sudo needs no password
#   --phase N     run only these phases (repeatable or comma separated)
#
# Phases: 1 host tools, 2 agent-sandbox, 3 rootless Docker, 4 image, admission and
# memory log, 5 skills, plugins and managed config, 6 readiness check and logins.
#
# Environment: CLAUDE_HOME (default ~/.claude), AGENT_SANDBOX_DIR (default
# ~/agent-sandbox), NVM_DIR (default ~/.nvm).
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="${CLAUDE_HOME:-$HOME/.claude}"
SANDBOX_DIR="${AGENT_SANDBOX_DIR:-$HOME/agent-sandbox}"
SANDBOX_REPO="https://github.com/bishalu/agent-sandbox.git"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
TOOLS="$R/src/host-tools.txt"
LOCAL_BIN="$HOME/.local/bin"
ROOTLESS_SOCK="unix:///run/user/$(id -u)/docker.sock"

DRY=0; WITH_SUDO=0; PHASES=""
usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --with-sudo) WITH_SUDO=1 ;;
    --phase) [ $# -ge 2 ] || { usage; exit 2; }; PHASES="${PHASES:+$PHASES,}$2"; shift ;;
    --phase=*) PHASES="${PHASES:+$PHASES,}${1#--phase=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1"; usage; exit 2 ;;
  esac
  shift
done
case ",$PHASES," in *[!0-9,]*) echo "--phase takes numbers 1-6"; exit 2 ;; esac

export PATH="$LOCAL_BIN:$PATH"
PENDING=()

# ---------------------------------------------------------------- helpers
phase() { printf '\n== phase %s: %s\n' "$1" "$2"; }
say() { printf '   %s\n' "$*"; }
pending() { PENDING+=("$*"); }
wants() { [ -z "$PHASES" ] || [[ ",$PHASES," == *",$1,"* ]]; }
# Run a command line (a string, so pipelines work), or print it under --dry-run.
act() {
  if [ "$DRY" = 1 ]; then say "would run: $1"; else say "+ $1"; bash -c "$1"; fi
}
have() { command -v "$1" >/dev/null 2>&1; }
sudo_ok() { [ "$WITH_SUDO" = 1 ] && have sudo && sudo -n true 2>/dev/null; }
denv() { DOCKER_HOST="${DOCKER_HOST:-$ROOTLESS_SOCK}" "$@"; }
docker_ok() { have docker && denv timeout 15 docker info >/dev/null 2>&1; }
sandbox_running() {
  docker_ok && [ -n "$(denv docker ps -q --filter label=agent-sandbox.managed=true 2>/dev/null)" ]
}
# Ask the agent-sandbox package a yes/no question without going through its CLI.
sandbox_py() { PYTHONPATH="$SANDBOX_DIR" python3 -c "$1" 2>/dev/null || echo no; }

[ "$DRY" = 1 ] && echo "dry run: nothing below is changed"

# ---------------------------------------------------------------- 1 host tools
if wants 1; then
  phase 1 "host tools ($TOOLS)"
  node_bin=""
  while read -r name method spec <&3; do
    case "$name" in ''|\#*) continue ;; esac
    case "$method" in
      system)
        if have "$name"; then say "ok       $name"
        elif [ "$name" = aws ]; then
          say "missing  aws: user-local install, needs curl and unzip:"
          say "  curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-\$(uname -m).zip -o /tmp/awscliv2.zip && unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install -i ~/.local/aws-cli -b ~/.local/bin"
          pending "install the AWS CLI (hint printed in phase 1)"
        elif sudo_ok; then act "sudo apt-get install -y $spec"
        else
          say "missing  $name: sudo apt-get install -y $spec"
          pending "sudo apt-get install -y $spec"
        fi ;;
      uv-installer)
        if have uv; then say "ok       uv ($(uv --version 2>/dev/null))"
        elif ! have curl; then say "blocked  uv: needs curl"; pending "install curl, then rerun for uv"
        else act "curl -LsSf https://astral.sh/uv/$spec/install.sh | env UV_NO_MODIFY_PATH=1 sh"
        fi ;;
      uv-tool)
        if have "$name"; then say "ok       $name ($("$name" --version 2>/dev/null | head -1))"
        elif ! have uv && [ "$DRY" = 0 ]; then say "blocked  $name: needs uv"; pending "install uv, then rerun for $name"
        else act "uv tool install '$spec'"
        fi ;;
      nvm)
        if [ -s "$NVM_DIR/nvm.sh" ]; then say "ok       nvm ($NVM_DIR)"
        elif ! have curl; then say "blocked  nvm: needs curl"; pending "install curl, then rerun for nvm"
        else act "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/$spec/install.sh | NVM_DIR='$NVM_DIR' bash"
        fi ;;
      node)
        node_bin="$NVM_DIR/versions/node/v$spec/bin"
        if [ -x "$node_bin/node" ]; then say "ok       node v$spec ($node_bin)"
        elif [ ! -s "$NVM_DIR/nvm.sh" ] && [ "$DRY" = 0 ]; then say "blocked  node: needs nvm"; pending "install nvm, then rerun for node"
        else act "export NVM_DIR='$NVM_DIR'; . '$NVM_DIR/nvm.sh' && nvm install '$spec'"
        fi ;;
      npm-global)
        want="${spec##*@}"
        [ -n "$node_bin" ] || { echo "host-tools.txt: $name needs a node row before it"; exit 1; }
        got="$(PATH="$node_bin:$PATH" "$node_bin/$name" --version 2>/dev/null || true)"
        if [ "$got" = "$want" ]; then say "ok       $name $want (under $node_bin)"
        elif [ ! -x "$node_bin/npm" ] && [ "$DRY" = 0 ]; then say "blocked  $name: needs node"; pending "install node, then rerun for $name"
        else act "PATH='$node_bin':\"\$PATH\" npm install -g '$spec'"
        fi ;;
      claude)
        if have claude; then say "ok       claude ($(claude --version 2>/dev/null | head -1))"
        elif ! have curl; then say "blocked  claude: needs curl"; pending "install curl, then rerun for claude"
        else act "curl -fsSL https://claude.ai/install.sh | bash"
        fi ;;
      *) echo "host-tools.txt: unknown method '$method' for $name"; exit 1 ;;
    esac
  done 3< "$TOOLS"
  case ":$(bash -lc 'echo $PATH' 2>/dev/null):" in
    *":$LOCAL_BIN:"*) ;;
    *) say "note     $LOCAL_BIN is not on a login shell's PATH; add it to ~/.profile"
       pending "put $LOCAL_BIN on PATH in ~/.profile" ;;
  esac
fi

# ---------------------------------------------------------------- 2 agent-sandbox
if wants 2; then
  phase 2 "agent-sandbox ($SANDBOX_DIR)"
  if [ -d "$SANDBOX_DIR/.git" ]; then
    if sandbox_running; then
      say "skip     pull: a sandbox container is running; pull between runs"
    elif [ "$DRY" = 1 ]; then
      say "would run: git -C $SANDBOX_DIR pull --ff-only"
    else
      say "+ git -C $SANDBOX_DIR pull --ff-only"
      git -C "$SANDBOX_DIR" pull --ff-only || {
        say "warn     pull did not fast-forward; left $SANDBOX_DIR as it is"
        pending "reconcile $SANDBOX_DIR with its upstream (pull --ff-only failed)"; }
    fi
  elif ! have git && [ "$DRY" = 0 ]; then
    say "blocked  clone: needs git"; pending "install git, then rerun phase 2"
  else
    act "git clone $SANDBOX_REPO '$SANDBOX_DIR'"
  fi
  # The documented install is one symlink onto PATH (agent-sandbox PLAN.md).
  link="$LOCAL_BIN/agent-sandbox"; target="$SANDBOX_DIR/bin/agent-sandbox"
  if [ "$(readlink "$link" 2>/dev/null)" = "$target" ]; then say "ok       $link -> $target"
  elif [ -e "$link" ] && [ ! -L "$link" ]; then
    say "warn     $link exists and is not a symlink; left alone"
    pending "replace $link with a symlink to $target"
  else act "mkdir -p '$LOCAL_BIN' && ln -sfn '$target' '$link'"
  fi
fi

# ---------------------------------------------------------------- 3 rootless Docker
# The exact lines from the agent-sandbox README, with Docker's apt repository spelled out.
DOCKER_SUDO=(
  'sudo apt-get install -y ca-certificates curl iptables uidmap dbus-user-session slirp4netns fuse-overlayfs'
  'sudo install -m 0755 -d /etc/apt/keyrings'
  'sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc'
  'sudo chmod a+r /etc/apt/keyrings/docker.asc'
  'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null'
  'sudo apt-get update'
  'sudo apt-get install -y docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io'
  'sudo systemctl disable --now docker.service docker.socket'
)
DOCKER_USER=(
  'dockerd-rootless-setuptool.sh install'
  'systemctl --user enable --now docker'
)
LINGER='sudo loginctl enable-linger "$USER"'
if wants 3; then
  phase 3 "rootless Docker"
  if docker_ok; then
    say "ok       docker answers on ${DOCKER_HOST:-$ROOTLESS_SOCK}"
  else
    if ! have dockerd-rootless-setuptool.sh; then
      if sudo_ok; then
        for l in "${DOCKER_SUDO[@]}"; do act "$l"; done
      else
        say "missing  Docker packages. Run these (they need sudo), then rerun:"
        for l in "${DOCKER_SUDO[@]}" "${DOCKER_USER[@]}" "$LINGER"; do say "  $l"; done
        pending "rootless Docker: run the lines printed in phase 3"
      fi
    fi
    if have dockerd-rootless-setuptool.sh || { [ "$DRY" = 1 ] && sudo_ok; }; then
      for l in "${DOCKER_USER[@]}"; do act "$l"; done
      [ "$DRY" = 1 ] || docker_ok || { say "warn     docker still does not answer"; pending "rootless Docker does not answer; see agent-sandbox doctor"; }
    fi
  fi
fi

# ---------------------------------------------------------------- 4 image, admission, memlog
if wants 4; then
  phase 4 "image, admission and memory log"
  AS="$SANDBOX_DIR/bin/agent-sandbox"
  if ! docker_ok; then
    say "skip     docker does not answer (phase 3)"
    pending "rerun phase 4 once Docker works: image build, admission, memory log"
  elif sandbox_running; then
    say "skip     a sandbox container is running; rerun between runs"
    pending "rerun phase 4 when no sandbox runs"
  elif [ ! -x "$AS" ]; then
    say "skip     $AS missing (phase 2)"
    pending "rerun phase 4 once agent-sandbox is installed"
  else
    if [ "$(sandbox_py 'from agent_sandbox import image; print("no" if image.needs_build()[0] else "current")')" = current ]; then
      say "ok       image up to date"
    else act "'$AS' build"
    fi
    if [ "$(sandbox_py 'import json; from agent_sandbox import config; print("yes" if json.load(open(config.ROOT / "config.json")).get("admission_enabled") is True else "no")')" = yes ]; then
      say "ok       admission enabled"
    else act "'$AS' config set admission_enabled true"
    fi
    if [ "$(sandbox_py 'from agent_sandbox import admission as a, config as c
s = a.read_state(); b = a.resolve_settings(c.load_config()).budget
print("yes" if s and s.get("ok") and s.get("memory_max") == b else "no")')" = yes ]; then
      say "ok       admission slice cap installed"
    else act "'$AS' admission install"
    fi
    if [ "$(sandbox_py 'from agent_sandbox import memlog; print("yes" if memlog.timer_active() else "no")')" = yes ]; then
      say "ok       memory log timer active"
    else act "'$AS' memlog install"
    fi
    if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
      say "ok       linger enabled"
    elif sudo_ok; then act "$LINGER"
    else say "hint     $LINGER"; pending "$LINGER"
    fi
  fi
fi

# ---------------------------------------------------------------- 5 skills, plugins, config
if wants 5; then
  phase 5 "skills, plugins and managed config ($G)"
  # A fresh clone has no upstream/; fetch each source at its pinned commit so the build
  # matches what this checkout describes. Existing clones are left alone (sync.sh moves them).
  missing="$(python3 - "$R" <<'PY'
import json, os, sys
R = sys.argv[1]
for s in json.load(open(f"{R}/sources.json"))["sources"].values():
    d = os.path.join(R, "upstream", s["repo"].replace("/", "_"))
    if not os.path.isdir(os.path.join(d, ".git")):
        print(f"{s['repo']} {d} {s.get('pinnedSha', '')}")
PY
)"
  if [ -z "$missing" ]; then say "ok       upstream clones present"
  else
    while read -r repo dir sha <&3; do
      act "git clone --quiet https://github.com/$repo.git '$dir'${sha:+ && git -C '$dir' checkout --quiet $sha}"
    done 3<<< "$missing"
  fi
  if sandbox_running; then
    # A full install reinstalls plugins that running sandboxes mount.
    say "skip     full install: a sandbox container is running; config only for now"
    act "CLAUDE_HOME='$G' '$R/scripts/install.sh' --config-only"
    pending "run scripts/install.sh between milestones (a sandbox was running)"
  elif ! have claude && [ "$DRY" = 0 ]; then
    say "blocked  plugins need the claude CLI (phase 1); config only for now"
    act "CLAUDE_HOME='$G' '$R/scripts/install.sh' --config-only"
    pending "install claude, then rerun phase 5"
  else
    act "python3 '$R/scripts/build.py'"
    act "CLAUDE_HOME='$G' '$R/scripts/install.sh'"
  fi
fi

# ---------------------------------------------------------------- 6 readiness
if wants 6; then
  phase 6 "readiness"
  if have agent-sandbox || [ -x "$SANDBOX_DIR/bin/agent-sandbox" ]; then
    if [ "$DRY" = 1 ]; then say "would run: agent-sandbox doctor"
    else
      as_bin="$SANDBOX_DIR/bin/agent-sandbox"; [ -x "$as_bin" ] || as_bin=agent-sandbox
      "$as_bin" doctor || pending "agent-sandbox doctor reports failures (above)"
    fi
  else
    say "skip     agent-sandbox doctor: not installed"
  fi

  mark() { if eval "$1" >/dev/null 2>&1; then echo "[x]"; else echo "[ ]"; fi; }
  echo
  echo "Logins only the owner can do (never a host /login while a milestone sandbox runs:"
  echo "it revokes the agent's token):"
  echo "  $(mark "[ -s '$G/.credentials.json' ]") claude          run \`claude\`, then /login"
  echo "  $(mark 'gh auth status') gh              gh auth login"
  echo "  $(mark '[ -s ~/.aws/credentials ] || [ -s ~/.aws/config ]') AWS             aws configure (or aws configure sso)"
  echo "  $(mark '[ -s ~/.config/gcloud/credentials.db ]') gcloud          gcloud auth login"
  echo "  [ ] design          /design-login inside Claude Code"

  if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    distro="${WSL_DISTRO_NAME:-<distro>}"
    echo
    echo "Windows side (WSL), from a Windows terminal:"
    echo "  wsl --shutdown"
    echo "  wsl --manage $distro --set-sparse true      # sparseVhd=true only affects new VHDs"
    echo "  then in WSL: wsl.exe -u root -- fstrim -v /"
    echo "  %UserProfile%\\.wslconfig:"
    echo "    [wsl2]         memory=<leave Windows 16 GB>  swap=16GB"
    echo "    [experimental] sparseVhd=true  autoMemoryReclaim=dropCache"
  fi
fi

echo
if [ "${#PENDING[@]}" -eq 0 ]; then
  echo "Nothing else pending from the phases run."
else
  echo "Still to do:"
  for p in "${PENDING[@]}"; do echo "  - $p"; done
fi
