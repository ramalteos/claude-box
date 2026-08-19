#!/usr/bin/env bash
# claude-box container entrypoint.
#
# Two jobs, in this order:
#   1. work out what we were actually asked to run, and
#   2. refresh Claude Code first — but ONLY when that command is `claude`.
#
# The order matters: a `./claude-box shell` should hand you a prompt now, not
# after a package install it has no use for. Explicit commands (bash, git, …)
# skip the refresh and print how to run it by hand.
#
# The refresh itself is best-effort and non-fatal; see update-claude.sh.
set -euo pipefail

# Runner args REPLACE the image CMD (`container run <img> --resume` → argv is
# just `--resume`), so a bare flag would arrive here as the command to exec and
# die with "exec: --: invalid option". Re-attach it to `claude`; a leading dash
# is the tell. `shell` and explicit commands ($1 = bash, claude, …) exec as-is.
if [ "$#" -eq 0 ]; then
  set -- claude
elif [ "${1#-}" != "$1" ]; then
  set -- claude "$@"
fi

# Set CLAUDE_BOX_SKIP_UPDATE=1 to skip the refresh for `claude` too (fast
# offline start). Always exits 0, so a failed update never stops the handoff.
if [ "$1" != "claude" ]; then
  echo "claude-box: starting '$1' — skipping the Claude Code refresh (run 'claude-box-update' for it)." >&2
elif [ "${CLAUDE_BOX_SKIP_UPDATE:-}" != "1" ]; then
  claude-box-update
fi

exec "$@"
