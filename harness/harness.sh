#!/usr/bin/env bash
# claude-box harness — run ai-bridge role agents as individual boxes.
#
# Sourced by the `claude-box` runner for the `role` and `harness` subcommands; it
# relies on the runner's helpers (die/note, resolve_target, run_box_fg/bg,
# box_is_running, ENGINE_BIN, STATE_HOME, ROOT, CONTAINER_WS).
#
# Division of labour, and the reason for it: the HOST is the only thing that talks
# to the container engine. A role box writes a dispatch INTENT to a file; the host
# validates it and launches the container. Mounting the engine socket into a box
# would hand a sandboxed agent the host daemon, which is a sandbox escape rather
# than a feature — so the intent file is the whole interface.
#
# See docs/superpowers/specs/2026-08-19-claude-box-harness-design.md.

HARNESS_DIR="$SETUP_DIR/harness"
# Per-box wall-clock limit. A wedged agent must not hold a dispatch slot forever.
CLAUDE_BOX_ROLE_TIMEOUT="${CLAUDE_BOX_ROLE_TIMEOUT:-2700}"      # 45 min
# Cap on the assembled memory preamble. Memory that eats the context window makes
# every role worse at the job the memory was supposed to help with.
CLAUDE_BOX_MEMORY_MAX="${CLAUDE_BOX_MEMORY_MAX:-8000}"          # characters

# --- instance + config --------------------------------------------------------
# An ai-bridge control-panel instance, identified the way ai-bridge's own pm-loop
# identifies one: config + role definitions + schema all present.
INSTANCE="" INSTANCE_SLUG="" INSTANCE_STATE=""

# Every panel directly under the repos root. A panel is data — your objectives, tasks
# and knowledge — so it lives beside your repos rather than inside the tool.
find_panels() {
  local d
  [ -n "$ROOT" ] || return 0
  for d in "$ROOT"/*/; do
    d="${d%/}"
    [ -f "$d/instance.config.json" ] && [ -f "$d/SCHEMA.md" ] && [ -d "$d/.claude/agents" ] \
      && printf '%s\n' "$d"
  done
}

# Work out which panel a command means, so the path is something you set once rather
# than type every time: an explicit argument, then $CLAUDE_BOX_PANEL, then the current
# directory if it is one, then the only panel under the root.
default_panel() {
  local found count
  if [ -n "${CLAUDE_BOX_PANEL:-}" ]; then printf '%s\n' "$CLAUDE_BOX_PANEL"; return 0; fi
  if [ -f "$PWD/instance.config.json" ] && [ -f "$PWD/SCHEMA.md" ]; then printf '%s\n' "$PWD"; return 0; fi
  found="$(find_panels)"
  count="$(printf '%s\n' "$found" | grep -c . || true)"
  if [ "$count" = 1 ]; then printf '%s\n' "$found"; return 0; fi
  if [ "$count" = 0 ]; then
    die "no control panel found under $ROOT — create one with 'claude-box harness init'"
  fi
  die "several panels under $ROOT; name one, or set CLAUDE_BOX_PANEL:
$(printf '%s\n' "$found" | sed 's|^|  |')"
}

resolve_instance() {
  local dir="${1:-}"
  [ -n "$dir" ] || dir="$(default_panel)"
  [ -d "$dir" ] || die "panel directory not found: $dir"
  dir="$(cd "$dir" && pwd -P)"
  for f in instance.config.json SCHEMA.md .claude/agents; do
    [ -e "$dir/$f" ] || die "$dir is not a control panel (missing $f) — stamp one with 'claude-box harness init $dir', or pass an existing ai-bridge instance"
  done
  [ -n "$ROOT" ] && [ "${dir#"$ROOT"/}" = "$dir" ] && [ "$dir" != "$ROOT" ] && \
    die "instance $dir is outside the root ($ROOT) so a box could not see it — move it under the root or set CLAUDE_BOX_ROOT"
  INSTANCE="$dir"
  INSTANCE_SLUG="$(slug "$(basename "$dir")")"
  INSTANCE_STATE="$STATE_HOME/harness/$INSTANCE_SLUG"
  mkdir -p "$INSTANCE_STATE/ticks" "$STATE_HOME/harness/memory" \
           "$INSTANCE/.harness/intents/rejected" "$INSTANCE/.harness/pending"
}

# cfg <dotted.path> [default] — read instance.config.json without needing jq.
cfg() {
  python3 - "$INSTANCE/instance.config.json" "$1" "${2:-}" <<'PY'
import json, sys
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    cur = json.load(open(path))
except Exception:
    print(default); raise SystemExit(0)
for part in key.split('.'):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        print(default); raise SystemExit(0)
print(cur if not isinstance(cur, (list, dict)) else json.dumps(cur))
PY
}

# The model a role runs on: roleTiers[role] -> models[tier], exactly as ai-bridge
# resolves it, so a role behaves the same whichever executor runs it.
role_model() {
  local role="$1" tier="${2:-}"
  [ -z "$tier" ] && tier="$(cfg "roleTiers.$role" standard)"
  local model; model="$(cfg "models.$tier" "")"
  [ -z "$model" ] && model="$tier"
  printf '%s\n' "$model"
}

# Reasoning effort per role. xhigh is the current sweet spot for coding and agentic
# work on the Opus/Sonnet 5 generation; low is right for a mechanical role like the
# cataloguer. Skipped for the haiku tier, which rejects the flag.
role_effort() {
  local role="$1" model="$2" effort
  case "$model" in *haiku*) return 0 ;; esac
  effort="$(cfg "roleEffort.$role" "")"
  [ -n "$effort" ] && printf '%s\n' "$effort"
  return 0
}

role_is_known() {
  local role="$1"
  [ -f "$INSTANCE/.claude/agents/$role.md" ] || return 1
  local roles; roles="$(cfg roles '[]')"
  printf '%s' "$roles" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))' 2>/dev/null \
    | grep -qx "$role"
}

# host path -> the path the box sees (the mount keeps $HOME-relative parity)
container_path() { printf '%s\n' "$CONTAINER_WS${1#"$ROOT"}"; }

# --- login ---------------------------------------------------------------------
# `claude -p` with no credentials prints "Not logged in" and exits 0, so a box that
# cannot authenticate looks exactly like a box that had nothing to say. Check before
# spending one, and check the output afterwards.
require_login() {
  [ -n "${ANTHROPIC_API_KEY:-}" ] && return 0
  [ -f "$CONFIG_HOME/.credentials.json" ] && return 0
  die "the sandbox has no Claude login yet, so every box would exit without doing anything.

Log in once, in your own terminal (it needs a TTY, so this cannot be done for you):

  claude-box            # then /login, then exit

Credentials persist in $CONFIG_HOME and every box shares them. Alternatively, export
ANTHROPIC_API_KEY before running the harness."
}

# Did this box actually run, or did it fall out for a reason that is not the task's fault?
# Returns a human-readable reason, or nothing when the box looks healthy.
box_failure_reason() {
  local log="$1" code="$2"
  [ -f "$log" ] || { printf 'the box produced no log at all\n'; return 0; }
  if grep -qiE 'not logged in|please run /login|invalid api key|authentication_error' "$log"; then
    printf 'the box is not logged in — run `claude-box` in a terminal, /login, then retry\n'
    return 0
  fi
  if grep -qiE 'credit balance|quota|rate.?limit|overloaded' "$log"; then
    printf 'the API refused the request (credit, quota or rate limit) — see the log\n'
    return 0
  fi
  case "$code" in
    0|'') ;;
    timeout) printf 'the box hit the %ss timeout\n' "$CLAUDE_BOX_ROLE_TIMEOUT"; return 0 ;;
    gone)    printf 'the box vanished without reporting\n'; return 0 ;;
    *)       printf 'the box exited %s\n' "$code"; return 0 ;;
  esac
  # Fewer than three lines of output from a real agent run means it never got started.
  [ "$(wc -l < "$log" | tr -d ' ')" -lt 3 ] && printf 'the box wrote almost no output — it never really started\n'
  return 0
}

# --- lock ---------------------------------------------------------------------
# mkdir is the atomic primitive here: either this process created the directory or
# another holds it. That is what gives the cross-session guarantee ai-bridge's
# pm-loop documents as absent — a second loop against the same instance cannot
# start, rather than being asked politely not to.
LOCK_DIR=""
lock_acquire() {
  LOCK_DIR="$INSTANCE_STATE/lock"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s %s\n' "$$" "$(date +%s)" > "$LOCK_DIR/owner"
    return 0
  fi
  local pid held
  pid="$(awk '{print $1}' "$LOCK_DIR/owner" 2>/dev/null || true)"
  held="$(awk '{print $2}' "$LOCK_DIR/owner" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    LOCK_DIR=""
    die "another harness loop holds this instance (pid $pid, since $(date -r "${held:-0}" 2>/dev/null || echo unknown)) — stop it first"
  fi
  note "reclaiming a stale lock (holder pid ${pid:-unknown} is gone)"
  printf '%s %s\n' "$$" "$(date +%s)" > "$LOCK_DIR/owner"
}
lock_release() { [ -n "$LOCK_DIR" ] && rm -rf "$LOCK_DIR"; LOCK_DIR=""; }

# --- memory -------------------------------------------------------------------
# Three tiers, read-only into the box, later tiers overriding earlier ones:
#   global      $STATE_HOME/harness/memory/        every repo, every instance
#   instance KB $INSTANCE/knowledge/               ai-bridge's own, untouched here
#   repo-local  <repo>/.harness/memory/            one product repo
# The instance KB is NOT inlined: ai-bridge's knowledge/index.md is explicitly a
# lookup surface ("don't bulk-read knowledge/"), so the preamble points at it and
# lets the role open only what it needs.
memory_preamble() {
  local repo="${1:-}" out="" f
  out="## Memory"$'\n\n'"Read-only context. Later sections override earlier ones."$'\n'
  out="$out"$'\n'"### Global (all repos)"$'\n'
  local found=0
  for f in "$STATE_HOME/harness/memory"/*.md; do
    [ -f "$f" ] || continue
    out="$out"$'\n'"<!-- $(basename "$f") -->"$'\n'"$(cat "$f")"$'\n'
    found=1
  done
  [ "$found" = 0 ] && out="$out"$'\n'"_(nothing accepted yet)_"$'\n'

  out="$out"$'\n'"### Instance knowledge base"$'\n\n'
  if [ -f "$INSTANCE/knowledge/index.md" ]; then
    out="$out""Catalogued at \`knowledge/index.md\`. Scan that index and open only the docs you need — do not bulk-read \`knowledge/\`."$'\n'
  else
    out="$out""_(no knowledge base in this instance)_"$'\n'
  fi

  if [ -n "$repo" ] && [ -d "$ROOT/$repo/.harness/memory" ]; then
    out="$out"$'\n'"### Repo-local ($repo) — wins over global"$'\n'
    for f in "$ROOT/$repo/.harness/memory"/*.md "$ROOT/$repo/.harness/memory/learnings"/*.md; do
      [ -f "$f" ] || continue
      out="$out"$'\n'"<!-- $(basename "$f") -->"$'\n'"$(cat "$f")"$'\n'
    done
  fi

  # Truncate rather than let memory crowd out the task. Silent truncation would
  # read as "you know everything relevant", so say where the cut happened.
  if [ "${#out}" -gt "$CLAUDE_BOX_MEMORY_MAX" ]; then
    out="${out:0:$CLAUDE_BOX_MEMORY_MAX}"$'\n\n'"_[memory truncated at ${CLAUDE_BOX_MEMORY_MAX} chars — accept fewer, shorter learnings]_"$'\n'
  fi
  printf '%s\n' "$out"
}

# Every git repo directly under the root, panels excluded. A role that cannot see what
# exists has to infer the target repo from a sentence, which is how work lands in the
# wrong repository — so the inventory goes into every role's system prompt as fact.
CLAUDE_BOX_MAX_REPOS="${CLAUDE_BOX_MAX_REPOS:-80}"

repo_inventory() {
  local d n=0
  [ -n "$ROOT" ] || return 0
  for d in "$ROOT"/*/; do
    d="${d%/}"
    [ -d "$d/.git" ] || [ -f "$d/.git" ] || continue
    # A control panel is not a target repo.
    [ -f "$d/instance.config.json" ] && [ -f "$d/SCHEMA.md" ] && continue
    n=$((n + 1))
    [ "$n" -gt "$CLAUDE_BOX_MAX_REPOS" ] && { printf '%s\n' "…and more"; return 0; }
    printf '%s\n' "$(basename "$d")"
  done
}

