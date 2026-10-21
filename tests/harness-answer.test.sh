#!/usr/bin/env bash
# Answering rewrites an item inside a multi-line YAML flow array. That is fiddly enough by
# hand to be worth a tool, and fiddly enough in a tool to be worth tests.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
load_runner

INST="$(make_instance)"
resolve_instance "$INST"
T="$INST/projects/demo/tasks/q.md"
mkdir -p "$(dirname "$T")"

fresh() {
  cat > "$T" <<'EOF'
---
type: Task
status: draft
target_repo: demo-repo
acceptance_criteria: [
  "it works"
]
open_questions: [
  "Q1: which region should we default to, given the buckets differ?",
  "Q2: may this add data-test attributes to src/ components?"
]
pr: [ ]
---

# Context
Body text mentioning open_questions: [ "not a real one" ] to be ignored.
EOF
}

fresh
assert_eq "both questions are seen" "$(fm_list_count "$T" open_questions)" "2"

answer_write "$T" 1 "eu-central-1"
assert_contains "the answer lands on the right question" \
  "$(fm_list_items "$T" open_questions | sed -n 1p)" "region should we default to, given the buckets differ? --- eu-central-1"
assert_fails "the other question is untouched" \
  bash -c 'case "$1" in *" --- "*) exit 0 ;; *) exit 1 ;; esac' _ "$(fm_list_items "$T" open_questions | sed -n 2p)"
assert_eq "the list still parses as two items" "$(fm_list_count "$T" open_questions)" "2"
assert_eq "other fields survive" "$(fm_list_count "$T" acceptance_criteria)" "1"
assert_contains "the body is untouched" "$(cat "$T")" "Body text mentioning"

answer_write "$T" 2 "yes, standardise on data-test"
assert_contains "the second answer lands too" \
  "$(fm_list_items "$T" open_questions | sed -n 2p)" "components? --- yes, standardise on data-test"

# A quote in the answer must not be able to corrupt the document.
fresh
answer_write "$T" 1 'use the "sandbox" bucket'
assert_eq "a quoted answer keeps the list parseable" "$(fm_list_count "$T" open_questions)" "2"
assert_contains "the quotes are made safe" "$(fm_list_items "$T" open_questions | sed -n 1p)" "use the 'sandbox' bucket"

# Promotion must stay blocked until every question is answered — an answered question is
# still an entry, so the PM clears it on the next pass; the host must not promote before then.
fresh
TICK_DIR="$(mktemp -d)"
autonomy_promote promote >/dev/null 2>&1
assert_eq "a task with questions is not promoted" "$(task_status "$T")" "draft"
python3 - "$T" <<'CLEAR'
import re, sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"open_questions: \[.*?\]", "open_questions: [ ]", s, flags=re.S))
CLEAR
autonomy_promote promote >/dev/null 2>&1
assert_eq "once cleared, it promotes" "$(task_status "$T")" "ready"
rm -rf "$TICK_DIR"

# --- the stdin bug ------------------------------------------------------------
# The task list arrives on stdin. If a prompt reads its reply from stdin too, it eats the
# next FILENAME off that list and records it as the answer — which happened to real task
# documents, silently, with no error and a plausible-looking "recorded". The reply must
# come from a separate channel.
fresh
mkdir -p "$INST/projects/demo/tasks"
printf -- '---\ntype: Task\nstatus: draft\nopen_questions: [ ]\n---\n' > "$INST/projects/demo/tasks/decoy.md"
printf 'eu-central-1\nyes, use data-test\n' > "$SANDBOX/answers"
CLAUDE_BOX_TTY="$SANDBOX/answers" answer_interactively "projects/demo/tasks/q.md
projects/demo/tasks/decoy.md" >/dev/null 2>&1

a1="$(fm_list_items "$T" open_questions | sed -n 1p)"
a2="$(fm_list_items "$T" open_questions | sed -n 2p)"
assert_contains "the first answer is what was typed"  "$a1" " --- eu-central-1"
assert_contains "the second answer is what was typed" "$a2" " --- yes, use data-test"
assert_fails "no filename was swallowed as an answer" \
  bash -c 'case "$1$2" in *"--- projects/"*) exit 0 ;; *) exit 1 ;; esac' _ "$a1" "$a2"

# An exhausted answer channel must skip, not record something wrong.
fresh
: > "$SANDBOX/empty"
CLAUDE_BOX_TTY="$SANDBOX/empty" answer_interactively "projects/demo/tasks/q.md" >/dev/null 2>&1
assert_fails "no answers are invented when nothing is typed" \
  bash -c 'case "$(cat "$1")" in *" --- "*) exit 0 ;; *) exit 1 ;; esac' _ "$T"

# The interactive path must refuse to run without a terminal rather than hang.
fresh
out="$(bash -c '. "$1"; resolve_instance "$2"; cmd_harness_answer "$2" < /dev/null' _ "$REPO_DIR/claude-box" "$INST" 2>&1 || true)"
assert_contains "answering without a terminal is refused, not hung" "$out" "needs a terminal"

# --- block-form questions ------------------------------------------------------
# The project-manager writes long questions as an indented block list. answer_write used to
# refuse that shape outright ("open_questions is not a list"), so the answer was dropped and
# the task stayed blocked on a question the human had already answered.

cat > "$INST/projects/demo/tasks/blk.md" <<'EOF'
---
type: Task
title: A task
status: draft
target_repo: demo-repo
acceptance_criteria:
  - "something testable"
open_questions:
  - "Q1: which region should we default to?"
  - "Q2: should the client carry a timeout?"
timestamp: 2026-08-31T00:00:00Z
---

# Context
EOF

answer_write "$INST/projects/demo/tasks/blk.md" 1 "eu-central-1"
assert_contains "a block question records the answer" \
  "$(cat "$INST/projects/demo/tasks/blk.md")" "default to? --- eu-central-1"
assert_contains "the answer stays inside the quotes" \
  "$(cat "$INST/projects/demo/tasks/blk.md")" '--- eu-central-1"'
assert_contains "the sibling question is untouched" \
  "$(cat "$INST/projects/demo/tasks/blk.md")" '"Q2: should the client carry a timeout?"'

answer_write "$INST/projects/demo/tasks/blk.md" 2 "yes, with a named constant"
assert_contains "the second block question records too" \
  "$(cat "$INST/projects/demo/tasks/blk.md")" "a timeout? --- yes, with a named constant"
assert_eq "both are still counted as questions" \
  "$(fm_list_count "$INST/projects/demo/tasks/blk.md" open_questions)" "2"
assert_contains "the frontmatter is still intact" \
  "$(cat "$INST/projects/demo/tasks/blk.md")" "timestamp: 2026-08-31T00:00:00Z"
assert_contains "the body survived" "$(cat "$INST/projects/demo/tasks/blk.md")" "# Context"

# A double quote in the answer would break the YAML scalar, so it is downgraded.
answer_write "$INST/projects/demo/tasks/blk.md" 1 'use "eu-west-1" instead'
assert_contains "double quotes in an answer are downgraded" \
  "$(cat "$INST/projects/demo/tasks/blk.md")" "use 'eu-west-1' instead"

out="$(answer_write "$INST/projects/demo/tasks/blk.md" 9 "nope" 2>&1)"
assert_contains "an out-of-range block index is refused" "$out" "no question 9"

summary
