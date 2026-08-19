#!/usr/bin/env bash
# Intent validation is the harness's gate: a rejection costs a file write, a bad
# dispatch costs a container, minutes and tokens. So every rule gets a test.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
load_runner

INST="$(make_instance)"
make_repo demo-repo >/dev/null
resolve_instance "$INST"

check() {  # check <label> <json> <expect: ok|reject> [substring of reason]
  local label="$1" json="$2" expect="$3" want="${4:-}" file reason
  file="$(make_intent "$INST" "probe" "$json")"
  if intent_validate "$file"; then
    [ "$expect" = ok ] && ok "$label" || fail "$label" "accepted, expected rejection"
  else
    reason="$I_REJECT_REASON"
    if [ "$expect" = reject ]; then
      if [ -n "$want" ]; then assert_contains "$label" "$reason" "$want"; else ok "$label"; fi
    else
      fail "$label" "rejected: $reason"
    fi
  fi
  rm -f "$file"
}

make_task "$INST" t1 ready >/dev/null
make_task "$INST" t2 draft >/dev/null

check "valid intent is accepted" \
  '{"intent":"dispatch","role":"software-engineer","task":"projects/demo/tasks/t1.md","target_repo":"demo-repo","reason":"go"}' ok

check "unknown intent type rejected" \
  '{"intent":"merge","role":"software-engineer","task":"projects/demo/tasks/t1.md","target_repo":"demo-repo"}' reject "unknown intent type"

check "unlisted role rejected" \
  '{"intent":"dispatch","role":"ceo","task":"projects/demo/tasks/t1.md","target_repo":"demo-repo"}' reject "not in instance.config.json"

check "project-manager is never a task assignee" \
  '{"intent":"dispatch","role":"project-manager","task":"projects/demo/tasks/t1.md","target_repo":"demo-repo"}' reject "never dispatched"

# OKF cross-links start with "/" and mean bundle-relative, so a leading slash is the
# CONVENTION, not an escape. It must resolve inside the panel or be refused.
check "the OKF bundle-relative spelling is accepted" \
  '{"intent":"dispatch","role":"qa-reviewer","task":"/projects/demo/tasks/t1.md","target_repo":"demo-repo"}' ok
assert_eq "the leading slash is normalised away" "$I_TASK" "projects/demo/tasks/t1.md"

check "a path that does not exist in the panel is rejected" \
  '{"intent":"dispatch","role":"qa-reviewer","task":"/etc/passwd","target_repo":"demo-repo"}' reject "not found"

check "path traversal rejected" \
  '{"intent":"dispatch","role":"qa-reviewer","task":"../../etc/passwd","target_repo":"demo-repo"}' reject "escapes the panel"

check "missing task file rejected" \
  '{"intent":"dispatch","role":"qa-reviewer","task":"projects/demo/tasks/nope.md","target_repo":"demo-repo"}' reject "not found"

check "draft task cannot be dispatched" \
  '{"intent":"dispatch","role":"software-engineer","task":"projects/demo/tasks/t2.md","target_repo":"demo-repo"}' reject "human-promoted"

check "non-repo target rejected" \
  '{"intent":"dispatch","role":"software-engineer","task":"projects/demo/tasks/t1.md","target_repo":"not-a-repo"}' reject "has no clone at"

check "target_repo as a traversing path rejected" \
  '{"intent":"dispatch","role":"software-engineer","task":"projects/demo/tasks/t1.md","target_repo":"../demo-repo"}' reject "not a path"

# ai-bridge's SCHEMA.md spells target_repo as <org>/<repo>, so both forms must work.
check "org/repo form is accepted (ai-bridge's own spelling)" \
  '{"intent":"dispatch","role":"software-engineer","task":"projects/demo/tasks/t1.md","target_repo":"test-org/demo-repo"}' ok
assert_eq "org/repo yields the bare dir to mount" "$I_REPO_DIR" "demo-repo"

check "a foreign org is rejected" \
  '{"intent":"dispatch","role":"software-engineer","task":"projects/demo/tasks/t1.md","target_repo":"someone-else/demo-repo"}' reject "not this instance's org"

check "too many segments rejected" \
  '{"intent":"dispatch","role":"software-engineer","task":"projects/demo/tasks/t1.md","target_repo":"a/b/c"}' reject "too many path segments"

