# Claura

Ambient audio for [Claude Code](https://claude.com/claude-code). Plays a
soundscape while Claude is working and stops the instant it goes idle —
even when you press Escape mid-generation.

**0.1.0 ships macOS-only.** Linux and Windows are planned for 0.2.0+.

## How it works

Hooks (`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`,
`PermissionRequest`, `SessionEnd`, …) drive a small controller that
registers/unregisters each session. A background player runs as long as at
least one session is "working". Aliveness is refreshed by both hook events
and a CPU sampler watching the Claude process tree, so the audio survives
long model thinking (no hooks fire) but cuts within ~10s of Escape or idle.

## Install

```sh
claude plugin marketplace add /abs/path/to/this/repo
claude plugin install claura@claura-marketplace
```

That's it — no `settings.json` edits. The plugin owns its own state under
`${CLAUDE_PLUGIN_DATA}`.

### Requirements

- macOS (uses `afplay`, `stat -f`, BSD `ps`).
- `jq` on `PATH` (`brew install jq`).

## No bundled sound

0.1.0 ships with **no audio file**. Drop your own `.mp3` (loopable, ~60-300s
works best) into:

```
${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claura}/sounds/<name>.mp3
```

Then point Claura at it:

```
/claura:menu set sound <name>
```

(Without the `.mp3` extension.) `/claura:menu` lists the sounds it can find.

## Configure

The slash command is the supported interface:

```
/claura:menu                     # status: enabled, sound, volume, muted, legacy state
/claura:menu on                  # enable + unmute
/claura:menu off                 # disable + stop player
/claura:menu mute                # mute + stop player
/claura:menu set volume 60       # 0..100; restarts player so it applies right away
/claura:menu set sound rain      # restarts player
```

Everything outputs a single line of JSON; you can run the script directly
too: `${CLAUDE_PLUGIN_ROOT}/bin/claura-cli.sh status`.

## Migrating from the standalone prototype

If you wired the original `~/.claude/audio/claude-audio.sh` watcher into your
global `~/.claude/settings.json`, Claura detects it on first launch and stays
**inert** until you clean up by hand. See [`docs/MIGRATION.md`](docs/MIGRATION.md).

## Uninstall

```sh
claude plugin uninstall claura
```

Removes the plugin and the active player. Your sound files under
`${CLAUDE_PLUGIN_DATA}/sounds/` and your `config.json` stay.

To reset settings:

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
# bump version in both manifests, then:
git tag v0.1.0
git push --tags
```

(There is intentionally no helper script in 0.1.0 — bump both
`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` by hand.)

## License

MIT — see [`LICENSE`](LICENSE).
