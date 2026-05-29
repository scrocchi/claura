#!/usr/bin/env bash
# bin/claura-cli.sh
#
# Slash-command dispatcher behind `/claura:menu`. Prints one JSON object per
# invocation on stdout. Exit codes are 0 for both success and user-visible
# errors (so Claude can render them); we only exit non-zero on hard
# environment failures (no jq, no writable data dir).
#
# Subcommands:
#   status                       — print current config + available sounds
#   on                           — enabled=true, muted=false
#   off                          — enabled=false; stops the player
#   mute                         — muted=true; stops the player
#   set volume N                 — N in 0..100; stops the player so the
#                                  next spawn applies the new volume
#   set sound NAME               — NAME must resolve to a .mp3; stops the
#                                  player so the next spawn applies it
#
# Config writes are atomic (mktemp + jq + mv).

set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/_lib.sh
source "$SELF_DIR/_lib.sh"

os_detect >/dev/null

# --- env -------------------------------------------------------------------
DATA_DIR=$(claura_data_dir)
CFG="$DATA_DIR/config.json"
LEGACY_DETECTED="$DATA_DIR/.legacy-detected"
LEGACY_CLEARED="$DATA_DIR/.legacy-cleared"

# --- jq is mandatory -------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo '{"ok":false,"error":"jq not found on PATH; install with: brew install jq"}' >&2
  exit 2
fi

# --- ensure config exists (lazy bootstrap) ---------------------------------
ensure_config() {
  if [[ ! -f "$CFG" ]]; then
    "$SELF_DIR/claura-bootstrap.sh" </dev/null >/dev/null 2>&1 || true
  fi
  if [[ ! -f "$CFG" ]]; then
    jq -nc --arg cfg "$CFG" '{ok:false, error:"config.json missing", path:$cfg}'
    exit 1
  fi
}

# --- atomic writes ---------------------------------------------------------
set_field_json() {
  local key="$1" val_json="$2" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/claura.config.XXXXXX")
  if jq --arg k "$key" --argjson v "$val_json" '.[$k] = $v' "$CFG" > "$tmp"; then
    mv "$tmp" "$CFG"
  else
    rm -f "$tmp"
    return 1
  fi
}

set_field_str() {
  local key="$1" val="$2" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/claura.config.XXXXXX")
  if jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$CFG" > "$tmp"; then
    mv "$tmp" "$CFG"
  else
    rm -f "$tmp"
    return 1
  fi
}

# --- sound discovery -------------------------------------------------------
# Whitelist = "birds" plus the basenames of every .mp3 under
# ${CLAUDE_PLUGIN_DATA}/sounds/ and ${CLAUDE_PLUGIN_ROOT}/audio/. Returns one
# name per line, deduplicated, preserving insertion order.
discover_sounds() {
  local root f
  root=$(claura_root_dir)
  {
    echo "birds"
    shopt -s nullglob
    for f in "$DATA_DIR"/sounds/*.mp3; do
      basename "$f" .mp3
    done
    for f in "$root"/audio/*.mp3; do
      [[ -z "$root" ]] && continue
      basename "$f" .mp3
    done
  } | awk 'NF && !seen[$0]++'
}

sounds_json_array() {
  discover_sounds | jq -R . | jq -sc .
}

# --- status ----------------------------------------------------------------
status_cmd() {
  local sounds legacy data_dir root
  sounds=$(sounds_json_array)
  legacy=false
  if [[ -f "$LEGACY_DETECTED" && ! -f "$LEGACY_CLEARED" ]]; then
    legacy=true
  fi
  data_dir="$DATA_DIR"
  root=$(claura_root_dir)
  jq -c \
    --argjson sounds "$sounds" \
    --argjson legacy "$legacy" \
    --arg data "$data_dir" \
    --arg root "$root" \
    '{ok:true,
      enabled:    (if has("enabled") then .enabled else true  end),
      sound:      (.sound      // "birds"),
      volume:     (.volume     // 100),
      muted:      (if has("muted")   then .muted   else false end),
      threshold:  (.threshold  // 5),
      hysteresis: (.hysteresis // 10),
      max_stale:  (.max_stale  // 75),
      available_sounds: $sounds,
      legacy_detected:  $legacy,
      data_dir:   $data,
      plugin_root: $root}' "$CFG"
}

# --- commands --------------------------------------------------------------
on_cmd() {
  set_field_json enabled true
  set_field_json muted false
  status_cmd
}

off_cmd() {
  set_field_json enabled false
  claura_stop_player
  status_cmd
}

mute_cmd() {
  set_field_json muted true
  claura_stop_player
  status_cmd
}

set_cmd() {
  local sub="${1:-}" arg="${2:-}"
  case "$sub" in
    volume)
      if [[ -z "$arg" || ! "$arg" =~ ^[0-9]+$ ]] || (( arg < 0 || arg > 100 )); then
        jq -nc --arg arg "$arg" '{ok:false, error:"volume must be an integer 0..100", got:$arg}'
        return 0
      fi
      set_field_json volume "$arg"
      claura_stop_player
      status_cmd
      ;;
    sound)
      if [[ -z "$arg" ]]; then
        jq -nc --argjson allowed "$(sounds_json_array)" \
          '{ok:false, error:"set sound requires a name", allowed:$allowed}'
        return 0
      fi
      local allowed_list
      allowed_list=$(discover_sounds)
      if ! grep -qxF -- "$arg" <<<"$allowed_list"; then
        jq -nc --arg arg "$arg" --argjson allowed "$(sounds_json_array)" \
          '{ok:false, error:"unknown sound", got:$arg, allowed:$allowed}'
        return 0
      fi
      set_field_str sound "$arg"
      claura_stop_player
      status_cmd
      ;;
    "")
      jq -nc '{ok:false, error:"set requires a subcommand", allowed:["volume","sound"]}'
      ;;
    *)
      jq -nc --arg sub "$sub" \
        '{ok:false, error:"unknown set subcommand", got:$sub, allowed:["volume","sound"]}'
      ;;
  esac
}

main() {
  ensure_config
  local cmd="${1:-status}"
  case "$cmd" in
    status) status_cmd ;;
    on)     on_cmd ;;
    off)    off_cmd ;;
    mute)   mute_cmd ;;
    set)    shift; set_cmd "${1:-}" "${2:-}" ;;
    *)
      jq -nc --arg cmd "$cmd" \
        '{ok:false, error:"unknown command", got:$cmd, allowed:["status","on","off","mute","set"]}'
      ;;
  esac
}

main "$@"
