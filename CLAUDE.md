# ClaudeIsland

Notch live-activity for Claude Code (macOS). Deep reference: `src/island/ARCHITECTURE.md`.

## Build
```bash
pkill -x island; sleep 0.3; node bin/cli.js install
```
- `pkill -x island` first is required — the KeepAlive daemon locks its binary, else `swiftc` fails with "text file busy" (reported as "Compilation failed").
- The trailing "Auto-configure hooks? (Y/n)" prompt is safe to ignore; binary + hook are already in place by then.
- Compile-only check (no install/kill): `swiftc -O -o /tmp/x src/island/island.swift -framework Cocoa -framework SwiftUI 2>&1 | grep -i error` (empty = clean). Ignore `+`/`onChange` deprecation warnings.
- Other: `node bin/cli.js test` (cycle states), `uninstall`.

## Animation in the panel
The island is a non-activating `NSPanel`: SwiftUI's animation clock doesn't tick there. `withAnimation(.repeatForever)` and bare `TimelineView(.animation)` freeze. Animate only via a self-stepped `Timer` + `@Published` (see `Ticker`, `WobbleClock`). Note `Ticker.shared` is stopped in `attention`/`idle` modes, so anything relying on it freezes in those states — give resting-state motion its own clock.

## Render paths for the `!`/status marker (patch all that apply)
- Front pill, ≥2 sessions: `leading` → `aggKind` switch.
- Front pill, single: `leadingSingle` → `state.mode` switch.
- Dropdown: `rowMarker(_:)` (dot/`!`) and `dropdownRow(_:)` (verb + title + grey preview).
- `Spinner`'s `.attention`/`.done` cases are mostly unused for the pill — editing it won't change the visible `!`.

## Add a per-session field (thread all 6)
`island-hook.sh` (extract from transcript; add to **both** `emit` and `emit_keep`) → `SessionFile` → `LiveSession` → `merge` → `makeCard` → `SessionCard`.

## Inspect state
- `~/.claude-island/sessions/<tabUUID>.json` — exact payload the daemon reads.
- `~/.claude/projects/<slug>/<id>.jsonl` — CC transcript (titles/preview/prompt/context). Types: `user` (skip `isMeta`/tool_result), `assistant`, `ai-title`, `custom-title`.

## Flags
- `kRowTitleUsesPrompt` (top of `island.swift`): dropdown rows lead with opening prompt vs tab name. Done/stale rows show the agent's response regardless.
