#!/usr/bin/env bash
# bin/claura-bootstrap.sh
#
# Wired to SessionStart. Also called lazily from claura-control.sh the first
# time a hook fires on a fresh install (covers the "installed mid-session"
# case where SessionStart already passed).
#
# Responsibilities, in order:
#   1. OS gate.
#   2. Ensure ${CLAUDE_PLUGIN_DATA} exists.
#   3. Honor .legacy-cleared: if the user has signalled cleanup, remove both
#      legacy markers and proceed normally.
#   4. Fast path: if .bootstrapped exists AND .legacy-detected does not, exit.
#   5. Detect the standalone-prototype install (~/.claude/audio/claude-audio.sh
#      referenced in the user's settings.json). If found, write
#      .legacy-detected and print a banner to stderr.
#   6. Seed config.json with defaults if missing.
#   7. Touch .bootstrapped.
#
# Idempotent. Never writes to anything outside ${CLAUDE_PLUGIN_DATA}.

set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/_lib.sh
source "$SELF_DIR/_lib.sh"

os_detect >/dev/null

DATA_DIR=$(claura_data_dir)
mkdir -p "$DATA_DIR" "$DATA_DIR/sounds" "$DATA_DIR/state" \
         "$DATA_DIR/state/sessions" "$DATA_DIR/state/baseline"

CFG="$DATA_DIR/config.json"
BOOTSTRAPPED="$DATA_DIR/.bootstrapped"
LEGACY_DETECTED="$DATA_DIR/.legacy-detected"
LEGACY_CLEARED="$DATA_DIR/.legacy-cleared"

# (3) User signalled "I cleaned up the prototype" → clear all legacy markers
# and treat this as a fresh bootstrap so we re-evaluate.
if [[ -f "$LEGACY_CLEARED" ]]; then
  rm -f "$LEGACY_DETECTED" "$LEGACY_CLEARED"
fi

# (4) Fast path.
if [[ -f "$BOOTSTRAPPED" && ! -f "$LEGACY_DETECTED" ]]; then
  exit 0
fi

# (5) Legacy detection.
# The standalone prototype lived at ~/.claude/audio/claude-audio.sh and was
# wired by hand into the user's global settings.json. We refuse to play sound
# until the user removes those hooks — otherwise two players race for the
# same audio device.
SETTINGS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
LEGACY_SCRIPT="$HOME/.claude/audio/claude-audio.sh"

legacy=false
if [[ -f "$LEGACY_SCRIPT" ]] && [[ -f "$SETTINGS_FILE" ]] \
   && grep -q '/.claude/audio/claude-audio\.sh' "$SETTINGS_FILE" 2>/dev/null; then
  legacy=true
fi

if [[ "$legacy" == true ]]; then
  : > "$LEGACY_DETECTED"
  {
    echo ""
    echo "⚠️  Claura: detected legacy prototype at ~/.claude/audio/"
    echo "    Plugin is INERT until you clean it up. To proceed:"
    echo "      1. Edit $SETTINGS_FILE and remove the hooks block referencing"
    echo "         /.claude/audio/"
    echo "      2. pkill -f claude-audio-player.sh"
    echo "      3. touch $LEGACY_CLEARED"
    echo "    See docs/MIGRATION.md for details."
    echo ""
  } >&2
else
  rm -f "$LEGACY_DETECTED"
fi

# (6) Seed defaults if config.json is missing.
if [[ ! -f "$CFG" ]]; then
  if command -v jq >/dev/null 2>&1; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/claura.config.XXXXXX")
    jq -n '{
      enabled: true,
      sound: "birds",
      volume: 100,
      muted: false,
      threshold: 5,
      hysteresis: 10,
      max_stale: 75
    }' > "$tmp"
    mv "$tmp" "$CFG"
  else
    echo "Claura: jq not found on PATH — install with 'brew install jq'." >&2
    # Continue without seeding; claura_cfg_get will fall back to defaults.
  fi
fi

# (7) Mark bootstrap complete.
: > "$BOOTSTRAPPED"

exit 0
