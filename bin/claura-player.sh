#!/usr/bin/env bash
# bin/claura-player.sh
#
# Background player. Spawned by claura-control.sh when a session goes
# active. Lives as long as at least one session is "alive" by the Phase-2
# rule:
#
#   alive = PID running AND (now - effective_mtime < HYSTERESIS)
#   effective_mtime = max(mtime(sessions/<sid>), mtime(sessions/<sid>.cpu))
#
# The CPU sampler `touch`es sessions/<sid>.cpu whenever the aggregate CPU
# percent of the claude process tree (root + descendants) is >= THRESHOLD.
# So the activity window is refreshed by BOTH hooks (working events touch the
# main file) AND the CPU watcher (touches the sidecar). During long model
# thinking, hooks don't fire but CPU stays >5% (measured: worst gap <5% was 3s
# during 15.7h of real use), so the sidecar keeps the session alive without
# glitching. On Escape/idle, CPU drops to <1%; HYSTERESIS=10s decides the cut.
#
# Degradation fallback: if sum_cputime fails to read CPU for a session, the
# sampler creates baseline/<sid>.degraded. any_alive() then uses MAX_STALE=75
# for that session instead of HYSTERESIS, falling back to the Phase-1 known-
# good behavior rather than chronic cutting.
#
# Race with the controller's `rm` under lock (the watcher does NOT take the
# lock): solved by using a sidecar `sessions/<sid>.cpu` instead of the main
# file. The controller `rm`s both (main + .cpu) under lock on idle/end. If the
# watcher recreates only the sidecar after that, it's an orphan (no main file)
# and any_alive() ignores it because aliveness requires the MAIN file to exist.
#
# Config (read ONCE at startup):
#   sound       — name resolved via _lib.sh::claura_resolve_sound
#   volume      — 0..100 → afplay -v
#   threshold   — %CPU; below this, the sampler does not touch the sidecar
#   hysteresis  — seconds; activity window
#   max_stale   — seconds; degradation fallback

set -u
export PATH="/usr/bin:/bin:$PATH"
shopt -s nullglob

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
CPU_LOG="$STATE_DIR/cpu.log"
TRANSCRIPT_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"

mkdir -p "$BASELINE_DIR" "$SESSIONS_DIR"

# --- record our root so the controller can detect plugin-update swaps ------
CURRENT_ROOT=$(claura_root_dir)
if [[ -n "$CURRENT_ROOT" ]]; then
  echo "$CURRENT_ROOT" > "$PLAYER_ROOT_FILE"
fi

# --- config (read ONCE) -----------------------------------------------------
SOUND=$(claura_cfg_get sound birds)
VOLUME=$(claura_cfg_get volume 100)
THRESHOLD=$(claura_cfg_get threshold 5)
HYSTERESIS=$(claura_cfg_get hysteresis 10)
MAX_STALE=$(claura_cfg_get max_stale 75)
DEBUG="${CLAURA_DEBUG:-${CLAUDE_AUDIO_DEBUG:-0}}"

# Fixed cadence (not user-tunable in 0.1.0). Matches the validated prototype.
SAMPLE_INTERVAL=2     # cap overhead; still detects Escape in ~3-5s
ALIVE_CHECK_EVERY=2   # invoke any_alive every 2 samples (~4s)

TRACK=$(claura_resolve_sound "$SOUND" || true)
if [[ -z "$TRACK" ]]; then
  echo "claura-player: no playable sound found for '$SOUND'. Drop a file at $DATA_DIR/sounds/<name>.mp3 or set a different sound via /claura:menu set sound NAME." >&2
  rm -f "$PLAYER_PID_FILE" "$PLAYER_ROOT_FILE"
  exit 1
fi

afplay_pid=""
sample_counter=0

# --- cleanup ---------------------------------------------------------------
cleanup() {
  trap - EXIT TERM INT
  [[ -n "$afplay_pid" ]] && kill -9 "$afplay_pid" 2>/dev/null
  if [[ "$(cat "$PLAYER_PID_FILE" 2>/dev/null)" == "$$" ]]; then
    rm -f "$PLAYER_PID_FILE" "$PLAYER_ROOT_FILE"
  fi
  exit 0
}
trap cleanup EXIT TERM INT

