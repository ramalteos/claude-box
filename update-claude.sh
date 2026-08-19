#!/usr/bin/env bash
# claude-box — refresh Claude Code to the latest release inside the box, and repair the
# persisted install if it is broken.
#
# The image pins a baseline at BUILD time; this is what moves it forward at RUN time.
# `entrypoint.sh` calls it when a start actually launches `claude`; from a
# `./claude-box shell` you can run `claude-box-update` by hand.
#
# It installs into $PNPM_HOME (/root/pnpm-global), which the runner bind-mounts from the
# host — so the result PERSISTS instead of dying with the --rm container, and a stamp lets
# repeat starts skip the work. Two rules learned the hard way:
#
#   1. VERIFY BEFORE STAMPING. A stamp written after a half-finished install makes every
#      later start skip the repair, so the box stays broken until someone notices.
#   2. THE GLOBAL INSTALL OWNS ITS STORE. pnpm's global node_modules is a symlink farm
#      into the store; if the store path moves (it depends on what was mounted), every
#      link dangles and the shim execs a path that no longer exists. So the global install
#      uses a store INSIDE the persisted dir, where the two always move together. Project
#      installs keep the workspace store from ~/.npmrc, which is what makes hardlinking
#      into node_modules work.
#
#   CLAUDE_BOX_UPDATE_TTL   seconds before another check is due (default 21600 = 6h)
#   claude-box-update --force   check now regardless of the stamp
#
# BEST-EFFORT: the update needs network egress, and the box is routinely started offline
# or behind a VPN that has dropped egress. A failure warns and still exits 0 — it must
# never block you from using a version that works.
set -uo pipefail

PNPM_HOME="${PNPM_HOME:-/root/pnpm-global}"
GLOBAL_STORE="$PNPM_HOME/store"
STAMP="$PNPM_HOME/.last-update"
TTL="${CLAUDE_BOX_UPDATE_TTL:-21600}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# Not "is it on PATH" but "does it run": a dangling shim satisfies the first and fails
# the second, which is exactly the state this script exists to get out of.
claude_works() { command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1; }

# Remove a broken persisted install so the image's baseline — second on PATH — takes over.
# Without this the broken shim shadows a working binary and the fallback is a fiction.
drop_persisted() {
  rm -rf "$PNPM_HOME/bin" "$PNPM_HOME/global" "$PNPM_HOME/.pnpm" 2>/dev/null || true
  mkdir -p "$PNPM_HOME/bin"
  rm -f "$STAMP"
  hash -r 2>/dev/null || true
}

if [ -e "$PNPM_HOME/bin/claude" ] && ! claude_works; then
  echo "claude-box: the persisted Claude Code install is broken — discarding it and reinstalling." >&2
  drop_persisted
fi

if [ "$FORCE" = 0 ] && [ -f "$STAMP" ] && claude_works; then
  last="$(cat "$STAMP" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  age=$(( $(date +%s) - last ))
  if [ "$age" -lt "$TTL" ]; then
    echo "claude-box: Claude Code checked ${age}s ago (TTL ${TTL}s) — $(claude --version 2>/dev/null)" >&2
    exit 0
  fi
fi

echo "claude-box: updating Claude Code to latest…" >&2
# --allow-build lets claude-code's postinstall fetch its platform binary. --store-dir
# keeps the global install and its store on the same persisted mount (see rule 2 above).
mkdir -p "$GLOBAL_STORE"
if pnpm add -g --allow-build=@anthropic-ai/claude-code \
     --store-dir "$GLOBAL_STORE" \
     @anthropic-ai/claude-code@latest >&2; then
  hash -r 2>/dev/null || true
  if claude_works; then
    date +%s > "$STAMP" 2>/dev/null || true
    echo "claude-box: Claude Code is $(claude --version 2>/dev/null)" >&2
  else
    echo "claude-box: the install finished but 'claude --version' fails — discarding it and falling back to the version baked into the image." >&2
    drop_persisted
    claude_works && echo "claude-box: fell back to $(claude --version 2>/dev/null)" >&2
  fi
else
  echo "claude-box: update failed (offline?) — using the version already installed." >&2
  claude_works || {
    echo "claude-box: the persisted install does not run either — discarding it to fall back to the image baseline." >&2
    drop_persisted
  }
fi
exit 0
