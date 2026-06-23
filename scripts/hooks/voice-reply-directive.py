#!/usr/bin/env python3
"""UserPromptSubmit hook: voice-reply directive injection.

When a voice message is delivered to a voice/auto-mode agent, this hook
appends a ready-to-run TTS curl directive to the prompt so the agent knows
to reply with voice instead of text.

Claude Code delivers stdout from UserPromptSubmit hooks directly into the model
prompt (no JSON wrapper needed -- plain text is injected as-is). This hook
stays completely silent for non-voice messages.

Never raises: any error results in a silent exit(0) so the prompt is never blocked.
"""
import sys
import os
import json
import re
import urllib.request


def _project_root():
    # scripts/hooks/ -> project root (two dirs up)
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _web_port():
    port = os.environ.get("WEB_PORT")
    if not port:
        try:
            with open(os.path.join(_project_root(), ".env")) as f:
                for line in f:
                    if line.startswith("WEB_PORT="):
                        port = line.split("=", 1)[1].strip().strip('"\'')
                        break
        except Exception:
            pass
    return port or "3420"


def _token():
    try:
        with open(os.path.join(_project_root(), "store", ".dashboard-token")) as f:
            return f.read().strip()
    except Exception:
        return ""


def _agent_id(cwd):
    if not cwd:
        return None
    parts = os.path.normpath(cwd).split(os.sep)
    if "agents" in parts:
        i = parts.index("agents")
        if i + 1 < len(parts):
            return parts[i + 1]
    return None


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    prompt = payload.get("prompt") or ""

    # Only fire for voice inbound messages
    if 'attachment_kind="voice"' not in prompt:
        sys.exit(0)

    # Extract chat_id from <channel chat_id="...">
    m = re.search(r'\bchat_id="(\d+)"', prompt)
    if not m:
        sys.exit(0)
    chat_id = m.group(1)

    agent_id = _agent_id(payload.get("cwd"))
    if not agent_id:
        sys.exit(0)

    token = _token()
    if not token:
        sys.exit(0)

    port = _web_port()
    url = "http://localhost:%s/api/voice/directive?agent=%s&chat=%s" % (port, agent_id, chat_id)
    try:
        req = urllib.request.Request(url)
        req.add_header("Authorization", "Bearer " + token)
        with urllib.request.urlopen(req, timeout=5) as r:
            data = json.load(r)
    except Exception:
        sys.exit(0)  # dashboard unavailable -- fail-safe, no directive injected

    directive = data.get("directive")
    if directive:
        # Plain text stdout is injected directly into the model prompt by Claude Code.
        sys.stdout.write(directive)
        sys.stdout.flush()

    sys.exit(0)


if __name__ == "__main__":
    main()
