#!/usr/bin/env bash
# `clean` discards an attempt; `delete` removes the documents. The panel is usually a git
# repo with nothing committed and no remote, so these check the two things that make the
# difference between a delete and a mistake: what it REFUSES, and the copy it leaves behind.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
load_runner

INST="$(make_instance)"
REPO="$(make_repo demo-repo)"

STATE_SLUG="$(slug "$(basename "$INST")")"
TRASH="$CLAUDE_BOX_STATE/harness/$STATE_SLUG/trash"

# --- what it refuses ----------------------------------------------------------

out="$(cmd_harness_delete "$INST" 2>&1)"
assert_contains "no target is an error" "$out" "say what to delete"

out="$(cmd_harness_delete "$INST" --project demo --task projects/demo/tasks/t1.md 2>&1)"
assert_contains "project and task together are refused" "$out" "pass one"

out="$(cmd_harness_delete "$INST" --task ../../etc/passwd 2>&1)"
assert_contains "a path outside projects/ is refused" "$out" "not a task path"

out="$(cmd_harness_delete "$INST" --task projects/demo/../../tasks/t1.md 2>&1)"
assert_contains "traversal inside the path is refused" "$out" "not a task path"

out="$(cmd_harness_delete "$INST" --project nope 2>&1)"
assert_contains "an unknown project is refused" "$out" "no such project"

make_task "$INST" t1 ready >/dev/null
out="$(cmd_harness_delete "$INST" --task projects/demo/tasks/t1.md </dev/null 2>&1)"
assert_contains "no tty and no -y is refused" "$out" "refusing to delete non-interactively"
assert_ok "the task survived that refusal" test -f "$INST/projects/demo/tasks/t1.md"

# A box holding the task would keep writing into the worktree we are about to remove.
printf 'claude-box-h-%s-software-engineer-t1\n' "$STATE_SLUG" > "$CLAUDE_BOX_FAKE_STATE/running"
out="$(cmd_harness_delete "$INST" --task projects/demo/tasks/t1.md -y 2>&1)"
assert_contains "a running box blocks the delete" "$out" "still running"
assert_ok "the task survived the running box" test -f "$INST/projects/demo/tasks/t1.md"
: > "$CLAUDE_BOX_FAKE_STATE/running"

# --- dry run ------------------------------------------------------------------

out="$(cmd_harness_delete "$INST" --task projects/demo/tasks/t1.md --dry-run 2>&1)"
assert_contains "dry run says so" "$out" "nothing was deleted"
assert_ok "dry run left the document alone" test -f "$INST/projects/demo/tasks/t1.md"

# --- deleting one task --------------------------------------------------------

# A worktree and a branch, exactly as a box would have left them.
WT="$(worktree_name projects/demo/tasks/t1.md)"
git -C "$REPO" branch -q feature/t1-does-a-thing
git -C "$REPO" worktree add -q --detach "$CLAUDE_BOX_ROOT/_wt/$WT" >/dev/null 2>&1

out="$(cmd_harness_delete "$INST" --task projects/demo/tasks/t1.md -y 2>&1)"
assert_ok "the task document is gone" test ! -f "$INST/projects/demo/tasks/t1.md"
assert_ok "the worktree is gone" test ! -d "$CLAUDE_BOX_ROOT/_wt/$WT"
assert_eq "the local branch is gone" \
  "$(git -C "$REPO" branch --list 'feature/t1-does-a-thing' | tr -d ' *')" ""
assert_contains "it says where the copy went" "$out" "a copy is in"

# The copy is the point: the panel has no remote to recover from.
copy="$(find "$TRASH" -path '*projects/demo/tasks/t1.md' 2>/dev/null | head -1)"
assert_ok "a trashed copy exists" test -n "$copy"
assert_contains "the trashed copy is the document" "$(cat "$copy" 2>/dev/null)" "# Context"

# --- dangling references get named --------------------------------------------

make_task "$INST" t2 ready >/dev/null
make_task "$INST" t3 ready >/dev/null
python3 - "$INST/projects/demo/tasks/t3.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("status: ready",
    "status: ready\ndepends_on: [ /projects/demo/tasks/t2.md ]", 1)
