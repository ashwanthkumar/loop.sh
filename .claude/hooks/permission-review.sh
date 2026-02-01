#!/usr/bin/env bash
set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

PROMPT="You are a security reviewer for Claude Code tool permissions. Evaluate whether this tool action is safe for a software development workflow.

Tool: ${TOOL_NAME}
Input: ${TOOL_INPUT}

Rules:
- ALLOW: Read, Edit, Write, Glob, Grep, WebSearch, WebFetch on project files
- ALLOW: Bash commands for standard dev tools (git, npm, pytest, uv, pip, cargo, make, docker, gh, curl, ls, cat, find, grep, etc.)
- ALLOW: Bash commands that run tests, linters, formatters, build tools
- DENY: Bash commands that delete files outside the project (rm -rf /, rm -rf ~)
- DENY: Bash commands that modify system files (/etc, /usr)
- DENY: Bash commands that install global packages without clear dev purpose
- DENY: Bash commands that exfiltrate data to unknown external services
- DENY: Commands accessing secrets/credentials outside the project
- When in doubt, DENY — err on the side of caution

Respond with ONLY JSON, no markdown fences:
To allow: {\"decision\": \"allow\"}
To deny: {\"decision\": \"deny\", \"reason\": \"brief explanation\"}"

RESPONSE=$(claude -p "$PROMPT" --model claude-opus-4-5 2>/dev/null || echo '{"decision":"deny","reason":"Failed to evaluate"}')

DECISION=$(echo "$RESPONSE" | jq -r '.decision // "deny"')
REASON=$(echo "$RESPONSE" | jq -r '.reason // "Denied by security reviewer"')

if [[ "$DECISION" == "allow" ]]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
else
  jq -nc --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","reason":$reason}}}'
fi
