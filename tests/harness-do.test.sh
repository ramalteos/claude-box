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
assert_contains "it points at the answering command" "$out" "harness answer"
assert_contains "it prints a path you can actually open" "$out" "$INST/projects/"
assert_eq "and exits 2" "$code" "2"
assert_fails "no implementer ran" grep -q 'lead-dev' "$CLAUDE_BOX_FAKE_STATE/argv.log"

# --- answers must be folded in before anything is promoted --------------------
# An answered question still occupies its entry, and the host refuses to promote while any
# entry remains. A resume that skipped the project-manager would stall forever — and an
# answer that says "skip this" must be able to cancel the task, not become built work.
rm -f "$TASK_DIR"/*.md
export CLAUDE_BOX_FAKE_STATE="$SANDBOX/fake-fold"; mkdir -p "$CLAUDE_BOX_FAKE_STATE"
cat > "$TASK_DIR/t7.md" <<'EOF'
---
type: Task
status: draft
assignee: lead-dev
target_repo: demo-repo
acceptance_criteria: [ "it works" ]
open_questions: [
  "Q1: which region? --- eu-central-1"
]
pr: [ ]
---
EOF
out="$("$CB" harness do "$INST" --resume 2>&1)"
assert_contains "resume folds answers in first" "$out" "folding in your answers"
assert_ok "the fold-in runs a project-manager box" \
  wait_for_text "$CLAUDE_BOX_FAKE_STATE/argv.log" "-pm-fold"
assert_contains "the fold-in instruction says to clear the entry" \
  "$(cat "$CLAUDE_BOX_FAKE_STATE/argv.log")" "DELETE that entry from open_questions"
assert_contains "and to cancel work the human declined" \
  "$(cat "$CLAUDE_BOX_FAKE_STATE/argv.log")" "Do not implement work the human declined"
assert_contains "and never to promote" \
  "$(cat "$CLAUDE_BOX_FAKE_STATE/argv.log")" "Do NOT set any task to ready"

# --- the host creates the worktree, in the right place -------------------------
# A role that made its own worktree put it at <repo>/_wt/... — inside the monorepo — which
# turned six thousand files into untracked changes on the human's main branch. The path,
# the base and the branch name are facts the host knows; it issues the command now.
export CLAUDE_BOX_FAKE_STATE="$SANDBOX/fake-wt"; mkdir -p "$CLAUDE_BOX_FAKE_STATE"
# NOTE: a prefix assignment on the `.` builtin persists in this shell, so unset it after —
# otherwise every later `claude-box` child sees it. The runner now also requires being
# genuinely sourced, but the test should not rely on that.
CLAUDE_BOX_SOURCE_ONLY=1 . "$CB"; set +e
unset CLAUDE_BOX_SOURCE_ONLY
resolve_instance "$INST" >/dev/null 2>&1

b="$(branch_for_task projects/auto/tasks/t1.md)"
assert_contains "the branch is named for the project and task" "$b" "auto/t1"
assert_fails "the branch does not carry a role name" \
  bash -c 'case "$1" in *lead-dev*) exit 0 ;; *) exit 1 ;; esac' _ "$b"
assert_eq "the worktree name is project-scoped" "$(worktree_name projects/auto/tasks/t1.md)" "auto-t1"

# The path handed to a role must sit under the repos root, never inside a repo.
mkdir -p "$CLAUDE_BOX_ROOT/_wt/auto-t1"
ensure_task_worktree projects/auto/tasks/t1.md demo-repo >/dev/null 2>&1
assert_contains "the worktree path is under the repos root" "$TASK_WORKTREE" "/_wt/auto-t1"
assert_fails "the worktree path is not inside the repo" \
  bash -c 'case "$1" in */demo-repo/_wt/*) exit 0 ;; *) exit 1 ;; esac' _ "$TASK_WORKTREE"

# A stray worktree inside the repo is removed rather than left to pollute git status.
mkdir -p "$CLAUDE_BOX_ROOT/demo-repo/_wt/auto-t1"
ensure_task_worktree projects/auto/tasks/t1.md demo-repo >/dev/null 2>&1
assert_fails "a worktree found inside the repo is removed" test -d "$CLAUDE_BOX_ROOT/demo-repo/_wt"

# --- the design gate ----------------------------------------------------------
# `design_review: required` means the architect judges the approach BEFORE anything is
# built. A gate that lets implementation start anyway would be decoration.
export CLAUDE_BOX_FAKE_STATE="$SANDBOX/fake-arch"; mkdir -p "$CLAUDE_BOX_FAKE_STATE"
cat > "$INST/.claude/agents/architect.md" <<'EOF'
---
name: architect
description: fixture
---
PERSONA-MARKER-architect
EOF
python3 - "$INST/instance.config.json" <<'CFG'
import json, sys
c = json.load(open(sys.argv[1]))
c["roles"].append("architect")
c["roleTiers"]["architect"] = "deep"
json.dump(c, open(sys.argv[1], "w"), indent=2)
CFG
rm -f "$TASK_DIR"/*.md
cat > "$TASK_DIR/t8.md" <<'EOF'
---
type: Task
status: ready
assignee: lead-dev
target_repo: demo-repo
acceptance_criteria: [ "it works" ]
open_questions: [ ]
design_review: required
arch:
pr: [ ]
---
EOF
# The fake box writes no verdict, which must stop the task rather than let it build.
CLAUDE_BOX_FAKE_HOOK="" out="$("$CB" harness do "$INST" --resume 2>&1)"
assert_contains "a task needing design review gets the architect first" "$out" "design review of t8.md"
assert_ok "the architect box actually ran" \
  wait_for_text "$CLAUDE_BOX_FAKE_STATE/argv.log" "-architect-t8"
assert_contains "no verdict stops the task" "$out" "not implementing this until the design is settled"
assert_fails "the implementer never ran" grep -q -- '-lead-dev-t8' "$CLAUDE_BOX_FAKE_STATE/argv.log"

# With a sound verdict, implementation proceeds.
export CLAUDE_BOX_FAKE_STATE="$SANDBOX/fake-arch2"; mkdir -p "$CLAUDE_BOX_FAKE_STATE"
cat > "$SANDBOX/arch-hook.sh" <<'HOOK'
#!/usr/bin/env bash
case "$1" in
  *-architect-*) python3 - "$TASK_DIR/t8.md" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"^arch:.*$", "arch: sound", s, count=1, flags=re.M))
PY
  ;;
esac
HOOK
chmod +x "$SANDBOX/arch-hook.sh"
CLAUDE_BOX_FAKE_HOOK="$SANDBOX/arch-hook.sh" out="$("$CB" harness do "$INST" --resume 2>&1)"
assert_contains "a sound verdict lets it proceed" "$out" "arch: sound — proceeding"
assert_ok "and the implementer runs" \
  wait_for_text "$CLAUDE_BOX_FAKE_STATE/argv.log" "-lead-dev-t8"

# --- the host must not rewrite the routing -------------------------------------
# Recording who is working must not clobber `assignee`: doing so meant that after a design
# review the pipeline re-dispatched `architect` instead of the implementer.
cat > "$TASK_DIR/t6.md" <<'EOF'
---
type: Task
status: ready
assignee: lead-dev
target_repo: demo-repo
acceptance_criteria: [ "x" ]
open_questions: [ ]
pr: [ ]
---
EOF
CLAUDE_BOX_SOURCE_ONLY=1 . "$CB"; set +e
unset CLAUDE_BOX_SOURCE_ONLY
resolve_instance "$INST" >/dev/null 2>&1
task_mark_working "$TASK_DIR/t6.md" architect claude-box-h-x-architect-t6
assert_eq "assignee survives another role working the task" \
  "$(task_field "$TASK_DIR/t6.md" assignee)" "lead-dev"
assert_eq "the working box is recorded separately" \
  "$(task_field "$TASK_DIR/t6.md" box)" "claude-box-h-x-architect-t6"
assert_eq "and the status moved to in-progress" \
  "$(task_status "$TASK_DIR/t6.md")" "in-progress"

# A box that ends with no PR must not leave the task stuck at in-progress.
task_reconcile "$TASK_DIR/t6.md" 0
assert_eq "a clean box with no PR returns the task to ready" \
  "$(task_status "$TASK_DIR/t6.md")" "ready"
task_mark_working "$TASK_DIR/t6.md" lead-dev box2
task_reconcile "$TASK_DIR/t6.md" 1
assert_eq "a failed box with no PR marks it blocked" \
  "$(task_status "$TASK_DIR/t6.md")" "blocked"
assert_contains "and records why" "$(task_field "$TASK_DIR/t6.md" blocked_reason)" "without opening a pull request"

# --- stacking across tasks -----------------------------------------------------
# `depends_on` is the plan saying "this cannot exist without that". Basing every task on the
# default branch anyway yields sibling branches that each re-contain their dependency's work,
# and PRs that all target main — a pile, not a stack.
REPO="$CLAUDE_BOX_ROOT/demo-repo"
git -C "$REPO" checkout -q -B main 2>/dev/null
printf 'a\n' > "$REPO/a.txt"; git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm base
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

mkdir -p "$INST/projects/chain/tasks"
for id in c1 c2 c3; do
  deps=""
  [ "$id" = c2 ] && deps='[ /projects/chain/tasks/c1.md ]'
  [ "$id" = c3 ] && deps='[ /projects/chain/tasks/c1.md, /projects/chain/tasks/c2.md ]'
  cat > "$INST/projects/chain/tasks/$id.md" <<EOF
---
type: Task
title: slice $id
status: ready
target_repo: demo-repo
acceptance_criteria: [ "x" ]
depends_on: ${deps:-[ ]}
pr: [ ]
---
EOF
done
CLAUDE_BOX_SOURCE_ONLY=1 . "$CB"; set +e
unset CLAUDE_BOX_SOURCE_ONLY
resolve_instance "$INST" >/dev/null 2>&1

assert_eq "a task with no dependency starts from the default branch" \
  "$(task_base_branch projects/chain/tasks/c1.md "$REPO" main)" "origin/main"

# c1's branch exists and is unmerged, so c2 must stack on it.
git -C "$REPO" branch "$(branch_for_task projects/chain/tasks/c1.md)" HEAD >/dev/null 2>&1
printf 'b\n' > "$REPO/b.txt"
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm slice1 >/dev/null
git -C "$REPO" branch -f "$(branch_for_task projects/chain/tasks/c1.md)" HEAD >/dev/null 2>&1
git -C "$REPO" checkout -q main
assert_eq "a dependent task stacks on its dependency" \
  "$(task_base_branch projects/chain/tasks/c2.md "$REPO" main)" "$(branch_for_task projects/chain/tasks/c1.md)"

# With c1 and c2 both present, c3 must pick the TIP of the chain, not the first entry.
git -C "$REPO" branch "$(branch_for_task projects/chain/tasks/c2.md)" \
  "$(branch_for_task projects/chain/tasks/c1.md)" >/dev/null 2>&1
git -C "$REPO" checkout -q "$(branch_for_task projects/chain/tasks/c2.md)"
printf 'c\n' > "$REPO/c.txt"; git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm slice2 >/dev/null
git -C "$REPO" checkout -q main
assert_eq "the deepest dependency wins, not the first listed" \
  "$(task_base_branch projects/chain/tasks/c3.md "$REPO" main)" "$(branch_for_task projects/chain/tasks/c2.md)"

# A merged dependency is already in main; stacking on it would be noise.
git -C "$REPO" merge -q --no-edit "$(branch_for_task projects/chain/tasks/c1.md)" >/dev/null 2>&1
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
assert_eq "a merged dependency is not stacked on" \
  "$(task_base_branch projects/chain/tasks/c2.md "$REPO" main)" "origin/main"

# --- work that comes back must be picked up in the same run --------------------
# A review that requests changes puts a task back BEHIND the cursor. With a single forward
# pass it sat there until a human noticed and re-ran the command.
export CLAUDE_BOX_FAKE_STATE="$SANDBOX/fake-pass"; mkdir -p "$CLAUDE_BOX_FAKE_STATE"
rm -f "$TASK_DIR"/*.md
cat > "$TASK_DIR/p1.md" <<'EOF'
---
type: Task
status: ready
assignee: lead-dev
target_repo: demo-repo
acceptance_criteria: [ "x" ]
open_questions: [ ]
pr: [ ]
---
EOF
# The hook plays a QA reviewer that rejects once, then approves — so the task returns to
# in-progress after the first review and must be picked up again without a second command.
cat > "$SANDBOX/pass-hook.sh" <<'HOOK'
#!/usr/bin/env bash
T="$TASK_DIR/p1.md"
set_status() { python3 - "$T" "$1" "$2" <<PY
import re, sys
p, st, qa = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
s = re.sub(r"^status:.*$", "status: " + st, s, count=1, flags=re.M)
if re.search(r"^qa:", s, re.M): s = re.sub(r"^qa:.*$", "qa: " + qa, s, count=1, flags=re.M)
else: s = s.replace("pr: [", "qa: %s\npr: [" % qa, 1)
if "pull/9" not in s: s = s.replace("pr: [ ]", 'pr: [ "https://github.com/o/demo-repo/pull/9" ]', 1)
open(p, "w").write(s)
PY
}
case "$1" in
  *lead-dev*)    set_status in-review "" ;;
  *qa-reviewer*) if [ -f "$SANDBOX/rejected-once" ]; then set_status in-review approved
                 else : > "$SANDBOX/rejected-once"; set_status in-progress changes-requested; fi ;;
esac
HOOK
chmod +x "$SANDBOX/pass-hook.sh"
rm -f "$SANDBOX/rejected-once"
CLAUDE_BOX_FAKE_HOOK="$SANDBOX/pass-hook.sh" TASK_DIR="$TASK_DIR" SANDBOX="$SANDBOX" \
  out="$(CLAUDE_BOX_ROLE_TIMEOUT=25 "$CB" harness do "$INST" --resume --max-rounds 1 --passes 3 2>&1)"
assert_contains "the run makes another pass when work comes back" "$out" "another pass"
devs="$(grep -c -- '-lead-dev-p1' "$CLAUDE_BOX_FAKE_STATE/argv.log" || true)"
if [ "$devs" -ge 2 ]; then ok "the implementer runs again in the same command"
else fail "the implementer runs again in the same command" "it ran $devs time(s)"; fi

# The bound must hold: with one pass allowed, it does not loop.
rm -f "$SANDBOX/rejected-once"; : > "$CLAUDE_BOX_FAKE_STATE/argv.log"
cat > "$TASK_DIR/p1.md" <<'EOF'
---
type: Task
status: ready
assignee: lead-dev
target_repo: demo-repo
acceptance_criteria: [ "x" ]
open_questions: [ ]
pr: [ ]
---
EOF
CLAUDE_BOX_FAKE_HOOK="$SANDBOX/pass-hook.sh" TASK_DIR="$TASK_DIR" SANDBOX="$SANDBOX" \
  out="$(CLAUDE_BOX_ROLE_TIMEOUT=25 "$CB" harness do "$INST" --resume --max-rounds 1 --passes 1 2>&1)"
assert_fails "--passes 1 makes exactly one pass" \
  bash -c 'case "$1" in *"another pass"*) exit 0 ;; *) exit 1 ;; esac' _ "$out"

# --- a blocked task must not kill the run --------------------------------------
# `[ test ] && printf` as the last command in a loop leaves the loop's exit status at 1, which
# fails the enclosing command substitution and — under set -e — exits the whole script with no
# message. A panel containing blocked tasks turned --resume into a silent no-op.
# The block carries a reason: a block WITHOUT one is not a verdict, and resume retries it
# (blocked_retryable) — that is the --retry case below, not this one.
rm -f "$TASK_DIR"/*.md
cat > "$TASK_DIR/b1.md" <<'EOF'
---
type: Task
status: blocked
blocked_reason: "needs a secret nobody has granted"
target_repo: demo-repo
acceptance_criteria: [ "x" ]
pr: [ ]
---
EOF
out="$("$CB" harness do "$INST" --resume --project auto 2>&1)"; code=$?
assert_contains "a panel of blocked tasks reports instead of vanishing" "$out" "nothing to resume"
assert_eq "and exits cleanly" "$code" "0"

# With --retry the same board is workable.
export CLAUDE_BOX_FAKE_STATE="$SANDBOX/fake-retry"; mkdir -p "$CLAUDE_BOX_FAKE_STATE"
out="$(CLAUDE_BOX_ROLE_TIMEOUT=20 "$CB" harness do "$INST" --retry --project auto 2>&1)"
assert_contains "--retry picks the blocked task up" "$out" "b1.md"
assert_fails "and does not report nothing to resume" \
  bash -c 'case "$1" in *"nothing to resume"*) exit 0 ;; *) exit 1 ;; esac' _ "$out"

# A timeout is a clock, not a verdict: the task stays workable and resume continues it.
rm -f "$TASK_DIR"/*.md
cat > "$TASK_DIR/to1.md" <<'EOF'
---
type: Task
status: in-progress
target_repo: demo-repo
acceptance_criteria: [ "x" ]
pr: [ ]
---
EOF
bash -c 'CLAUDE_BOX_SOURCE_ONLY=1 . "$1"; set +e; resolve_instance "$2" >/dev/null 2>&1
  task_reconcile "$2/projects/auto/tasks/to1.md" timeout >/dev/null 2>&1' _ "$CB" "$INST"
assert_contains "a timed-out task stays in-progress"   "$(grep '^status:' "$TASK_DIR/to1.md")" "in-progress"
assert_contains "and records the attempt" "$(cat "$TASK_DIR/to1.md")" "attempts: 1"
out="$("$CB" harness do "$INST" --resume --project auto --dry-run 2>&1)"
assert_contains "so resume still lists it" "$out" "to1.md"

# After the attempt cap it becomes a block worth a human's attention.
bash -c 'CLAUDE_BOX_SOURCE_ONLY=1 . "$1"; set +e; resolve_instance "$2" >/dev/null 2>&1
  set_task_field "$2/projects/auto/tasks/to1.md" attempts 2
  task_reconcile "$2/projects/auto/tasks/to1.md" timeout >/dev/null 2>&1' _ "$CB" "$INST"
assert_contains "the third timeout blocks it" "$(grep '^status:' "$TASK_DIR/to1.md")" "blocked"

# Blocked with an open PR and no reason is a review nobody moved, not a block.
cat > "$TASK_DIR/n1.md" <<'EOF'
---
type: Task
status: blocked
target_repo: demo-repo
acceptance_criteria: [ "x" ]
pr: [ "https://github.com/o/r/pull/1" ]
blocked_reason: ""
---
EOF
"$CB" harness do "$INST" --resume --project auto >/dev/null 2>&1 || true
assert_contains "normalising moves it to in-review" "$(grep '^status:' "$TASK_DIR/n1.md")" "in-review"

# No comment inside a command substitution may contain a backtick: bash reads it as a nested
# substitution and swallows the rest of the file.
assert_ok "the harness parses" bash -n "$REPO_DIR/harness/harness.sh"


# A box that stops writing to its log is stuck, not working: the watchdog stops it and the
# task stays resumable rather than burning the whole budget.
out="$(bash -c 'CLAUDE_BOX_SOURCE_ONLY=1 . "$1"; set +e
  CLAUDE_BOX_STALL_TIMEOUT=1 CLAUDE_BOX_ROLE_TIMEOUT=60
  box_is_running() { return 0; }
  engine_stop_box() { echo "stopped $1"; }
  log="$2/quiet.log"; : > "$log"
  wait_for_box quiet-box "$2/never-exits" "$log"' _ "$CB" "$SANDBOX" 2>&1)"
assert_contains "silence stops the box" "$out" "wrote nothing for 1s"
assert_eq "and is recorded as stalled" "$(cat "$SANDBOX/never-exits")" "stalled"

# No subagents in a role box: their output is a file the parent then waits on.
out="$("$CB" harness do "$INST" --task "projects/auto/tasks/to1.md" --dry-run 2>&1 || true)"
assert_ok "the Task tool is denied to role boxes" bash -c '
  grep -q "disallowed-tools Task" "$1/harness/harness.sh"' _ "$REPO_DIR"

# "a human should run this" is a missing CI job, not a verdict that ends the round.
assert_ok "the host rewrites blocked-on-human-verification into a CI instruction" bash -c '
  grep -q "wire the verification into a CI job" "$1/harness/harness.sh"' _ "$REPO_DIR"


# A box working a blocked task means the task is in progress: leaving it blocked made the
# board claim nothing was happening while lead-dev was building.
cat > "$TASK_DIR/w1.md" <<'EOF'
---
type: Task
status: blocked
target_repo: demo-repo
acceptance_criteria: [ "x" ]
pr: [ ]
blocked_reason: "an old attempt ran out of time"
---
EOF
bash -c 'CLAUDE_BOX_SOURCE_ONLY=1 . "$1"; set +e; resolve_instance "$2" >/dev/null 2>&1
  task_mark_working "$2/projects/auto/tasks/w1.md" lead-dev some-box' _ "$CB" "$INST"
assert_contains "an implementer moves a blocked task to in-progress" \
  "$(grep '^status:' "$TASK_DIR/w1.md")" "in-progress"
assert_ok "and the stale reason is cleared" bash -c '
  grep -q '"'"'^blocked_reason: *""*$'"'"' "$1" || ! grep -q "an old attempt" "$1"' _ "$TASK_DIR/w1.md"

# A reviewer reads; it must not claim the work is being built.
bash -c 'CLAUDE_BOX_SOURCE_ONLY=1 . "$1"; set +e; resolve_instance "$2" >/dev/null 2>&1
  set_task_field "$2/projects/auto/tasks/w1.md" status in-review
  task_mark_working "$2/projects/auto/tasks/w1.md" qa-reviewer some-box' _ "$CB" "$INST"
assert_contains "qa-reviewer leaves the status alone" \
  "$(grep '^status:' "$TASK_DIR/w1.md")" "in-review"


# --- an expired session stops the run, it does not blame the tasks -----------------
# One dead credential killed twelve boxes in ~80ms each, and every empty exit was read as
# "no PR — task blocked": nine documents rewritten for a reason that had nothing to do with
# them. The first auth failure must abort and leave the document as it was.
rm -f "$TASK_DIR"/*.md
cat > "$TASK_DIR/a1.md" <<'EOF'
---
type: Task
status: ready
assignee: lead-dev
target_repo: demo-repo
acceptance_criteria: [ "x" ]
open_questions: [ ]
pr: [ ]
---
EOF
cat > "$SANDBOX/auth-hook.sh" <<'HOOK'
#!/usr/bin/env bash
printf '%s\n' '{"error":"authentication_failed","result":"Failed to authenticate: OAuth session expired and could not be refreshed"}' \
  >> "$LOGDIR/$1.log"
HOOK
chmod +x "$SANDBOX/auth-hook.sh"
export CLAUDE_BOX_FAKE_STATE="$SANDBOX/fake-auth"; mkdir -p "$CLAUDE_BOX_FAKE_STATE"
out="$(CLAUDE_BOX_FAKE_HOOK="$SANDBOX/auth-hook.sh" LOGDIR="$CLAUDE_BOX_STATE/logs" \
       CLAUDE_BOX_ROLE_TIMEOUT=25 "$CB" harness do "$INST" --resume --project auto 2>&1)"; code=$?
assert_contains "an auth failure stops the run" "$out" "could not authenticate"
assert_ok "and it exits non-zero" bash -c '[ "$1" != 0 ]' _ "$code"
assert_contains "and the task keeps the status it had" "$(grep '^status:' "$TASK_DIR/a1.md")" "ready"

# --- an approved verdict is a decision, not a cache to refill ---------------------
cat > "$TASK_DIR/a2.md" <<'EOF'
---
type: Task
status: in-review
assignee: lead-dev
target_repo: demo-repo
qa: approved
acceptance_criteria: [ "x" ]
open_questions: [ ]
pr: [ "https://github.com/o/r/pull/9" ]
---
EOF
rm -f "$TASK_DIR/a1.md"
: > "$CLAUDE_BOX_FAKE_STATE/argv.log"
out="$(CLAUDE_BOX_ROLE_TIMEOUT=25 "$CB" harness do "$INST" --resume --project auto --max-rounds 2 2>&1)"
assert_contains "an approved task is not re-reviewed" "$out" "qa already approved"
assert_fails "and no qa box is spent on it" \
  grep -q -- '-qa-reviewer-a2' "$CLAUDE_BOX_FAKE_STATE/argv.log"

summary
