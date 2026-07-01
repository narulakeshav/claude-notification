#!/usr/bin/env python3
"""island-statusline.py — Claude Code statusline command that feeds the notch daemon.

Claude Code passes a rich JSON blob on the statusline command's stdin (model, cwd, cost,
context_window, and — for Pro/Max subscribers, after the first API response — `rate_limits`
with the REAL 5-hour and 7-day plan-limit percentages + reset times). None of that is on the
critical path and none of it reaches hooks, so a tiny statusline command is the only supported
way to get the live rate-limit %.

This captures `rate_limits` (and `context_window`) to ~/.claude-island/rate-limits.json for the
daemon to read, then prints NOTHING — the status bar stays invisible (pure data capture). If you
want a visible Claude Code status line too, print your own line at the end of main().

Stdin schema (the bits we use):
  rate_limits.five_hour.used_percentage / .resets_at   (0..100 ; unix epoch secs)
  rate_limits.seven_day.used_percentage / .resets_at
  context_window.used_percentage
"""
import json, os, sys, time

ISLAND_DIR = os.environ.get("ISLAND_DIR_OVERRIDE") or os.path.expanduser("~/.claude-island")
OUT = os.path.join(ISLAND_DIR, "rate-limits.json")
CTX_DIR = os.path.join(ISLAND_DIR, "ctx")   # per-session context fill, keyed by CC session_id


def write_atomic(path, payload):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, path)   # atomic — the daemon never sees a half-written file
    except Exception:
        pass


def main():
    try:
        d = json.loads(sys.stdin.read() or "{}")
    except Exception:
        d = {}

    # Rate limits are account-wide → one shared file. Only persist when a window is actually
    # present, else we'd clobber a last-known-good reading (rate_limits is absent at session
    # start and for non-subscription auth).
    rl = d.get("rate_limits") or {}
    if rl.get("five_hour") or rl.get("seven_day"):
        write_atomic(OUT, {
            "five_hour": rl.get("five_hour"),
            "seven_day": rl.get("seven_day"),
            "ts": time.time(),
        })

    # Context fill is PER SESSION, and CC's `used_percentage` is computed against the session's
    # REAL window (model + 1M-beta aware) — far better than the daemon's 200k/1M guess. Key it by
    # session_id so the daemon can map each transcript (<…>/<session_id>.jsonl) to its true fill.
    sid = d.get("session_id") or ""
    cw = d.get("context_window") or {}
    pct = cw.get("used_percentage")
    if sid and isinstance(pct, (int, float)):
        write_atomic(os.path.join(CTX_DIR, sid + ".json"), {"pct": pct, "ts": time.time()})

    # Print nothing: the status bar stays empty (we only wanted the data).


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
