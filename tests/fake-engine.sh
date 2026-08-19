#!/usr/bin/env bash
# A stand-in container engine for the tests: records what it was asked to do and
# returns, instead of launching anything. This is what lets the harness tests cover
# intent validation, capping, box naming, mount wiring and prompt assembly without
# spending containers or tokens.
#
# Reads:  CLAUDE_BOX_FAKE_STATE   directory for its bookkeeping (required)
#         CLAUDE_BOX_FAKE_EXIT    exit code a fake `run` reports (default 0)
#         CLAUDE_BOX_FAKE_SLEEP   seconds a fake `run` should take (default 0)
# Writes: $STATE/calls.log        one line per invocation
#         $STATE/argv.log         argv one item per line, per invocation
#         $STATE/running          names currently "running"
set -uo pipefail

S="${CLAUDE_BOX_FAKE_STATE:?CLAUDE_BOX_FAKE_STATE must be set for the fake engine}"
mkdir -p "$S"
touch "$S/running"

# Redact secret-looking env values before they reach a log file. The runner forwards
# real host tokens (GH_TOKEN, GITHUB_REGISTRY_ACCESS_TOKEN, ANTHROPIC_API_KEY) into
# every box, and a test artifact is exactly the wrong place for them to accumulate.
redact() {
  printf '%s' "$1" | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*(TOKEN|KEY|SECRET|PASSWORD)[A-Za-z0-9_]*)=.*/\1=<redacted>/'
}

{ printf '=== %s\n' "${1:-}"; for a in "$@"; do redact "$a"; printf '\n'; done; } >> "$S/argv.log"
for a in "$@"; do printf '%s ' "$(redact "$a")"; done >> "$S/calls.log"; printf '\n' >> "$S/calls.log"

drop_running() {
  local name="$1"
  grep -vxF "$name" "$S/running" > "$S/running.next" 2>/dev/null || true
  mv "$S/running.next" "$S/running" 2>/dev/null || true
}

case "${1:-}" in
  run)
    name="" prev=""
    for a in "$@"; do [ "$prev" = "--name" ] && name="$a"; prev="$a"; done
    [ -n "$name" ] && printf '%s\n' "$name" >> "$S/running"
    # A hook lets a test simulate what a role box actually WRITES — drafting a task,
    # opening a PR, setting a qa verdict — so pipeline control flow can be tested
    # without a real agent.
    [ -n "${CLAUDE_BOX_FAKE_HOOK:-}" ] && [ -x "$CLAUDE_BOX_FAKE_HOOK" ] \
      && "$CLAUDE_BOX_FAKE_HOOK" "$name" >>"$S/hook.log" 2>&1
    [ -n "${CLAUDE_BOX_FAKE_SLEEP:-}" ] && sleep "$CLAUDE_BOX_FAKE_SLEEP"
    [ -n "$name" ] && drop_running "$name"
    exit "${CLAUDE_BOX_FAKE_EXIT:-0}"
    ;;
  stop)
    [ -n "${2:-}" ] && drop_running "$2"
    exit 0
    ;;
  build) exit 0 ;;
  *)     exit 0 ;;
esac
