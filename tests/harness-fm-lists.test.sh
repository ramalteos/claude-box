#!/usr/bin/env bash
# Frontmatter lists come in two YAML shapes and the harness must read both. It used to read
# only the flow form (`key: [ a, b ]`), so a task whose criteria were written as an indented
# block counted as ZERO criteria — which silently disabled autonomy promotion for exactly the
# tasks a project-manager writes, and hid their open questions from `harness answer`.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT
load_runner

INST="$(make_instance)"
resolve_instance "$INST" >/dev/null 2>&1

block_task() {  # block_task <id> <status> — criteria and questions in BLOCK form
  cat > "$INST/projects/demo/tasks/$1.md" <<EOF
---
type: Task
title: A task
status: $2
target_repo: demo-repo
acceptance_criteria:
  - "The first outcome, which is long enough to want its own line."
  - "The second outcome, with a colon: and a [bracket] in it."
  - 'A single-quoted third outcome.'
open_questions: [ ]
timestamp: 2026-08-31T00:00:00Z
---

# Context
Test task.
EOF
}

# --- block lists are read ------------------------------------------------------

block_task b1 draft
assert_eq "block criteria are counted" "$(fm_list_count "$INST/projects/demo/tasks/b1.md" acceptance_criteria)" "3"
assert_contains "quotes are stripped" \
  "$(fm_list_items "$INST/projects/demo/tasks/b1.md" acceptance_criteria | head -1)" \
  "The first outcome"
assert_contains "a colon inside an item survives" \
  "$(fm_list_items "$INST/projects/demo/tasks/b1.md" acceptance_criteria | sed -n 2p)" \
  "with a colon: and a [bracket]"
assert_eq "an empty flow list is still zero" \
  "$(fm_list_count "$INST/projects/demo/tasks/b1.md" open_questions)" "0"

# --- the flow form still works -------------------------------------------------

cat > "$INST/projects/demo/tasks/f1.md" <<'EOF'
---
type: Task
title: A task
status: draft
target_repo: demo-repo
acceptance_criteria: [ "one outcome", "two outcome" ]
open_questions: [ "Q1: which region? --- eu-central-1" ]
depends_on: [ /projects/demo/tasks/b1.md ]
---

# Context
EOF
assert_eq "flow criteria are counted" "$(fm_list_count "$INST/projects/demo/tasks/f1.md" acceptance_criteria)" "2"
assert_eq "flow questions are counted" "$(fm_list_count "$INST/projects/demo/tasks/f1.md" open_questions)" "1"
assert_eq "flow depends_on is counted" "$(fm_list_count "$INST/projects/demo/tasks/f1.md" depends_on)" "1"

# --- a block list stops at the next key, not at the next document --------------

cat > "$INST/projects/demo/tasks/b2.md" <<'EOF'
---
type: Task
title: A task
status: draft
target_repo: demo-repo
acceptance_criteria:
  - "only this one"
open_questions:
  - "Q1: a real blocking question"
  - "Q2: a second one"
---

# Context
- this body bullet is not a criterion
EOF
assert_eq "the block stops at the next key" "$(fm_list_count "$INST/projects/demo/tasks/b2.md" acceptance_criteria)" "1"
assert_eq "block questions are counted" "$(fm_list_count "$INST/projects/demo/tasks/b2.md" open_questions)" "2"

# --- the promotion gate, which is what the bug actually broke ------------------

export TICK_DIR="$SANDBOX/tick"; mkdir -p "$TICK_DIR"

# Refined: block criteria, no questions. This is the case that never promoted.
block_task p1 draft
autonomy_promote promote >/dev/null 2>&1
assert_eq "a refined block-list task is promoted" \
  "$(task_status "$INST/projects/demo/tasks/p1.md")" "ready"

# Unrefined: block criteria, but a block question still waiting on a human.
autonomy_promote promote >/dev/null 2>&1
assert_eq "an open block question still blocks promotion" \
  "$(task_status "$INST/projects/demo/tasks/b2.md")" "draft"

# No criteria at all is still unrefined.
cat > "$INST/projects/demo/tasks/p2.md" <<'EOF'
---
type: Task
title: A task
status: draft
target_repo: demo-repo
acceptance_criteria:
open_questions: [ ]
---

# Context
EOF
autonomy_promote promote >/dev/null 2>&1
assert_eq "a task with no criteria is not promoted" \
  "$(task_status "$INST/projects/demo/tasks/p2.md")" "draft"

# gated mode promotes nothing, whatever the document says.
block_task g1 draft
autonomy_promote gated >/dev/null 2>&1
assert_eq "gated mode promotes nothing" \
  "$(task_status "$INST/projects/demo/tasks/g1.md")" "draft"

summary