# --- prompt assembly ----------------------------------------------------------
# The persona is the instance's own role definition with its frontmatter stripped
# (the frontmatter configures a subagent; there is no subagent here). The overlay
# follows it, because the executor's rules must win over the persona's assumption
# that it can dispatch.
strip_frontmatter() {
  awk 'NR==1 && $0=="---" { infm=1; next } infm && $0=="---" { infm=0; next } !infm { print }' "$1"
}

repo_preamble() {
  local repo="${1:-}" inventory
  inventory="$(repo_inventory)"
  printf '## Repositories\n\n'
  printf 'Cloned under the repos root, which is the same path inside your box as on the\n'
  printf 'host. A `target_repo` must name one of these — `<repo>` or `<org>/<repo>`:\n\n'
  if [ -n "$inventory" ]; then
    printf '%s\n' "$inventory" | sed 's/^/- /'
  else
    printf '%s\n' "_(none found — the root has no clones)_"
  fi
  if [ -n "$repo" ]; then
    printf '\nThis task targets **%s**.\n' "$repo"
  else
    printf '\nNo target was given. Pick one from the list above based on what the work\n'
    printf 'actually touches. If two are plausible, that is an open question for the\n'
    printf 'human — ask it rather than guessing, because work in the wrong repository\n'
    printf 'costs a review cycle and a revert.\n'
  fi
}

# Code standards ship with claude-box so a change to them reaches every panel, rather
# than drifting per panel. A panel that wants its own puts STANDARDS.md at its root and
# that wins outright.
standards_doc() {
  if [ -f "$INSTANCE/STANDARDS.md" ]; then
    cat "$INSTANCE/STANDARDS.md"
  else
    cat "$HARNESS_DIR/standards.md"
  fi
}

role_system_prompt() {
  local role="$1" repo="${2:-}"
  printf '%s\n\n---\n\n%s\n\n---\n\n%s\n\n---\n\n%s\n\n---\n\n%s\n' \
    "$(strip_frontmatter "$INSTANCE/.claude/agents/$role.md")" \
    "$(cat "$HARNESS_DIR/overlay.md")" \
    "$(standards_doc)" \
    "$(repo_preamble "$repo")" \
    "$(memory_preamble "$repo")"
}

# --- intents ------------------------------------------------------------------
I_INTENT="" I_ROLE="" I_TASK="" I_TARGET_REPO="" I_TIER="" I_REASON="" I_ERR=""
I_REJECT_REASON="" I_REPO_DIR=""

intent_parse() {
  I_INTENT="" I_ROLE="" I_TASK="" I_TARGET_REPO="" I_TIER="" I_REASON="" I_ERR=""
  local out
  out="$(python3 - "$1" <<'PY'
import json, shlex, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as exc:
    print("I_ERR=%s" % shlex.quote("unparseable JSON: %s" % exc)); raise SystemExit(0)
if not isinstance(d, dict):
    print("I_ERR=%s" % shlex.quote("not a JSON object")); raise SystemExit(0)
for key in ("intent", "role", "task", "target_repo", "tier", "reason"):
    print("I_%s=%s" % (key.upper(), shlex.quote(str(d.get(key, "")))))
PY
)"
  eval "$out"
}

# How many role boxes may be in flight: the instance's own cap AND what the host
# can actually afford. ai-bridge's maxAgentsInFlight assumes the resources exist;
# here the memory budget is real, so the smaller number wins.
inflight_cap() {
  local declared budget by_mem mem_gib
  declared="$(cfg maxAgentsInFlight 5)"
  case "$declared" in ''|*[!0-9]*) declared=5 ;; esac
  mem_gib="${CLAUDE_BOX_MEM%[Gg]}"
  case "$mem_gib" in ''|*[!0-9]*) mem_gib=8 ;; esac
  budget=$((HOST_GIB * CLAUDE_BOX_FANOUT_MEM_PCT / 100))
  by_mem=$((budget / mem_gib))
  [ "$by_mem" -lt 1 ] && by_mem=1
  if [ "$by_mem" -lt "$declared" ]; then printf '%s\n' "$by_mem"; else printf '%s\n' "$declared"; fi
}

# Seconds a fresh in-flight marker counts even though the engine has not registered
# its container yet. Without it, dispatching two intents in one tick races: the marker
# for the first is written before its box appears, so a `box_is_running` check on the
# second intent sees a free slot AND no owner for the task — which is how one task gets
# two boxes and the cap gets exceeded.
CLAUDE_BOX_BOX_GRACE="${CLAUDE_BOX_BOX_GRACE:-45}"

file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# Is this marker's box still ours to count? Either the engine knows it, or it is new
# enough that the engine cannot be trusted to know yet.
marker_live() {
  local f="$1" name age
  name="$(cat "$f" 2>/dev/null || true)"
  [ -n "$name" ] || return 1
  box_is_running "$name" && return 0
  age=$(( $(date +%s) - $(file_mtime "$f") ))
  [ "$age" -lt "$CLAUDE_BOX_BOX_GRACE" ]
}

