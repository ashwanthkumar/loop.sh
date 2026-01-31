#!/usr/bin/env bash
set -euo pipefail

# Autonomous Claude CLI loop
# Runs Claude CLI repeatedly with a prompt until it outputs DONE
# Usage: ./loop.sh [--max-runs N] [--prompt "custom prompt"]
#        ./loop.sh --prompt-file prompt.txt

MAX_RUNS=20
LOG_DIR="./build-logs"
CUSTOM_PROMPT=""
PROMPT_FILE=""
CHECK_MODE=false
YES_MODE=false

usage() {
  cat <<'EOF'
Usage: ./loop.sh [OPTIONS]

Runs Claude CLI in a loop until it outputs DONE.

Options:
  --prompt "..."       Inline prompt to run repeatedly
  --prompt-file FILE   Read prompt from a file
  --max-runs N         Maximum number of runs (default: 20)
  --check              Check if .claude/settings.local.json has all permissions needed for the prompt
  --yes                With --check, actually apply the missing permissions to settings file (default: no)
  --help               Show this help message

Examples:
  ./loop.sh --prompt "fix all failing tests"         # Custom task
  ./loop.sh --prompt-file tasks/build-plan.txt       # Prompt from file
  ./loop.sh --max-runs 5 --prompt "add logging"      # Limit runs
  ./loop.sh --check --prompt "run tests and fix bugs" # Check permissions
  ./loop.sh --check --yes --prompt "run tests"        # Check and apply permissions

Requires --prompt or --prompt-file.
Claude outputs DONE when finished, CONTINUE when there's more work.
Full JSON stream goes to build-logs/, assistant text shown on stdout.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --max-runs) MAX_RUNS="$2"; shift 2 ;;
    --prompt) CUSTOM_PROMPT="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --check) CHECK_MODE=true; shift ;;
    --yes) YES_MODE=true; shift ;;
    --help|-h) usage ;;
    *) echo "Unknown option: $1"; echo "Run ./loop.sh --help for usage."; exit 1 ;;
  esac
done

mkdir -p "$LOG_DIR"

if [[ -n "$PROMPT_FILE" ]]; then
  PROMPT=$(cat "$PROMPT_FILE")
elif [[ -n "$CUSTOM_PROMPT" ]]; then
  PROMPT="$CUSTOM_PROMPT"
else
  echo "Error: No prompt provided. Use --prompt or --prompt-file."
  echo "Run ./loop.sh --help for usage."
  exit 1
fi

# --check mode: ask Claude to analyse permissions needed
if [[ "$CHECK_MODE" == true ]]; then
  SETTINGS_FILE=".claude/settings.local.json"
  SETTINGS_CONTENT="{}"
  [[ -f "$SETTINGS_FILE" ]] && SETTINGS_CONTENT=$(cat "$SETTINGS_FILE")

  if [[ "$YES_MODE" == true ]]; then
    CHECK_PROMPT="You are a permissions auditor for Claude Code's autonomous mode.

Given this task prompt:
---
$PROMPT
---

And the current .claude/settings.local.json:
---
$SETTINGS_CONTENT
---

Analyse what bash commands and tools Claude would need to run autonomously for this task.
Compare against the allowedTools list in settings.local.json.
Output ONLY the updated JSON for .claude/settings.local.json with the missing permissions added to the allowedTools array.
Preserve all existing settings. Output raw JSON only, no markdown fences or commentary."

    UPDATED_SETTINGS=$(claude -p "$CHECK_PROMPT")

    # Validate JSON before writing
    if echo "$UPDATED_SETTINGS" | jq empty 2>/dev/null; then
      mkdir -p "$(dirname "$SETTINGS_FILE")"
      echo "$UPDATED_SETTINGS" | jq . > "$SETTINGS_FILE"
      echo "✅ Updated $SETTINGS_FILE with required permissions."
      echo ""
      cat "$SETTINGS_FILE"
    else
      echo "⚠️  Claude returned invalid JSON. Raw output:"
      echo "$UPDATED_SETTINGS"
      exit 1
    fi
  else
    claude -p "You are a permissions auditor for Claude Code's autonomous mode.

Given this task prompt:
---
$PROMPT
---

And the current .claude/settings.local.json:
---
$SETTINGS_CONTENT
---

Analyse what bash commands and tools Claude would need to run autonomously for this task.
Compare against the allowedTools list in settings.local.json.
List any missing permissions that should be added to allowedTools for fully autonomous execution.
Output a concise report: what's present, what's missing, and the exact entries to add.
If nothing is missing, say 'All permissions are configured.'"
  fi

  exit 0
fi

# Append DONE/CONTINUE instructions if not already present
if ! echo "$PROMPT" | grep -q "DONE"; then
  PROMPT="$PROMPT

When you are completely finished, output DONE as the very last line.
If there is still work to do, output CONTINUE as the very last line."
fi

echo "=== autonomous build loop ==="
echo "Max runs: $MAX_RUNS"
echo ""

for ((run=1; run<=MAX_RUNS; run++)); do
  timestamp=$(date +%Y%m%d_%H%M%S)
  log_file="$LOG_DIR/run_${run}_${timestamp}.log"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "▶  Run $run/$MAX_RUNS"
  echo "   Log: $log_file"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # --output-format stream-json: full JSON stream to log file
  # -p: print only the final result text to stdout
  claude -p "$PROMPT" --output-format stream-json --verbose > "$log_file" 2>&1 &
  claude_pid=$!

  # Tail the log in background, extract and display assistant text as it streams
  (
    tail -f "$log_file" 2>/dev/null | while IFS= read -r line; do
      # Extract assistant text content from JSON stream
      type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
      if [[ "$type" == "assistant" ]]; then
        echo "$line" | jq -r '.message.content[]? | select(.type == "text") | .text' 2>/dev/null
      elif [[ "$type" == "result" ]]; then
        echo "$line" | jq -r '.result // empty' 2>/dev/null
      fi
    done
  ) &
  tail_pid=$!

  wait "$claude_pid"
  exit_code=$?
  sleep 1
  kill "$tail_pid" 2>/dev/null || true

  if [[ "$exit_code" -ne 0 ]]; then
    echo ""
    echo "⚠️  Run $run exited with code $exit_code. Check log: $log_file"
    echo "   Re-run with: ./loop.sh --max-runs $((MAX_RUNS - run))"
    exit 1
  fi

  # Check for DONE/CONTINUE in the result message
  last_line=$(jq -r 'select(.type == "result") | .result // empty' "$log_file" 2>/dev/null | grep -oE '(DONE|CONTINUE)' | tail -1)

  if [[ "$last_line" == "DONE" ]]; then
    echo ""
    echo "✅ All steps complete after $run runs"
    break
  fi

  echo ""
  echo "↻  More work to do, continuing..."
  echo ""
done

if [[ "$run" -ge "$MAX_RUNS" && "$last_line" != "DONE" ]]; then
  echo ""
  echo "⛔ Reached max runs ($MAX_RUNS) without completing. Re-run to continue."
fi

echo ""
echo "=== Build loop finished ==="
echo "Logs in $LOG_DIR/"