check "a URL is rejected" \
  '{"intent":"dispatch","role":"software-engineer","task":"projects/demo/tasks/t1.md","target_repo":"https://github.com/test-org/demo-repo"}' reject "not a URL"

check "malformed JSON rejected" \
  '{not json' reject "unparseable"

# --- idempotency: a task already being worked cannot be dispatched twice -------
mkdir -p "$INSTANCE_STATE/inflight"
printf 'claude-box-h-busy\n' > "$INSTANCE_STATE/inflight/$(task_key projects/demo/tasks/t1.md)"
printf 'claude-box-h-busy\n' > "$CLAUDE_BOX_FAKE_STATE/running"
check "double-dispatch of one task refused" \
  '{"intent":"dispatch","role":"software-engineer","task":"projects/demo/tasks/t1.md","target_repo":"demo-repo"}' reject "double-dispatch"
rm -f "$INSTANCE_STATE/inflight"/* "$CLAUDE_BOX_FAKE_STATE/running"

# --- the dispatch race --------------------------------------------------------
# A marker is written BEFORE its container exists. If a fresh marker did not count,
# two intents for one task in a single tick would both be dispatched, and the cap
# would be exceeded by however many boxes had not registered yet.
rm -f "$INSTANCE_STATE/inflight"/* 2>/dev/null || true
: > "$CLAUDE_BOX_FAKE_STATE/running"
mkdir -p "$INSTANCE_STATE/inflight"
printf 'claude-box-h-not-yet-visible\n' > "$INSTANCE_STATE/inflight/$(task_key projects/demo/tasks/t1.md)"
check "a just-written marker blocks a second dispatch of the same task" \
  '{"intent":"dispatch","role":"software-engineer","task":"projects/demo/tasks/t1.md","target_repo":"demo-repo"}' reject "double-dispatch"
assert_eq "a just-written marker counts toward the cap" "$(inflight_count)" 1
assert_ok "a live marker is not reaped" test -f "$INSTANCE_STATE/inflight/$(task_key projects/demo/tasks/t1.md)"

# Past the grace window with no container, the slot must come back.
CLAUDE_BOX_BOX_GRACE=0
assert_eq "an expired marker frees its slot" "$(inflight_count)" 0
assert_fails "an expired marker is reaped" test -f "$INSTANCE_STATE/inflight/$(task_key projects/demo/tasks/t1.md)"
CLAUDE_BOX_BOX_GRACE=45

# Task identity must survive long, similar paths — the marker filename IS the
# double-dispatch key, so a collision means one task blocks another forever.
k1="$(task_key projects/platform-migration/tasks/extract-billing-client.md)"
k2="$(task_key projects/platform-migration/tasks/extract-invoice-client.md)"
if [ "$k1" != "$k2" ]; then ok "long sibling task paths get distinct keys"; else fail "long sibling task paths get distinct keys" "both are '$k1'"; fi
assert_contains "the key stays readable" "$k1" "extract-billing-client"

# --- caps ---------------------------------------------------------------------
assert_eq "cap is the instance's maxAgentsInFlight when memory allows" "$(inflight_cap)" 2

rm -f "$INSTANCE_STATE/inflight"/* 2>/dev/null || true
printf 'claude-box-h-a\nclaude-box-h-b\n' > "$CLAUDE_BOX_FAKE_STATE/running"
mkdir -p "$INSTANCE_STATE/inflight"
printf 'claude-box-h-a\n' > "$INSTANCE_STATE/inflight/a"
printf 'claude-box-h-b\n' > "$INSTANCE_STATE/inflight/b"
check "dispatch refused at the in-flight cap" \
  '{"intent":"dispatch","role":"software-engineer","task":"projects/demo/tasks/t1.md","target_repo":"demo-repo"}' reject "cap reached"

# A finished box must free its slot rather than wedging the cap forever — once it is
# past the grace window, which is what distinguishes "finished" from "not yet visible".
: > "$CLAUDE_BOX_FAKE_STATE/running"
CLAUDE_BOX_BOX_GRACE=0
assert_eq "finished boxes stop counting against the cap" "$(inflight_count)" 0
CLAUDE_BOX_BOX_GRACE=45

CLAUDE_BOX_MEM=48G
assert_eq "memory budget can lower the cap below the declared one" "$(inflight_cap)" 1
CLAUDE_BOX_MEM=8G

summary
