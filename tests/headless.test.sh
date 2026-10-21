#!/usr/bin/env bash
# `headless` is the seam an external orchestrator (claude-graph) drives: one box, one
# prompt, one worktree, in the foreground, exit code passed through. These pin what the
# engine is asked to do, since nothing else checks it.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
load_runner

REPO="$(make_repo demo-repo)"
P="$SANDBOX/prompt.md"; S="$SANDBOX/system.md"
printf 'do the thing\nsecond line\n' > "$P"
printf 'PERSONA-MARKER-coder\n' > "$S"
ARGV="$CLAUDE_BOX_FAKE_STATE/argv.log"
BASE="$(git -C "$REPO" rev-parse HEAD)"

# --- refusals -----------------------------------------------------------------

out="$(cmd_headless "$REPO" --name b1 2>&1)"
assert_contains "no prompt file is an error" "$out" "--prompt-file"
out="$(cmd_headless "$REPO" --prompt-file "$P" 2>&1)"
assert_contains "no name is an error" "$out" "--name"
out="$(cmd_headless "$REPO" --name b1 --prompt-file "$P" --worktree '../x' 2>&1)"
assert_contains "a worktree id with path characters is refused" "$out" "worktree id"
out="$(cmd_headless "$REPO" --name 'b 1' --prompt-file "$P" 2>&1)"
assert_contains "a box name with odd characters is refused" "$out" "box name"
out="$(cmd_headless "$REPO" --worktree t1 --remove --name b1 --prompt-file "$P" 2>&1)"
assert_contains "remove refuses a prompt" "$out" "--remove"
assert_contains "refusals launch nothing" "$(cat "$ARGV" 2>/dev/null || echo none)" "none"

# --- a plain box in the repo itself -------------------------------------------

out="$(cmd_headless "$REPO" --name b1 --prompt-file "$P" --system-prompt-file "$S" --model opus --effort high 2>&1)"
argv="$(cat "$ARGV")"
assert_contains "runs claude headless"             "$argv" "bypassPermissions"
assert_contains "streams json so the log is live"  "$argv" "stream-json"
assert_contains "bypass as root needs IS_SANDBOX"  "$argv" "IS_SANDBOX=1"
assert_contains "system prompt file is read in"    "$argv" "PERSONA-MARKER-coder"
assert_contains "prompt file is read in, whole"    "$argv" $'do the thing\nsecond line'
assert_contains "model is forwarded"               "$argv" $'--model\nopus'
assert_contains "effort is forwarded"              "$argv" $'--effort\nhigh'
assert_contains "workdir is the repo"              "$argv" "-w"$'\n'"$CONTAINER_WS/demo-repo"
assert_contains "box name carries the prefix"      "$argv" $'--name\nclaude-box-b1'
assert_contains "box name is reported"             "$out" "box=claude-box-b1"
case "$argv" in *"worktree add"*) fail "no worktree without --worktree" ;; *) ok "no worktree without --worktree" ;; esac

# --- a box in its own worktree ------------------------------------------------

: > "$ARGV"
out="$(cmd_headless "$REPO" --name b2 --prompt-file "$P" --worktree t1 2>&1)"
argv="$(cat "$ARGV")"
assert_contains "worktree is added in-container, from HEAD" "$argv" \
  "worktree add -b 'claude-box/t1' '$CONTAINER_WS/.claude-box-runs/t1' '$BASE'"
assert_contains "box runs in the worktree"         "$argv" "-w"$'\n'"$CONTAINER_WS/.claude-box-runs/t1"
assert_contains "worktree host path is reported"   "$out" "worktree=$CLAUDE_BOX_ROOT/.claude-box-runs/t1"
assert_contains "branch is reported"               "$out" "branch=claude-box/t1"
assert_contains "base sha is reported"             "$out" "base=$BASE"

# A second role on the same task lands in the same tree. The fake engine never ran git,
# so stand in for the directory the in-container add would have created.
mkdir -p "$CLAUDE_BOX_ROOT/.claude-box-runs/t1"
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "head moved"
: > "$ARGV"
out="$(cmd_headless "$REPO" --name b3 --prompt-file "$P" --worktree t1 2>&1)"
argv="$(cat "$ARGV")"
case "$argv" in *"worktree add"*) fail "an existing worktree is not re-added" ;; *) ok "an existing worktree is not re-added" ;; esac
assert_contains "base is the ORIGINAL base, not the new HEAD" "$out" "base=$BASE"
assert_contains "second box runs in the same tree" "$argv" "-w"$'\n'"$CONTAINER_WS/.claude-box-runs/t1"

# --- a caller-named branch ----------------------------------------------------

: > "$ARGV"
out="$(cmd_headless "$REPO" --name b5 --prompt-file "$P" --worktree t2 --branch graph/t2 2>&1)"
argv="$(cat "$ARGV")"
assert_contains "worktree is cut on the named branch"  "$argv" "worktree add -b 'graph/t2'"
assert_contains "named branch is reported"             "$out" "branch=graph/t2"
mkdir -p "$CLAUDE_BOX_ROOT/.claude-box-runs/t2"
out="$(cmd_headless "$REPO" --name b6 --prompt-file "$P" --worktree t2 --branch other/name 2>&1)"
assert_contains "a later --branch cannot move the tree" "$out" "branch=graph/t2"
out="$(cmd_headless "$REPO" --name b7 --prompt-file "$P" --worktree t3 --branch '../x' 2>&1)"
assert_contains "a branch with .. is refused"          "$out" "branch must match"
out="$(cmd_headless "$REPO" --name b7 --prompt-file "$P" --branch x 2>&1)"
assert_contains "--branch without --worktree is refused" "$out" "needs --worktree"
out="$(cmd_headless "$REPO" --worktree t2 --remove 2>&1)"
assert_contains "remove names the real branch"         "$out" "branch graph/t2 kept"

# --- exit code passes through -------------------------------------------------

( CLAUDE_BOX_FAKE_EXIT=7 cmd_headless "$REPO" --name b4 --prompt-file "$P" ) >/dev/null 2>&1
assert_eq "the box's exit code is the command's" "$?" "7"

# --- remove -------------------------------------------------------------------

: > "$ARGV"
out="$(cmd_headless "$REPO" --worktree t1 --remove 2>&1)"
argv="$(cat "$ARGV")"
assert_contains "remove runs in-container"         "$argv" "worktree remove --force '$CONTAINER_WS/.claude-box-runs/t1'"
case "$argv" in *bypassPermissions*) fail "remove launches no claude" ;; *) ok "remove launches no claude" ;; esac
assert_contains "branch is kept"                   "$out" "kept"
assert_ok "host dir is gone" test ! -d "$CLAUDE_BOX_ROOT/.claude-box-runs/t1"

summary
