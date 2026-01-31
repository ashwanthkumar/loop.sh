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

usage() {
  cat <<'EOF'
Usage: ./loop.sh [OPTIONS]

Runs Claude CLI in a loop until it outputs DONE.

Options:
  --prompt "..."       Inline prompt to run repeatedly
  --prompt-file FILE   Read prompt from a file
  --max-runs N         Maximum number of runs (default: 20)
  --help               Show this help message

Examples:
  ./loop.sh --prompt "fix all failing tests"         # Custom task
  ./loop.sh --prompt-file tasks/build-plan.txt       # Prompt from file
  ./loop.sh --max-runs 5 --prompt "add logging"      # Limit runs

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
