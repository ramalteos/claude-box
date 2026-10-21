#!/usr/bin/env bash
# The dashboard can now ACT. A page that can stop containers and promote tasks needs more
# than "it is only on localhost": any site you visit can POST to 127.0.0.1 without a CORS
# preflight. These test the guards, not the cosmetics.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
UI_PID=""
trap 'stop_ui; teardown_sandbox' EXIT
CB="$REPO_DIR/claude-box"
unset CLAUDE_BOX_SOURCE_ONLY

INST="$(make_instance)"
make_repo demo-repo >/dev/null
make_task "$INST" t1 draft >/dev/null

stop_ui() {
  [ -n "${UI_PID:-}" ] && kill "$UI_PID" 2>/dev/null
  UI_PID=""
}

# A free port, so a leftover server from another run cannot be mistaken for ours — that
# happened, and the test then talked to a PREVIOUS sandbox's panel.
free_port() {
  local p
  for p in $(seq 7850 7899); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$p/" 2>/dev/null || { printf '%s\n' "$p"; return 0; }
  done
  printf '%s\n' 7899
}

start_ui() {  # start_ui <port> [--actions]
  stop_ui
  "$CB" harness ui "$INST" --port "$1" "${2:-}" >"$SANDBOX/ui.log" 2>&1 &
  UI_PID=$!
  local i served
  for i in $(seq 1 60); do
    served="$(curl -sf "http://127.0.0.1:$1/api/state" 2>/dev/null \
                | python3 -c 'import json,sys; print(json.load(sys.stdin).get("instance",""))' 2>/dev/null || true)"
    # It must be OUR server: a stale one on this port would answer for another panel.
    [ "$served" = "$INST" ] && return 0
    sleep 0.5
  done
  return 1
}
post() { curl -s -X POST -H 'Content-Type: application/json' ${2:+-H "X-CB-Token: $2"} -d "$1" "http://127.0.0.1:$PORT/api/action"; }

# --- actions OFF by default ---------------------------------------------------
PORT="$(free_port)"
assert_ok "the dashboard starts read-only" start_ui "$PORT"
assert_contains "a write is refused when actions are off" "$(post '{"action":"tick"}')" "actions are off"
assert_contains "the page ships no token when actions are off" \
  "$(curl -s "http://127.0.0.1:$PORT/" | grep -c 'ACTION_TOKEN = ""')" "1"
assert_eq "the task is untouched" "$(awk -F': *' '/^status:/{print $2;exit}' "$INST/projects/demo/tasks/t1.md")" "draft"
stop_ui; sleep 1

# --- actions ON, but only with the token -------------------------------------
PORT="$(free_port)"
assert_ok "it starts with --actions" start_ui "$PORT" --actions
TOKEN="$(curl -s "http://127.0.0.1:$PORT/" | sed -n 's/.*ACTION_TOKEN = "\([a-f0-9]\{8,\}\)".*/\1/p' | head -1)"
if [ -n "$TOKEN" ]; then ok "the page carries a per-start token"; else fail "the page carries a per-start token" "none found"; fi

assert_contains "no token is refused" "$(post '{"action":"tick"}')" "bad token"
assert_contains "a wrong token is refused" "$(post '{"action":"tick"}' deadbeef)" "bad token"
assert_eq "still untouched after refused writes" "$(awk -F': *' '/^status:/{print $2;exit}' "$INST/projects/demo/tasks/t1.md")" "draft"

# --- with the token, promote works and is bounded ----------------------------
out="$(post '{"action":"promote","arg":"projects/demo/tasks/t1.md"}' "$TOKEN")"
assert_contains "promote with the token works" "$out" "promoted"
assert_eq "the task really is ready" "$(awk -F': *' '/^status:/{print $2;exit}' "$INST/projects/demo/tasks/t1.md")" "ready"
assert_contains "promoting a non-draft is refused" \
  "$(post '{"action":"promote","arg":"projects/demo/tasks/t1.md"}' "$TOKEN")" "not a draft"
assert_contains "escaping the panel is refused" \
  "$(post '{"action":"promote","arg":"../../../../etc/hosts.md"}' "$TOKEN")" "not a task in this panel"
assert_contains "an unknown action is refused, and says what is supported" \
  "$(post '{"action":"rm","arg":"x"}' "$TOKEN")" "does not support the action"
assert_contains "a malformed box name is refused as a bad ARGUMENT, not a bad action" \
  "$(post '{"action":"stop","arg":"; rm -rf /"}' "$TOKEN")" "is not valid for"