inflight_count() {
  local n=0 f
  for f in "$INSTANCE_STATE/inflight"/*; do
    [ -f "$f" ] || continue
    if marker_live "$f"; then n=$((n + 1)); else rm -f "$f"; fi
  done
  printf '%s\n' "$n"
}

task_status() { awk -F': *' '/^status:/ { print $2; exit }' "$1" 2>/dev/null; }

# A task's identity, used as the in-flight marker filename and therefore as the
# double-dispatch key. It MUST NOT collide: slugging the path and truncating it (as an
# earlier version did) makes projects/<p>/tasks/aaa.md and .../bbb.md the same key once
# the prefix is long enough, and one task then permanently blocks the other. So: a
# readable id plus a hash of the full path.
path_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum | cut -c1-8
  elif command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | cut -c1-8
  else
    printf '%s' "$1" | cksum | tr -d ' ' | cut -c1-8
  fi
}
task_key() {
  local id; id="$(slug "$(basename "${1%.md}")")"
  [ -n "$id" ] || id=task
  printf '%s-%s\n' "$id" "$(path_hash "$1")"
}

# Validate one intent: returns 0 when it may be dispatched, otherwise sets
# I_REJECT_REASON and returns 1. The parsed fields land in the I_* globals, which
# is why this must NOT be called in a command substitution — a subshell would
# discard exactly the values the caller needs to dispatch with.
intent_validate() {
  local file="$1" cap inflight
  I_REJECT_REASON=""
  intent_parse "$file"
  [ -n "$I_ERR" ] && { I_REJECT_REASON="$I_ERR"; return 1; }
  [ "$I_INTENT" = dispatch ] || { I_REJECT_REASON="unknown intent type '$I_INTENT' (only 'dispatch')"; return 1; }
  [ -n "$I_ROLE" ] || { I_REJECT_REASON="no role"; return 1; }
  role_is_known "$I_ROLE" || { I_REJECT_REASON="role '$I_ROLE' is not in instance.config.json roles, or has no .claude/agents/$I_ROLE.md"; return 1; }
  [ "$I_ROLE" = project-manager ] && { I_REJECT_REASON="the project-manager is the tick itself and is never dispatched as a task assignee"; return 1; }

  # OKF cross-links are BUNDLE-relative and start with "/" (e.g.
  # /projects/<slug>/tasks/<id>.md) — that is the convention every document in the
  # panel uses, so a leading slash means "panel root", not "host root". Strip one and
  # normalise; traversal is still refused.
  [ -n "$I_TASK" ] || { I_REJECT_REASON="no task path"; return 1; }
  I_TASK="${I_TASK#/}"
  case "$I_TASK" in
    *..*) I_REJECT_REASON="task path escapes the panel: '$I_TASK'"; return 1 ;;
  esac
  [ -f "$INSTANCE/$I_TASK" ] || { I_REJECT_REASON="task file not found: $I_TASK"; return 1; }
  local st; st="$(task_status "$INSTANCE/$I_TASK")"
  case "$st" in
    ready|in-progress) ;;
    *) I_REJECT_REASON="task status is '$st' — only a human-promoted 'ready' (or a resumed 'in-progress') task may be dispatched"; return 1 ;;
  esac

  # ai-bridge's SCHEMA.md writes target_repo as `<org>/<repo>`, and its own docs also
  # use the bare repo name in places. Accept both and normalise to the directory name
  # under the root — I_REPO_DIR is what actually gets mounted and worked in. Anything
  # deeper, absolute, or traversing is still refused.
  [ -n "$I_TARGET_REPO" ] || { I_REJECT_REASON="no target_repo"; return 1; }
  case "$I_TARGET_REPO" in
    /*|*..*) I_REJECT_REASON="target_repo must name a repo, not a path: '$I_TARGET_REPO'"; return 1 ;;
    http*|git@*) I_REJECT_REASON="target_repo must be a repo name, not a URL: '$I_TARGET_REPO'"; return 1 ;;
  esac
  I_REPO_DIR="$I_TARGET_REPO"
  case "$I_TARGET_REPO" in
    */*/*) I_REJECT_REASON="target_repo has too many path segments (want '<repo>' or '<org>/<repo>'): '$I_TARGET_REPO'"; return 1 ;;
    */*)
      local intent_org="${I_TARGET_REPO%%/*}" cfg_org
      I_REPO_DIR="${I_TARGET_REPO##*/}"
      cfg_org="$(cfg org "")"
      if [ -n "$cfg_org" ] && [ "$intent_org" != "$cfg_org" ]; then
        I_REJECT_REASON="target_repo org '$intent_org' is not this instance's org ('$cfg_org')"; return 1
      fi
      ;;
  esac
  [ -d "$ROOT/$I_REPO_DIR/.git" ] || [ -f "$ROOT/$I_REPO_DIR/.git" ] || \
    { I_REJECT_REASON="target_repo '$I_TARGET_REPO' has no clone at $ROOT/$I_REPO_DIR"; return 1; }

  local key; key="$(task_key "$I_TASK")"
  if [ -f "$INSTANCE_STATE/inflight/$key" ] && marker_live "$INSTANCE_STATE/inflight/$key"; then
    I_REJECT_REASON="a box is already working task $I_TASK (double-dispatch refused)"; return 1
  fi

  cap="$(inflight_cap)"; inflight="$(inflight_count)"
  [ "$inflight" -lt "$cap" ] || { I_REJECT_REASON="in-flight cap reached ($inflight/$cap)"; return 1; }
  return 0
}

# --- one role, one box --------------------------------------------------------
cmd_role() {
  local role="" inst="" task="" repo="" tier="" instr="" detach=0 dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance) inst="${2:-}"; shift 2 ;;
      --task)     task="${2:-}"; shift 2 ;;
      --repo)     repo="${2:-}"; shift 2 ;;
      --tier)     tier="${2:-}"; shift 2 ;;
      --prompt)   instr="${2:-}"; shift 2 ;;
      --detach)   detach=1; shift ;;
      --dry-run)  dry=1; shift ;;
      -*)         die "unknown flag for 'role': $1" ;;
      *)          if [ -z "$role" ]; then role="$1"; shift; else die "unexpected argument: $1"; fi ;;
    esac
  done
  [ -n "$role" ] || die "usage: claude-box role <role> [--instance <dir>] [--task <path>] [--repo <name>] [--tier <t>] [--prompt <text>] [--detach] [--dry-run]"
  resolve_instance "$inst"
  [ "$dry" = 1 ] || require_login
  [ -f "$INSTANCE/.claude/agents/$role.md" ] || die "no role definition at $INSTANCE/.claude/agents/$role.md"

  local model sys log name key
  model="$(role_model "$role" "$tier")"
  sys="$(role_system_prompt "$role" "$repo")"
  if [ -z "$instr" ]; then
    if [ -n "$task" ]; then
      instr="Execute the task at $task (path relative to this panel root). Follow your role definition and the executor rules in your system prompt. Report by updating the task document."
    else
      instr="Run one tick of your role's procedure as defined in your system prompt."
    fi
  fi

  resolve_target "$INSTANCE"
  name="claude-box-h-$INSTANCE_SLUG-$(slug "$role")"
  [ -n "$task" ] && name="$name-$(slug "$(basename "${task%.md}")")"
  name="$(unique_name "$name")"
  log="$STATE_HOME/logs/$name.log"

  local claude_args=(claude --permission-mode bypassPermissions --model "$model")
  local effort fallback
  effort="$(role_effort "$role" "$model")"
  [ -n "$effort" ] && claude_args+=(--effort "$effort")
  fallback="$(cfg fallbackModel "")"
  case "$fallback" in ''|null|None) ;; *) claude_args+=(--fallback-model "$fallback") ;; esac
  claude_args+=(--append-system-prompt "$sys" -p "$instr")
  local effort_preview; effort_preview="$(role_effort "$role" "$model")"
  if [ "$dry" = 1 ]; then
    effort="$effort_preview"
    echo "role:      $role"
    echo "instance:  $INSTANCE"
    echo "model:     $model${effort:+  (effort $effort)}"
    echo "box:       $name"
    echo "workdir:   $WORKDIR"
    echo "mount:     $MOUNT_SRC -> $CONTAINER_WS"
    echo "task:      ${task:-(none)}"
    echo "repo:      ${repo:-(none)}"
    echo "prompt:    ${#sys} chars of system prompt (persona + overlay + standards + repos + memory)"
    echo "ask:       $instr"
    return 0
  fi

  # Claude Code refuses bypassPermissions as root — which every box is — unless
  # IS_SANDBOX says the containment already exists.
  EXTRA_RUN_ARGS=(-e IS_SANDBOX=1)
  if [ "$detach" = 1 ]; then
    key="$(task_key "${task:-$role}")"
    mkdir -p "$INSTANCE_STATE/inflight" "$INSTANCE_STATE/exits"
    printf '%s\n' "$name" > "$INSTANCE_STATE/inflight/$key"
    rm -f "$INSTANCE_STATE/exits/$name"
    run_box_bg "$name" isolated "$log" "$INSTANCE_STATE/exits/$name" "${claude_args[@]}"
    printf '%s\n' "$name"
  else
    run_box_fg "$name" isolated "${claude_args[@]}"
  fi
}

# --- waiting on boxes ---------------------------------------------------------
# Poll an exit file rather than the engine, so this behaves the same on Docker,
# Apple `container` and the fake engine used by the tests.
wait_for_box() {
  local name="$1" exit_file="$2" missing=0
  local deadline=$(( $(date +%s) + CLAUDE_BOX_ROLE_TIMEOUT ))
  while :; do
    [ -f "$exit_file" ] && return 0
    if box_is_running "$name"; then
      missing=0
    else
      # Tolerate the first few seconds (the container takes a moment to appear) but
      # do not wait out the full timeout for a box that died without reporting.
      missing=$((missing + 1))
      if [ "$missing" -ge 5 ]; then
        printf '%s\n' gone > "$exit_file"
        note "$name vanished without reporting an exit code"
        return 1
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      note "$name exceeded ${CLAUDE_BOX_ROLE_TIMEOUT}s — stopping it"
      box_is_running "$name" && engine_stop_box "$name"
      printf '%s\n' timeout > "$exit_file"
      return 1
    fi
    sleep 2
  done
}

