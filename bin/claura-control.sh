#!/usr/bin/env bash
# bin/claura-control.sh
#
# Hook dispatcher. Wired to UserPromptSubmit/PreToolUse/PostToolUse/Stop/
# PermissionRequest/StopFailure/Notification/SessionEnd. Invoked with one of:
#   working | idle | end
# plus the hook payload on stdin.
#
# Responsibilities:
#   - OS gate; lazy bootstrap on fresh installs.
#   - Honor inert-on-legacy: stay silent if the standalone-prototype install
#     is still wired in the user's settings.json.
#   - Root-mismatch killswitch: if the player was spawned from a different
#     plugin root (i.e. `claude plugin update` swapped paths), kill it so the
#     reconcile step respawns it from the current root.
#   - Register/unregister this session under an mkdir lock.
#   - Reconcile: spawn player if any session is active AND enabled AND !muted;
#     kill player if none active OR disabled OR muted.
#
# All state mutations are serialized with an mkdir lock (macOS has no flock).

set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/_lib.sh
source "$SELF_DIR/_lib.sh"

os_detect >/dev/null

DATA_DIR=$(claura_data_dir)
STATE_DIR="$DATA_DIR/state"
SESSIONS_DIR="$STATE_DIR/sessions"
BASELINE_DIR="$STATE_DIR/baseline"
PLAYER_PID_FILE="$STATE_DIR/player.pid"
PLAYER_ROOT_FILE="$STATE_DIR/player.root"
LOCK_DIR="$STATE_DIR/lock.d"
BOOTSTRAPPED="$DATA_DIR/.bootstrapped"
LEGACY_DETECTED="$DATA_DIR/.legacy-detected"
LEGACY_CLEARED="$DATA_DIR/.legacy-cleared"
PLAYER="$SELF_DIR/claura-player.sh"

LOCK_TIMEOUT_SECS=5
# Controller-side staleness ceiling. Fine-grained HYSTERESIS lives in the
# player (with the CPU sampler). Matches the prototype's value.
MAX_STALE=75
DEBUG="${CLAURA_DEBUG:-${CLAUDE_AUDIO_DEBUG:-0}}"

# --- lazy bootstrap on first hook --------------------------------------------
# Covers the "installed mid-session" case where SessionStart already fired
# before the plugin existed. Run as a subprocess with /dev/null stdin so it
# does not consume the hook payload meant for us.
if [[ ! -f "$BOOTSTRAPPED" ]]; then
  "$SELF_DIR/claura-bootstrap.sh" </dev/null >/dev/null 2>&1 || true
fi

# --- inert-on-legacy ---------------------------------------------------------
# If the standalone prototype is still wired in the user's settings.json,
# stay silent until they touch .legacy-cleared. Touching nothing here keeps
# the plugin from corrupting state that the prototype owns.
if [[ -f "$LEGACY_DETECTED" && ! -f "$LEGACY_CLEARED" ]]; then
  exit 0
fi

mkdir -p "$SESSIONS_DIR" "$BASELINE_DIR"
cmd="${1:-}"
[[ -z "$cmd" ]] && exit 0

# --- session_id from stdin JSON ---------------------------------------------
input=""
[[ ! -t 0 ]] && input=$(cat 2>/dev/null || true)
session_id=""
hook_evt=""
if [[ -n "$input" ]] && command -v jq >/dev/null 2>&1; then
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
  hook_evt=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
fi
[[ -z "$session_id" ]] && session_id="pid-$PPID"
session_id=$(printf '%s' "$session_id" | tr -cd 'a-zA-Z0-9-')

