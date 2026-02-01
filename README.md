# loop.sh

A bash wrapper that runs [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) in an autonomous loop, re-invoking it until the task is fully complete.

## Why

Claude Code's CLI (`claude -p`) runs a single prompt-to-completion turn. For large tasks — fixing all tests, multi-step refactors, migrations — one turn often isn't enough. `loop.sh` re-runs the prompt automatically (up to a configurable limit), stopping only when Claude signals it's done.

## How it works

1. You provide a prompt (inline or from a file).
2. The script appends `DONE`/`CONTINUE` instructions to the prompt if not already present.
3. Each iteration calls `claude -p` with JSON streaming, logging the full output to `build-logs/`.
4. Assistant text is streamed to stdout in real time.
5. After each run, the script checks Claude's output:
   - **`DONE`** — task is complete, loop exits.
   - **`CONTINUE`** (or anything else) — loop runs again.
6. If the maximum number of runs is reached without `DONE`, the script exits with a warning.

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- `jq` (for parsing JSON stream output)
- Bash 4+

## Usage

```bash
# Run with an inline prompt
./loop.sh --prompt "fix all failing tests"

# Run with a prompt file
./loop.sh --prompt-file tasks/build-plan.txt

# Limit the number of iterations (default: 20)
./loop.sh --max-runs 5 --prompt "add logging to all API handlers"

```

### Options

| Flag | Description | Default |
|---|---|---|
| `--prompt "..."` | Inline prompt to send to Claude | *(required unless `--prompt-file`)* |
| `--prompt-file FILE` | Read the prompt from a file | |
| `--max-runs N` | Maximum loop iterations | `20` |
| `--no-update` | Skip the auto-update check on startup | |
| `--help` | Show help | |

## Automated Permissions via PermissionRequest Hook

Instead of pre-configuring allowed tools in `settings.local.json`, this project uses a `PermissionRequest` prompt hook (defined in `.claude/settings.json`). When Claude Code requests permission for a tool action, the hook routes the request to Claude Opus 4.5 for evaluation. Safe dev commands are approved automatically; dangerous operations (deleting files outside the project, modifying system files, exfiltrating data) are denied.

To see hook execution in action, run `claude --debug`.

## Auto-update

On startup, `loop.sh` checks for a newer version from the main branch on GitHub. If an update is available, it prompts you to apply it. The check is skipped silently if the script has local modifications in a git repo or if the download fails. Pass `--no-update` to skip this check entirely.

## Logs

Every run is logged as a full JSON stream to `build-logs/run_<N>_<timestamp>.log`. These logs contain the complete Claude API response including tool use, reasoning, and result text.

## License

MIT
