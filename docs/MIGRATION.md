# Migrating from the standalone prototype to the Claura plugin

If you ran the original `~/.claude/audio/claude-audio.sh` watcher by editing
your global `~/.claude/settings.json` by hand, the Claura plugin will detect
it during the first `SessionStart` and **stay inert** until you remove the old
wiring. This prevents two players running at once.

## How to tell it's inert

`/claura:menu` will report `legacy_detected: true`. The control hook exits
silently on every event; no audio plays from the plugin.

## Cleanup steps (one-time)

1. **Edit `~/.claude/settings.json`** and remove every hook entry that
   references `~/.claude/audio/claude-audio.sh`. Typically these are the
   `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`,
   `PermissionRequest`, `StopFailure`, `Notification`, and `SessionEnd`
   blocks pointing at the prototype.

2. **Stop the prototype's player** if it is still running:

   ```sh
   pkill -f claude-audio-player.sh
   ```

3. **Clear the marker** so the plugin starts handling hooks:

   ```sh
   touch "${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claura}/.legacy-cleared"
   ```

4. (Optional) Delete the prototype scripts you no longer use:

   ```sh
   rm -rf ~/.claude/audio
   ```

   The plugin keeps its own state in `${CLAUDE_PLUGIN_DATA}` — removing
   `~/.claude/audio` does not affect it.

After step 3, the next hook event will start the plugin's player normally.
