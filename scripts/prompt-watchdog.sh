#!/bin/bash
# Monitors the main agent's <id>-channels tmux pane for interactive prompts.
# Safe prompts (rate limit, compact) are auto-handled.
# Unknown interactive prompts trigger a Telegram alert.
#
# Safe auto-responses:
#   - Rate limit "Stop and wait"  -> "1" Enter
#   - Compact "Auto-compact"      -> "1" Enter
#
# Alert (never auto-accept):
#   - Any other "Enter to confirm" dialog

set -u

INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$INSTALL_DIR/store"
STATE_FILE="$STORE/.prompt-watchdog-state"
LOG_TAG="prompt-watchdog"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

# Resolve session name from .env
MAIN_AGENT_ID="$(grep -E '^MAIN_AGENT_ID=' "$INSTALL_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
MAIN_AGENT_ID="${MAIN_AGENT_ID:-marveen}"
MAIN_AGENT_ID="${MAIN_AGENT_ID//[^a-zA-Z0-9_-]/}"
SESSION="${MAIN_AGENT_ID}-channels"

send_telegram() {
  local msg="$1"
  local TOKEN CHAT_ID
  TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$INSTALL_DIR/.env" 2>/dev/null | cut -d= -f2-)
  CHAT_ID=$(grep '^ALLOWED_CHAT_ID=' "$INSTALL_DIR/.env" 2>/dev/null | cut -d= -f2-)
  [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ] && return
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${msg}" \
    -d "parse_mode=HTML" > /dev/null
}

# Check session exists
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  log "session $SESSION not found, skipping"
  exit 0
fi

# Capture last 40 lines of pane
PANE_CONTENT=$(tmux capture-pane -t "$SESSION" -p -S -40 2>/dev/null)

# Only act if "Enter to confirm" is present (means a dialog is waiting)
if ! echo "$PANE_CONTENT" | grep -qF "Enter to confirm"; then
  exit 0
fi

# Compute hash to avoid re-handling the same prompt
CONTENT_HASH=$(echo "$PANE_CONTENT" | md5sum | cut -d' ' -f1)
LAST_HASH=$(cat "$STATE_FILE" 2>/dev/null || echo "")
if [ "$CONTENT_HASH" = "$LAST_HASH" ]; then
  exit 0
fi

# Classify the prompt
if echo "$PANE_CONTENT" | grep -qF "Stop and wait for limit to reset"; then
  log "Rate limit prompt detected -- auto-selecting option 1 (wait)"
  # Record when the block started (used to find missed messages after unblock)
  BLOCK_TS=$(date -u +%Y-%m-%dT%H:%M:%S)
  echo "$CONTENT_HASH" > "$STATE_FILE"
  tmux send-keys -t "$SESSION" "1" Enter
  # After unblock: inject missed messages from MCP log into the session.
  # Wait for Claude to resume, then check for channel notifications that
  # arrived during the blocked period.
  (
    sleep 10
    # Claude Code encodes the project dir into the cache path by replacing every
    # "/" with "-" (e.g. /home/u/marveen -> -home-u-marveen). Derive it from
    # INSTALL_DIR so this works on any machine, no hardcoded user path.
    PROJECT_SLUG="${INSTALL_DIR//\//-}"
    MCP_DIR="$HOME/.cache/claude-cli-nodejs/${PROJECT_SLUG}/mcp-logs-plugin-telegram-telegram"
    CURRENT_LOG=$(ls -1t "$MCP_DIR"/*.jsonl 2>/dev/null | head -1)
    if [ -n "$CURRENT_LOG" ]; then
      MISSED=$(grep 'notifications/claude/channel:' "$CURRENT_LOG" 2>/dev/null \
        | python3 -c "
import sys, json
from datetime import datetime, timezone
block_ts = datetime.fromisoformat('${BLOCK_TS}').replace(tzinfo=timezone.utc)
msgs = []
for line in sys.stdin:
    try:
        d = json.loads(line)
        text = d.get('debug','')
        ts_str = d.get('timestamp','')
        if 'notifications/claude/channel:' not in text: continue
        ts = datetime.fromisoformat(ts_str.replace('Z','+00:00'))
        if ts >= block_ts:
            msg = text.split('notifications/claude/channel: ', 1)[-1][:200]
            msgs.append(msg)
    except: pass
print('\n'.join(msgs))
" 2>/dev/null)
      if [ -n "$MISSED" ]; then
        tmux send-keys -t "$SESSION" "[Messages that arrived during the rate limit, process them:
${MISSED}]" Enter
      fi
    fi
  ) &
  exit 0
fi

if echo "$PANE_CONTENT" | grep -qiE "auto.compact|compacting context|compact.*(recommended)"; then
  log "Compact prompt detected -- auto-selecting option 1 (auto-compact)"
  tmux send-keys -t "$SESSION" "1" Enter
  echo "$CONTENT_HASH" > "$STATE_FILE"
  exit 0
fi

# Unknown interactive prompt -- alert the operator, do NOT auto-accept
log "Unknown interactive prompt detected -- sending Telegram alert"
SNIPPET=$(echo "$PANE_CONTENT" | grep -A5 -B2 "Enter to confirm" | head -10 | tr '\n' '|' | sed 's/|/ · /g' | cut -c1-300)
send_telegram "Stuck. Manual action needed.

<code>${SNIPPET}</code>

<code>tmux attach -t ${SESSION}</code>"
echo "$CONTENT_HASH" > "$STATE_FILE"
log "Alert sent for unknown prompt"
exit 0
