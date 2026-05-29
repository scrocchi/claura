# Changelog

All notable changes to this project are documented here. Versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-05-28

Initial release. **macOS-only.**

### Added

- Hook-driven ambient audio for Claude Code sessions, with CPU-refreshed
  aliveness detection that survives long model thinking and cuts within ~10s
  of Escape or idle.
- `/claura:menu` slash command (`status`, `on`, `off`, `mute`, `set volume N`,
  `set sound NAME`).
- Lazy bootstrap that detects the standalone-prototype install at
  `~/.claude/audio/` and stays inert until the user clears the legacy hooks
  manually (see `docs/MIGRATION.md`).
- Root-mismatch killswitch that respawns the player after `claude plugin
  update`.
- User-dropped sounds at `${CLAUDE_PLUGIN_DATA}/sounds/*.mp3`.

### Not bundled

- No audio file ships in 0.1.0: `audio/birds.mp3` was cut because its
  provenance/license could not be verified for this release. Drop your own
  `.mp3` into `${CLAUDE_PLUGIN_DATA}/sounds/` and `/claura:menu set sound
  NAME` (filename without extension).

### Platform

- macOS only. Linux/Windows are planned for 0.2.0+.
