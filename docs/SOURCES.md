# Bundled audio: provenance and license

This file is a release gate. Every audio file shipped under `audio/` MUST
appear here with all four of these fields filled in:

| Field    | Requirement                                                |
| -------- | ---------------------------------------------------------- |
| File     | Path inside this repo (e.g. `audio/birds.mp3`)             |
| Source   | Verifiable URL where the file (or its source) was obtained |
| Author   | Original creator's name or handle                          |
| License  | CC0 or CC-BY only. Include SPDX identifier.                |

If a file cannot be documented this way, it **must not be bundled**. Users can
still drop their own `.mp3` files into `${CLAUDE_PLUGIN_DATA}/sounds/` at
runtime — see the README.

## Currently bundled (0.1.0)

_None._

`birds.mp3` from the standalone prototype was excluded from 0.1.0 because its
original source/license could not be re-verified at release time. To bundle
it (or any other audio) in a future release, add an entry below following the
format above, and include the file in `audio/`.

### Template

```
- **File:** `audio/<name>.mp3`
- **Source:** <URL>
- **Author:** <name>
- **License:** <CC0-1.0 | CC-BY-4.0> (SPDX: `<identifier>`)
- **Notes:** <attribution string if CC-BY, trimming/normalization, etc.>
```
