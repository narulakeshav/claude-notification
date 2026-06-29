#!/bin/bash
# island-hook.sh — dispatches Claude Code hook events to the notch daemon.
# Usage: island-hook.sh <prompt|tool|attention|stop>
# Reads the hook JSON payload on stdin, builds a normalized payload, pipes to
# island-send. Left shows a verb (or "Done"); right shows a clip of Claude's
# latest message, read live from the transcript.

EVENT="$1"
SEND="$(dirname "$0")/island-send"
INPUT=$(cat)

PROJECT=$(echo "$INPUT" | python3 -c "
import sys, json, os
try: d = json.load(sys.stdin)
except: d = {}
cwd = d.get('cwd') or os.getcwd()
print(os.path.basename(cwd.rstrip('/')) or 'Claude Code')
" 2>/dev/null)
[ -z "$PROJECT" ] && PROJECT="Claude Code"
TITLE="Claude Code · $PROJECT"

# Warp sets a per-tab/pane deep link in the shell env (warp://session/<uuid>).
# Hooks run as children of Claude Code inside that tab, so we inherit it and can
# refocus the exact tab on click — not just bring Warp forward. This is also the
# per-session key the multi-session UX will hang off of.
FOCUS="${WARP_FOCUS_URL:-}"

# Per-tab identity (Warp's session UUID) keys this session's state file, so the
# daemon shows one card per tab and routes clicks back to the right one. Falls
# back to the UUID inside the focus URL, then to "local" for non-Warp shells.
TAB_UUID="${WARP_TERMINAL_SESSION_UUID:-}"
[ -z "$TAB_UUID" ] && [ -n "$FOCUS" ] && TAB_UUID="${FOCUS##*/}"
[ -z "$TAB_UUID" ] && TAB_UUID="local"
SESSION_OUT="sessions/${TAB_UUID}.json"
TS=$(date +%s)
CWD=$(echo "$INPUT" | python3 -c "import sys,json,os;d=json.load(sys.stdin);print(d.get('cwd') or os.getcwd())" 2>/dev/null)

TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)

