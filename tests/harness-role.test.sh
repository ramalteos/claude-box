#!/usr/bin/env bash
# End-to-end through the real CLI with the fake engine: prompt assembly, model
# resolution, what actually gets passed to `run`, and a whole tick.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT

CB="$REPO_DIR/claude-box"
unset CLAUDE_BOX_SOURCE_ONLY          # these tests drive the CLI, not the helpers

INST="$(make_instance)"
make_repo demo-repo >/dev/null
TASK="$(make_task "$INST" t1 ready)"
TICK_TASK="$(make_task "$INST" t3 ready)"      # the tick gets its own task: t1 is held
                                              # by the direct dispatch below, and
                                              # refusing a second box for it is correct
SLUG="_ai-bridge-test"        # slug() keeps the leading underscore ai-bridge asks for

# --- dry run: model tiers and prompt assembly ---------------------------------
out="$("$CB" role software-engineer --instance "$INST" --task "$TASK" --repo demo-repo --dry-run 2>&1)"
assert_contains "standard tier resolves to sonnet"   "$out" "model:     sonnet"
assert_contains "dry run reports the box name"       "$out" "box:       claude-box-h-"
assert_contains "workdir is the instance in the box" "$out" "workdir:   /root/root/_ai-bridge-test"
assert_contains "dry run does not launch"            "$(cat "$CLAUDE_BOX_FAKE_STATE/calls.log" 2>/dev/null || echo none)" "none"

out="$("$CB" role qa-reviewer --instance "$INST" --task "$TASK" --repo demo-repo --dry-run 2>&1)"
assert_contains "deep tier resolves to opus" "$out" "model:     opus"

# Effort: current guidance is xhigh for agentic work, low for mechanical roles, and
# the flag must be omitted for haiku, which rejects it.
assert_contains "effort is shown for a configured role" \
  "$("$CB" role software-engineer --instance "$INST" --task "$TASK" --repo demo-repo --dry-run 2>&1)" \
  "(effort high)"
assert_contains "the deep role gets xhigh" \
  "$("$CB" role qa-reviewer --instance "$INST" --task "$TASK" --repo demo-repo --dry-run 2>&1)" \
  "(effort xhigh)"
python3 - "$INST/instance.config.json" <<'CFG'
import json, sys
c = json.load(open(sys.argv[1]))
c["roleTiers"]["software-engineer"] = "light"
c["roleEffort"]["software-engineer"] = "high"
json.dump(c, open(sys.argv[1], "w"), indent=2)
CFG
out="$("$CB" role software-engineer --instance "$INST" --task "$TASK" --repo demo-repo --dry-run 2>&1)"
assert_contains "the haiku tier resolves" "$out" "model:     haiku"
assert_fails "effort is omitted for haiku (it rejects the flag)" bash -c 'case "$1" in *effort*) exit 0 ;; *) exit 1 ;; esac' _ "$out"
python3 - "$INST/instance.config.json" <<'CFG2'
import json, sys
c = json.load(open(sys.argv[1]))
c["roleTiers"]["software-engineer"] = "standard"
json.dump(c, open(sys.argv[1], "w"), indent=2)
CFG2

# --- the assembled system prompt ---------------------------------------------
mkdir -p "$CLAUDE_BOX_STATE/harness/memory"
printf 'GLOBAL-RULE: prefer small diffs.\n' > "$CLAUDE_BOX_STATE/harness/memory/style.md"
"$CB" role software-engineer --instance "$INST" --task "$TASK" --repo demo-repo --detach >/dev/null 2>&1
# The system prompt is the last big argument written, so waiting for its marker means
# the whole invocation has landed.
assert_ok "the detached box reaches the engine" \
  wait_for_text "$CLAUDE_BOX_FAKE_STATE/argv.log" "PERSONA-MARKER-software-engineer"
argv="$(cat "$CLAUDE_BOX_FAKE_STATE/argv.log")"
assert_contains "persona comes from the instance's own role file" "$argv" "PERSONA-MARKER-software-engineer"
assert_contains "overlay is appended after the persona"           "$argv" "Executor rules (claude-box harness)"
assert_contains "memory is injected"                              "$argv" "GLOBAL-RULE: prefer small diffs."
assert_contains "headless boxes get IS_SANDBOX (root needs it)"    "$argv" "IS_SANDBOX=1"
assert_contains "permission mode is bypass"                        "$argv" "bypassPermissions"
assert_contains "the root is mounted with \$HOME-relative parity"  "$argv" "$CLAUDE_BOX_ROOT:/root/root"
assert_contains "the mount path is exported for the entrypoint"    "$argv" "CLAUDE_BOX_MOUNT=/root/root"

# --- a whole tick with the fake engine ---------------------------------------
: > "$CLAUDE_BOX_FAKE_STATE/argv.log"
mkdir -p "$INST/.harness/intents"
cat > "$INST/.harness/intents/good.json" <<EOF
{"intent":"dispatch","role":"qa-reviewer","task":"$TICK_TASK","target_repo":"demo-repo","reason":"review it"}
EOF
cat > "$INST/.harness/intents/bad.json" <<'EOF'
{"intent":"dispatch","role":"ceo","task":"projects/demo/tasks/t1.md","target_repo":"demo-repo"}
EOF

