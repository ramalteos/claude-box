#!/usr/bin/env bash
# Claude Code replaces a box's credentials symlink with a regular file when it refreshes the
# token, and refresh tokens rotate: whichever box refreshed last holds the only valid one.
# Boxes named per task/role/attempt never start twice under one name, so the carry-back must
# look at every box dir, not just this box's own.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
load_runner

SHARED="$CLAUDE_BOX_CONFIG_HOME/.credentials.json"
B="$CLAUDE_BOX_STATE/boxes"
mkdir -p "$B/claude-box-graph-t1-pm-1/claude" "$B/claude-box-graph-t1-coder-1/claude"
printf '{"claudeAiOauth":{"expiresAt":1}}' > "$SHARED";                                      touch -t 202601010000 "$SHARED"
printf '{"claudeAiOauth":{"expiresAt":2}}' > "$B/claude-box-graph-t1-coder-1/claude/.credentials.json"; touch -t 202601020000 "$B/claude-box-graph-t1-coder-1/claude/.credentials.json"
printf '{"claudeAiOauth":{"expiresAt":3}}' > "$B/claude-box-graph-t1-pm-1/claude/.credentials.json";    touch -t 202601030000 "$B/claude-box-graph-t1-pm-1/claude/.credentials.json"

out="$(resolve_config_mount claude-box-graph-t1-architect-1 isolated 2>&1)"
assert_eq "the newest token from ANY box is carried back to the shared login" "$(cat "$SHARED")" '{"claudeAiOauth":{"expiresAt":3}}'
assert_contains "it names the box it came from" "$out" "pm-1"
assert_fails "the carried copy is dropped so that box relinks next time" test -e "$B/claude-box-graph-t1-pm-1/claude/.credentials.json"
assert_fails "an older stale copy is dropped too" test -e "$B/claude-box-graph-t1-coder-1/claude/.credentials.json"

# A copy older than the shared login carries nothing back.
printf '{"claudeAiOauth":{"expiresAt":0}}' > "$B/claude-box-graph-t1-qa-1/claude/.credentials.json" 2>/dev/null || { mkdir -p "$B/claude-box-graph-t1-qa-1/claude"; printf '{"claudeAiOauth":{"expiresAt":0}}' > "$B/claude-box-graph-t1-qa-1/claude/.credentials.json"; }
touch -t 202501010000 "$B/claude-box-graph-t1-qa-1/claude/.credentials.json"
resolve_config_mount claude-box-graph-t1-reviewer-1 isolated >/dev/null 2>&1
assert_eq "an older copy never overwrites the shared login" "$(cat "$SHARED")" '{"claudeAiOauth":{"expiresAt":3}}'
assert_fails "and it is dropped" test -e "$B/claude-box-graph-t1-qa-1/claude/.credentials.json"
summary