# Session title shown on the card. A manual /rename (custom-title) wins over Claude's
# auto-generated ai-title; fall back to the latest ai-title when no custom name is set.
AITITLE=$(python3 -c "
import json
custom = ''; ai = ''
try:
    for line in reversed(open('$TRANSCRIPT').readlines()[-500:]):
        try: d = json.loads(line)
        except: continue
        t = d.get('type')
        if t == 'custom-title' and not custom:
            custom = d.get('customTitle', '') or ''
            break                      # most-recent manual rename wins outright
        if t == 'ai-title' and not ai:
            ai = d.get('aiTitle', '') or ''
except: pass
print(custom or ai)
" 2>/dev/null)

# Context-window fill (0..1) from the latest assistant entry's token usage.
# input + cache_read + cache_creation ≈ the live prompt size. The transcript
# strips the model's "[1m]" suffix, so the window can't be read reliably from
# the model id; honor an explicit override in ~/.claude-island/context-window
# (a plain integer), else infer 1M once usage exceeds the 200k base window.
CTX=$(python3 -c "
import json, os
tx = '$TRANSCRIPT'
override = 0
try:
    override = int(open(os.path.expanduser('~/.claude-island/context-window')).read().strip())
except: pass
pct = 0.0
try:
    for line in reversed(open(tx).readlines()[-200:]):
        try: d = json.loads(line)
        except: continue
        if d.get('type') != 'assistant': continue
        u = d.get('message', {}).get('usage', {}) or {}
        total = (u.get('input_tokens', 0) + u.get('cache_read_input_tokens', 0)
                 + u.get('cache_creation_input_tokens', 0))
        if total <= 0: break
        window = override if override > 0 else (1_000_000 if total > 200_000 else 200_000)
        pct = max(0.0, min(1.0, total / window))
        break
except: pass
print(round(pct, 4))
" 2>/dev/null)
[ -z "$CTX" ] && CTX=0

# Whimsical status verbs in the spirit of Claude Code's own spinner (the real
# word isn't exposed to hooks). A fresh one fires on each prompt/tool event.
GERUNDS=(
"Accomplishing" "Actioning" "Actualizing" "Architecting" "Baking" "Beaming" "Beboppin'" \
"Befuddling" "Billowing" "Blanching" "Bloviating" "Boogieing" "Boondoggling" "Booping" \
"Bootstrapping" "Brewing" "Bunning" "Burrowing" "Calculating" "Canoodling" "Caramelizing" \
"Cascading" "Catapulting" "Cerebrating" "Channeling" "Channelling" "Choreographing" "Churning" \
"Clauding" "Coalescing" "Cogitating" "Combobulating" "Composing" "Computing" "Concocting" \
"Considering" "Contemplating" "Cooking" "Crafting" "Creating" "Crunching" "Crystallizing" \
"Cultivating" "Deciphering" "Deliberating" "Determining" "Dilly-dallying" "Discombobulating" \
"Doing" "Doodling" "Drizzling" "Ebbing" "Effecting" "Elucidating" "Embellishing" "Enchanting" \
"Envisioning" "Evaporating" "Fermenting" "Fiddle-faddling" "Finagling" "Flambéing" \
"Flibbertigibbeting" "Flowing" "Flummoxing" "Fluttering" "Forging" "Forming" "Frolicking" \
"Frosting" "Gallivanting" "Galloping" "Garnishing" "Generating" "Gesticulating" "Germinating" \
"Gitifying" "Grooving" "Gusting" "Harmonizing" "Hashing" "Hatching" "Herding" "Honking" \
"Hullaballooing" "Hyperspacing" "Ideating" "Imagining" "Improvising" "Incubating" "Inferring" \
"Infusing" "Ionizing" "Jitterbugging" "Julienning" "Kneading" "Leavening" "Levitating" \
"Lollygagging" "Manifesting" "Marinating" "Meandering" "Metamorphosing" "Misting" "Moonwalking" \
"Moseying" "Mulling" "Mustering" "Musing" "Nebulizing" "Nesting" "Newspapering" "Noodling" \
"Nucleating" "Orbiting" "Orchestrating" "Osmosing" "Perambulating" "Percolating" "Perusing" \
"Philosophising" "Photosynthesizing" "Pollinating" "Pondering" "Pontificating" "Pouncing" \
"Precipitating" "Prestidigitating" "Processing" "Proofing" "Propagating" "Puttering" "Puzzling" \
"Quantumizing" "Razzle-dazzling" "Razzmatazzing" "Recombobulating" "Reticulating" "Roosting" \
"Ruminating" "Sautéing" "Scampering" "Schlepping" "Scurrying" "Seasoning" "Shenaniganing" \
"Shimmying" "Simmering" "Skedaddling" "Sketching" "Slithering" "Smooshing" "Sock-hopping" \
"Spelunking" "Spinning" "Sprouting" "Stewing" "Sublimating" "Swirling" "Swooping" "Symbioting" \
"Synthesizing" "Tempering" "Thundering" "Tinkering" "Tomfoolering" "Topsy-turvying" \
"Transfiguring" "Transmuting" "Twisting" "Undulating" "Unfurling" "Unravelling" "Vibing" \
"Waddling" "Wandering" "Warping" "Whatchamacalliting" "Whirlpooling" "Whirring" "Whisking" \
"Wibbling" "Working" "Wrangling" "Zesting" "Zigzagging"
)
pick() { echo "${GERUNDS[$((RANDOM % ${#GERUNDS[@]}))]}"; }

# Count of trailing consecutive errored tool steps (a tool_result with is_error) in the
# transcript, newest first; the first successful tool_result breaks the streak. A single tool
# error is routine (the agent reads it and recovers), but a run of them = the agent is stuck,
# which we surface as a "struggling" state.
consec_tool_errors() {
    [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || { echo 0; return; }
    python3 -c "
import json
n = 0
try:
    for line in reversed(open('$TRANSCRIPT').readlines()[-400:]):
        try: d = json.loads(line)
        except: continue
        if d.get('type') != 'user': continue
        c = d.get('message', {}).get('content', '')
        if not isinstance(c, list): continue
        trs = [b for b in c if isinstance(b, dict) and b.get('type') == 'tool_result']
        if not trs: continue                 # not a tool step — skip (assistant text etc.)
        if any(b.get('is_error') for b in trs): n += 1
        else: break                          # a clean tool result ends the streak
except: pass
print(n)
" 2>/dev/null
}

# First line of Claude's most recent assistant text in the transcript.
latest_text() {
    [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || { echo ""; return; }
    python3 -c "
import json
last = ''
try:
    lines = open('$TRANSCRIPT').readlines()[-400:]
    for line in reversed(lines):
        try: d = json.loads(line)
        except: continue
        if d.get('type') == 'assistant':
            c = d.get('message', {}).get('content', '')
            if isinstance(c, list):
                texts = [x.get('text','') for x in c if x.get('type') == 'text']
                msg = texts[-1] if texts else ''
            else:
                msg = str(c)
            first = msg.strip().split(chr(10))[0][:120]
            if first:           # skip tool_use-only entries; keep scanning back
                last = first
                break
except: pass
print(last)
" 2>/dev/null
}

# The session's opening user prompt — a stickier "which convo is this" anchor than the
# tab name. Scans forward for the first real typed message, skipping tool results,
# command wrappers, caveats, and system reminders. Capped to one line.
FIRSTPROMPT=$(python3 -c "
import json
out = ''
try:
    with open('$TRANSCRIPT') as f:
        for line in f:
            try: d = json.loads(line)
            except: continue
            if d.get('type') != 'user' or d.get('isMeta'): continue
            c = d.get('message', {}).get('content', '')
            if isinstance(c, list):
                msg = ' '.join(x.get('text','') for x in c
                               if isinstance(x, dict) and x.get('type') == 'text')
            else:
                msg = str(c)
            msg = ' '.join(msg.split())
            if not msg: continue
            if msg.startswith(('<command-', '<local-command', '<system-reminder', '<task-notification', 'Caveat:', '[Request interrupted')): continue
            if any(b in msg for b in ('</tool-use-id>', '<tool-use-id>', '<output-file>', '<task-id>', '<task-notification')): continue
            out = msg[:80]
            break
except: pass
print(out)
" 2>/dev/null)

# The session's MOST RECENT typed user message, for the hover-peek marquee. On a
# UserPromptSubmit the prompt is in the payload directly — prefer it: it's clean and avoids
# the one-event lag (the transcript hasn't been written yet at that point). Otherwise scan
# the tail, skipping system-injected pseudo-"user" messages (slash-command wrappers, caveats,
# and especially <task-notification>/<tool-use-id>/<output-file> blocks from background tasks).
LASTPROMPT=$(echo "$INPUT" | python3 -c "
import sys, json
SKIP_PREFIX = ('<command-','<local-command','<system-reminder','<task-notification','Caveat:','[Request interrupted')
SKIP_CONTAIN = ('</tool-use-id>','<tool-use-id>','<output-file>','<task-id>','<task-notification')
def real(m):
    m = ' '.join((m or '').split())
    if not m or m.startswith(SKIP_PREFIX): return ''
    if any(b in m for b in SKIP_CONTAIN): return ''
    return m
d = {}
try: d = json.load(sys.stdin)
except: pass
out = real(d.get('prompt',''))
if not out:
    try:
        for line in reversed(open('$TRANSCRIPT').readlines()[-500:]):
            try: e = json.loads(line)
            except: continue
            if e.get('type') != 'user' or e.get('isMeta'): continue
            c = e.get('message', {}).get('content', '')
            if isinstance(c, list):
                m = ' '.join(x.get('text','') for x in c if isinstance(x,dict) and x.get('type')=='text')
            else:
                m = str(c)
            m = real(m)
            if m: out = m; break
    except: pass
print(out[:200])
" 2>/dev/null)

emit() { # emit <mode> <detail> <preview>
    # qHeader/qText carry a pending AskUserQuestion (empty on every other emit, so a normal
    # turn clears the previous question). emit_keep omits them, so they're retained across a
    # follow-up Notification for the same pause.
    python3 -c "
import json, sys, os
print(json.dumps({'mode': sys.argv[1], 'detail': sys.argv[2], 'preview': sys.argv[3],
                  'project': sys.argv[4], 'title': sys.argv[5], 'context': float(sys.argv[6]),
                  'focus': sys.argv[7], 'id': sys.argv[8], 'aiTitle': sys.argv[9],
                  'cwd': sys.argv[10], 'ts': float(sys.argv[11]), 'kind': sys.argv[12],
                  'transcript': sys.argv[13], 'firstPrompt': sys.argv[14], 'lastPrompt': sys.argv[15],
                  'qHeader': os.environ.get('QHEADER',''), 'qText': os.environ.get('QTEXT','')}))
" "$1" "$2" "$3" "$PROJECT" "$TITLE" "$CTX" "$FOCUS" "$TAB_UUID" "$AITITLE" "$CWD" "$TS" "$EVENT" "$TRANSCRIPT" "$FIRSTPROMPT" "$LASTPROMPT" | "$SEND" "$SESSION_OUT"
}

emit_keep() { # emit <mode> <detail>, omitting preview so the daemon retains it
    python3 -c "
import json, sys
print(json.dumps({'mode': sys.argv[1], 'detail': sys.argv[2], 'project': sys.argv[3],
                  'title': sys.argv[4], 'context': float(sys.argv[5]), 'focus': sys.argv[6],
                  'id': sys.argv[7], 'aiTitle': sys.argv[8], 'cwd': sys.argv[9],
                  'ts': float(sys.argv[10]), 'kind': sys.argv[11], 'transcript': sys.argv[12],
                  'firstPrompt': sys.argv[13], 'lastPrompt': sys.argv[14]}))
" "$1" "$2" "$PROJECT" "$TITLE" "$CTX" "$FOCUS" "$TAB_UUID" "$AITITLE" "$CWD" "$TS" "$EVENT" "$TRANSCRIPT" "$FIRSTPROMPT" "$LASTPROMPT" | "$SEND" "$SESSION_OUT"
}

case "$EVENT" in
    prompt)
        # Turn just started: Claude is thinking, no narration/tool yet.
        emit thinking "Thinking…" ""
        ;;
    tool)
        # AskUserQuestion always pauses for the user, so treat it as "needs input" right here
        # (PreToolUse) — don't wait on a Notification that may not fire. Carry the question's
        # short header + full text so the dropdown row can show exactly what's being asked.
        TOOL=$(echo "$INPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('tool_name','') or '')" 2>/dev/null)
        if [ "$TOOL" = "AskUserQuestion" ]; then
            eval "$(echo "$INPUT" | python3 -c "
import sys, json, shlex
d = json.load(sys.stdin)
qs = (d.get('tool_input',{}) or {}).get('questions') or []
q = qs[0] if qs else {}
print('export QHEADER=' + shlex.quote((q.get('header','') or '')[:40]))
print('export QTEXT=' + shlex.quote((q.get('question','') or '')[:160]))
" 2>/dev/null)"
            emit attention "Input Needed" ""
            exit 0
        fi
        # Left = a playful gerund (Claude Code's own spinner vocabulary — the real word isn't
        # exposed to hooks, so we pick our own). Right = the concrete action: Claude's text if
        # its latest block is text, else "<verb> <target>" (file / command / pattern).
        PREVIEW=$(echo "$INPUT" | python3 -c "
import sys, json, os
d = json.load(sys.stdin)
tx = d.get('transcript_path','')
last_kind=''; last_text=''
try:
    for line in reversed(open(tx).readlines()[-400:]):
        try: e=json.loads(line)
        except: continue
        if e.get('type')=='assistant':
            c=e.get('message',{}).get('content','')
            if isinstance(c,list) and c:
                lb=c[-1]
                last_kind=lb.get('type','')
                ts=[b.get('text','') for b in c if b.get('type')=='text']
                if ts: last_text=ts[-1]
            break
except: pass
if last_kind=='text' and last_text.strip():
    print(last_text.strip().split(chr(10))[0][:60])
else:
    tool=d.get('tool_name',''); ti=d.get('tool_input',{}) or {}
    base=lambda p: os.path.basename(p) if p else ''
    if tool in ('Edit','MultiEdit','Write','Read'): tgt=base(ti.get('file_path',''))
    elif tool=='NotebookEdit': tgt=base(ti.get('notebook_path',''))
    elif tool=='Bash':
        parts=(ti.get('command','') or '').strip().split(); tgt=parts[0] if parts else ''
    elif tool in ('Grep','Glob'): tgt=ti.get('pattern','')
    else: tgt=''
    label={'Edit':'Editing','MultiEdit':'Editing','Write':'Writing','Read':'Reading',
           'NotebookEdit':'Editing','Bash':'Running','Grep':'Searching','Glob':'Finding',
           'Task':'Delegating','WebFetch':'Fetching','WebSearch':'Searching','TodoWrite':'Planning'}.get(tool,tool)
    print((label+' '+tgt).strip())
" 2>/dev/null)
        # Mid-streak of consecutive tool failures → the agent is stuck, show "Struggling…";
        # otherwise the normal playful gerund.
        if [ "$(consec_tool_errors)" -ge 3 ]; then
            emit struggling "Struggling…" "$PREVIEW"
        else
            emit working "$(pick)…" "$PREVIEW"
        fi
        ;;
    post)
        # A tool just finished. A tool error is routine — the agent reads it and recovers — so
        # we DON'T flip to the red error state for it (that red is reserved for API/connection
        # failures, detected daemon-side). Instead, a RUN of consecutive failures surfaces as
        # the amber "struggling" state.
        ERR=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
tx = d.get('transcript_path','')
def text_of(c):
    if isinstance(c, list):
        return ' '.join(b.get('text','') if isinstance(b,dict) else str(b) for b in c)
    return str(c or '')
msg = ''
try:
    for line in reversed(open(tx).readlines()[-200:]):
        try: e = json.loads(line)
        except: continue
        if e.get('type') != 'user': continue
        c = e.get('message',{}).get('content','')
        if not isinstance(c, list): continue
        for b in c:
            if isinstance(b, dict) and b.get('type') == 'tool_result' and b.get('is_error'):
                msg = text_of(b.get('content',''))
        break
except: pass
print(' '.join(msg.split())[:120])
" 2>/dev/null)
        CURMODE=$(python3 -c "
import json, os
try: print(json.load(open(os.path.expanduser('~/.claude-island/$SESSION_OUT'))).get('mode',''))
except: print('')
" 2>/dev/null)
        if [ -n "$ERR" ]; then
            # This tool failed. If it's the 3rd+ failure in a row, surface "Struggling…";
            # otherwise stay quiet (the next PreToolUse refreshes the working verb).
            if [ "$(consec_tool_errors)" -ge 3 ]; then emit struggling "Struggling…" "$ERR"; fi
        else
            # A clean tool result. If we were parked on the user (AskUserQuestion answer or a
            # permission prompt) or stuck "Struggling…", the agent is moving again — flip back
            # to a live state instead of leaving the stale label until the next prompt.
            if [ "$CURMODE" = "attention" ]; then emit thinking "Thinking…" "";
            elif [ "$CURMODE" = "struggling" ]; then emit working "$(pick)…" ""; fi
        fi
        ;;
    attention)
        NT=$(echo "$INPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('notification_type','') or '')" 2>/dev/null)
        if [ "$NT" = "idle_prompt" ]; then
            # idle_prompt is a PASSIVE nudge Claude Code fires ~60s after any idle — it does
            # NOT mean the user is actually needed. So it must never manufacture a red
            # "Waiting for input" state. A done session stays green "Finished"; a session
            # still parked in working/thinking here means its turn was interrupted (Esc fires
            # no Stop), so settle it to a calm "Finished" rather than a stuck spinner or a
            # false attention. (Real permission/question prompts use the else-branch.)
            CURMODE=$(python3 -c "
import json, os
try: print(json.load(open(os.path.expanduser('~/.claude-island/$SESSION_OUT'))).get('mode',''))
except: print('')
" 2>/dev/null)
            if [ "$CURMODE" = "working" ] || [ "$CURMODE" = "thinking" ]; then emit done "" ""; fi
        else
            # Permission: keep the pending tool action (set by the preceding
            # PreToolUse) on the right, label the left "Permission".
            emit_keep attention "Permission"
        fi
        ;;
    stop)
        # The Stop payload carries the full final message — reliable, no transcript race.
        MSG=$(echo "$INPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('last_assistant_message','') or '')" 2>/dev/null)
        emit done "" "$MSG"
        ;;
    compact)
        # PreCompact: the transcript is about to be compacted (manual /compact or auto when
        # the context fills). Show the periwinkle "Compacting…" state until it completes.
        emit compacting "Compacting…" ""
        ;;
    sessionstart)
        # SessionStart fires for startup/resume/clear/compact. Only the compact source means
        # a compaction just finished — flip to the "Compacted" success state. Ignore the rest
        # so a fresh launch/resume never clobbers the live state.
        SRC=$(echo "$INPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('source','') or '')" 2>/dev/null)
        # The latest assistant usage at this instant is the *summarization* call, which read the
        # full pre-compaction context — i.e. stale-high. Force the ring low so it reflects the new
        # compacted size; the next real turn recomputes the accurate value.
        if [ "$SRC" = "compact" ]; then CTX=0; emit compacted "Compacted" ""; fi
        ;;
    *)
        exit 0
        ;;
esac

# Never let a hook's incidental exit code (e.g. a falsy test on the last line)
# bubble up — Claude Code reports any non-zero hook exit as an error.
exit 0
