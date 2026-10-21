#!/usr/bin/env bash
# Closing work out is the human's call from ANY state — the command never argues about the
# status it found. What it must not do is let a `done` imply a merge that never happened, so
# every one of these checks the RECORD it leaves as much as the status it writes.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
load_runner

INST="$(make_instance)"
make_repo demo-repo >/dev/null

# A stub gh whose answer is per-PR: a stacked task holds several URLs and they can disagree.
FAKE_GH="$SANDBOX/gh"
cat > "$FAKE_GH" <<'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    num="${3##*/}"
    state="$(awk -v n="$num" '$1 == n { print $2; exit }' "$SANDBOX/pr-states" 2>/dev/null)"
    printf '%s\n' "${state:-${GH_STATE-MERGED}}"
    ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$FAKE_GH"
GH_BIN="$FAKE_GH"; export SANDBOX
: > "$SANDBOX/pr-states"

task() {  # task <id> <status> <pr-list> — replaced each time, so no test sees leftovers
  cat > "$INST/projects/demo/tasks/$1.md" <<EOF
---
type: Task
title: A task
status: $2
target_repo: demo-repo
pr: [ $3 ]
qa: approved
---

# Context
Test task.
EOF
  printf 'projects/demo/tasks/%s.md\n' "$1"
}

pr()   { printf '"https://github.com/o/demo-repo/pull/%s"' "$1"; }
st()   { task_status "$INST/projects/demo/tasks/$1.md"; }
body() { cat "$INST/projects/demo/tasks/$1.md"; }

# --- every state can be closed out --------------------------------------------
printf '1 MERGED\n' > "$SANDBOX/pr-states"
for state in draft ready in-progress in-review blocked cancelled; do
  t="$(task "$state" "$state" "$(pr 1)")"
  cmd_harness_done "$t" "$INST" >/dev/null 2>&1
  assert_eq "a $state task can be marked done" "$(st "$state")" "done"
  assert_contains "  and the note says what state it was in" "$(body "$state")" "was $state"
done

t="$(task alreadydone done "$(pr 1)")"
out="$(cmd_harness_done "$t" "$INST" 2>&1)"
assert_contains "an already-done task says so" "$out" "already"

# --- the merge is recorded, never enforced ------------------------------------
t="$(task allmerged in-review "$(pr 1), $(pr 2)")"
printf '1 MERGED\n2 MERGED\n' > "$SANDBOX/pr-states"
out="$(cmd_harness_done "$t" "$INST" 2>&1)"
assert_eq "every PR merged is done" "$(st allmerged)" "done"
assert_contains "  and the note counts them" "$(body allmerged)" "2 PR(s) merged"
assert_contains "  and the states are printed" "$out" "MERGED"

# The case the button exists for: work merged by hand, and work not merged at all. Both are
# done if the human says so — but the document must not imply the second was merged.
t="$(task stillopen in-progress "$(pr 1), $(pr 3)")"
printf '1 MERGED\n3 OPEN\n' > "$SANDBOX/pr-states"
cmd_harness_done "$t" "$INST" >/dev/null 2>&1
assert_eq "an open PR does not block it" "$(st stillopen)" "done"
assert_contains "  but the note refuses to imply a merge" "$(body stillopen)" "NOT every PR was merged"
assert_contains "  and names the PR that was open" "$(body stillopen)" "pull/3 OPEN"

t="$(task closedpr in-review "$(pr 6)")"
printf '6 CLOSED\n' > "$SANDBOX/pr-states"
cmd_harness_done "$t" "$INST" >/dev/null 2>&1
assert_contains "a closed-unmerged PR is recorded as unmerged" "$(body closedpr)" "pull/6 CLOSED"

: > "$SANDBOX/pr-states"
t="$(task nopr draft "")"
cmd_harness_done "$t" "$INST" >/dev/null 2>&1
assert_eq "a task with no PR at all is done" "$(st nopr)" "done"
assert_contains "  and the note says there was none" "$(body nopr)" "no PR on this task"

t="$(task unchecked in-review "$(pr 1)")"
cmd_harness_done "$t" "$INST" --no-pr >/dev/null 2>&1
assert_eq "--no-pr marks it done" "$(st unchecked)" "done"
assert_contains "  and records that nothing was checked" "$(body unchecked)" "merges not checked"

t="$(task nogh in-review "$(pr 1)")"
GH_BIN="$SANDBOX/there-is-no-gh"
cmd_harness_done "$t" "$INST" >/dev/null 2>&1
assert_eq "no gh does not block it either" "$(st nogh)" "done"
assert_contains "  and says the merges were never checked" "$(body nogh)" "never checked"
GH_BIN="$FAKE_GH"

# --- projects -----------------------------------------------------------------
project() {  # project <slug> <status>
  mkdir -p "$INST/projects/$1/tasks"
  cat > "$INST/projects/$1/project.md" <<EOF
---
type: Project
title: A project
status: $2
target_repo: demo-repo
---

# Context
Test project.
EOF
}

project halfdone active
cat > "$INST/projects/halfdone/tasks/a.md" <<'EOF'
---
type: Task
status: in-review
---
EOF
cat > "$INST/projects/halfdone/tasks/b.md" <<'EOF'
---
type: Task
status: done
---
EOF
out="$(cmd_harness_done projects/halfdone/project.md "$INST" 2>&1)"
assert_eq "a project can be marked done" "$(task_status "$INST/projects/halfdone/project.md")" "done"
assert_contains "  and the note names the tasks that were still open" \
  "$(cat "$INST/projects/halfdone/project.md")" "a.md"
assert_contains "  and says so on the way out" "$out" "not done or cancelled"

project byslug paused
cat > "$INST/projects/byslug/tasks/a.md" <<'EOF'
---
type: Task
status: cancelled
---
EOF
cmd_harness_done byslug "$INST" >/dev/null 2>&1
assert_eq "a bare project slug works, which is what the page has" \
  "$(task_status "$INST/projects/byslug/project.md")" "done"
assert_contains "  and a fully terminal project says that" \
  "$(cat "$INST/projects/byslug/project.md")" "every task done or cancelled"

# --- what may be addressed ----------------------------------------------------
assert_fails "a path outside the panel refuses" cmd_harness_done "../../../etc/hosts" "$INST"
assert_fails "a path that is not a file refuses" cmd_harness_done "projects/demo/tasks/nope.md" "$INST"

printf '%s\n' "---" "type: Objective" "status: active" "---" > "$INST/objectives/o1.md" 2>/dev/null \
  || { mkdir -p "$INST/objectives"; printf '%s\n' "---" "type: Objective" "status: active" "---" > "$INST/objectives/o1.md"; }
assert_fails "a document that is neither Task nor Project refuses" \
  cmd_harness_done "objectives/o1.md" "$INST"
assert_eq "  and is left alone" "$(task_status "$INST/objectives/o1.md")" "active"

summary
