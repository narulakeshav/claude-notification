#!/bin/bash
# Stop hook for Claude Code notifications
# Checks if terminal is focused (skip if so) and extracts last Claude message

NOTIFY_BIN="$(dirname "$0")/notify"
CONFIG="$HOME/.claude-notify.json"

# Check if terminal is focused — skip notification if so
BUNDLEID=$(python3 -c "import json;print(json.load(open('$CONFIG')).get('terminalBundleId',''))" 2>/dev/null)
FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null)
if [ "$FRONT" = "$BUNDLEID" ]; then
    exit 0
fi

# Read hook payload from stdin
INPUT=$(cat)

# Extract transcript path from hook payload
TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)

# Extract last assistant message from transcript
LAST_MSG="Finished working"
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    LAST_MSG=$(python3 -c "
import json, sys
with open('$TRANSCRIPT') as f:
    lines = f.readlines()
for line in reversed(lines):
    try:
        d = json.loads(line)
    except:
        continue
    if d.get('type') == 'assistant':
        c = d.get('message', {}).get('content', '')
        if isinstance(c, list):
            texts = [x.get('text', '') for x in c if x.get('type') == 'text']
            msg = texts[-1] if texts else ''
        else:
            msg = str(c)
        # Grab first line, truncate
        first_line = msg.strip().split('\n')[0][:150]
        if first_line:
            print(first_line)
        else:
            print('Finished working')
        sys.exit(0)
print('Finished working')
" 2>/dev/null || echo "Finished working")
fi

PROJECT=$(basename "$(pwd)")

pkill -f ClaudeNotify.app/Contents/MacOS/notify 2>/dev/null
nohup "$NOTIFY_BIN" 'Claude Code' "$PROJECT" "$LAST_MSG" >/dev/null 2>&1 & disown
