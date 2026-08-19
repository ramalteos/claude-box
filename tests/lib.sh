#!/usr/bin/env bash
# Shared harness-test scaffolding: a throwaway root, state dir and ai-bridge
# instance fixture, plus the fake engine. Sourced by tests/*.test.sh.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TESTS_PASSED=0 TESTS_FAILED=0

ok()   { TESTS_PASSED=$((TESTS_PASSED + 1)); printf '  ok   %s\n' "$1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

assert_eq()       { [ "$2" = "$3" ] && ok "$1" || fail "$1" "want '$3', got '$2'"; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) fail "$1" "'$3' not found in: $(printf '%s' "$2" | head -c 300)" ;; esac; }
assert_ok()       { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else fail "$1" "command failed: ${*:2}"; fi; }
assert_fails()    { if "${@:2}" >/dev/null 2>&1; then fail "$1" "expected failure: ${*:2}"; else ok "$1"; fi; }

summary() {
  printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$TESTS_PASSED" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}

# A sandbox with its own root, state and config, so nothing touches the real ones.
setup_sandbox() {
  # Resolved with pwd -P: on macOS $TMPDIR lives under the /var -> /private/var
  # symlink, and the runner resolves paths, so an unresolved sandbox path would not
  # match what the runner computes.
  SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/claude-box-test.XXXXXX")" && pwd -P)"
  export CLAUDE_BOX_ROOT="$SANDBOX/root"
  export CLAUDE_BOX_STATE="$SANDBOX/state"
  export CLAUDE_BOX_CONFIG_HOME="$SANDBOX/config"
  export CLAUDE_BOX_ENGINE=fake
  export CLAUDE_BOX_FAKE_STATE="$SANDBOX/fake"
  export CLAUDE_BOX_SOURCE_ONLY=1
  mkdir -p "$CLAUDE_BOX_ROOT" "$CLAUDE_BOX_STATE" "$CLAUDE_BOX_CONFIG_HOME" "$CLAUDE_BOX_FAKE_STATE"
  # HOME must contain the root, or the runner cannot map it to a container path.
  export HOME="$SANDBOX"
  export CLAUDE_BOX_ROOT="$SANDBOX/root"
}

# A detached box is launched in the background, so its record appears a moment after
# the command returns — and appears in pieces. Waiting for the file to merely EXIST is
# a flake: under load the first read lands before the interesting argument is written.
# Wait for the content that is about to be asserted on instead.
wait_for_file() {
  local f="$1" i=0
  while [ ! -s "$f" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$f" ]
}

wait_for_text() {
  local f="$1" needle="$2" i=0
  while [ "$i" -lt 300 ]; do
    grep -qF -- "$needle" "$f" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

teardown_sandbox() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }

load_runner() { . "$REPO_DIR/claude-box"; }

# A minimal but realistic ai-bridge control-panel instance.
make_instance() {
  local dir="$CLAUDE_BOX_ROOT/_ai-bridge-test"
  mkdir -p "$dir/.claude/agents" "$dir/projects/demo/tasks" "$dir/knowledge"
  cat > "$dir/instance.config.json" <<'JSON'
{
  "org": "test-org",
  "reposRoot": "~/root",
  "maxAgentsInFlight": 2,
  "roles": ["project-manager", "software-engineer", "qa-reviewer"],
  "models": { "light": "haiku", "standard": "sonnet", "deep": "opus", "apex": "fable" },
  "roleTiers": { "project-manager": "deep", "software-engineer": "standard", "qa-reviewer": "deep" },
  "roleEffort": { "project-manager": "xhigh", "software-engineer": "high", "qa-reviewer": "xhigh" }
}
JSON
  printf '# Schema\n\nTask lifecycle: draft -> ready -> in-progress -> in-review -> done.\n' > "$dir/SCHEMA.md"
  printf '# Knowledge Base — index\n\n_(none yet)_\n' > "$dir/knowledge/index.md"
  local role
  for role in project-manager software-engineer qa-reviewer; do
    cat > "$dir/.claude/agents/$role.md" <<EOF
---
name: $role
description: test fixture role
tools: Read, Write, Bash
---

You are the **$role**. PERSONA-MARKER-$role.
EOF
  done
  printf '%s\n' "$dir"
}

make_task() {  # make_task <instance> <id> <status>
  local inst="$1" id="$2" status="$3"
  cat > "$inst/projects/demo/tasks/$id.md" <<EOF
---
id: $id
status: $status
target_repo: demo-repo
---

# Context
Test task.
EOF
  printf 'projects/demo/tasks/%s.md\n' "$id"
}

make_repo() {  # make_repo <name>
  local dir="$CLAUDE_BOX_ROOT/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf 'x\n' > "$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@t commit -qm init
  printf '%s\n' "$dir"
}

make_intent() {  # make_intent <instance> <name> <json>
  mkdir -p "$1/.harness/intents"
  printf '%s\n' "$3" > "$1/.harness/intents/$2.json"
  printf '%s\n' "$1/.harness/intents/$2.json"
}