# --- find the Claude Code PID by walking up the process tree ----------------
# The hook runs several levels below Claude Code: claude -> shell -> this
# script. We must match the EXECUTABLE name (`claude`), not the command line —
# the shell's command line contains the ".claude/" directory path and would
# match a naive substring test, pinning us to the short-lived hook shell.
# Claude Code's executable basename is "claude" (or "node" running a claude
# cli.js). Climb up to 10 levels.
find_claude_pid() {
  local pid="$PPID" base cmdline
  for _ in $(seq 1 10); do
    [[ -z "$pid" || "$pid" -le 1 ]] && break
    base=$(ps -o comm= -p "$pid" 2>/dev/null); base=${base##*/}
    if [[ "$base" == "claude" ]]; then echo "$pid"; return; fi
    if [[ "$base" == node* ]]; then
      cmdline=$(ps -o command= -p "$pid" 2>/dev/null)
      [[ "$cmdline" == *claude* ]] && { echo "$pid"; return; }
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  echo ""   # unknown -> player falls back to timestamp staleness
}
claude_pid=$(find_claude_pid)

if [[ "$DEBUG" == "1" ]]; then
  echo "$(date '+%H:%M:%S') cmd=$cmd evt=${hook_evt:-?} sid=${session_id:0:8} cpid=$claude_pid" \
    >> "$STATE_DIR/events.log" 2>/dev/null || true
fi

# --- acquire lock (mkdir; steal if the owner PID is dead) -------------------
acquired=false
deadline=$(( $(date_epoch) + LOCK_TIMEOUT_SECS ))
while (( $(date_epoch) < deadline )); do
  if mkdir "$LOCK_DIR" 2>/dev/null; then acquired=true; break; fi
  if [[ -f "$LOCK_DIR/owner" ]]; then
    owner=$(cat "$LOCK_DIR/owner" 2>/dev/null || echo "")
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$LOCK_DIR"; continue
    fi
  fi
  sleep 0.05
done
[[ "$acquired" == true ]] || exit 0
echo "$$" > "$LOCK_DIR/owner"
trap 'rm -rf "$LOCK_DIR"' EXIT

# --- root-mismatch killswitch ----------------------------------------------
# If a player is running but was spawned from a different ${CLAUDE_PLUGIN_ROOT}
# (e.g. `claude plugin update` swapped the install path), kill it so the
# reconcile step below respawns it from the current root.
CURRENT_ROOT=$(claura_root_dir)
if [[ -f "$PLAYER_PID_FILE" && -f "$PLAYER_ROOT_FILE" && -n "$CURRENT_ROOT" ]]; then
  recorded_root=$(cat "$PLAYER_ROOT_FILE" 2>/dev/null || echo "")
  if [[ -n "$recorded_root" && "$recorded_root" != "$CURRENT_ROOT" ]]; then
    stale_pid=$(cat "$PLAYER_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$stale_pid" ]] && kill -0 "$stale_pid" 2>/dev/null; then
      kill "$stale_pid" 2>/dev/null || true
    fi
    rm -f "$PLAYER_PID_FILE" "$PLAYER_ROOT_FILE"
  fi
fi

# --- apply event ------------------------------------------------------------
# On idle/end we remove the .cpu sidecar and any baseline state under the
# same lock. The watcher in the player writes the sidecar WITHOUT the lock,
# so the controller must remove main + sidecar atomically to prevent a stray
# sidecar `touch` right after rm from creating a ghost session.
case "$cmd" in
  working)
    echo "$claude_pid" > "$SESSIONS_DIR/$session_id"
    ;;
  idle|end)
    rm -f "$SESSIONS_DIR/$session_id" \
          "$SESSIONS_DIR/$session_id.cpu" \
          "$BASELINE_DIR/$session_id" \
          "$BASELINE_DIR/$session_id.degraded"
    ;;
  *) exit 0 ;;
esac

# --- count live sessions ----------------------------------------------------
# Controller-side count uses MAX_STALE (the degradation floor); fine-grained
# HYSTERESIS lives in the player. Skip .cpu sidecars (metadata, not sessions).
now=$(date_epoch)
active=0
shopt -s nullglob
for f in "$SESSIONS_DIR"/*; do
  [[ "$f" == *.cpu ]] && continue
  pid=$(cat "$f" 2>/dev/null)
  mtime=$(stat_mtime "$f")
  if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$f" "$f.cpu" "$BASELINE_DIR/$(basename "$f")" "$BASELINE_DIR/$(basename "$f").degraded"
    continue
  fi
  if (( now - mtime >= MAX_STALE )); then
    rm -f "$f" "$f.cpu" "$BASELINE_DIR/$(basename "$f")" "$BASELINE_DIR/$(basename "$f").degraded"
    continue
  fi
  active=$((active+1))
done

# --- is the player running? -------------------------------------------------
player_alive=false
player_pid=""
if [[ -f "$PLAYER_PID_FILE" ]]; then
  player_pid=$(cat "$PLAYER_PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$player_pid" ]] && kill -0 "$player_pid" 2>/dev/null; then
    player_alive=true
  else
    rm -f "$PLAYER_PID_FILE" "$PLAYER_ROOT_FILE"
  fi
fi

# --- read enabled/muted from config (defaults: enabled=true, muted=false) ---
enabled=$(claura_cfg_get enabled true)
muted=$(claura_cfg_get muted false)
playable=true
if [[ "$enabled" != "true" ]] || [[ "$muted" == "true" ]]; then
  playable=false
fi

# --- reconcile --------------------------------------------------------------
# Active session + nothing playing + audio allowed → spawn.
# Otherwise (no active session OR audio disabled) and a player is running →
# kill it. We keep session files around when audio is just muted/disabled so
# re-enabling re-engages from the same state on the next hook tick.
if (( active > 0 )) && [[ "$player_alive" == false ]] && [[ "$playable" == true ]]; then
  /usr/bin/env bash "$PLAYER" </dev/null >/dev/null 2>&1 &
  echo $! > "$PLAYER_PID_FILE"
  if [[ -n "$CURRENT_ROOT" ]]; then
    echo "$CURRENT_ROOT" > "$PLAYER_ROOT_FILE"
  fi
elif [[ "$player_alive" == true ]] && { (( active == 0 )) || [[ "$playable" == false ]]; }; then
  kill "$player_pid" 2>/dev/null || true
  rm -f "$PLAYER_PID_FILE" "$PLAYER_ROOT_FILE"
fi

exit 0
