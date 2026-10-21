#!/usr/bin/env bash
# Autonomy removes the human, not the gates. Each gate gets a test, because the failure
# mode here is a merged mistake rather than an error message.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
load_runner

INST="$(make_instance)"
make_repo demo-repo >/dev/null
resolve_instance "$INST"
TICK_DIR="$(mktemp -d)"

assert_eq "gated is the default" "$(autonomy_mode)" "gated"

# The switch must be unreachable from a box: it lives in the host state dir, which is
# never mounted into one.
printf 'full\n' > "$INSTANCE_STATE/autonomy"
assert_eq "the mode is read from host state" "$(autonomy_mode)" "full"
assert_contains "the switch is outside the panel" "$INSTANCE_STATE/autonomy" "$CLAUDE_BOX_STATE"
assert_fails "nothing in the panel can set it" test -e "$INST/autonomy"
printf 'nonsense\n' > "$INSTANCE_STATE/autonomy"
assert_eq "an unreadable mode falls back to gated" "$(autonomy_mode)" "gated"

# --- promotion ----------------------------------------------------------------
mk() {  # mk <id> <criteria> <questions>
  cat > "$INST/projects/demo/tasks/$1.md" <<EOF
---
type: Task
status: draft
target_repo: demo-repo
acceptance_criteria: $2
open_questions: $3
---
EOF
}
mk refined '[ "returns 200" ]' '[ ]'
mk nocriteria '[ ]' '[ ]'
mk blocked '[ "returns 200" ]' '[ "Q1: which region?" ]'

autonomy_promote gated >/dev/null 2>&1
assert_eq "gated promotes nothing" "$(task_status "$INST/projects/demo/tasks/refined.md")" "draft"

autonomy_promote promote >/dev/null 2>&1
assert_eq "a refined draft is promoted" "$(task_status "$INST/projects/demo/tasks/refined.md")" "ready"
assert_eq "a draft with no criteria is left alone" "$(task_status "$INST/projects/demo/tasks/nocriteria.md")" "draft"
assert_eq "a draft with an open question is left alone" "$(task_status "$INST/projects/demo/tasks/blocked.md")" "draft"
assert_contains "the promotion is recorded" "$(cat "$TICK_DIR/autonomy.tsv")" "promoted by host"

# --- merge gates --------------------------------------------------------------
# A stub gh, so the gates are tested without touching a real repository.
FAKE_GH="$SANDBOX/gh"
cat > "$FAKE_GH" <<'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")   printf '%s\n' "${GH_STATE-OPEN MERGEABLE draft=false}" ;;
  "pr checks") printf '%s\n' "${GH_CHECKS-SUCCESS}" ;;
  "pr merge")  printf '%s\n' "$3" >> "$SANDBOX/merged.log" ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$FAKE_GH"
GH_BIN="$FAKE_GH"; export SANDBOX

review() {  # review <id> <qa> <status> <pr-number> — replaces every task, so each gate
            # is tested in isolation rather than against leftovers
  rm -f "$INST/projects/demo/tasks/"*.md
  cat > "$INST/projects/demo/tasks/$1.md" <<EOF
---
type: Task
status: $3
target_repo: demo-repo
pr: [ "https://github.com/o/demo-repo/pull/$4" ]
qa: $2
---
EOF
}

: > "$SANDBOX/merged.log"
review approved approved in-review 1
autonomy_merge promote >/dev/null 2>&1
assert_fails "promote mode never merges" grep -q . "$SANDBOX/merged.log"

autonomy_merge full >/dev/null 2>&1
assert_ok "approved + green + open merges" grep -q 'pull/1' "$SANDBOX/merged.log"

: > "$SANDBOX/merged.log"
review notqa "changes-requested" in-review 2
autonomy_merge full >/dev/null 2>&1
assert_fails "changes-requested is never merged" grep -q . "$SANDBOX/merged.log"

: > "$SANDBOX/merged.log"
review noqa "" in-review 3
autonomy_merge full >/dev/null 2>&1
assert_fails "a missing qa verdict is never merged" grep -q . "$SANDBOX/merged.log"

: > "$SANDBOX/merged.log"
review nochecks approved in-review 4
GH_CHECKS="" autonomy_merge full >/dev/null 2>&1
assert_fails "no CI checks means no merge (absence of evidence)" grep -q . "$SANDBOX/merged.log"

: > "$SANDBOX/merged.log"
GH_CHECKS="SUCCESS,FAILURE" autonomy_merge full >/dev/null 2>&1
assert_fails "a failing check blocks the merge" grep -q . "$SANDBOX/merged.log"

: > "$SANDBOX/merged.log"
GH_CHECKS="SUCCESS,PENDING" autonomy_merge full >/dev/null 2>&1
assert_fails "a pending check blocks the merge" grep -q . "$SANDBOX/merged.log"

: > "$SANDBOX/merged.log"
GH_STATE="CLOSED UNKNOWN draft=false" autonomy_merge full >/dev/null 2>&1
assert_fails "a closed PR is not merged" grep -q . "$SANDBOX/merged.log"

# A draft is how a role hands over work it could not fully verify — it must never merge.
: > "$SANDBOX/merged.log"
GH_STATE="OPEN MERGEABLE draft=true" autonomy_merge full >/dev/null 2>&1
assert_fails "a draft PR is not merged" grep -q . "$SANDBOX/merged.log"

: > "$SANDBOX/merged.log"
for i in 1 2 3 4 5; do
  cat > "$INST/projects/demo/tasks/m$i.md" <<EOF
---
type: Task
status: in-review
target_repo: demo-repo
pr: [ "https://github.com/o/demo-repo/pull/$i" ]
qa: approved
---
EOF
done
CLAUDE_BOX_MAX_MERGES_PER_TICK=2 autonomy_merge full >/dev/null 2>&1
assert_eq "the per-tick merge cap holds" "$(grep -c . "$SANDBOX/merged.log")" "2"

rm -rf "$TICK_DIR"
summary
