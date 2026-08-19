#!/usr/bin/env bash
# `harness init` has one rule that matters: machinery refreshes, your data never does.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
CB="$REPO_DIR/claude-box"
unset CLAUDE_BOX_SOURCE_ONLY

PANEL="$CLAUDE_BOX_ROOT/_panel"
out="$("$CB" harness init "$PANEL" --org test-org --email t@t 2>&1)"
assert_contains "init reports where it stamped" "$out" "control panel created at"
assert_contains "init lists the roles it installed" "$out" "project-manager"

for f in instance.config.json SCHEMA.md CLAUDE.md index.md log.md knowledge/index.md; do
  assert_ok "init writes $f" test -f "$PANEL/$f"
done
for r in project-manager lead-dev qa-reviewer devops cataloguer; do
  assert_ok "role $r is installed" test -f "$PANEL/.claude/agents/$r.md"
done
assert_ok "the intents dir exists" test -d "$PANEL/.harness/intents/rejected"
assert_ok "the pending dir exists" test -d "$PANEL/.harness/pending"
assert_ok "init makes it a git repo" test -d "$PANEL/.git"
assert_contains "runtime state is gitignored" "$(cat "$PANEL/.gitignore")" "_wt/"
assert_contains "org is filled in" "$(cat "$PANEL/instance.config.json")" '"org": "test-org"'
assert_contains "reposRoot points at the root" "$(cat "$PANEL/instance.config.json")" '"reposRoot": "~/root"'

# OKF: only the bundle root may carry frontmatter, and only for okf_version.
assert_contains "the bundle root declares okf_version" "$(head -3 "$PANEL/index.md")" 'okf_version: "0.1"'
assert_fails "the knowledge index carries no frontmatter" \
  bash -c '[ "$(head -1 "$1")" = "---" ]' _ "$PANEL/knowledge/index.md"
assert_contains "index links are bundle-relative" "$(cat "$PANEL/index.md")" "](/SCHEMA.md)"

# The panel must be a valid instance to the rest of the harness.
assert_ok "the stamped panel validates" "$CB" harness status "$PANEL"

# --- refresh: machinery yes, data no -----------------------------------------
printf 'MY OWN NOTES\n' > "$PANEL/log.md"
python3 - "$PANEL/instance.config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["maxAgentsInFlight"] = 9
json.dump(c, open(sys.argv[1], "w"), indent=2)
PY
mkdir -p "$PANEL/projects/mine/tasks"
printf -- '---\nstatus: draft\n---\n' > "$PANEL/projects/mine/tasks/keep.md"
printf 'HAND EDITED ROLE\n' > "$PANEL/.claude/agents/lead-dev.md"

out="$("$CB" harness init "$PANEL" 2>&1)"
assert_contains "a re-run says it refreshed machinery" "$out" "refreshed the machinery"
assert_eq "my log is untouched" "$(cat "$PANEL/log.md")" "MY OWN NOTES"
assert_contains "my config is untouched" "$(cat "$PANEL/instance.config.json")" '"maxAgentsInFlight": 9'
assert_ok "my task survives" test -f "$PANEL/projects/mine/tasks/keep.md"
assert_fails "an edited role IS refreshed (machinery)" grep -q "HAND EDITED ROLE" "$PANEL/.claude/agents/lead-dev.md"

# A deliberately customised reposRoot must survive a refresh.
python3 - "$PANEL/instance.config.json" <<'CFG'
import json, sys
c = json.load(open(sys.argv[1])); c["reposRoot"] = "~/root/sub"
json.dump(c, open(sys.argv[1], "w"), indent=2)
CFG
"$CB" harness init "$PANEL" >/dev/null 2>&1
assert_contains "a customised reposRoot is not rewritten" \
  "$(cat "$PANEL/instance.config.json")" '"reposRoot": "~/root/sub"'

printf 'HAND EDITED AGAIN\n' > "$PANEL/.claude/agents/lead-dev.md"
"$CB" harness init "$PANEL" --keep-roles >/dev/null 2>&1
assert_ok "--keep-roles leaves an edited role alone" grep -q "HAND EDITED AGAIN" "$PANEL/.claude/agents/lead-dev.md"

# --- a panel must be reachable from inside a box ------------------------------
assert_fails "a panel outside the root is refused" "$CB" harness init "$SANDBOX/outside-panel"

# --- you should not have to type the panel path -------------------------------
# With exactly one panel under the root, every command must find it on its own.
out="$("$CB" harness status 2>&1)"
assert_contains "the only panel is found without an argument" "$out" "$PANEL"

# A second panel makes the choice ambiguous, and guessing would act on the wrong data.
"$CB" harness init "$CLAUDE_BOX_ROOT/_other" >/dev/null 2>&1
err="$("$CB" harness status 2>&1 || true)"
assert_contains "two panels ask which one, listing both" "$err" "several panels"
assert_contains "the ambiguity error names a candidate" "$err" "_other"

# ...unless you set it once.
out="$(CLAUDE_BOX_PANEL="$PANEL" "$CB" harness status 2>&1)"
assert_contains "CLAUDE_BOX_PANEL settles it" "$out" "$PANEL"
rm -rf "$CLAUDE_BOX_ROOT/_other"

# init with no directory picks the default name.
rm -rf "$CLAUDE_BOX_ROOT/_panel_default_check"
out="$(cd "$SANDBOX" && "$CB" harness init 2>&1)"
assert_ok "init with no argument stamps \$CLAUDE_BOX_ROOT/_panel" test -f "$CLAUDE_BOX_ROOT/_panel/instance.config.json"

# git is a default, not a requirement.
"$CB" harness init "$CLAUDE_BOX_ROOT/_nogit" --no-git >/dev/null 2>&1
assert_fails "--no-git leaves it a plain directory" test -d "$CLAUDE_BOX_ROOT/_nogit/.git"
assert_ok "a non-git panel still validates" "$CB" harness status "$CLAUDE_BOX_ROOT/_nogit"
rm -rf "$CLAUDE_BOX_ROOT/_nogit"

summary
