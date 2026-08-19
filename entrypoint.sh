#!/usr/bin/env bash
# claude-box container entrypoint.
#
# Three jobs, in this order:
#   1. work out what we were actually asked to run,
#   2. finish the runtime wiring the image cannot do at build time, and
#   3. refresh Claude Code — but ONLY when the command is `claude`.
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

# Compatibility symlinks for the mount. The mount path follows CLAUDE_BOX_ROOT
# (default ~/Documents/GitHub -> /root/Documents/GitHub), but absolute
# /workspace/... and /root/workspace/... paths are baked into git worktree admin
# files, agent definitions and session history, so both spellings must keep
# resolving. /root/workspace exists as an empty dir in the image; replace it with
# a symlink only when it is not itself the mount.
if [ -n "${CLAUDE_BOX_MOUNT:-}" ]; then
  if [ "$CLAUDE_BOX_MOUNT" != /root/workspace ]; then
    rmdir /root/workspace 2>/dev/null || true
    [ -e /root/workspace ] || ln -sfn "$CLAUDE_BOX_MOUNT" /root/workspace
  fi
  [ -e /workspace ] || ln -sfn "$CLAUDE_BOX_MOUNT" /workspace
fi

# Auth from the shared config dir, when the runner mounted it. The credentials file is
# SYMLINKED so a token refresh reaches every other box; .claude.json is COPIED so each box
# keeps its own project/session state (sharing it is what per-box config dirs exist to
# avoid). Never overwrite what the box already has.
if [ -d /root/.claude-host ]; then
  mkdir -p /root/.claude
  [ -e /root/.claude/.credentials.json ] || \
    ln -s /root/.claude-host/.credentials.json /root/.claude/.credentials.json
  [ -e /root/.claude/.claude.json ] && : || \
    { [ -f /root/.claude-host/.claude.json ] && cp /root/.claude-host/.claude.json /root/.claude/.claude.json; }
fi

# The persistent pnpm global dir arrives as a bind mount that is empty on the
# very first run; PATH already points at its bin dir, so make sure it exists
# rather than leaving a missing PATH entry behind.
mkdir -p "${PNPM_HOME:-/root/pnpm-global}/bin"

# The image's store-dir assumes the mount root is the ~/workspace root. When the
# box is pointed somewhere else, the runner passes a store dir on a separate mount
# so pnpm does not drop a .pnpm-store into the user's own project directory.
if [ -n "${CLAUDE_BOX_STORE_DIR:-}" ]; then
  pnpm config set store-dir "$CLAUDE_BOX_STORE_DIR" --global >/dev/null 2>&1 || true
fi

# Set CLAUDE_BOX_SKIP_UPDATE=1 to skip the refresh for `claude` too (fast
# offline start). Always exits 0, so a failed update never stops the handoff.
if [ "$1" != "claude" ]; then
  echo "claude-box: starting '$1' — skipping the Claude Code refresh (run 'claude-box-update' for it)." >&2
elif [ "${CLAUDE_BOX_SKIP_UPDATE:-}" != "1" ]; then
  claude-box-update
fi

exec "$@"