# Claude Code may rewrite .credentials.json atomically, which replaces the symlink with a
# regular file inside the box's own config dir — so a refreshed token would be stranded
# there. Carry it back when it is newer than the shared one.
reclaim_credentials() {
  local box="$1" mine="$STATE_HOME/boxes/$1/claude/.credentials.json"
  [ -f "$mine" ] || return 0
  [ -L "$mine" ] && return 0
  if [ ! -f "$CONFIG_HOME/.credentials.json" ] || [ "$mine" -nt "$CONFIG_HOME/.credentials.json" ]; then
    cp "$mine" "$CONFIG_HOME/.credentials.json" 2>/dev/null \
      && note "carried a refreshed token back from $box"
  fi
  return 0
}

# --- promotion guard ----------------------------------------------------------
# `draft -> ready` is a plain file edit, so no tool-permission rule can stop a
# role writing it. The host checks instead: snapshot statuses, and if a role
# promoted anything, put it back and say so. Enforcement lives here, not in the
# overlay's wording.
status_snapshot() {
  local f st
  find "$INSTANCE/projects" -type f -name '*.md' 2>/dev/null | sort | while IFS= read -r f; do
    st="$(task_status "$f")"
    [ -n "$st" ] && printf '%s\t%s\n' "$f" "$st"
  done
}

revert_promotions() {
  local before="$1" after="$2" who="$3" reverted=0 f st_before st_after
  while IFS=$'\t' read -r f st_after; do
    [ -n "$f" ] || continue
    st_before="$(awk -F'\t' -v k="$f" '$1==k { print $2 }' "$before")"
    if [ "$st_before" = draft ] && [ "$st_after" = ready ]; then
      # Only the human promotes. Put it back and leave a trace in the tick dir.
      sed -i.bak 's/^status: *ready/status: draft/' "$f" && rm -f "$f.bak"
      note "reverted an illegal draft -> ready promotion by $who in ${f#"$INSTANCE"/}"
      printf '%s\treverted draft->ready by %s\n' "${f#"$INSTANCE"/}" "$who" >> "$TICK_DIR/violations.tsv"
      reverted=$((reverted + 1))
    fi
  done < "$after"
  return 0
}

# --- one tick -----------------------------------------------------------------
TICK_ID="" TICK_DIR=""

