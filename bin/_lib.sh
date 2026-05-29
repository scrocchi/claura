#!/usr/bin/env bash
# bin/_lib.sh
#
# Shared helpers sourced by every Claura script. Do not execute directly.
# Conventions:
#   - Caller scripts set their own `set -u` / `set -e`. We don't.
#   - All env vars referenced via ${VAR:-default} so we're safe under -u.
#   - macOS-only in 0.1.0; os_detect bails cleanly on other OSes.

# --- OS gate -----------------------------------------------------------------
# 0.1.0 is macOS-only. On any other OS we exit the CALLING script with code 0
# so hooks don't appear as failures. Stderr message is the only user-facing
# breadcrumb (visible via `claude --debug`).
os_detect() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) printf 'darwin\n' ;;
    *)
      echo "Claura 0.1.0 is macOS-only; Linux/Windows support coming in 0.2.0" >&2
      exit 0
      ;;
  esac
}

# --- paths -------------------------------------------------------------------
claura_data_dir() {
  printf '%s\n' "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claura}"
}

claura_root_dir() {
  printf '%s\n' "${CLAUDE_PLUGIN_ROOT:-}"
}

# --- config get --------------------------------------------------------------
# Usage: claura_cfg_get KEY DEFAULT
# Prints DEFAULT if config.json is missing, jq is missing, the key is absent,
# or jq yields "null". Always single-line stdout.
claura_cfg_get() {
  local key="$1" def="${2-}" cfg val
  cfg="$(claura_data_dir)/config.json"
  if [[ ! -f "$cfg" ]] || ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$def"
    return 0
  fi
  val=$(jq -r --arg k "$key" '.[$k] // empty' "$cfg" 2>/dev/null || true)
  if [[ -z "$val" || "$val" == "null" ]]; then
    val="$def"
  fi
  printf '%s\n' "$val"
}

# --- sound resolution --------------------------------------------------------
# Resolution order, in this priority:
#   1. ${CLAUDE_PLUGIN_DATA}/sounds/<name>.mp3   (user-dropped)
#   2. ${CLAUDE_PLUGIN_ROOT}/audio/<name>.mp3    (bundled)
# Falls back to "birds" by the same lookup if NAME does not resolve.
# Prints the absolute path on success; returns non-zero with no output if
# nothing is found.
claura_resolve_sound() {
  local name="${1:-birds}" data root n file
  data=$(claura_data_dir)
  root=$(claura_root_dir)
  for n in "$name" "birds"; do
    [[ -z "$n" ]] && continue
    for file in "$data/sounds/$n.mp3" "$root/audio/$n.mp3"; do
      if [[ -f "$file" ]]; then
        printf '%s\n' "$file"
        return 0
      fi
    done
  done
  return 1
}

# --- volume conversion -------------------------------------------------------
# Map a 0..100 percentage to afplay's 0.0..1.0 scale, clamped.
claura_vol_for_afplay() {
  awk -v p="${1:-100}" '
    BEGIN {
      p = p + 0
      if (p < 0)   p = 0
      if (p > 100) p = 100
      printf "%.3f", p / 100
    }
  '
}

# --- one-shot playback -------------------------------------------------------
# Plays FILE once at PCT volume. Caller is responsible for backgrounding and
# tracking the resulting PID; we run afplay in the foreground.
claura_play_loop() {
  local file="$1" pct="${2:-100}" vol
  vol=$(claura_vol_for_afplay "$pct")
  exec afplay -v "$vol" "$file"
}

# --- stop the running player -------------------------------------------------
# Idempotent; safe to call even if no player is running. The player's own
# cleanup trap removes the pidfile, but we also rm it here so a stale pidfile
# from a dead process does not linger.
claura_stop_player() {
  local pidfile pid
  pidfile="$(claura_data_dir)/state/player.pid"
  [[ -f "$pidfile" ]] || return 0
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    # Best-effort: wait briefly so the next reconcile sees a clean slate.
    local i
    for i in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  rm -f "$pidfile"
}

# --- stat/date wrappers ------------------------------------------------------
# Single-branch wrappers in 0.1.0 (darwin only). 0.2.0 will add Linux branches
# here without callers needing to change.
stat_mtime() {
  stat -f %m "$1" 2>/dev/null || echo 0
}

stat_size() {
  stat -f %z "$1" 2>/dev/null || echo 0
}

date_epoch() {
  date +%s
}