open(p, "w").write(t)
PY
out="$(cmd_harness_delete "$INST" --task projects/demo/tasks/t2.md -y 2>&1)"
assert_contains "a dependent task is named" "$out" "projects/demo/tasks/t3.md"
assert_contains "and named again after the delete" "$out" "Still referencing"

# --- index links are dropped --------------------------------------------------

mkdir -p "$INST/projects/demo"
cat > "$INST/projects/demo/index.md" <<'EOF'
# demo

* [Task three](/projects/demo/tasks/t3.md) - the one that stays
* [Task four](/projects/demo/tasks/t4.md) - the one that goes
EOF
make_task "$INST" t4 ready >/dev/null
cmd_harness_delete "$INST" --task projects/demo/tasks/t4.md -y >/dev/null 2>&1
idx="$(cat "$INST/projects/demo/index.md")"
assert_contains "the surviving link is kept" "$idx" "/projects/demo/tasks/t3.md"
case "$idx" in
  *"/projects/demo/tasks/t4.md"*) fail "the dead link is dropped" "t4 still listed" ;;
  *) ok "the dead link is dropped" ;;
esac

# --- purge keeps no copy ------------------------------------------------------

make_task "$INST" t5 ready >/dev/null
before="$(find "$TRASH" -type f 2>/dev/null | wc -l | tr -d ' ')"
cmd_harness_delete "$INST" --task projects/demo/tasks/t5.md -y --purge >/dev/null 2>&1
after="$(find "$TRASH" -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_ok "the purged task is gone" test ! -f "$INST/projects/demo/tasks/t5.md"
assert_eq "--purge trashed nothing" "$after" "$before"

# --- deleting a whole project -------------------------------------------------

mkdir -p "$INST/projects/other/tasks"
cat > "$INST/projects/other/project.md" <<'EOF'
---
type: Project
title: Another project
status: active
target_repo: demo-repo
---

# Context
Test project.
EOF
cat > "$INST/projects/other/tasks/a1.md" <<'EOF'
---
type: Task
title: A task
status: ready
target_repo: demo-repo
---

# Context
Test task.
EOF

# A slug is a directory name, never a path — that is the whole containment check.
out="$(cmd_harness_delete "$INST" --project ../../etc -y 2>&1)"
assert_contains "a project slug with a path is refused" "$out" "no such project"

cmd_harness_delete "$INST" --project other -y >/dev/null 2>&1
assert_ok "the project directory is gone" test ! -d "$INST/projects/other"
assert_ok "the other project is untouched" test -d "$INST/projects/demo"
copy="$(find "$TRASH" -path '*projects/other/project.md' 2>/dev/null | head -1)"
assert_ok "the project was trashed, not destroyed" test -n "$copy"

# --- objectives ---------------------------------------------------------------

mkdir -p "$INST/objectives"
cat > "$INST/objectives/ship-it.md" <<'EOF'
---
type: Objective
status: active
projects: [ "/projects/demo/index.md" ]
---

Ship the thing.
EOF

out="$(cmd_harness_delete "$INST" --objective nope -y 2>&1)"
assert_contains "an unknown objective is refused" "$out" "no such objective"

out="$(cmd_harness_delete "$INST" --project demo --objective ship-it -y 2>&1)"
assert_contains "two targets at once are refused" "$out" "pass one"

# A project that cites the objective is a dangling reference the other way round.
mkdir -p "$INST/projects/demo"
cat > "$INST/projects/demo/project.md" <<'EOF'
---
type: Project
title: Demo
status: active
objective: /objectives/ship-it.md
---

# Context
EOF

out="$(cmd_harness_delete "$INST" --objective ship-it -y 2>&1)"
assert_ok "the objective is gone" test ! -f "$INST/objectives/ship-it.md"
assert_contains "the project citing it is named" "$out" "projects/demo/project.md"
copy="$(find "$TRASH" -path '*objectives/ship-it.md' 2>/dev/null | head -1)"
assert_ok "the objective was trashed" test -n "$copy"

# A slug, never a path — same containment rule as projects.
printf 'x\n' > "$SANDBOX/outside.md"
out="$(cmd_harness_delete "$INST" --objective ../../outside -y 2>&1)"
assert_contains "an objective path is refused" "$out" "no such objective"
assert_ok "the outside file survived" test -f "$SANDBOX/outside.md"

summary