tick_body() {
  local dry="${1:-0}"
  TICK_ID="t$(date +%Y%m%d-%H%M%S)"
  TICK_DIR="$INSTANCE_STATE/ticks/$TICK_ID"
  mkdir -p "$TICK_DIR/intents" "$TICK_DIR/logs" "$INSTANCE_STATE/exits" "$INSTANCE_STATE/inflight"
  note "tick $TICK_ID on $INSTANCE_SLUG (cap $(inflight_cap), in flight $(inflight_count))"

  local snap_pre="$TICK_DIR/status-pre.tsv" snap_mid="$TICK_DIR/status-mid.tsv" snap_post="$TICK_DIR/status-post.tsv"
  status_snapshot > "$snap_pre"

  # 1. The PM tick. Serial by design: it decides what to dispatch, so nothing else
  #    may run while it is deciding.
  local pm_name pm_exit pm_log pm_model pm_sys
  pm_model="$(role_model project-manager)"
  pm_sys="$(role_system_prompt project-manager)"
  pm_name="$(unique_name "claude-box-h-$INSTANCE_SLUG-pm")"
  pm_log="$TICK_DIR/logs/$pm_name.log"
  pm_exit="$INSTANCE_STATE/exits/$pm_name"
  rm -f "$pm_exit"

  if [ "$dry" = 1 ]; then
    echo "DRY RUN — would run the PM tick as $pm_name on $pm_model (system prompt ${#pm_sys} chars)"
  else
    resolve_target "$INSTANCE"
    EXTRA_RUN_ARGS=(-e IS_SANDBOX=1)
    local pm_args=(claude --permission-mode bypassPermissions --model "$pm_model")
    local pm_effort; pm_effort="$(role_effort project-manager "$pm_model")"
    [ -n "$pm_effort" ] && pm_args+=(--effort "$pm_effort")
    local pm_fallback; pm_fallback="$(cfg fallbackModel "")"
    case "$pm_fallback" in ''|null|None) ;; *) pm_args+=(--fallback-model "$pm_fallback") ;; esac
    run_box_bg "$pm_name" isolated "$pm_log" "$pm_exit" \
      "${pm_args[@]}" \
      --append-system-prompt "$pm_sys" \
      -p "Run ONE tick of your project-manager procedure. Reconcile task documents against live git/gh state, refine drafts, and for every human-promoted 'ready' task write a dispatch intent file as described in your system prompt. Do not promote and do not merge. End with a short summary of deltas, dispatch intents written, and what awaits the human."
    wait_for_box "$pm_name" "$pm_exit" || note "PM tick timed out"
    note "PM tick exit $(cat "$pm_exit" 2>/dev/null || echo unknown) — log: $pm_log"
    status_snapshot > "$snap_mid"
    revert_promotions "$snap_pre" "$snap_mid" project-manager
  fi

  # 1b. Autonomy, if you enabled it. Promotion happens BEFORE the intents are read, so
  #     a task the PM refined this very tick can be dispatched in the same tick.
  local mode; mode="$(autonomy_mode)"
  [ "$mode" != gated ] && note "autonomy: $mode"
  if [ "$dry" = 1 ]; then
    [ "$mode" != gated ] && echo "DRY RUN — would apply autonomy '$mode' (promote refined drafts$([ "$mode" = full ] && printf ', merge approved PRs'))"
  else
    autonomy_promote "$mode"
  fi

  # 2. Harvest intents the PM wrote, validate each, and dispatch what survives.
  local file base reason accepted=0 rejected=0 names=""
  for file in "$INSTANCE/.harness/intents"/*.json; do
    [ -f "$file" ] || continue
    base="$(basename "$file")"
    if intent_validate "$file"; then
      cp "$file" "$TICK_DIR/intents/$base"
      if [ "$dry" = 1 ]; then
        echo "DRY RUN — would dispatch $I_ROLE for $I_TASK (repo $I_TARGET_REPO)"
        accepted=$((accepted + 1))
        continue
      fi
      local nm
      local tier_args=()
      [ -n "$I_TIER" ] && tier_args=(--tier "$I_TIER")
      nm="$(cmd_role "$I_ROLE" --instance "$INSTANCE" --task "$I_TASK" --repo "$I_REPO_DIR" \
                    ${tier_args[@]+"${tier_args[@]}"} --detach)"
      names="$names$nm"$'\n'
      note "dispatched $I_ROLE -> $I_TASK as $nm"
      rm -f "$file"
      accepted=$((accepted + 1))
    else
      reason="$I_REJECT_REASON"
      mkdir -p "$INSTANCE/.harness/intents/rejected"
      python3 - "$file" "$reason" "$INSTANCE/.harness/intents/rejected/$base" <<'PY'
import json, sys
src, reason, dst = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.load(open(src))
    if not isinstance(data, dict):
        data = {"raw": data}
except Exception:
    data = {"raw": open(src, errors="replace").read()}
data["rejected_reason"] = reason
json.dump(data, open(dst, "w"), indent=2)
PY
      rm -f "$file"
      note "rejected $base: $reason"
      rejected=$((rejected + 1))
    fi
  done

  # 3. Wait for the dispatched boxes, then check nobody promoted anything.
  if [ "$dry" != 1 ] && [ -n "$names" ]; then
    local nm
    while IFS= read -r nm; do
      [ -n "$nm" ] || continue
      wait_for_box "$nm" "$INSTANCE_STATE/exits/$nm" || true
    done <<< "$names"
    status_snapshot > "$snap_post"
    revert_promotions "$snap_mid" "$snap_post" "role boxes"
    autonomy_merge "$mode"
  fi

  {
    printf 'tick %s\ninstance %s\naccepted %s\nrejected %s\n' \
      "$TICK_ID" "$INSTANCE_SLUG" "$accepted" "$rejected"
    printf 'pending_memory %s\n' "$(command ls "$INSTANCE/.harness/pending"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  } > "$TICK_DIR/summary.txt"
  printf '%s\n' "$TICK_ID" > "$INSTANCE_STATE/last-tick"
  note "tick $TICK_ID done — $accepted dispatched, $rejected rejected"
}

cmd_harness_tick() {
  local dry=0 inst=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      *) inst="$1"; shift ;;
    esac
  done
  resolve_instance "$inst"
  ensure_daemon
  [ "$dry" = 1 ] || require_login
  lock_acquire
  trap 'lock_release' EXIT INT TERM
  tick_body "$dry"
  lock_release
  trap - EXIT INT TERM
}

cmd_harness_loop() {
  local gap="10m" inst="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      [0-9]*m|[0-9]*s|[0-9]*) gap="$1"; shift ;;
      *) inst="$1"; shift ;;
    esac
  done
  local secs="${gap%[ms]}"
  case "$gap" in *m) secs=$((secs * 60)) ;; esac
  case "$secs" in ''|*[!0-9]*) die "gap must look like 10m, 90s or 600" ;; esac

  resolve_instance "$inst"
  ensure_daemon
  lock_acquire
  trap 'lock_release; exit 0' EXIT INT TERM
  note "loop on $INSTANCE_SLUG, ${secs}s between ticks — Ctrl-C to stop"
  while :; do
    tick_body "$dry"
    note "sleeping ${secs}s"
    sleep "$secs"
  done
}

cmd_harness_status() {
  resolve_instance "${1:-}"
  local last pid
  echo "instance:  $INSTANCE"
  if [ -f "$INSTANCE_STATE/lock/owner" ]; then
    pid="$(awk '{print $1}' "$INSTANCE_STATE/lock/owner")"
    if kill -0 "$pid" 2>/dev/null; then echo "loop:      running (pid $pid)"; else echo "loop:      stale lock (pid $pid gone)"; fi
  else
    echo "loop:      not running"
  fi
  local mode; mode="$(autonomy_mode)"
  if [ "$mode" = gated ]; then
    echo "autonomy:  gated (you promote, you merge)"
  else
    echo "autonomy:  $mode  ** the host acts without you — 'harness autonomy gated' to stop **"
  fi
  echo "cap:       $(inflight_count)/$(inflight_cap) boxes in flight"
  last="$(cat "$INSTANCE_STATE/last-tick" 2>/dev/null || true)"
  if [ -n "$last" ] && [ -f "$INSTANCE_STATE/ticks/$last/summary.txt" ]; then
    echo "last tick: $last"
    sed 's/^/           /' "$INSTANCE_STATE/ticks/$last/summary.txt"
  else
    echo "last tick: none"
  fi
  echo "pending:   $(command ls "$INSTANCE/.harness/pending"/*.md 2>/dev/null | wc -l | tr -d ' ') memory proposals"
  echo "rejected:  $(command ls "$INSTANCE/.harness/intents/rejected"/*.json 2>/dev/null | wc -l | tr -d ' ') intents"
  local boxes; boxes="$(engine_running_boxes | grep "^claude-box-h-$INSTANCE_SLUG-" || true)"
  if [ -n "$boxes" ]; then
    echo "boxes:"
    printf '%s\n' "$boxes" | sed 's/^/           /'
  fi
  # Explicit: a bare trailing test would make "no boxes running" an exit-1 status.
  return 0
}

# --- memory review ------------------------------------------------------------
# The gate: role boxes propose, a human accepts. Nothing a box wrote becomes
# memory here without passing through this command.
fm_field() { awk -F': *' -v k="$2" '$1 == k { print $2; exit }' "$1"; }

memory_accept() {
  local file="$1" tier repo dst body
  tier="$(fm_field "$file" tier)"
  repo="$(fm_field "$file" repo)"
  case "$tier" in
    global)
      dst="$STATE_HOME/harness/memory/$(basename "$file")"
      ;;
    repo)
      [ -n "$repo" ] || { note "proposal has tier: repo but no repo: field — edit or drop it"; return 1; }
      [ -d "$ROOT/$repo" ] || { note "repo '$repo' not found under $ROOT"; return 1; }
      mkdir -p "$ROOT/$repo/.harness/memory/learnings"
      dst="$ROOT/$repo/.harness/memory/learnings/$(basename "$file")"
      ;;
    *)
      note "proposal has no usable tier (want 'global' or 'repo', got '${tier:-none}') — edit or drop it"; return 1 ;;
  esac
  mkdir -p "$(dirname "$dst")"
  cp "$file" "$dst"
  rm -f "$file"
  echo "accepted -> $dst"
  [ "$tier" = repo ] && echo "  (commit it in $repo so it travels with the code)"
  return 0
}

cmd_harness_memory() {
  local inst=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance) inst="${2:-}"; shift 2 ;;
      *) inst="$1"; shift ;;
    esac
  done
  resolve_instance "$inst"
  local files=() f
  for f in "$INSTANCE/.harness/pending"/*.md; do [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -eq 0 ] && { echo "no pending memory proposals"; return 0; }

  echo "${#files[@]} pending proposal(s) in $INSTANCE/.harness/pending"
  echo
  for f in "${files[@]}"; do
    echo "──────────────────────────────────────────────────────────────"
    echo "file:     $(basename "$f")"
    echo "tier:     $(fm_field "$f" tier)$( [ -n "$(fm_field "$f" repo)" ] && printf ' (%s)' "$(fm_field "$f" repo)")"
    echo "evidence: $(fm_field "$f" evidence)"
    echo
    strip_frontmatter "$f" | sed 's/^/  /'
    echo
    if [ ! -t 0 ]; then
      echo "(not a terminal — listing only; run this from a shell to accept or drop)"
      continue
    fi
    local ans
    printf '[a]ccept  [e]dit  [d]rop  [s]kip  [q]uit > '
    read -r ans
    case "$ans" in
      a|A) memory_accept "$f" || true ;;
      e|E) "${EDITOR:-vi}" "$f"; printf 'accept now? [y/N] '; read -r ans
           case "$ans" in y|Y) memory_accept "$f" || true ;; *) echo "left pending" ;; esac ;;
      d|D) rm -f "$f"; echo "dropped" ;;
      q|Q) echo "stopped"; return 0 ;;
      *)   echo "skipped" ;;
    esac
  done
}

# --- dashboard ----------------------------------------------------------------
cmd_harness_ui() {
  local port=7777 inst=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)     port="${2:-}"; shift 2 ;;
      --instance) inst="${2:-}"; shift 2 ;;
      *)          inst="$1"; shift ;;
    esac
  done
  resolve_instance "$inst"
  command -v python3 >/dev/null 2>&1 || die "the dashboard needs python3 (macOS ships it)"
  note "dashboard on http://localhost:$port  (Ctrl-C to stop)"
  CB_INSTANCE="$INSTANCE" CB_INSTANCE_SLUG="$INSTANCE_SLUG" CB_STATE="$STATE_HOME" \
  CB_ROOT="$ROOT" CB_PORT="$port" CB_RUNNER="$SETUP_DIR/claude-box" \
    exec python3 "$HARNESS_DIR/ui/server.py"
}

# --- autonomy -----------------------------------------------------------------
# The switch lives in the HOST state dir, not in the panel. That is the whole design:
# a role box has no access to the state dir (only its own config dir is mounted), so an
# agent cannot grant itself autonomy — not by editing config, not by writing a file, not
# by talking the PM into it. ai-bridge gates this on a file inside the bundle; putting it
# outside the bundle makes it enforceable rather than conventional.
#
#   gated   (default) you promote, you merge
#   promote           the host promotes refined drafts; you still merge
#   full              the host promotes AND merges, subject to the machine gates below
CLAUDE_BOX_MAX_MERGES_PER_TICK="${CLAUDE_BOX_MAX_MERGES_PER_TICK:-3}"
GH_BIN="${CLAUDE_BOX_GH:-gh}"

autonomy_mode() {
  local f="$INSTANCE_STATE/autonomy" mode
  [ -f "$f" ] || { printf 'gated\n'; return 0; }
  mode="$(head -1 "$f" | tr -d '[:space:]')"
  case "$mode" in
    promote|full) printf '%s\n' "$mode" ;;
    *)            printf 'gated\n' ;;
  esac
}

cmd_harness_autonomy() {
  local mode="" inst="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) yes=1; shift ;;
      gated|promote|full) mode="$1"; shift ;;
      --instance|--panel) inst="${2:-}"; shift 2 ;;
      -*) die "unknown flag for 'harness autonomy': $1" ;;
      *) inst="$1"; shift ;;
    esac
  done
  resolve_instance "$inst"

  if [ -z "$mode" ]; then
    echo "panel:    $INSTANCE"
    echo "autonomy: $(autonomy_mode)"
    echo
    echo "  gated    you promote draft -> ready, you merge          (default)"
    echo "  promote  the host promotes refined drafts; you merge"
    echo "  full     the host promotes and merges, if every machine gate passes"
    echo
    echo "set with: claude-box harness autonomy <mode>"
    return 0
  fi

  if [ "$mode" = gated ]; then
    rm -f "$INSTANCE_STATE/autonomy"
    echo "autonomy: gated — both gates are yours again"
    return 0
  fi

  # Enabling this removes a human from the loop. Say exactly what that means, in the
  # imperative, and require a deliberate confirmation.
  cat <<WARN
Enabling autonomy '$mode' on $INSTANCE.

What changes:
  - the host will promote a draft to ready as soon as the project-manager has filled
    acceptance_criteria and cleared open_questions, with no human reading it
WARN
  if [ "$mode" = full ]; then
    cat <<'WARN2'
  - the host will MERGE pull requests written by agents into your default branch,
    with no human reading the diff

Machine gates that still hold on every merge (a merge is refused unless ALL pass):
  - the task carries `qa: approved`, written by a qa-reviewer box that is not the box
    that wrote the code
  - the pull request is open and mergeable
  - every CI check has succeeded; a PR with no checks at all is NOT merged
  - at most 3 merges per tick (CLAUDE_BOX_MAX_MERGES_PER_TICK)

Not covered: whether the task itself was specified correctly. An agent that satisfies
a wrong acceptance criterion produces a green, approved, merged mistake.
WARN2
  fi
  echo
  echo "Reversible at any time:  claude-box harness autonomy gated"
  echo
  if [ "$yes" != 1 ]; then
    if [ ! -t 0 ]; then
      die "refusing to enable autonomy non-interactively without -y"
    fi
    printf 'Type the mode to confirm (%s): ' "$mode"
    local answer; read -r answer
    [ "$answer" = "$mode" ] || { echo "aborted — still $(autonomy_mode)"; return 1; }
  fi
  mkdir -p "$INSTANCE_STATE"
  printf '%s\n' "$mode" > "$INSTANCE_STATE/autonomy"
  echo "autonomy: $mode"
}

# The host promotes — never a role. Keeping promotion in one place means the revert
# guard stays on for everyone, so a role that writes `ready` is still caught and logged
# even while the host is promoting freely.
autonomy_promote() {
  local mode="$1" f promoted=0 criteria questions status
  case "$mode" in promote|full) ;; *) return 0 ;; esac
  find "$INSTANCE/projects" -type f -name '*.md' 2>/dev/null | sort | while IFS= read -r f; do
    status="$(task_status "$f")"
    [ "$status" = draft ] || continue
    grep -q '^type: *Task' "$f" || continue
    # Refined means: testable criteria present, and nothing waiting on a human.
    criteria="$(awk -F': *' '/^acceptance_criteria:/ { print $2; exit }' "$f")"
    questions="$(awk -F': *' '/^open_questions:/ { print $2; exit }' "$f")"
    case "$criteria" in ''|'[]'|'[ ]') continue ;; esac
    case "$questions" in ''|'[]'|'[ ]') ;; *) continue ;; esac
    sed -i.bak 's/^status: *draft/status: ready/' "$f" && rm -f "$f.bak"
    note "autonomy($mode): promoted ${f#"$INSTANCE"/}"
    printf '%s\tpromoted by host\n' "${f#"$INSTANCE"/}" >> "$TICK_DIR/autonomy.tsv"
  done
  return 0
}

# The host merges — the boxes cannot (gh pr merge is denied at the policy layer). Every
# gate is checked here, against live gh state rather than against what a document claims.
autonomy_merge() {
  local mode="$1" merged=0 f status qa prs pr checks state
  [ "$mode" = full ] || return 0
  command -v "$GH_BIN" >/dev/null 2>&1 || { note "autonomy(full): no gh on PATH — not merging"; return 0; }

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$merged" -ge "$CLAUDE_BOX_MAX_MERGES_PER_TICK" ] && { note "autonomy(full): merge cap reached ($merged)"; break; }
    status="$(task_status "$f")"
    [ "$status" = in-review ] || continue
    qa="$(awk -F': *' '/^qa:/ { print $2; exit }' "$f")"
    if [ "$qa" != approved ]; then
      note "autonomy(full): ${f#"$INSTANCE"/} has no qa: approved — leaving it"
      continue
    fi
    prs="$(awk -F'[][]' '/^pr:/ { print $2; exit }' "$f" | tr -d ' "' | tr ',' '\n')"
    [ -n "$prs" ] || continue
    for pr in $prs; do
      [ -n "$pr" ] || continue
      state="$("$GH_BIN" pr view "$pr" --json state,mergeable --jq '.state + " " + (.mergeable // "UNKNOWN")' 2>/dev/null || true)"
      case "$state" in
        "OPEN MERGEABLE") ;;
        *) note "autonomy(full): $pr is '$state' — not merging"; continue ;;
      esac
      # No checks at all is NOT a pass: it is the absence of evidence.
      checks="$("$GH_BIN" pr checks "$pr" --json state --jq '[.[].state] | join(",")' 2>/dev/null || true)"
      if [ -z "$checks" ]; then
        note "autonomy(full): $pr has no CI checks — refusing to merge on no evidence"
        continue
      fi
      case "$checks" in
        *FAILURE*|*ERROR*|*CANCELLED*|*TIMED_OUT*|*ACTION_REQUIRED*|*PENDING*|*IN_PROGRESS*|*QUEUED*)
          note "autonomy(full): $pr checks are '$checks' — not merging"; continue ;;
      esac
      if "$GH_BIN" pr merge "$pr" --squash --delete-branch >/dev/null 2>&1; then
        note "autonomy(full): merged $pr"
        printf '%s\tmerged %s\n' "${f#"$INSTANCE"/}" "$pr" >> "$TICK_DIR/autonomy.tsv"
        merged=$((merged + 1))
      else
        note "autonomy(full): gh refused to merge $pr — left open"
      fi
    done
  done <<< "$(find "$INSTANCE/projects" -type f -name '*.md' 2>/dev/null | sort)"
  return 0
}

# --- new work -----------------------------------------------------------------
# Turn a sentence into documents. The project-manager authors the project and task
# docs as DRAFTS — it cannot promote them, so the gate stays yours. This is the
# entry point that means you never have to hand-write frontmatter.
cmd_harness_new() {
  local inst="" desc="" project="" repo="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance|--panel) inst="${2:-}"; shift 2 ;;
      --project)          project="${2:-}"; shift 2 ;;
      --repo)             repo="${2:-}"; shift 2 ;;
      --dry-run)          dry=1; shift ;;
      -*)                 die "unknown flag for 'harness new': $1" ;;
      *)
        if [ -z "$inst" ] && [ -d "$1" ] && [ -f "$1/instance.config.json" ]; then
          inst="$1"
        elif [ -z "$desc" ]; then
          desc="$1"
        else
          desc="$desc $1"
        fi
        shift ;;
    esac
  done
  [ -n "$desc" ] || die "usage: claude-box harness new [<panel>] \"<what you want>\" [--project <slug>] [--repo <name>]"
  resolve_instance "$inst"
  ensure_daemon
  require_login

  local default_repo; default_repo="$(cfg defaultRepo "")"
  case "$repo" in ''|null) repo="$default_repo" ;; esac
  case "$repo" in null) repo="" ;; esac

  local instr
  instr="A human has asked for the following work:

$desc

Create the documents for it, following SCHEMA.md and the OKF conventions in this panel exactly:"
  if [ -n "$project" ]; then
    instr="$instr
- Add the task(s) to the EXISTING project at /projects/$project/project.md. Do not create a new project."
  else
    instr="$instr
- Decide whether this belongs in an existing project (check /projects/) or needs a new one, and say which you chose and why.
- If new: write /projects/<slug>/project.md with a slug you pick from the work itself."
  fi
  [ -n "$repo" ] && instr="$instr
- The target repo is $repo unless the request clearly points elsewhere."
  instr="$instr
- Write one task document per independently reviewable slice at /projects/<slug>/tasks/<id>.md. Prefer the smallest slice that is independently useful over one big task.
- Fill acceptance_criteria with testable outcomes. Where a decision genuinely blocks the work and only the human can make it, add a numbered entry to open_questions instead of guessing.
- Every task must be status: draft. You must NOT set ready — promotion is the human's gate.
- Do not dispatch anything and do not write dispatch intents in this run.

Finish with: what you created (paths), what you assumed, and anything you need the human to answer."

  local model sys name log effort
  model="$(role_model project-manager)"
  effort="$(role_effort project-manager "$model")"
  sys="$(role_system_prompt project-manager "$repo")"
  name="$(unique_name "claude-box-h-$INSTANCE_SLUG-pm-new")"
  log="$STATE_HOME/logs/$name.log"

  if [ "$dry" = 1 ]; then
    echo "would ask the project-manager ($model${effort:+, effort $effort}) to draft:"
    printf '%s\n' "$desc" | sed 's/^/  /'
    echo
    echo "box:  $name"
    echo "log:  $log"
    return 0
  fi

  local before after
  before="$(mktemp)"; after="$(mktemp)"
  ( cd "$INSTANCE" && find projects -type f -name '*.md' 2>/dev/null | sort ) > "$before"

  resolve_target "$INSTANCE"
  EXTRA_RUN_ARGS=(-e IS_SANDBOX=1)
  local claude_args=(claude --permission-mode bypassPermissions --model "$model")
  [ -n "$effort" ] && claude_args+=(--effort "$effort")
  claude_args+=(--append-system-prompt "$sys" -p "$instr")

  mkdir -p "$INSTANCE_STATE/exits"
  rm -f "$INSTANCE_STATE/exits/$name"
  note "asking the project-manager to draft this ($model${effort:+, effort $effort})…"
  run_box_bg "$name" isolated "$log" "$INSTANCE_STATE/exits/$name" "${claude_args[@]}"
  wait_for_box "$name" "$INSTANCE_STATE/exits/$name" || true

  ( cd "$INSTANCE" && find projects -type f -name '*.md' 2>/dev/null | sort ) > "$after"
  echo
  echo "exit $(cat "$INSTANCE_STATE/exits/$name" 2>/dev/null || echo unknown) — full output: $log"
  echo
  local created; created="$(comm -13 "$before" "$after")"
  local why; why="$(box_failure_reason "$log" "$(cat "$INSTANCE_STATE/exits/$name" 2>/dev/null || true)")"
  if [ -z "$created" ] && [ -n "$why" ]; then
    echo "the drafting box did not do the work: $why"
    echo
    echo "last lines of $log:"
    tail -5 "$log" 2>/dev/null | sed 's/^/  /'
    rm -f "$before" "$after"
    return 1
  fi
  if [ -n "$created" ]; then
    echo "created:"
    printf '%s\n' "$created" | sed 's/^/  /'
    echo
    echo "review them, then promote what you approve:"
    printf '%s\n' "$created" | grep '/tasks/' | head -3 | while IFS= read -r t; do
      echo "  sed -i '' 's/^status: draft/status: ready/' $INSTANCE/$t"
    done
    echo
    echo "then: ./claude-box harness tick $INSTANCE"
  else
    echo "no new documents — read the log; it may have amended an existing task or asked you a question"
  fi
  rm -f "$before" "$after"
}

# --- one request, driven to completion ----------------------------------------
# The loop is a scheduler: right for a queue, wrong for "finish this one thing". Here the
# host drives the chain itself — draft, promote, implement, review, merge — because it
# launches every box and sees each one exit. There is nothing to poll for except CI, which
# is genuinely asynchronous and gets a bounded wait rather than a heartbeat.
CLAUDE_BOX_CI_TIMEOUT="${CLAUDE_BOX_CI_TIMEOUT:-900}"

# Dispatch one role at one task and block until its box exits. Returns the exit code.
run_role_sync() {
  local role="$1" task="$2" repo="$3" label="$4"
  local model sys name log effort code
  model="$(role_model "$role")"
  effort="$(role_effort "$role" "$model")"
  sys="$(role_system_prompt "$role" "$repo")"
  name="$(unique_name "claude-box-h-$INSTANCE_SLUG-$(slug "$role")-$(slug "$(basename "${task%.md}")")")"
  log="$STATE_HOME/logs/$name.log"
  mkdir -p "$INSTANCE_STATE/exits" "$INSTANCE_STATE/inflight"
  rm -f "$INSTANCE_STATE/exits/$name"
  printf '%s\n' "$name" > "$INSTANCE_STATE/inflight/$(task_key "$task")"

  local claude_args=(claude --permission-mode bypassPermissions --model "$model")
  [ -n "$effort" ] && claude_args+=(--effort "$effort")
  claude_args+=(--append-system-prompt "$sys"
                -p "$label

Task document: $task (bundle-relative, this panel's root is your working directory).
Follow your role definition and the executor rules in your system prompt. Report by updating the task document.")

  resolve_target "$INSTANCE"
  EXTRA_RUN_ARGS=(-e IS_SANDBOX=1)
  note "  → $role on $(basename "$task") ($model${effort:+, $effort})"
  run_box_bg "$name" isolated "$log" "$INSTANCE_STATE/exits/$name" "${claude_args[@]}"
  wait_for_box "$name" "$INSTANCE_STATE/exits/$name" || true
  code="$(cat "$INSTANCE_STATE/exits/$name" 2>/dev/null || echo unknown)"
  reclaim_credentials "$name"
  rm -f "$INSTANCE_STATE/inflight/$(task_key "$task")"
  note "    exit $code — $log"
  [ "$code" = 0 ]
}

task_field() { awk -F': *' -v k="$2" '$1 == k { print $2; exit }' "$1" 2>/dev/null; }

# Wait for CI to reach a verdict. The one honest poll in the system: CI runs on someone
# else's schedule, so the alternative to polling is not knowing.
wait_for_ci() {
  local pr="$1" deadline=$(( $(date +%s) + CLAUDE_BOX_CI_TIMEOUT )) checks
  while :; do
    checks="$("$GH_BIN" pr checks "$pr" --json state --jq '[.[].state] | join(",")' 2>/dev/null || true)"
    [ -z "$checks" ] && { printf 'none\n'; return 1; }
    case "$checks" in
      *PENDING*|*IN_PROGRESS*|*QUEUED*)
        [ "$(date +%s)" -ge "$deadline" ] && { printf 'timeout\n'; return 1; }
        sleep 20; continue ;;
      *FAILURE*|*ERROR*|*CANCELLED*|*TIMED_OUT*|*ACTION_REQUIRED*) printf 'failed\n'; return 1 ;;
      *) printf 'green\n'; return 0 ;;
    esac
  done
}

cmd_harness_do() {
  local inst="" desc="" project="" repo="" rounds=2 dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance|--panel) inst="${2:-}"; shift 2 ;;
      --project)          project="${2:-}"; shift 2 ;;
      --repo)             repo="${2:-}"; shift 2 ;;
      --max-rounds)       rounds="${2:-}"; shift 2 ;;
      --dry-run)          dry=1; shift ;;
      -*)                 die "unknown flag for 'harness do': $1" ;;
      *)
        if [ -z "$inst" ] && [ -d "$1" ] && [ -f "$1/instance.config.json" ]; then inst="$1"
        elif [ -z "$desc" ]; then desc="$1"
        else desc="$desc $1"; fi
        shift ;;
    esac
  done
  [ -n "$desc" ] || die "usage: claude-box harness do [<panel>] \"<what you want>\" [--repo <name>] [--max-rounds N]"
  resolve_instance "$inst"
  ensure_daemon
  local mode; mode="$(autonomy_mode)"
  [ "$dry" = 1 ] || require_login

  if [ "$dry" = 1 ]; then
    echo "would drive this to completion on $INSTANCE (autonomy: $mode):"
    echo "  1. project-manager drafts the documents"
    echo "  2. $([ "$mode" = gated ] && echo 'STOP — gated: you promote' || echo 'host promotes the refined drafts')"
    echo "  3. the assigned role implements each task, in its own box"
    echo "  4. qa-reviewer reviews, up to $rounds round(s) of changes"
    echo "  5. $([ "$mode" = full ] && echo 'wait for CI, then the host merges' || echo 'STOP — you merge')"
    echo
    echo "  ask: $desc"
    return 0
  fi

  # 1. Draft.
  echo "── drafting ─────────────────────────────────────────────"
  local before after created
  before="$(mktemp)"; after="$(mktemp)"
  ( cd "$INSTANCE" && find projects -type f -name '*.md' 2>/dev/null | sort ) > "$before"
  # Not swallowed: when drafting fails, its diagnosis is the only useful output there is.
  cmd_harness_new "$INSTANCE" "$desc" ${project:+--project "$project"} ${repo:+--repo "$repo"} || true
  ( cd "$INSTANCE" && find projects -type f -name '*.md' 2>/dev/null | sort ) > "$after"
  created="$(comm -13 "$before" "$after" | grep '/tasks/' || true)"
  rm -f "$before" "$after"

  if [ -z "$created" ]; then
    echo
    echo "no task documents were created — nothing downstream can run."
    echo "the drafting output above says why; a sharper request is the LAST thing to suspect."
    return 1
  fi
  printf '%s\n' "$created" | sed 's/^/  drafted /'

  # 2. Anything waiting on a human stops here: nothing downstream can answer it.
  local blocked=0 t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    local q; q="$(task_field "$INSTANCE/$t" open_questions)"
    case "$q" in ''|'[]'|'[ ]') ;; *)
      echo
      echo "  $t is waiting on you:"
      printf '%s\n' "$q" | sed 's/^/    /'
      blocked=1 ;;
    esac
  done <<< "$created"
  if [ "$blocked" = 1 ]; then
    echo
    echo "Answer inline in the task document — append ' --- <your answer>' to the question — then:"
    echo "  ./claude-box harness do \"$desc\"    (or ./claude-box harness tick to pick it up)"
    return 2
  fi

  # 3. Promote.
  echo "── promoting ────────────────────────────────────────────"
  if [ "$mode" = gated ]; then
    echo "  autonomy is gated, so promotion is yours:"
    printf '%s\n' "$created" | while IFS= read -r t; do
      echo "    sed -i '' 's/^status: draft/status: ready/' $INSTANCE/$t"
    done
    echo "  then re-run this command, or: ./claude-box harness autonomy promote"
    return 3
  fi
  TICK_DIR="$INSTANCE_STATE/ticks/do-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$TICK_DIR"
  autonomy_promote "$mode"

  # 4. Implement, then review, per task.
  local failures=0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    local doc="$INSTANCE/$t" role trepo round=1
    [ "$(task_status "$doc")" = ready ] || { echo "  skipping $t (status $(task_status "$doc"))"; continue; }
    role="$(task_field "$doc" assignee)"
    case "$role" in ''|'~') role=lead-dev ;; esac
    role_is_known "$role" || role=lead-dev
    trepo="$(task_field "$doc" target_repo)"; trepo="${trepo##*/}"
    [ -n "$trepo" ] || trepo="$repo"

    echo "── implementing $(basename "$t") ───────────────────────"
    run_role_sync "$role" "$t" "$trepo" "Implement this task end to end." || true

    while [ "$round" -le "$rounds" ]; do
      local st; st="$(task_status "$doc")"
      [ "$st" = in-review ] || break
      echo "── reviewing $(basename "$t") (round $round) ───────────"
      run_role_sync qa-reviewer "$t" "$trepo" "Review the open pull request on this task against its acceptance criteria. Set the qa: field." || true
      local qa; qa="$(task_field "$doc" qa)"
      [ "$qa" = approved ] && break
      echo "  qa: ${qa:-none} — sending it back"
      run_role_sync "$role" "$t" "$trepo" "The qa-reviewer requested changes. Address every point, then hand it back for review." || true
      round=$((round + 1))
    done

    # 5. Merge, when you have handed that gate over.
    local final; final="$(task_status "$doc")"
    if [ "$mode" = full ] && [ "$final" = in-review ] && [ "$(task_field "$doc" qa)" = approved ]; then
      local pr; pr="$(awk -F'[][]' '/^pr:/ { print $2; exit }' "$doc" | tr -d ' "' | cut -d, -f1)"
      if [ -n "$pr" ]; then
        echo "── ci ──────────────────────────────────────────────────"
        local verdict; verdict="$(wait_for_ci "$pr")"
        case "$verdict" in
          green)   autonomy_merge full ;;
          none)    echo "  $pr has no CI checks — not merging on no evidence" ;;
          failed)  echo "  CI failed on $pr — left open for you" ;;
          timeout) echo "  CI still running after ${CLAUDE_BOX_CI_TIMEOUT}s — left open; 'harness tick' will merge it once green" ;;
        esac
      fi
    fi

    final="$(task_status "$doc")"
    case "$final" in
      done) echo "  ✓ $t is done" ;;
      *)    echo "  · $t is $final"; failures=$((failures + 1)) ;;
    esac
  done <<< "$created"

  echo
  echo "── result ───────────────────────────────────────────────"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    printf '  %-46s %s%s\n' "$t" "$(task_status "$INSTANCE/$t")" \
      "$(pr="$(awk -F'[][]' '/^pr:/ { print $2; exit }' "$INSTANCE/$t" | tr -d ' "' | cut -d, -f1)"; [ -n "$pr" ] && printf '  %s' "$pr")"
  done <<< "$created"
  if [ "$mode" != full ]; then
    echo
    echo "  merging is still yours (autonomy: $mode)"
  fi
  [ "$failures" = 0 ]
}