# --- parse_cputime: portable parser for `ps -o time=` -----------------------
# Accepts "SS.ss", "MM:SS.ss", "HH:MM:SS", "D-HH:MM:SS". Outputs seconds as a
# float with 3 decimals. Empty input -> empty output.
parse_cputime() {
  local t="$1"
  [[ -z "$t" ]] && return
  t="${t#"${t%%[![:space:]]*}"}"
  local days=0
  if [[ "$t" == *-* ]]; then
    days="${t%%-*}"
    t="${t#*-}"
  fi
  local h=0 m=0 s=0 a b c
  if [[ "$t" == *:*:* ]]; then
    a="${t%%:*}"; t="${t#*:}"
    b="${t%%:*}"; c="${t#*:}"
    h="$a"; m="$b"; s="$c"
  elif [[ "$t" == *:* ]]; then
    a="${t%%:*}"; b="${t#*:}"
    m="$a"; s="$b"
  else
    s="$t"
  fi
  awk -v d="$days" -v h="$h" -v m="$m" -v s="$s" \
    'BEGIN{printf "%.3f", d*86400 + h*3600 + m*60 + s}'
}

# --- parser self-test ------------------------------------------------------
test_parser() {
  local pair in expected got failed=0
  for pair in \
    "12.34|12.340" \
    "1:02.50|62.500" \
    "9:16.73|556.730" \
    "1:02:03|3723.000" \
    "1-02:03:04|93784.000"; do
    in="${pair%|*}"; expected="${pair#*|}"
    got=$(parse_cputime "$in")
    if [[ "$got" != "$expected" ]]; then
      echo "parser FAIL: '$in' -> '$got' (expected '$expected')" >&2
      failed=$((failed + 1))
    fi
  done
  return $failed
}
if ! test_parser; then
  echo "claura-player: cputime parser self-test failed, refusing to start" >&2
  exit 1
fi

# --- find_claude_pids: root + descendants ----------------------------------
find_claude_pids() {
  local root="$1"
  [[ -z "$root" ]] && return
  ps -axo pid,ppid | awk -v root="$root" '
    NR > 1 { kids[$2] = kids[$2] " " $1 }
    END {
      head=1; tail=1; queue[head]=root; out=root
      while (head <= tail) {
        cur = queue[head]; head++
        n = split(kids[cur], a, " ")
        for (i=1; i<=n; i++) if (a[i] != "") {
          tail++; queue[tail] = a[i]; out = out " " a[i]
        }
      }
      print out
    }
  '
}

# --- sum_cputime: sum cputime of a list of PIDs ----------------------------
# Returns the sum if at least one PID was readable; empty string if none were.
sum_cputime() {
  local p total=0 ct secs read_ok=0
  for p in "$@"; do
    [[ -z "$p" ]] && continue
    ct=$(ps -o time= -p "$p" 2>/dev/null | tr -d ' ')
    [[ -z "$ct" ]] && continue
    secs=$(parse_cputime "$ct")
    [[ -z "$secs" ]] && continue
    total=$(awk -v a="$total" -v b="$secs" 'BEGIN{printf "%.3f", a+b}')
    read_ok=1
  done
  (( read_ok == 1 )) && echo "$total"
}

