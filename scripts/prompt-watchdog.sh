#!/bin/bash
# Monitors the main agent's <id>-channels tmux pane for interactive prompts and
# usage rate limits. Safe prompts (compact) are auto-handled. Rate limits are
# handled with a poll-and-verify retry loop (no fragile reset-time parsing).
# Unknown interactive prompts trigger a Telegram alert.
#
# Rate limit handling (poll-and-verify, version-proof):
#   - Detect the limit (interactive "Stop and wait" prompt OR inline
#     "You've hit your session limit" banner).
#   - Enter wait mode (marker file). Dismiss the interactive prompt with "1".
#   - Every ~10 min, if the session is idle, inject an English continue prompt
#     so the agent resumes the interrupted task from context (--continue keeps it).
#   - Verify: if a limit marker still shows, reschedule; if the agent is already
#     working again, just clear wait mode. Never parses the reset time, so a
#     wording change in a Claude Code update cannot break it.
#
# Safe auto-responses:
#   - Compact "Auto-compact"      -> "1" Enter
#
# Alert (never auto-accept):
#   - Any other "Enter to confirm" dialog

set -u

INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$INSTALL_DIR/store"
STATE_FILE="$STORE/.prompt-watchdog-state"
RL_MARKER="$STORE/.ratelimit-waiting"   # presence = waiting on a limit; content = next-retry epoch
LOG_TAG="prompt-watchdog"

# Approved English continue prompt. The session context survives (same --continue
# session), so one sentence is enough -- no need to restore the parked prompt.
CONTINUE_PROMPT="You were paused by a usage rate limit, which has now reset. Review your last task above and continue from where you left off. Do not restart from scratch."

RETRY_INTERVAL=600   # 10 min between retries
FIRST_DELAY=120      # first retry 2 min after detection (covers short resets cheaply)

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

PANE_CONTENT=$(tmux capture-pane -t "$SESSION" -p -S -40 2>/dev/null)
TAIL=$(echo "$PANE_CONTENT" | tail -n 10)
NOW=$(date +%s)

# Is the pane actively processing? (Claude shows "esc to interrupt" while working.)
is_busy() { echo "$TAIL" | grep -qi "esc to interrupt"; }

# The real interactive limit menu renders all three of these lines together.
# Requiring all three avoids false-firing on prose that merely mentions the
# phrase (this watchdog runs against the very session that may be discussing it).
has_interactive() {
  echo "$PANE_CONTENT" | grep -qF "Stop and wait for limit to reset" \
    && echo "$PANE_CONTENT" | grep -qF "Upgrade your plan" \
    && echo "$PANE_CONTENT" | grep -qF "Enter to confirm"
}

# Are we currently rate limited? Two real UI shapes, both deliberately strict:
#   - interactive menu  -> has_interactive (the three-line prompt)
#   - inline red banner -> the "hit your session limit" line AND the rendered
#     "/upgrade to increase your usage limit" command hint, in the tail only.
# Detection is best-effort; the retry cadence is the robustness layer, so being
# strict here (no self-trigger) is the right trade-off.
is_limited() {
  has_interactive && return 0
  echo "$TAIL" | grep -qi "hit your session limit" \
    && echo "$TAIL" | grep -qF "/upgrade to increase your usage limit"
}

# ---------------------------------------------------------------------------
# 1. Already waiting on a rate limit -> drive the retry loop.
# ---------------------------------------------------------------------------
if [ -f "$RL_MARKER" ]; then
  NEXT=$(cat "$RL_MARKER" 2>/dev/null || echo 0)
  case "$NEXT" in (*[!0-9]*|"") NEXT=0 ;; esac
  [ "$NOW" -lt "$NEXT" ] && exit 0   # not time yet

  if is_busy; then
    log "session active again -- clearing wait mode (resumed on its own)"
    rm -f "$RL_MARKER"
    exit 0
  fi

  if is_limited; then
    # Still limited. Dismiss the interactive prompt if it is up, then wait more.
    has_interactive && tmux send-keys -t "$SESSION" "1" Enter
    echo $((NOW + RETRY_INTERVAL)) > "$RL_MARKER"
    log "still rate-limited -- next retry in $((RETRY_INTERVAL/60)) min"
    exit 0
  fi

  # Idle, no limit marker -> try to resume the interrupted task.
  log "retry -- injecting continue prompt"
  tmux send-keys -t "$SESSION" "$CONTINUE_PROMPT" Enter
  sleep 9
  PANE_CONTENT=$(tmux capture-pane -t "$SESSION" -p -S -40 2>/dev/null)
  TAIL=$(echo "$PANE_CONTENT" | tail -n 10)
  if is_limited; then
    has_interactive && tmux send-keys -t "$SESSION" "1" Enter
    echo $((NOW + RETRY_INTERVAL)) > "$RL_MARKER"
    log "continue rejected, still limited -- next retry in $((RETRY_INTERVAL/60)) min"
  else
    rm -f "$RL_MARKER"
    log "rate limit cleared -- task resumed automatically"
    send_telegram "Rate limit cleared. I resumed the task automatically."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Fresh rate-limit detection -> enter wait mode.
# ---------------------------------------------------------------------------
if is_limited; then
  log "rate limit detected -- entering wait/retry mode"
  has_interactive && tmux send-keys -t "$SESSION" "1" Enter
  echo $((NOW + FIRST_DELAY)) > "$RL_MARKER"
  send_telegram "Rate limit detected. I'll auto-retry the task every ~$((RETRY_INTERVAL/60)) min until it clears. No action needed."
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Other interactive prompts (only when an "Enter to confirm" dialog waits).
# ---------------------------------------------------------------------------
if ! echo "$PANE_CONTENT" | grep -qF "Enter to confirm"; then
  exit 0
fi

# Avoid re-handling the same prompt
CONTENT_HASH=$(echo "$PANE_CONTENT" | md5sum | cut -d' ' -f1)
LAST_HASH=$(cat "$STATE_FILE" 2>/dev/null || echo "")
if [ "$CONTENT_HASH" = "$LAST_HASH" ]; then
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
