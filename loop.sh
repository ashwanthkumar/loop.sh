#!/usr/bin/env bash
set -euo pipefail

# Autonomous Claude CLI loop
# Runs Claude CLI repeatedly with a prompt until it outputs DONE
# Usage: ./loop.sh [--max-runs N] [--prompt "custom prompt"]
#        ./loop.sh --prompt-file prompt.txt

UPDATE_URL="https://raw.githubusercontent.com/ashwanthkumar/loop.sh/refs/heads/main/loop.sh"

# Auto-update check (silently ignored on failure)
check_for_updates() {
  # Resolve the actual path of this script (handles symlinks and relative paths)
  local self
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  [[ -f "$self" ]] || return 0

  local tmp
  tmp=$(mktemp) || return 0
  trap 'rm -f "$tmp"' RETURN

  # Download latest version; silently bail on any failure
  if ! curl -fsSL --connect-timeout 5 --max-time 10 "$UPDATE_URL" -o "$tmp" 2>/dev/null; then
    return 0
  fi

  # Verify the download looks like a valid shell script
  if ! head -1 "$tmp" 2>/dev/null | grep -q '^#!/'; then
    return 0
  fi

  # Skip update if the script is in a git repo with local modifications
  if command -v git &>/dev/null && git -C "$(dirname "$self")" rev-parse --is-inside-work-tree &>/dev/null; then
    if ! git -C "$(dirname "$self")" diff --quiet -- "$self" 2>/dev/null; then
      return 0
    fi
  fi

  # Compare with current script
  if cmp -s "$self" "$tmp"; then
    return 0
  fi

  echo "A new version of loop.sh is available."
  read -rp "Do you want to update? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    cp "$tmp" "$self"
    chmod +x "$self"
    echo "Updated. Please re-run the script."
    exit 0
  else
    echo "Skipping update."
  fi
}

NO_UPDATE=false

# Parse --no-update early (before main arg parsing) so it's handled before the update check
for arg in "$@"; do
  [[ "$arg" == "--no-update" ]] && NO_UPDATE=true && break
done

[[ "$NO_UPDATE" == false ]] && check_for_updates

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
  --no-update          Skip the auto-update check
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
    --no-update) shift ;;  # already handled above
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
  disown "$tail_pid" 2>/dev/null || true
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true

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
