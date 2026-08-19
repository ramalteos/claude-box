#!/usr/bin/env bash
# Memory rules: three tiers in a fixed order, a hard size cap, and acceptance as
# the only way in. All three are things a wrong implementation gets subtly wrong.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
load_runner

INST="$(make_instance)"
make_repo demo-repo >/dev/null
resolve_instance "$INST"

# --- assembly -----------------------------------------------------------------
printf 'GLOBAL-RULE: never reformat whole files.\n' > "$STATE_HOME/harness/memory/style.md"
mkdir -p "$CLAUDE_BOX_ROOT/demo-repo/.harness/memory/learnings"
printf 'REPO-RULE: kafka consumers need idempotent keys.\n' \
  > "$CLAUDE_BOX_ROOT/demo-repo/.harness/memory/learnings/kafka.md"

pre="$(memory_preamble demo-repo)"
assert_contains "global tier is loaded"      "$pre" "GLOBAL-RULE"
assert_contains "repo tier is loaded"        "$pre" "REPO-RULE"
assert_contains "KB is referenced, not inlined" "$pre" "do not bulk-read"

g_pos=$(printf '%s' "$pre" | grep -n 'GLOBAL-RULE' | cut -d: -f1)
r_pos=$(printf '%s' "$pre" | grep -n 'REPO-RULE'  | cut -d: -f1)
if [ "$r_pos" -gt "$g_pos" ]; then ok "repo tier comes after global (it overrides)"; else fail "repo tier comes after global (it overrides)" "global at $g_pos, repo at $r_pos"; fi

pre_norepo="$(memory_preamble)"
assert_contains "no repo means no repo tier" "$(printf '%s' "$pre_norepo" | grep -c 'REPO-RULE')" "0"

# --- the cap ------------------------------------------------------------------
python3 -c "open('$STATE_HOME/harness/memory/huge.md','w').write('x'*20000)"
CLAUDE_BOX_MEMORY_MAX=2000
big="$(memory_preamble demo-repo)"
if [ "${#big}" -le 2200 ]; then ok "preamble is capped"; else fail "preamble is capped" "got ${#big} chars"; fi
assert_contains "truncation is stated, not silent" "$big" "memory truncated"
rm -f "$STATE_HOME/harness/memory/huge.md"
CLAUDE_BOX_MEMORY_MAX=8000

# --- acceptance routing -------------------------------------------------------
mkdir -p "$INST/.harness/pending"
cat > "$INST/.harness/pending/global-one.md" <<'EOF'
---
tier: global
evidence: projects/demo/tasks/t1.md
---

Always run the linter before opening a PR.
EOF
assert_ok "global proposal accepted" memory_accept "$INST/.harness/pending/global-one.md"
assert_ok "global proposal landed in the global tier" test -f "$STATE_HOME/harness/memory/global-one.md"
assert_fails "accepted proposal leaves the queue" test -f "$INST/.harness/pending/global-one.md"

cat > "$INST/.harness/pending/repo-one.md" <<'EOF'
---
tier: repo
repo: demo-repo
evidence: demo-repo/src/x.ts:12
---

This service reads its config at boot only; restart after changing it.
EOF
assert_ok "repo proposal accepted" memory_accept "$INST/.harness/pending/repo-one.md"
assert_ok "repo proposal landed in the product repo" \
  test -f "$CLAUDE_BOX_ROOT/demo-repo/.harness/memory/learnings/repo-one.md"

cat > "$INST/.harness/pending/bad-tier.md" <<'EOF'
---
tier: repo
evidence: nothing
---

Missing the repo field.
EOF
assert_fails "tier: repo without a repo is refused" memory_accept "$INST/.harness/pending/bad-tier.md"
assert_ok "refused proposal stays pending" test -f "$INST/.harness/pending/bad-tier.md"

cat > "$INST/.harness/pending/no-tier.md" <<'EOF'
---
evidence: nothing
---

No tier at all.
EOF
assert_fails "proposal with no tier is refused" memory_accept "$INST/.harness/pending/no-tier.md"

# A role box must never be able to write a tier directly — only acceptance does.
assert_contains "overlay tells roles to propose, not write" \
  "$(cat "$SETUP_DIR/harness/overlay.md")" ".harness/pending/"

summary
