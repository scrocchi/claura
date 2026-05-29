<p align="center">
  <img src="logo.png" alt="Claura" width="100%">
</p>

# Claura

[![validate](https://github.com/scrocchi/claura/actions/workflows/validate.yml/badge.svg)](https://github.com/scrocchi/claura/actions/workflows/validate.yml)

Ambient audio for [Claude Code](https://claude.com/claude-code). Plays a
soundscape while Claude is working and stops the instant it goes idle —
even when you press Escape mid-generation.

**0.1.0 ships macOS-only.** Linux and Windows are planned for 0.2.0+.

## How it works

Hooks (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`Stop`, `PermissionRequest`, `StopFailure`, `Notification`, `SessionEnd`)
drive a small controller that registers/unregisters each session. A
background player runs as long as at least one session is "working".
Aliveness is refreshed by both hook events and a CPU sampler watching the
Claude process tree, so the audio survives long model thinking (hooks
don't fire then) but cuts within ~10s of Escape or idle.

Two short system chimes are also wired in:

- `Glass.aiff` on `Stop` — turn finished cleanly.
- `Pop.aiff` on `PermissionRequest` — Claude is waiting for approval.

## Install

From GitHub (recommended):

```sh
claude plugin marketplace add scrocchi/claura
claude plugin install claura@claura-marketplace
```

(Equivalent: `claude plugin marketplace add https://github.com/scrocchi/claura`.)

From a local checkout (for development):

```sh
git clone https://github.com/scrocchi/claura
claude plugin marketplace add ./claura
claude plugin install claura@claura-marketplace
```

That's it — no `settings.json` edits. The plugin owns its own state under
`${CLAUDE_PLUGIN_DATA}`.

### Requirements

- macOS (uses `afplay`, `stat -f`, BSD `ps`).
- `jq` on `PATH` (`brew install jq`).

## No bundled sound

0.1.0 ships with **no audio file** (the prototype's `birds.mp3` could not be
license-cleared in time for the release — see [`docs/SOURCES.md`](docs/SOURCES.md)).

Drop your own `.mp3` (loopable, ~60–300s works best) into:

```
${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claura}/sounds/<name>.mp3
```

Then point Claura at it:

```
/claura:menu set sound <name>
```

(Without the `.mp3` extension.) `/claura:menu status` lists every sound it
can find under `available_sounds`.

## Configure

The slash command is the supported interface:

```
/claura:menu                     # full status JSON
/claura:menu on                  # enable + unmute
/claura:menu off                 # disable + stop player
/claura:menu mute                # mute + stop player
/claura:menu set volume 60       # 0..100; restarts player so it applies right away
/claura:menu set sound <name>    # name must resolve to a .mp3; restarts player
```

`status` returns one line of JSON with: `enabled`, `sound`, `volume`,
`muted`, `threshold`, `hysteresis`, `max_stale`, `available_sounds`,
`legacy_detected`, `data_dir`, `plugin_root`.

You can also run the script directly:
`${CLAUDE_PLUGIN_ROOT}/bin/claura-cli.sh status`.

## Migrating from the standalone prototype

If you wired the original `~/.claude/audio/claude-audio.sh` watcher into
your global `~/.claude/settings.json`, Claura detects it on first launch
and stays **inert** (no sound, no state mutation) until you clean it up
by hand. `/claura:menu status` will show `legacy_detected: true` while it
waits. See [`docs/MIGRATION.md`](docs/MIGRATION.md) for the steps.

## Uninstall

```sh
claude plugin uninstall claura
```

Removes the plugin and stops the active player. Your sounds under
`${CLAUDE_PLUGIN_DATA}/sounds/` and your `config.json` stay.

To reset settings without uninstalling:

```sh
rm "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claura}/config.json"
```

The bootstrap re-seeds defaults on the next session.

## Files in `${CLAUDE_PLUGIN_DATA}`

```
config.json              # enabled, sound, volume, muted, threshold, hysteresis, max_stale
sounds/*.mp3             # user-dropped sounds
state/sessions/<sid>     # one file per active session (contents = claude pid)
state/sessions/<sid>.cpu # CPU sampler sidecar (refreshed during model thinking)
state/baseline/<sid>     # CPU sampler baseline (prev pid + cputime + walltime)
state/player.pid         # PID of the running player
state/player.root        # CLAUDE_PLUGIN_ROOT the player was spawned from
state/lock.d/            # mkdir lock for the controller
.bootstrapped            # marker — bootstrap has run
.legacy-detected         # marker — prototype install detected, plugin is inert
.legacy-cleared          # marker — user resolved the legacy install
```

## Releasing

```sh
# 1. Bump `version` in both manifests by hand:
#       .claude-plugin/plugin.json
#       .claude-plugin/marketplace.json
# 2. Commit.
# 3. Create the canonical tag (validates manifest agreement):
claude plugin tag .
# 4. Push it:
git push origin "refs/tags/claura--v$(jq -r .version .claude-plugin/plugin.json)"
```

`claude plugin tag` writes a tag of the form `<plugin>--v<version>` (e.g.
`claura--v0.1.0`) after checking that `plugin.json` and the marketplace
entry agree on the version. There is intentionally no helper script in
0.1.0 — bump both manifests by hand.

## License

MIT — see [`LICENSE`](LICENSE).