# --- memory from the page ------------------------------------------------------
# Accepting a proposal was terminal-only, so the page could show what agents proposed but
# not act on it. The action goes through the same runner command, and the same guards.
mkdir -p "$INST/.harness/pending"
cat > "$INST/.harness/pending/from-ui.md" <<'EOF'
---
tier: global
evidence: projects/demo/tasks/t1.md
---

Never pass --store-dir; the box's store is already warm.
EOF
PORT="$(free_port)"
assert_ok "the dashboard restarts with actions" start_ui "$PORT" --actions
TOKEN="$(curl -s "http://127.0.0.1:$PORT/" | sed -n 's/.*ACTION_TOKEN = "\([a-f0-9]\{8,\}\)".*/\1/p' | head -1)"

assert_contains "the whole proposal is available to read, not a snippet" \
  "$(curl -s "http://127.0.0.1:$PORT/api/state" | python3 -c 'import json,sys; d=json.load(sys.stdin); print([p["body"] for p in d["pending"] if p["file"]=="from-ui.md"][0])')" \
  "the box's store is already warm"

assert_contains "accepting without the token is refused" \
  "$(post '{"action":"memory-accept","arg":"from-ui.md"}')" "bad token"
assert_ok "the proposal is still pending" test -f "$INST/.harness/pending/from-ui.md"

assert_contains "a path is refused, only a file name" \
  "$(post '{"action":"memory-accept","arg":"../../etc/hosts.md"}' "$TOKEN")" "is not valid for"

out="$(post '{"action":"memory-accept","arg":"from-ui.md"}' "$TOKEN")"
assert_contains "accepting with the token works" "$out" "accepted"
assert_fails "the proposal leaves the queue" test -f "$INST/.harness/pending/from-ui.md"
assert_ok "and lands in the global tier" test -f "$CLAUDE_BOX_STATE/harness/memory/from-ui.md"
assert_contains "the page can then read it back" \
  "$(curl -s "http://127.0.0.1:$PORT/api/state" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(e["body"] for e in d["memory"]["global"]))')" \
  "store is already warm"
stop_ui; sleep 1

# --- the page must not offer what the server cannot do -------------------------
# index.html is read from disk on every request; this module is not. A server started before
# an action existed served a page with that button and then answered "unknown or malformed
# action", which reads like the user's fault. The server now advertises its actions.
PORT="$(free_port)"
assert_ok "the dashboard starts" start_ui "$PORT" --actions
adv="$(curl -s "http://127.0.0.1:$PORT/api/state" \
        | python3 -c 'import json,sys; a=json.load(sys.stdin).get("actions") or {}; print(",".join(a.get("supported") or []))')"
for a in stop tick promote done memory-accept memory-drop; do
  assert_contains "the server advertises $a" "$adv" "$a"
done
TOKEN="$(curl -s "http://127.0.0.1:$PORT/" | sed -n 's/.*ACTION_TOKEN = "\([a-f0-9]\{8,\}\)".*/\1/p' | head -1)"
out="$(post '{"action":"nope","arg":""}' "$TOKEN")"
assert_contains "an unsupported action explains itself" "$out" "does not support the action"
assert_contains "and names what it does support" "$out" "memory-accept"
out="$(post '{"action":"memory-accept","arg":"not a file"}' "$TOKEN")"
assert_contains "a bad argument is distinguished from a bad action" "$out" "not valid for"
stop_ui; sleep 1

# --- marking a merge from the page --------------------------------------------
# The gate lives in `harness done`, not here: this checks the page can reach it and that
# what it reaches is the same guarded command, not a second implementation that writes YAML.
FAKE_GH="$SANDBOX/gh"
cat > "$FAKE_GH" <<'GHEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") printf '%s\n' "${GH_STATE-MERGED}" ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$FAKE_GH"
export CLAUDE_BOX_GH="$FAKE_GH"

cat > "$INST/projects/demo/tasks/merged.md" <<'EOF'
---
type: Task
title: Something you merged yourself
status: in-review
target_repo: demo-repo
pr: [ "https://github.com/o/demo-repo/pull/7" ]
qa: approved
---

# Context
Test task.
EOF

PORT="$(free_port)"
assert_ok "the dashboard restarts for done" start_ui "$PORT" --actions
TOKEN="$(curl -s "http://127.0.0.1:$PORT/" | sed -n 's/.*ACTION_TOKEN = "\([a-f0-9]\{8,\}\)".*/\1/p' | head -1)"

assert_contains "marking done without the token is refused" \
  "$(post '{"action":"done","arg":"projects/demo/tasks/merged.md"}')" "bad token"