# --- find_transcript -------------------------------------------------------
find_transcript() {
  local sid="$1" f
  for f in "$TRANSCRIPT_ROOT"/*/"${sid}".jsonl; do
    [[ -f "$f" ]] && { echo "$f"; return; }
  done
}

# --- effective_mtime: max(mtime(file), mtime(file.cpu)) --------------------
effective_mtime() {
  local f="$1" m1 m2
  m1=$(stat_mtime "$f")
  if [[ -f "$f.cpu" ]]; then
    m2=$(stat_mtime "$f.cpu")
    (( m2 > m1 )) && m1=$m2
  fi
  echo "$m1"
}

# --- aliveness (Phase 2: hybrid hooks + CPU) -------------------------------
# alive iff: PID running AND (now - effective_mtime) < limit
# limit = HYSTERESIS if CPU sampling works for this session, else MAX_STALE.
# Reaps dead/idle sessions and their .cpu sidecars.
any_alive() {
  local found=1 now pid emtime limit sid f
  now=$(date_epoch)
  for f in "$SESSIONS_DIR"/*; do
    [[ -e "$f" ]] || continue
    # skip sidecars: they're metadata for the main file
    [[ "$f" == *.cpu ]] && continue
    sid=$(basename "$f")
    pid=$(cat "$f" 2>/dev/null)
    # process gone -> reap (main + sidecar + baseline)
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$f" "$f.cpu" "$BASELINE_DIR/$sid" "$BASELINE_DIR/$sid.degraded"
      continue
    fi
    emtime=$(effective_mtime "$f")
    # pick limit based on whether CPU is working for this session
    if [[ -f "$BASELINE_DIR/$sid.degraded" ]]; then
      limit=$MAX_STALE
    else
      limit=$HYSTERESIS
    fi
    if (( now - emtime >= limit )); then
      rm -f "$f" "$f.cpu" "$BASELINE_DIR/$sid" "$BASELINE_DIR/$sid.degraded"
      continue
    fi
    found=0
  done
  return $found
}

# --- sample_all_sessions: refresh .cpu when active, log if DEBUG -----------
sample_all_sessions() {
  local now pid sid pids n_pids ct dcpu dt pct mtime mage tpath tsz
  local bfile prev_pid prev_ct prev_wt f cpu_ok
  now=$(date_epoch)
  for f in "$SESSIONS_DIR"/*; do
    [[ -e "$f" ]] || continue
    [[ "$f" == *.cpu ]] && continue
    sid=$(basename "$f")
    pid=$(cat "$f" 2>/dev/null)
    [[ -z "$pid" ]] && continue
    kill -0 "$pid" 2>/dev/null || continue

    pids=$(find_claude_pids "$pid")
    n_pids=$(echo "$pids" | wc -w | tr -d ' ')
    # shellcheck disable=SC2086
    ct=$(sum_cputime $pids)

    if [[ -z "$ct" ]]; then
      # CPU read failed -> degrade this session to MAX_STALE
      : > "$BASELINE_DIR/$sid.degraded"
      [[ "$DEBUG" == "1" ]] && echo "$now $sid $pid $n_pids NA NA NA NA NA NA" >> "$CPU_LOG"
      continue
    else
      # CPU read OK -> ensure no stale degraded marker
      rm -f "$BASELINE_DIR/$sid.degraded"
    fi

    bfile="$BASELINE_DIR/$sid"
    prev_pid=""; prev_ct=""; prev_wt=""
    [[ -f "$bfile" ]] && read -r prev_pid prev_ct prev_wt < "$bfile" || true

    if [[ "$prev_pid" == "$pid" && -n "$prev_ct" && -n "$prev_wt" ]]; then
      dcpu=$(awk -v a="$ct" -v b="$prev_ct" 'BEGIN{d=a-b; if(d<0) d=0; printf "%.3f", d}')
      dt=$(awk -v a="$now" -v b="$prev_wt" 'BEGIN{printf "%.3f", a-b}')
      pct=$(awk -v c="$dcpu" -v t="$dt" 'BEGIN{ if(t>0) printf "%.1f", 100*c/t; else print "0" }')
    else
      dcpu="0.000"; dt="0.000"; pct="0"
    fi

    # touch sidecar if active; only if main file still exists (avoid ghost)
    cpu_ok=0
    if awk -v p="$pct" -v t="$THRESHOLD" 'BEGIN{exit !(p+0 >= t+0)}'; then
      if [[ -e "$f" ]]; then
        touch "$f.cpu"
        cpu_ok=1
      fi
    fi

    if [[ "$DEBUG" == "1" ]]; then
      mtime=$(stat_mtime "$f")
      mage=$(( now - mtime ))
      tpath=$(find_transcript "$sid")
      if [[ -n "$tpath" && -f "$tpath" ]]; then
        tsz=$(stat_size "$tpath")
      else
        tsz=0
      fi
      echo "$now $sid $pid $n_pids $ct $dcpu $dt $pct $mage $tsz $cpu_ok" >> "$CPU_LOG"
    fi

    echo "$pid $ct $now" > "$bfile"
  done

  # GC baseline files whose session is gone
  for bfile in "$BASELINE_DIR"/*; do
    [[ -e "$bfile" ]] || continue
    sid=$(basename "$bfile" .degraded)
    sid=$(basename "$sid")
    [[ -e "$SESSIONS_DIR/$sid" ]] || rm -f "$bfile"
  done
}

# --- main loop --------------------------------------------------------------
AFPLAY_VOL=$(claura_vol_for_afplay "$VOLUME")
while :; do
  any_alive || break
  afplay -v "$AFPLAY_VOL" "$TRACK" &
  afplay_pid=$!
  while kill -0 "$afplay_pid" 2>/dev/null; do
    sample_all_sessions
    sleep "$SAMPLE_INTERVAL"
    sample_counter=$((sample_counter + 1))
    if (( sample_counter % ALIVE_CHECK_EVERY == 0 )); then
      if ! any_alive; then
        kill -9 "$afplay_pid" 2>/dev/null
        break
      fi
    fi
  done
  afplay_pid=""
  any_alive || break
done
# fall through -> EXIT trap -> cleanup (runs once)
