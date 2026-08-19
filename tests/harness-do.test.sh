#!/usr/bin/env bash
# `harness do` drives one request to completion. What is tested here is the CONTROL FLOW
# — which box runs next, and when it stops — using a hook that simulates what each role
# writes. Whether a real agent writes good code is not something a test can assert.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
CB="$REPO_DIR/claude-box"
unset CLAUDE_BOX_SOURCE_ONLY

INST="$(make_instance)"
make_repo demo-repo >/dev/null
# our own roles, since the pipeline routes to lead-dev
for r in lead-dev; do
  cat > "$INST/.claude/agents/$r.md" <<EOF
---
name: $r
description: fixture
---
PERSONA-MARKER-$r
EOF
done
python3 - "$INST/instance.config.json" <<'CFG'
import json, sys
c = json.load(open(sys.argv[1]))
c["roles"] = ["project-manager", "lead-dev", "qa-reviewer"]
c["roleTiers"]["lead-dev"] = "standard"
c["roleEffort"]["lead-dev"] = "high"
json.dump(c, open(sys.argv[1], "w"), indent=2)
CFG

TASK_DIR="$INST/projects/auto/tasks"
mkdir -p "$TASK_DIR"

# The hook plays every role in sequence, driven by the box name.
cat > "$SANDBOX/hook.sh" <<'HOOKEOF'
#!/usr/bin/env bash
name="$1"; T="$TASK_DIR/t1.md"
write() { cat > "$T" <<EOF
---
type: Task
status: $1
assignee: lead-dev
target_repo: demo-repo
acceptance_criteria: [ "it works" ]
open_questions: $OPEN_Q
pr: [ $2 ]
qa: $3
---
EOF
}
case "$name" in
  *-pm-new*)      write draft "" "" ;;
  *lead-dev*)     if [ -f "$SANDBOX/second-round" ]; then write in-review '"https://github.com/o/demo-repo/pull/7"' ""
                  else write in-review '"https://github.com/o/demo-repo/pull/7"' ""; fi ;;
  *qa-reviewer*)  if [ -f "$SANDBOX/reject-once" ] && [ ! -f "$SANDBOX/second-round" ]; then
                    : > "$SANDBOX/second-round"
                    write in-progress '"https://github.com/o/demo-repo/pull/7"' changes-requested
                  else
                    write in-review '"https://github.com/o/demo-repo/pull/7"' approved
                  fi ;;
esac
HOOKEOF
chmod +x "$SANDBOX/hook.sh"
export CLAUDE_BOX_FAKE_HOOK="$SANDBOX/hook.sh" TASK_DIR SANDBOX OPEN_Q=""

# --- gated: stops at promotion, and says what to do ---------------------------
out="$("$CB" harness do "$INST" "make it work" --repo demo-repo 2>&1)"; code=$?
assert_contains "gated stops before implementing" "$out" "promotion is yours"
assert_eq "gated exits 3 so a script can tell" "$code" "3"
assert_fails "gated never launched an implementer" grep -q 'lead-dev' "$CLAUDE_BOX_FAKE_STATE/argv.log"

# --- promote: draft -> implement -> review -> stop at merge -------------------
rm -f "$TASK_DIR"/*.md "$SANDBOX/second-round"; : > "$CLAUDE_BOX_FAKE_STATE/argv.log"
"$CB" harness autonomy promote -y --panel "$INST" >/dev/null 2>&1
out="$("$CB" harness do "$INST" "make it work" --repo demo-repo 2>&1)"
argv="$(cat "$CLAUDE_BOX_FAKE_STATE/argv.log")"
assert_contains "it drafts first"        "$argv" "-pm-new"
assert_contains "then implements"        "$argv" "-lead-dev-t1"
assert_contains "then reviews"           "$argv" "-qa-reviewer-t1"
assert_contains "and stops at the merge" "$out"  "merging is still yours"
assert_eq "the task ends in-review" "$(awk -F': *' '/^status:/{print $2;exit}' "$TASK_DIR/t1.md")" "in-review"

# --- a rejected review sends it back, bounded by --max-rounds ------------------
rm -f "$TASK_DIR"/*.md "$SANDBOX/second-round"; : > "$CLAUDE_BOX_FAKE_STATE/argv.log"
: > "$SANDBOX/reject-once"
out="$("$CB" harness do "$INST" "make it work" --repo demo-repo --max-rounds 2 2>&1)"
devs="$(grep -c -- '-lead-dev-t1' "$CLAUDE_BOX_FAKE_STATE/argv.log" || true)"
if [ "$devs" -ge 2 ]; then ok "changes-requested sends it back to the implementer"; else fail "changes-requested sends it back to the implementer" "implementer ran $devs time(s)"; fi
assert_contains "the rejection is reported" "$out" "sending it back"
rm -f "$SANDBOX/reject-once" "$SANDBOX/second-round"

# --- an open question stops the pipeline: nothing downstream can answer it -----
rm -f "$TASK_DIR"/*.md; : > "$CLAUDE_BOX_FAKE_STATE/argv.log"
OPEN_Q='[ "Q1: which region?" ]' out="$("$CB" harness do "$INST" "make it work" --repo demo-repo 2>&1)"; code=$?
assert_contains "an open question halts it" "$out" "waiting on you"
assert_contains "it says how to answer"     "$out" "append"
assert_eq "and exits 2" "$code" "2"
assert_fails "no implementer ran" grep -q 'lead-dev' "$CLAUDE_BOX_FAKE_STATE/argv.log"

summary