assert_eq "  so the task is untouched" \
  "$(awk -F': *' '/^status:/{print $2;exit}' "$INST/projects/demo/tasks/merged.md")" "in-review"

out="$(post '{"action":"done","arg":"projects/demo/tasks/merged.md"}' "$TOKEN")"
assert_contains "with the token it is marked done" "$out" "is done"
assert_eq "  and the document says so" \
  "$(awk -F': *' '/^status:/{print $2;exit}' "$INST/projects/demo/tasks/merged.md")" "done"

assert_contains "escaping the panel is refused by the command, not the page" \
  "$(post '{"action":"done","arg":"../../../../etc/hosts.md"}' "$TOKEN")" "not a document in this panel"

# An unmerged PR is the case the button exists to get wrong, so the page must not be able to.
cat > "$INST/projects/demo/tasks/stillopen.md" <<'EOF'
---
type: Task
title: Not merged yet
status: in-review
target_repo: demo-repo
pr: [ "https://github.com/o/demo-repo/pull/8" ]
qa: approved
---

# Context
Test task.
EOF
stop_ui; sleep 1
GH_STATE=OPEN start_ui "$PORT" --actions >/dev/null 2>&1
TOKEN="$(curl -s "http://127.0.0.1:$PORT/" | sed -n 's/.*ACTION_TOKEN = "\([a-f0-9]\{8,\}\)".*/\1/p' | head -1)"
out="$(post '{"action":"done","arg":"projects/demo/tasks/stillopen.md"}' "$TOKEN")"
assert_contains "an unmerged PR does not stop the page marking it done" "$out" "is done"
assert_eq "  the task is done" \
  "$(awk -F': *' '/^status:/{print $2;exit}' "$INST/projects/demo/tasks/stillopen.md")" "done"
assert_contains "  and the document records that nothing was merged" \
  "$(cat "$INST/projects/demo/tasks/stillopen.md")" "NOT every PR was merged"

# A project is addressable from the page too, by the path its row now carries.
mkdir -p "$INST/projects/demo"
cat > "$INST/projects/demo/project.md" <<'EOF'
---
type: Project
title: Demo
status: active
target_repo: demo-repo
---
EOF
assert_contains "the project row carries a path to address" \
  "$(curl -s "http://127.0.0.1:$PORT/api/state" | python3 -c 'import json,sys; print([p.get("path") for p in json.load(sys.stdin)["projects"]])')" \
  "projects/demo/project.md"
out="$(post '{"action":"done","arg":"projects/demo/project.md"}' "$TOKEN")"
assert_contains "a project can be closed out from the page" "$out" "is done"
assert_eq "  and the project document says done" \
  "$(awk -F': *' '/^status:/{print $2;exit}' "$INST/projects/demo/project.md")" "done"

# --- the remaining doors ------------------------------------------------------------
# DNS rebinding: a page on an attacker's host name resolving to 127.0.0.1 is same-origin to
# this server, so it could read the token out of GET / — unless the Host header is checked.
assert_contains "a request for another host name is refused" \
  "$(curl -s -H 'Host: evil.example' "http://127.0.0.1:$PORT/api/state")" "bad host"
assert_contains "  on POST too" \
  "$(curl -s -X POST -H 'Host: evil.example' -H "X-CB-Token: $TOKEN" -d '{"action":"tick"}' "http://127.0.0.1:$PORT/api/action")" "bad host"
# The name regexes allow the characters of `..`; the segment check is what keeps it inside.
assert_contains "a dot-dot project name is refused" \
  "$(post '{"action":"delete-project","arg":".."}' "$TOKEN")" "is not valid for 'delete-project'"
assert_contains "a dot-dot task path is refused" \
  "$(post '{"action":"delete-task","arg":"projects/../tasks/x.md"}' "$TOKEN")" "is not valid for 'delete-task'"
assert_contains "a body that is not an object is a bad body, not a dropped connection" \
  "$(post '[]' "$TOKEN")" "bad body"

# Objectives list their projects from a flow array, which the frontmatter parser files under
# lists — reading it as a scalar showed every objective with no projects.
mkdir -p "$INST/objectives"
cat > "$INST/objectives/o1.md" <<'EOF'
---
type: Objective
title: Ship it
status: active
projects: [ "/projects/demo/index.md" ]
---
EOF
assert_contains "an objective lists its projects" \
  "$(curl -s "http://127.0.0.1:$PORT/api/state" | python3 -c 'import json,sys; print([o["projects"] for o in json.load(sys.stdin)["objectives"] if o["file"]=="o1.md"])')" \
  "/projects/demo/index.md"
stop_ui

summary