dry="$("$CB" harness tick "$INST" --dry-run 2>&1)"
assert_contains "dry run says what it would dispatch" "$dry" "would dispatch qa-reviewer"
assert_ok "dry run leaves the intent in place" test -f "$INST/.harness/intents/good.json"

CLAUDE_BOX_ROLE_TIMEOUT=30 "$CB" harness tick "$INST" >/dev/null 2>&1
assert_ok "the tick's dispatch reaches the engine" \
  wait_for_text "$CLAUDE_BOX_FAKE_STATE/argv.log" "claude-box-h-$SLUG-qa-reviewer-t3"
argv="$(cat "$CLAUDE_BOX_FAKE_STATE/argv.log")"
assert_contains "the tick runs a PM box"          "$argv" "claude-box-h-$SLUG-pm"
assert_contains "the tick dispatches the valid intent" "$argv" "claude-box-h-$SLUG-qa-reviewer-t3"
assert_fails "a dispatched intent is consumed"    test -f "$INST/.harness/intents/good.json"
assert_ok "a rejected intent is kept with its reason" test -f "$INST/.harness/intents/rejected/bad.json"
assert_contains "the rejection says why" "$(cat "$INST/.harness/intents/rejected/bad.json")" "not in instance.config.json"

assert_ok "the task held by the direct dispatch keeps its marker" \
  test -n "$(command ls "$CLAUDE_BOX_STATE/harness/$SLUG/inflight" 2>/dev/null)"

last="$(cat "$CLAUDE_BOX_STATE/harness/$SLUG/last-tick")"
assert_contains "the tick writes a summary" "$(cat "$CLAUDE_BOX_STATE/harness/$SLUG/ticks/$last/summary.txt")" "accepted 1"

status="$("$CB" harness status "$INST" 2>&1)"
assert_contains "status reports the last tick" "$status" "last tick: $last"
assert_contains "status reports the cap"       "$status" "boxes in flight"

# --- the promotion guard ------------------------------------------------------
CLAUDE_BOX_SOURCE_ONLY=1 . "$CB"
resolve_instance "$INST"
TICK_DIR="$(mktemp -d)"
make_task "$INST" t9 draft >/dev/null
before="$TICK_DIR/before.tsv"; after="$TICK_DIR/after.tsv"
status_snapshot > "$before"
sed -i.bak 's/^status: draft/status: ready/' "$INST/projects/demo/tasks/t9.md" && rm -f "$INST/projects/demo/tasks/t9.md.bak"
status_snapshot > "$after"
revert_promotions "$before" "$after" "test role" >/dev/null 2>&1
assert_eq "an illegal draft->ready is reverted" "$(task_status "$INST/projects/demo/tasks/t9.md")" "draft"
assert_contains "the violation is recorded" "$(cat "$TICK_DIR/violations.tsv")" "reverted draft->ready"

# A legal transition by a role must be left alone.
status_snapshot > "$before"
sed -i.bak 's/^status: ready/status: in-progress/' "$INST/projects/demo/tasks/t1.md" && rm -f "$INST/projects/demo/tasks/t1.md.bak"
status_snapshot > "$after"
revert_promotions "$before" "$after" "test role" >/dev/null 2>&1
assert_eq "ready->in-progress is left alone" "$(task_status "$INST/projects/demo/tasks/t1.md")" "in-progress"
rm -rf "$TICK_DIR"

# --- the repo inventory -------------------------------------------------------
# A role that cannot see what repos exist has to infer the target from prose, which is
# how work lands in the wrong repository. Each phase gets its own fake-engine state dir:
# the log is append-only and shared, so a truncate races the previous box's writer.
make_repo other-service >/dev/null

export CLAUDE_BOX_FAKE_STATE="$SANDBOX/fake-inventory"
mkdir -p "$CLAUDE_BOX_FAKE_STATE"
"$CB" role software-engineer --instance "$INST" --task "$TASK" --repo demo-repo --detach >/dev/null 2>&1
assert_ok "the box carries a repo inventory" \
  wait_for_text "$CLAUDE_BOX_FAKE_STATE/argv.log" "## Repositories"
argv="$(cat "$CLAUDE_BOX_FAKE_STATE/argv.log")"
assert_contains "the inventory lists a real clone"     "$argv" "- demo-repo"
assert_contains "the inventory lists every clone"      "$argv" "- other-service"
assert_fails    "the panel is not offered as a target" \
  bash -c 'case "$1" in *"- _ai-bridge-test"*) exit 0 ;; *) exit 1 ;; esac' _ "$argv"
assert_contains "a given target is stated plainly"     "$argv" "This task targets **demo-repo**"

export CLAUDE_BOX_FAKE_STATE="$SANDBOX/fake-notarget"
mkdir -p "$CLAUDE_BOX_FAKE_STATE"
"$CB" role software-engineer --instance "$INST" --task "$TASK" --detach >/dev/null 2>&1
assert_ok "the no-target box launches" \
  wait_for_text "$CLAUDE_BOX_FAKE_STATE/argv.log" "## Repositories"
assert_contains "with no target, ambiguity is an open question, not a guess" \
  "$(cat "$CLAUDE_BOX_FAKE_STATE/argv.log")" "ask it rather than guessing"

summary
