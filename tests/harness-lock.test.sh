#!/usr/bin/env bash
# The lock is the whole reason the harness can claim what ai-bridge's pm-loop
# documents as missing: a second loop against one instance must not start.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
load_runner

INST="$(make_instance)"
resolve_instance "$INST"

lock_acquire
assert_ok "first acquire succeeds" test -d "$INSTANCE_STATE/lock"
assert_contains "lock records the holder pid" "$(cat "$INSTANCE_STATE/lock/owner")" "$$"

# A second acquirer must refuse while the holder lives (die exits, hence subshell).
assert_fails "second acquire is refused while the holder lives" bash -c '. "$1"; resolve_instance "$2"; lock_acquire' _ "$REPO_DIR/claude-box" "$INST"

lock_release
assert_fails "release removes the lock" test -d "$INSTANCE_STATE/lock"

# A dead holder must not wedge the instance forever.
mkdir -p "$INSTANCE_STATE/lock"
printf '999999 %s\n' "$(date +%s)" > "$INSTANCE_STATE/lock/owner"
lock_acquire
assert_contains "a stale lock is reclaimed" "$(cat "$INSTANCE_STATE/lock/owner")" "$$"
lock_release

summary
