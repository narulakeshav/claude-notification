#!/usr/bin/env python3
"""subagent-watch.py — live view of Claude Code subagents the hooks can't see.

WHY THIS EXISTS
  Claude Code fires PreToolUse/PostToolUse hooks ONLY for a session's own tool
  calls — never for a subagent's internal tool calls (verified empirically). So
  while a Task/subagent runs, the parent card freezes and any subagent we tried
  to surface via the hook path shows nothing live (it reads as "Thinking…", the
  prompt-time fallback). The only way to get a real per-subagent verb is to read
  the subagent transcript tree directly:

      ~/.claude/projects/<proj>/<sessionId>/subagents/
          agent-<id>.jsonl       <- subagent's live transcript (isSidechain:true)
          agent-<id>.meta.json   <- {agentType, description, toolUseId, spawnDepth}

  This script discovers every live session, finds its subagents, and rebuilds the
  same verb the island shows for top-level sessions — but per subagent.

USAGE
  subagent-watch.py            # one snapshot of all sessions + their subagents
  subagent-watch.py --watch    # refresh every 1s
  subagent-watch.py --json     # machine-readable (what island.swift would parse)
"""
import json, os, sys, time, glob

PROJECTS = os.path.expanduser("~/.claude/projects")
SESSIONS = os.path.expanduser("~/.claude/sessions")
FRESH_S = 8.0   # a subagent whose transcript moved within this window is "running"

# Mirror of island-hook.sh's tool->verb map so the sub-deck reads like the main pill.
VERB = {"Edit": "Editing", "MultiEdit": "Editing", "Write": "Writing", "Read": "Reading",
        "NotebookEdit": "Editing", "Bash": "Running", "Grep": "Searching", "Glob": "Finding",
        "Task": "Delegating", "Agent": "Delegating", "WebFetch": "Fetching",
        "WebSearch": "Searching", "TodoWrite": "Planning"}


def tail_lines(path, n=40):
    try:
        with open(path) as f:
            return f.readlines()[-n:]
    except OSError:
        return []


def base(p):
    return os.path.basename(p) if p else ""


def verb_from_transcript(path):
    """Reconstruct the live action from a (sub)agent transcript tail.

    Returns (verb, running). Walks back to the last assistant block: if it ends on
    a tool_use we have a concrete verb+target; a trailing text/thinking block (no
    tool yet) is the genuine 'Thinking…' state. mtime freshness decides running."""
    lines = tail_lines(path)
    verb = "Thinking…"
    for line in reversed(lines):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") != "assistant":
            continue
        content = e.get("message", {}).get("content", "")
        if not isinstance(content, list) or not content:
            break
        last = content[-1]
        kind = last.get("type", "")
        if kind == "tool_use":
            name = last.get("name", "")
            ti = last.get("input", {}) or {}
            if name in ("Edit", "MultiEdit", "Write", "Read"):
                tgt = base(ti.get("file_path", ""))
            elif name == "NotebookEdit":
                tgt = base(ti.get("notebook_path", ""))
            elif name == "Bash":
                parts = (ti.get("command", "") or "").strip().split()
                tgt = parts[0] if parts else ""
            elif name in ("Grep", "Glob"):
                tgt = ti.get("pattern", "")
            else:
                tgt = ""
            verb = (VERB.get(name, name) + " " + tgt).strip()
        else:
            verb = "Thinking…"   # trailing text/thinking, no tool in flight
        break
    try:
        running = (time.time() - os.path.getmtime(path)) < FRESH_S
    except OSError:
        running = False
    return verb, running


def live_sessions():
    """pid -> {sessionId, cwd, status} for sessions the daemon believes are alive."""
    out = {}
    for f in glob.glob(os.path.join(SESSIONS, "*.json")):
        try:
            d = json.load(open(f))
        except (OSError, ValueError):
            continue
        sid = d.get("sessionId")
        if sid:
            out[sid] = {"cwd": d.get("cwd", ""), "status": d.get("status", ""),
                        "kind": d.get("kind", "")}
    return out


def subagents_for(session_id):
    """All subagents under a session dir, newest first, with meta + live verb."""
    rows = []
    for proj in glob.glob(os.path.join(PROJECTS, "*", session_id, "subagents")):
        for jl in glob.glob(os.path.join(proj, "agent-*.jsonl")):
            aid = base(jl)[len("agent-"):-len(".jsonl")]
            meta = {}
            mp = jl[:-len(".jsonl")] + ".meta.json"
            try:
                meta = json.load(open(mp))
            except (OSError, ValueError):
                pass
            verb, running = verb_from_transcript(jl)
            rows.append({"agentId": aid, "agentType": meta.get("agentType", "?"),
                         "description": meta.get("description", ""),
                         "spawnDepth": meta.get("spawnDepth", 1),
                         "verb": verb, "running": running,
                         "mtime": os.path.getmtime(jl)})
    rows.sort(key=lambda r: r["mtime"], reverse=True)
    return rows


def snapshot():
    sess = live_sessions()
    result = []
    for sid, info in sess.items():
        subs = subagents_for(sid)
        if subs:
            result.append({"sessionId": sid, **info, "subagents": subs})
    return result


def render(rows):
    if not rows:
        return "(no sessions with subagents)"
    lines = []
    for s in rows:
        live = sum(1 for x in s["subagents"] if x["running"])
        lines.append(f"\033[1m{base(s['cwd']) or s['sessionId'][:8]}\033[0m  "
                     f"({live} live / {len(s['subagents'])} total)")
        for x in s["subagents"]:
            dot = "\033[32m●\033[0m" if x["running"] else "\033[90m○\033[0m"
            indent = "  " * x["spawnDepth"]
            label = f"{x['agentType']}: {x['description']}"[:46]
            lines.append(f"  {dot} {indent}{label:<48} \033[36m{x['verb']}\033[0m")
    return "\n".join(lines)


def main():
    if "--json" in sys.argv:
        print(json.dumps(snapshot(), indent=2))
        return
    if "--watch" in sys.argv:
        try:
            while True:
                sys.stdout.write("\033[2J\033[H")
                print(render(snapshot()))
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        return
    print(render(snapshot()))


if __name__ == "__main__":
    main()
