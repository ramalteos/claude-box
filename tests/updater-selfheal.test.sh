#!/usr/bin/env bash
# The updater's two hard rules, tested with stubs so no container or network is involved:
#   1. never stamp an install you have not verified runs
#   2. never leave a broken shim shadowing the image's working baseline
# This failure mode was silent in the wild — a dangling shim plus a fresh stamp meant every
# later start skipped the repair — so it gets tests.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT

UPD="$REPO_DIR/update-claude.sh"
PG="$SANDBOX/pnpm-global"
STUB="$SANDBOX/stub"
mkdir -p "$PG/bin" "$STUB"

# `claude` behaves per a flag file, standing in for a working or dangling install.
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
[ -f "$SANDBOX/claude-broken" ] && { echo "exec: claude.exe: not found" >&2; exit 127; }
echo "9.9.9 (Claude Code)"
EOF
# `pnpm add -g` records the call and either "installs" or fails.
cat > "$STUB/pnpm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SANDBOX/pnpm-calls.log"
[ -f "$SANDBOX/pnpm-offline" ] && { echo "network unreachable" >&2; exit 1; }
[ -f "$SANDBOX/install-lies" ] || rm -f "$SANDBOX/claude-broken"   # a real install fixes it
exit 0
EOF
chmod +x "$STUB/claude" "$STUB/pnpm"
export PATH="$STUB:$PATH" PNPM_HOME="$PG" SANDBOX

run_upd() { : > "$SANDBOX/pnpm-calls.log"; PNPM_HOME="$PG" bash "$UPD" "$@" 2>&1; }
pnpm_called() { [ -s "$SANDBOX/pnpm-calls.log" ]; }

# --- 1. a broken persisted install is repaired, not skipped -------------------
: > "$SANDBOX/claude-broken"
printf 'shim\n' > "$PG/bin/claude"; chmod +x "$PG/bin/claude"
date +%s > "$PG/.last-update"          # a FRESH stamp: the trap that hid this bug
out="$(run_upd)"
assert_contains "a broken install is called out" "$out" "broken"
assert_ok "a fresh stamp does not stop the repair" pnpm_called
assert_ok "a verified install is stamped" test -f "$PG/.last-update"

# --- 2. an install that lies is not stamped ----------------------------------
: > "$SANDBOX/claude-broken"; : > "$SANDBOX/install-lies"
printf 'shim\n' > "$PG/bin/claude"; chmod +x "$PG/bin/claude"
out="$(run_upd --force)"
assert_contains "a still-broken install is reported" "$out" "discarding it"
assert_fails "an unverified install is NOT stamped" test -f "$PG/.last-update"
assert_fails "the broken shim is removed so the baseline wins" test -e "$PG/bin/claude"
rm -f "$SANDBOX/install-lies"

# --- 3. a good install inside the TTL is left alone ---------------------------
rm -f "$SANDBOX/claude-broken"
mkdir -p "$PG/bin"; printf 'shim\n' > "$PG/bin/claude"; chmod +x "$PG/bin/claude"
date +%s > "$PG/.last-update"
out="$(run_upd)"
assert_contains "a recent check is reported, not repeated" "$out" "checked"
assert_fails "and pnpm is not called" pnpm_called

# --- 4. --force ignores the stamp --------------------------------------------
out="$(run_upd --force)"
assert_ok "--force always checks" pnpm_called
assert_contains "the global bin dir is the one on the image PATH" "$(cat "$SANDBOX/pnpm-calls.log")" "--global-bin-dir $PG/bin"

# --- 5. offline with a broken install still falls back ------------------------
: > "$SANDBOX/claude-broken"; : > "$SANDBOX/pnpm-offline"
mkdir -p "$PG/bin"; printf 'shim\n' > "$PG/bin/claude"; chmod +x "$PG/bin/claude"
out="$(run_upd --force)"
assert_contains "offline is reported, not fatal" "$out" "update failed"
assert_fails "a broken shim is still discarded when offline" test -e "$PG/bin/claude"
rm -f "$SANDBOX/pnpm-offline" "$SANDBOX/claude-broken"

# --- 6. the updater never fails a start --------------------------------------
: > "$SANDBOX/pnpm-offline"
PNPM_HOME="$PG" bash "$UPD" --force >/dev/null 2>&1
assert_eq "it always exits 0 so a start is never blocked" "$?" "0"

summary