# --- init ---------------------------------------------------------------------
# Stamp (or refresh) a control panel. The split matters: MACHINERY — the role
# definitions and the schema — belongs to claude-box and is refreshed on every run,
# so a fix here reaches every panel. INSTANCE DATA — config, projects, objectives,
# knowledge, the log — is yours and is never clobbered.
#
# The result is also compatible with an ai-bridge instance, so `harness tick` works
# against either: same frontmatter fields, same statuses, same two human gates.
cmd_harness_init() {
  local dir="" org="" email="" keep_roles=0 want_git=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --org)         org="${2:-}"; shift 2 ;;
      --email)       email="${2:-}"; shift 2 ;;
      --keep-roles)  keep_roles=1; shift ;;
      --no-git)      want_git=0; shift ;;
      -*)            die "unknown flag for 'harness init': $1" ;;
      *)             dir="$1"; shift ;;
    esac
  done
  # One panel is the common case, so it gets a default name and you never have to
  # invent one. Pass a directory when you want several (work vs. side project).
  [ -n "$dir" ] || dir="$ROOT/_panel"

  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd -P)"
  [ -n "$ROOT" ] || die "no repos root — set CLAUDE_BOX_ROOT"
  case "$dir" in
    "$ROOT"/*) ;;
    *) die "a panel must live under the repos root ($ROOT) so a box can see it; $dir does not" ;;
  esac

  local tpl="$HARNESS_DIR/template" fresh=1
  [ -f "$dir/instance.config.json" ] && fresh=0

  # Instance data: seed once, never overwrite.
  local f
  for f in index.md log.md CLAUDE.md knowledge/index.md; do
    mkdir -p "$dir/$(dirname "$f")"
    [ -e "$dir/$f" ] || cp "$tpl/$f" "$dir/$f"
  done
  mkdir -p "$dir/projects" "$dir/objectives" "$dir/.harness/intents/rejected" \
           "$dir/.harness/pending" "$dir/_wt" \
           "$dir/knowledge/services" "$dir/knowledge/findings" \
           "$dir/knowledge/runbooks" "$dir/knowledge/teams"
  for f in projects objectives knowledge/services knowledge/findings knowledge/runbooks knowledge/teams; do
    [ -e "$dir/$f/.gitkeep" ] || : > "$dir/$f/.gitkeep"
  done

  # Machinery: refreshed on every run, because a fix to a role should reach every panel.
  cp "$tpl/SCHEMA.md" "$dir/SCHEMA.md"
  mkdir -p "$dir/.claude/agents"
  if [ "$keep_roles" = 1 ]; then
    for f in "$HARNESS_DIR/roles"/*.md; do
      [ -e "$dir/.claude/agents/$(basename "$f")" ] || cp "$f" "$dir/.claude/agents/"
    done
  else
    cp "$HARNESS_DIR/roles"/*.md "$dir/.claude/agents/"
  fi

  # Config: seeded once, then filled in only where a field is still empty.
  [ -e "$dir/instance.config.json" ] || cp "$tpl/instance.config.json" "$dir/instance.config.json"
  [ -z "$email" ] && email="$(git config --get user.email 2>/dev/null || true)"
  python3 - "$dir/instance.config.json" "$org" "$email" "$ROOT" "$HOME" <<'PY_CFG'
import json, sys
path, org, email, root, home = sys.argv[1:6]
config = json.load(open(path))
if org and not config.get("org"):
    config["org"] = org
if email and not config.get("authorEmail"):
    config["authorEmail"] = email
# Fill in reposRoot only when it is empty or still the untouched template default —
# a re-run must never rewrite a path the user set deliberately.
if config.get("reposRoot", "") in ("", "~/Documents/GitHub"):
    config["reposRoot"] = "~/" + root[len(home) + 1:] if root.startswith(home + "/") else root
json.dump(config, open(path, "w"), indent=2)
PY_CFG

  # Machinery is ours; keep it out of the panel's own diffs where it is derived.
  if ! grep -qxF 'DASHBOARD.md' "$dir/.gitignore" 2>/dev/null; then
    { echo "# claude-box harness — derived and runtime state"
      echo "DASHBOARD.md"
      echo ".harness/intents/"
      echo "_wt/"
    } >> "$dir/.gitignore"
  fi

  # A local git repo costs nothing and makes the knowledge base a record rather than a
  # snapshot — but it is your data, so --no-git opts out.
  if [ "$want_git" = 1 ]; then
    [ -d "$dir/.git" ] || git -C "$dir" init -q
  fi

  if [ "$fresh" = 1 ]; then
    echo "control panel created at $dir"
    echo
    echo "next:"
    echo "  1. \$EDITOR $dir/instance.config.json        # org, authorEmail"
    echo "  2. write a task under $dir/projects/<slug>/tasks/<id>.md  (status: draft)"
    echo "  3. promote it yourself:  status: draft -> ready"
    echo "  4. ./claude-box harness tick $dir --dry-run"
    echo "  5. ./claude-box harness tick $dir"
    echo
    echo "roles installed: $(command ls "$dir/.claude/agents" | sed 's/\.md$//' | tr '\n' ' ')"
  else
    echo "refreshed the machinery in $dir (roles + SCHEMA.md); your config, projects and knowledge were left alone"
  fi
}

harness_usage() {
  cat <<'USAGE'
claude-box harness — role agents in boxes, over an OKF control panel

  claude-box harness init   [<dir>] [--org X] [--email Y] [--no-git]
                                                       stamp/refresh a control panel
                                                       (default: $CLAUDE_BOX_ROOT/_panel)
  claude-box harness do     [<panel>] "<what you want>"   draft -> implement -> review
                                                       -> merge, driven to completion
  claude-box harness new    [<panel>] "<what you want>"   just draft the documents
  claude-box harness tick   [<instance>] [--dry-run]   one PM tick, then dispatch
  claude-box harness loop   [<instance>] [gap]         tick, wait, sleep, repeat (locked)
  claude-box harness status [<instance>]               lock, in-flight, last tick, queues
  claude-box harness autonomy [gated|promote|full]     who promotes and who merges
  claude-box harness memory [<instance>]               review pending learnings
  claude-box harness ui     [<instance>] [--port N]    local dashboard

  claude-box role <role> [--instance <dir>] [--task <path>] [--repo <name>]
                         [--tier <tier>] [--prompt <text>] [--detach] [--dry-run]

<panel> is resolved in this order: the argument you pass, $CLAUDE_BOX_PANEL, the
current directory if it is a panel, or the only panel under $CLAUDE_BOX_ROOT. So with
one panel you never type its path. A panel is instance.config.json + SCHEMA.md +
.claude/agents — one stamped by `harness init`, or an existing ai-bridge instance.
USAGE
}

cmd_harness() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    init)          cmd_harness_init "$@" ;;
    new)           cmd_harness_new "$@" ;;
    do)            cmd_harness_do "$@" ;;
    autonomy)      cmd_harness_autonomy "$@" ;;
    tick)          cmd_harness_tick "$@" ;;
    loop)          cmd_harness_loop "$@" ;;
    status)        cmd_harness_status "$@" ;;
    memory)        cmd_harness_memory "$@" ;;
    ui)            cmd_harness_ui "$@" ;;
    ""|-h|--help)  harness_usage ;;
    *)             die "unknown harness subcommand '$sub' (try: init do new tick loop status autonomy memory ui)" ;;
  esac
}
