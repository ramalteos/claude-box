#!/usr/bin/env bash
# claude-box — refresh Claude Code to the latest release inside the box.
#
# The image pins a baseline at BUILD time; this is what moves it forward at RUN
# time. `entrypoint.sh` calls it automatically when a start actually launches
# `claude`; from a `./claude-box shell` you can run `claude-box-update` by hand.
#
# BEST-EFFORT: the update needs network egress, and the box is routinely started
# offline or behind a VPN that has dropped egress (see the runner's
# ip-forwarding note). A failure warns and still exits 0 — it must never block
# you from using the version already installed.
set -uo pipefail

echo "claude-box: updating Claude Code to latest…" >&2
# --allow-build lets claude-code's postinstall fetch its platform binary; the
# pnpm store on the workspace bind-mount caches the download across runs, so a
# repeat start that is already current is fast.
if pnpm add -g --allow-build=@anthropic-ai/claude-code \
     @anthropic-ai/claude-code@latest >&2; then
  echo "claude-box: Claude Code is $(claude --version 2>/dev/null || echo '(version unknown)')" >&2
else
  echo "claude-box: update failed (offline?) — using the version already installed." >&2
fi
