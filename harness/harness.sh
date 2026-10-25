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
# than a feature — so the intent file is the whole interface. See harness/README.md.

HARNESS_DIR="$SETUP_DIR/harness"
# Per-box wall-clock limit. A wedged agent must not hold a dispatch slot forever.
CLAUDE_BOX_ROLE_TIMEOUT="${CLAUDE_BOX_ROLE_TIMEOUT:-2700}"      # 45 min
CLAUDE_BOX_TASK_ATTEMPTS="${CLAUDE_BOX_TASK_ATTEMPTS:-3}"        # timeouts before a task blocks
CLAUDE_BOX_STALL_TIMEOUT="${CLAUDE_BOX_STALL_TIMEOUT:-420}"      # 7 min of silence = stuck; 0 disables
# Review rounds per run. Two was a spend cap, and it read as abandonment: a task with a real
# finding was handed back once and then left in-review while the run walked to the next task.
# The point of a budget is to bound a loop that is not converging, not to stop work that is.
CLAUDE_BOX_QA_ROUNDS="${CLAUDE_BOX_QA_ROUNDS:-10}"
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
  if [ -f "$CONFIG_HOME/.credentials.json" ]; then
    # The file existing is not the same as the session working. A box that refreshes the token
    # writes the credential back, and one such write landed without `expiresAt` — after which
    # every box read it as expired, failed to refresh, and died in 80ms. Say so before
    # spending a container per task.
    local verdict
    verdict="$(python3 - "$CONFIG_HOME/.credentials.json" <<'PY_CRED'
import json, sys, time
try:
    oauth = (json.load(open(sys.argv[1])) or {}).get("claudeAiOauth") or {}
except Exception:
    print("unreadable"); raise SystemExit
if not oauth:
    print("ok"); raise SystemExit                      # an API-key or other shape: not ours to judge
refresh = oauth.get("refreshTokenExpiresAt")
if refresh and refresh / 1000 < time.time():
    print("refresh-expired"); raise SystemExit
expires = oauth.get("expiresAt")
if expires is None:
    print("no-expiry"); raise SystemExit
print("expired" if expires / 1000 < time.time() else "ok")
PY_CRED
)"
    case "$verdict" in
      (ok) return 0 ;;
      (no-expiry|expired)
        note "the shared Claude credential looks stale ($verdict) — a box may fail to authenticate.
    If boxes die instantly, log in again: claude-box, then /login." ;;
      (refresh-expired)
        die "the shared Claude session has expired and cannot refresh itself.

Log in once, in your own terminal (it needs a TTY):

  claude-box            # then /login, then exit

Credentials live in $CONFIG_HOME and every box shares them." ;;
      (*) ;;
    esac
    return 0
  fi
  die "the sandbox has no Claude login yet, so every box would exit without doing anything.

Log in once, in your own terminal (it needs a TTY, so this cannot be done for you):

  claude-box            # then /login, then exit

Credentials persist in $CONFIG_HOME and every box shares them. Alternatively, export
ANTHROPIC_API_KEY before running the harness."
}

# An expired OAuth session kills every box in the run in about 80ms each, and the host used to
# read each empty exit as "no pull request — task blocked": one dead credential rewrote nine
# task documents. This is the check that stops a run instead of spending it.
box_auth_failed() {
  local log="$1"
  [ -f "$log" ] || return 1
  # A content grep over stream-json: a healthy box that READS these words (this repo's own
  # source, a tool result quoting an error) echoes them into its log. Only a run that never
  # reported completion gets to be judged on them.
  grep -q '"terminal_reason":"completed"' "$log" && return 1
  grep -qiE '"error":"authentication_failed"|OAuth session expired|Failed to authenticate|please run /login' "$log"
}

# Did this box actually run, or did it fall out for a reason that is not the task's fault?
# Returns a human-readable reason, or nothing when the box looks healthy.
box_failure_reason() {
  local log="$1" code="$2"
  [ -f "$log" ] || { printf 'the box produced no log at all\n'; return 0; }
  # These two are CONTENT greps over a stream-json log, so they only get to speak about a run
  # that did not report completion. A perfectly healthy stream carries `rateLimitTier` in its
  # init line and `rate_limit` in its policy metadata, which `rate.?limit` matched — and because
  # the greps sat above the exit-code check, an exit 0 could not clear them. A whole fold-in that
  # cleared every open question was reported as "the API refused the request".
  if ! grep -q '"terminal_reason":"completed"' "$log"; then
    if grep -qiE 'not logged in|please run /login|invalid api key|authentication_error|authentication_failed|OAuth session expired|Failed to authenticate' "$log"; then
      printf 'the box could not authenticate — run `claude-box` in a terminal, /login, then retry\n'
      return 0
    fi
    if grep -qiE 'credit balance|quota|rate.?limit|overloaded' "$log"; then
      printf 'the API refused the request (credit, quota or rate limit) — see the log\n'
      return 0
    fi
  fi
  case "$code" in
    0|'') ;;
    timeout) printf 'the box hit the %ss timeout\n' "$CLAUDE_BOX_ROLE_TIMEOUT"; return 0 ;;
    stalled) printf 'the box stopped producing output for %ss and was stopped\n' "$CLAUDE_BOX_STALL_TIMEOUT"; return 0 ;;
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

  # Repo-scoped memory is the panel's. A repo that ships its own `.harness/memory` is still
  # read — that is a team publishing learnings with its code — but the harness never writes
  # there, so the human's working tree stays clean.
  if [ -n "$repo" ]; then
    local repo_mem=0 repo_out=""
    for f in "$INSTANCE/memory/repos/$repo"/*.md \
             "$ROOT/$repo/.harness/memory"/*.md "$ROOT/$repo/.harness/memory/learnings"/*.md; do
      [ -f "$f" ] || continue
      repo_out="$repo_out"$'\n'"<!-- $(basename "$f") -->"$'\n'"$(cat "$f")"$'\n'
      repo_mem=1
    done
    if [ "$repo_mem" = 1 ]; then
      out="$out"$'\n'"### Repo-scoped ($repo) — wins over global"$'\n'"$repo_out"
    fi
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
  local scopes; scopes="$(gh_scopes)"
  if [ -n "$scopes" ]; then
    printf '\n### What your GitHub token may write\n\nScopes: `%s`.\n' "$scopes"
    if gh_has_scope workflow; then
      printf '\nYou CAN add and change CI: put the job in `.github/workflows/`, in the same pull\n'
      printf 'request as the code it proves. Nowhere else is CI.\n'
    else
      printf '\nYou CANNOT push `.github/workflows/**` — that needs the `workflow` scope, which this\n'
      printf 'token lacks. Do not park a workflow file in a neighbouring directory: a YAML file\n'
      printf 'Actions never reads is not CI, and a PR that ships one looks verified and is not.\n'
      printf 'Write what the job would be under `## Blocked on` in the PR body, naming the file\n'
      printf 'and the one command that unblocks it:\n\n'
      printf '    gh auth refresh -h github.com -s workflow\n'
    fi
  fi
}

# The scopes on the token every box gets. A box cannot discover this for itself without
# spending a turn on it, and not knowing cost a whole task: unable to push
# `.github/workflows/**` (that needs the `workflow` scope), an agent invented
# `.github/e2e-workflows-staged/` and shipped a PR whose CI proved nothing. Cached for an
# hour — it is one API call, and the answer only changes when a human refreshes the token in
# a browser, which is exactly the fix applied after a role reports it cannot push workflows.
gh_scopes() {
  local cache="$INSTANCE_STATE/gh-scopes"
  if [ -f "$cache" ] && [ -n "$(cat "$cache" 2>/dev/null)" ] \
     && [ $(( $(date +%s) - $(file_mtime "$cache") )) -lt 3600 ]; then
    cat "$cache"; return 0
  fi
  mkdir -p "$INSTANCE_STATE"
  local scopes=""
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    # Lowercase the whole response first: the header arrives as `X-Oauth-Scopes` and awk's
    # IGNORECASE is a gawk extension that macOS awk ignores in silence — which made this
    # return nothing and every role prompt claim the token could not push CI.
    scopes="$("$GH_BIN" api --include /user 2>/dev/null | tr 'A-Z' 'a-z' \
                | sed -n 's/^x-oauth-scopes: *//p' | tr -d '\r' | head -1)"
  fi
  printf '%s\n' "$scopes" > "$cache"
  printf '%s\n' "$scopes"
}

gh_has_scope() {
  case ",$(gh_scopes | tr -d ' ')," in (*",$1,"*) return 0 ;; (*) return 1 ;; esac
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

# A box that does not know its clock spends the whole budget exploring and gets killed with
# the work on the floor: six of eight tasks in one run ended "timeout, no pull request". The
# work survives in the worktree either way, but a pushed branch and a draft PR turn a
# stopped box into resumable progress a human can read, so say the number out loud.
time_budget_doc() {
  local total=$((CLAUDE_BOX_ROLE_TIMEOUT / 60)) soft=$(( (CLAUDE_BOX_ROLE_TIMEOUT * 3 / 4) / 60 ))
  cat <<EOF_TB
## Your clock

You have **${total} minutes** of wall clock. The box is stopped at that point, mid-sentence.

At **${soft} minutes**, stop starting anything new:

1. commit what works and push the branch,
2. open (or update) the draft pull request,
3. write what is left under \`## Blocked on\` in the PR body.

A stopped box with a pushed branch and a draft PR is progress the next run continues from.
A stopped box with everything uncommitted is a run nobody can read. Nothing is graded on
using the full budget — finishing early is the better outcome.
EOF_TB
}

role_system_prompt() {
  local role="$1" repo="${2:-}"
  printf '%s\n\n---\n\n%s\n\n---\n\n%s\n\n---\n\n%s\n\n---\n\n%s\n\n---\n\n%s\n' \
    "$(strip_frontmatter "$INSTANCE/.claude/agents/$role.md")" \
    "$(cat "$HARNESS_DIR/overlay.md")" \
    "$(standards_doc)" \
    "$(time_budget_doc)" \
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

  # stream-json, not text: the default prints nothing until the run ENDS, so a long box
  # looks hung and its log holds one line. The stream is rendered by harness/render-log.py.
  local claude_args=(claude --permission-mode bypassPermissions --model "$model"
                     --output-format stream-json --verbose)
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
# The third argument is the box's log, when the caller has one. A box that has stopped
# producing output is not working — one lead-dev box sat for eleven minutes inside
# `until [ -f <subagent output> ]`, spending the whole budget on a file that never
# appeared. The hard timeout eventually caught it; a stall check catches it in minutes.
wait_for_box() {
  local name="$1" exit_file="$2" log="${3:-}" missing=0
  local deadline=$(( $(date +%s) + CLAUDE_BOX_ROLE_TIMEOUT ))
  local last_size=-1 last_change; last_change="$(date +%s)"
  while :; do
    [ -f "$exit_file" ] && return 0
    # -f as well as -n: the log does not exist for the first second or two of a box, and
    # `wc -c < missing` makes bash itself print "No such file or directory" with a line number,
    # which looks like a harness crash in the middle of a run.
    if [ -n "$log" ] && [ -f "$log" ] && [ "$CLAUDE_BOX_STALL_TIMEOUT" -gt 0 ]; then
      local size; size="$(wc -c < "$log" 2>/dev/null | tr -d ' ')"; size="${size:-0}"
      if [ "$size" != "$last_size" ]; then
        last_size="$size"; last_change="$(date +%s)"
      elif [ $(( $(date +%s) - last_change )) -ge "$CLAUDE_BOX_STALL_TIMEOUT" ]; then
        note "$name wrote nothing for ${CLAUDE_BOX_STALL_TIMEOUT}s — stopping it"
        box_is_running "$name" && engine_stop_box "$name"
        printf '%s\n' stalled > "$exit_file"
        return 1
      fi
    fi
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
  # Retention runs here rather than from a cron: a tick is the only thing guaranteed to
  # happen regularly, and this is diagnostics rather than record.
  local pruned; pruned="$(prune_history "$CLAUDE_BOX_HISTORY_DAYS" 2>/dev/null || echo 0)"
  [ "${pruned:-0}" -gt 0 ] 2>/dev/null && note "pruned $pruned history item(s) older than ${CLAUDE_BOX_HISTORY_DAYS}d"

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
    local pm_args=(claude --permission-mode bypassPermissions --model "$pm_model"
                   --output-format stream-json --verbose)
    local pm_effort; pm_effort="$(role_effort project-manager "$pm_model")"
    [ -n "$pm_effort" ] && pm_args+=(--effort "$pm_effort")
    local pm_fallback; pm_fallback="$(cfg fallbackModel "")"
    case "$pm_fallback" in ''|null|None) ;; *) pm_args+=(--fallback-model "$pm_fallback") ;; esac
    run_box_bg "$pm_name" isolated "$pm_log" "$pm_exit" \
      "${pm_args[@]}" \
      --append-system-prompt "$pm_sys" \
      -p "Run ONE tick of your project-manager procedure. Reconcile task documents against live git/gh state, refine drafts, and for every human-promoted 'ready' task write a dispatch intent file as described in your system prompt. Do not promote and do not merge. End with a short summary of deltas, dispatch intents written, and what awaits the human."
    wait_for_box "$pm_name" "$pm_exit" "$pm_log" || note "PM tick timed out"
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
      wait_for_box "$nm" "$INSTANCE_STATE/exits/$nm" "$STATE_HOME/logs/$nm.log" || true
    done <<< "$names"
    status_snapshot > "$snap_post"
    revert_promotions "$snap_mid" "$snap_post" "role boxes"
    autonomy_merge "$mode"
  fi

  # Anything whose gates passed while we were elsewhere.
  local rt
  while IFS= read -r rt; do
    [ -n "$rt" ] || continue
    pr_ready_if_finished "$rt" "$(task_field "$INSTANCE/$rt" target_repo)"
  done <<< "$(cd "$INSTANCE" && find projects -type f -name '*.md' -path '*/tasks/*' 2>/dev/null | sort)"

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
      # Panel-owned, keyed by repo. Writing into the target repo put a dozen untracked files
      # in the human's working tree of a monorepo nobody asked us to modify — the pollution
      # without the sharing, since nothing ever committed them. The panel already holds
      # projects, knowledge and the log, and it can be a git repo a team shares.
      [ -n "$repo" ] || { note "proposal has tier: repo but no repo: field — edit or drop it"; return 1; }
      # A name, not a path: `..` passes the directory test and lands outside memory/repos.
      case "$repo" in (.|..|/*|*/..|../*|*/../*) note "repo '$repo' is not a repo name — edit or drop it"; return 1 ;; esac
      [ -d "$ROOT/$repo" ] || { note "repo '$repo' not found under $ROOT"; return 1; }
      mkdir -p "$INSTANCE/memory/repos/$repo"
      dst="$INSTANCE/memory/repos/$repo/$(basename "$file")"
      ;;
    *)
      note "proposal has no usable tier (want 'global' or 'repo', got '${tier:-none}') — edit or drop it"; return 1 ;;
  esac
  mkdir -p "$(dirname "$dst")"
  cp "$file" "$dst"
  rm -f "$file"
  echo "accepted -> $dst"
  [ "$tier" = repo ] && echo "  (scoped to $repo; commit it in this panel to share it with your team)"
  return 0
}

cmd_harness_memory() {
  local inst="" accept="" drop="" list=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance|--panel) inst="${2:-}"; shift 2 ;;
      # Non-interactive, so the dashboard can act through the same implementation rather
      # than growing a second one.
      --accept)           accept="${2:-}"; shift 2 ;;
      --drop)             drop="${2:-}"; shift 2 ;;
      --list)             list=1; shift ;;
      -*)                 die "unknown flag for 'harness memory': $1" ;;
      *)                  inst="$1"; shift ;;
    esac
  done
  resolve_instance "$inst"

  # A proposal is named by its file, and only inside the pending directory.
  if [ -n "$accept" ] || [ -n "$drop" ]; then
    local target="${accept:-$drop}"
    case "$target" in
      (*/*|..*|"") die "give the proposal's file name only, e.g. --accept kafka-idempotency.md" ;;
    esac
    local file="$INSTANCE/.harness/pending/$target"
    [ -f "$file" ] || die "no pending proposal named $target"
    if [ -n "$drop" ]; then
      rm -f "$file"
      echo "dropped $target"
      return 0
    fi
    memory_accept "$file"
    return $?
  fi

  if [ "$list" = 1 ]; then
    local f
    echo "global ($STATE_HOME/harness/memory):"
    for f in "$STATE_HOME/harness/memory"/*.md; do
      [ -f "$f" ] && printf '  %s\n' "$(basename "$f")"
    done
    echo "repo-scoped:"
    for f in "$INSTANCE"/memory/repos/*/*.md \
             "$ROOT"/*/.harness/memory/learnings/*.md "$ROOT"/*/.harness/memory/*.md; do
      [ -f "$f" ] || continue
      printf '  %s\n' "${f#"$ROOT"/}"
    done
    echo "pending ($INSTANCE/.harness/pending):"
    for f in "$INSTANCE/.harness/pending"/*.md; do
      [ -f "$f" ] && printf '  %s  [%s]\n' "$(basename "$f")" "$(fm_field "$f" tier)"
    done
    return 0
  fi
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
  local port=7777 inst="" actions=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)     port="${2:-}"; shift 2 ;;
      --instance) inst="${2:-}"; shift 2 ;;
      --actions)  actions=1; shift ;;
      *)          inst="$1"; shift ;;
    esac
  done
  resolve_instance "$inst"
  command -v python3 >/dev/null 2>&1 || die "the dashboard needs python3 (macOS ships it)"
  note "dashboard on http://localhost:$port  (Ctrl-C to stop)"
  [ "$actions" = 1 ] && note "actions ON — the page can stop boxes, promote tasks and run a tick"
  CB_INSTANCE="$INSTANCE" CB_INSTANCE_SLUG="$INSTANCE_SLUG" CB_STATE="$STATE_HOME" \
  CB_ROOT="$ROOT" CB_PORT="$port" CB_RUNNER="$SETUP_DIR/claude-box" \
  CB_UI_ACTIONS="$actions" \
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
  local mode="$1" f promoted=0 status
  case "$mode" in promote|full) ;; *) return 0 ;; esac
  find "$INSTANCE/projects" -type f -name '*.md' 2>/dev/null | sort | while IFS= read -r f; do
    status="$(task_status "$f")"
    [ "$status" = draft ] || continue
    grep -q '^type: *Task' "$f" || continue
    # Refined means: testable criteria present, and nothing waiting on a human.
    [ "$(fm_list_count "$f" acceptance_criteria)" -gt 0 ] || continue
    [ "$(fm_list_count "$f" open_questions)" -eq 0 ] || continue
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
      # A draft PR is the shape a role uses to hand over work it could not fully verify —
      # exactly the thing that must not merge itself.
      state="$("$GH_BIN" pr view "$pr" --json state,mergeable,isDraft --jq '.state + " " + (.mergeable // "UNKNOWN") + " draft=" + (.isDraft|tostring)' 2>/dev/null || true)"
      case "$state" in
        *"draft=true"*) note "autonomy(full): $pr is a draft — not merging"; continue ;;
        "OPEN MERGEABLE"*) ;;
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
  local inst="" desc="" project="" repo="" dry=0 terse=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --terse)            terse=1; shift ;;
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

  local jira_note=""
  if [ "$(cfg jira.enabled false)" = "True" ] || [ "$(cfg jira.enabled false)" = "true" ]; then
    jira_note="
- This panel mirrors work into Jira (project $(cfg jira.project '?') on $(cfg jira.site '?')): create one Epic for the project and one Story per task, with the acceptance criteria copied in full, and record the keys in jira_epic:/jira:. Search for an existing issue before creating anything."
  fi
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
- Every task must be status: draft. You must NOT set ready — promotion is the human's gate.$jira_note
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
  local claude_args=(claude --permission-mode bypassPermissions --model "$model"
                     --output-format stream-json --verbose)
  [ -n "$effort" ] && claude_args+=(--effort "$effort")
  claude_args+=(--append-system-prompt "$sys" -p "$instr

Write the project's objective document too — \`objectives/<project-slug>.md\`, per SCHEMA.md — and
point the project document at it with \`objective:\`. A project whose value nobody stated is a
project nobody can cancel.")

  mkdir -p "$INSTANCE_STATE/exits"
  rm -f "$INSTANCE_STATE/exits/$name"
  note "asking the project-manager to draft this ($model${effort:+, effort $effort})…"
  run_box_bg "$name" isolated "$log" "$INSTANCE_STATE/exits/$name" "${claude_args[@]}"
  wait_for_box "$name" "$INSTANCE_STATE/exits/$name" "$log" || true

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
    # `harness do` promotes and drives these itself, so the manual recipe would be noise
    # and, worse, wrong advice.
    if [ "$terse" = 0 ]; then
      echo
      echo "review them, then promote what you approve:"
      printf '%s\n' "$created" | grep '/tasks/' | head -3 | while IFS= read -r t; do
        echo "  sed -i '' 's/^status: draft/status: ready/' $INSTANCE/$t"
      done
      echo
      echo "or let the harness drive them:  claude-box harness do --resume"
    fi
  else
    echo "no new documents — read the log; it may have amended an existing task or asked you a question"
  fi
  rm -f "$before" "$after"
}

# --- answering the PM's questions ---------------------------------------------
# A blocking question is the one thing in the pipeline only a human can clear, so it gets
# a prompt rather than an instruction to hand-edit YAML. The answer is appended to the
# question's own line, in the form the project-manager reads on the next pass:
#
#   "Q1: which region? --- eu-central-1"
#
# Editing a multi-line flow array by hand is exactly the fiddly, easy-to-corrupt work a
# tool should do, so this rewrites the item in place and leaves the formatting alone.
answer_write() {
  local file="$1" index="$2" answer="$3"
  python3 - "$file" "$index" "$answer" <<'PY_ANSWER'
import re, sys
path, index, answer = sys.argv[1], int(sys.argv[2]), sys.argv[3]
text = open(path, errors="replace").read()
if not text.startswith("---"):
    raise SystemExit("not a frontmatter document")
end = text.index("\n---", 3)
front, body = text[:end], text[end:]

match = re.search(r"^open_questions:[ \t]*", front, re.M)
if not match:
    raise SystemExit("no open_questions")
rest = front[match.end():]
if not rest.lstrip().startswith("["):
    # A BLOCK list: `open_questions:` alone, then indented `- item` lines. Same job as the
    # flow branch below — rewrite the Nth item in place — but the item boundaries are lines
    # rather than commas. Refusing this shape meant an answer to a block-form question was
    # silently dropped, and the task stayed blocked on a question you had already answered.
    base, spans, pos = match.end(), [], match.end()
    for line in front[base:].splitlines(True):
        if line.strip() and not line[:1].isspace():
            break                       # dedented: the next frontmatter key
        if line.strip().startswith("- "):
            lead = len(line) - len(line.lstrip())
            spans.append((pos + lead + 2, pos + len(line.rstrip("\n"))))
        pos += len(line)
    if index < 1 or index > len(spans):
        raise SystemExit("no question %d" % index)
    a, b = spans[index - 1]
    stripped = front[a:b].strip()
    clean = answer.replace('"', "'").strip()
    if stripped[:1] in "\"'" and stripped[-1:] == stripped[:1] and len(stripped) > 1:
        q, inner = stripped[:1], stripped[1:-1].rstrip()
        replacement = "%s%s --- %s%s" % (q, inner, clean, q)
    else:
        replacement = "%s --- %s" % (stripped.rstrip(), clean)
    open(path, "w").write(front[:a] + replacement + front[b:] + body)
    raise SystemExit(0)

start = match.end() + rest.index("[")
depth, i = 0, start
while i < len(front):
    if front[i] == "[":
        depth += 1
    elif front[i] == "]":
        depth -= 1
        if depth == 0:
            break
    i += 1
inner_start, inner_end = start + 1, i

# Split the raw inner text into item spans, ignoring commas inside quotes.
spans, cur_start, quote = [], inner_start, None
for j in range(inner_start, inner_end):
    ch = front[j]
    if quote:
        if ch == quote:
            quote = None
    elif ch in "\"'":
        quote = ch
    elif ch == ",":
        spans.append((cur_start, j))
        cur_start = j + 1
spans.append((cur_start, inner_end))
spans = [(a, b) for (a, b) in spans if front[a:b].strip()]

if index < 1 or index > len(spans):
    raise SystemExit("no question %d" % index)
a, b = spans[index - 1]
raw = front[a:b]
stripped = raw.strip()
# A double quote inside a double-quoted YAML scalar would need escaping; a single quote
# reads the same to the project-manager and cannot break the document.
clean = answer.replace('"', "'").strip()
if stripped[:1] in "\"'" and stripped[-1:] == stripped[:1]:
    q = stripped[:1]
    inner = stripped[1:-1].rstrip()
    replacement = raw.replace(stripped, "%s%s --- %s%s" % (q, inner, clean, q), 1)
else:
    replacement = raw.replace(stripped, "%s --- %s" % (stripped.rstrip(), clean), 1)

open(path, "w").write(front[:a] + replacement + front[b:] + body)
PY_ANSWER
}

# Where a prompt reads its reply from. NOT stdin: the task list arrives on stdin, and a
# `read` on stdin would eat the next FILENAME off that list and record it as the answer —
# which is exactly what happened, silently, to real task documents. So the human is read
# from the terminal on a dedicated descriptor, opened ONCE so successive reads advance
# rather than re-reading the first line. Tests point CLAUDE_BOX_TTY at a file.
answer_open() {
  local channel="${CLAUDE_BOX_TTY:-/dev/tty}"
  [ -r "$channel" ] || die "cannot read your answer: $channel is not readable — run this from a terminal"
  exec 3< "$channel"
}
answer_close() { exec 3<&- 2>/dev/null || true; }
answer_read() {
  local line
  IFS= read -r -u 3 line || line=""
  printf '%s' "$line"
}

# Walk every unanswered question and ask it. Returns 0 when nothing is left unanswered.
answer_interactively() {
  local files="$1" t doc n total q reply answered=0 left=0
  # The list becomes an array first, so nothing depends on stdin while we are prompting.
  answer_open
  local list=() line
  local old_ifs="$IFS"; IFS=$'\n'
  for line in $files; do [ -n "$line" ] && list+=("$line"); done
  IFS="$old_ifs"

  for t in ${list[@]+"${list[@]}"}; do
    [ -n "$t" ] || continue
    doc="$INSTANCE/$t"
    total="$(fm_list_count "$doc" open_questions)"
    [ "$total" -gt 0 ] || continue
    echo
    echo "── $t ──"
    n=0
    # Re-read on every iteration: answering shifts nothing, but the file changes on disk.
    while :; do
      n=$((n + 1))
      q="$(fm_list_items "$doc" open_questions | sed -n "${n}p")"
      [ -n "$q" ] || break
      case "$q" in *' --- '*) continue ;; esac      # already answered
      echo
      printf '%s\n' "$q" | fold -s -w 88 | sed 's/^/  /'
      printf '\n  your answer (empty to skip) > '
      reply="$(answer_read)"
      printf '\n' 
      if [ -n "$reply" ]; then
        if answer_write "$doc" "$n" "$reply"; then
          answered=$((answered + 1))
          echo "  recorded"
        else
          note "could not record that answer — edit $doc by hand"
          left=$((left + 1))
        fi
      else
        echo "  skipped — this task stays blocked"
        left=$((left + 1))
      fi
    done
  done
  answer_close
  [ "$answered" -gt 0 ] && note "$answered answer(s) recorded"
  [ "$left" -eq 0 ]
}

cmd_harness_answer() {
  local inst="" project="" task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance|--panel) inst="${2:-}"; shift 2 ;;
      --project)          project="${2:-}"; shift 2 ;;
      --task)             task="${2:-}"; shift 2 ;;
      -*)                 die "unknown flag for 'harness answer': $1" ;;
      *)                  inst="$1"; shift ;;
    esac
  done
  resolve_instance "$inst"

  local files
  if [ -n "$task" ]; then
    files="${task#/}"
  else
    files="$(cd "$INSTANCE" && find "projects${project:+/$project}" -type f -name '*.md' -path '*/tasks/*' 2>/dev/null | sort)"
  fi

  local pending=0 t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ "$(fm_list_count "$INSTANCE/$t" open_questions)" -gt 0 ] && pending=$((pending + 1))
  done <<< "$files"
  if [ "$pending" -eq 0 ]; then
    echo "nothing is waiting on you in $INSTANCE"
    return 0
  fi
  if [ ! -t 0 ]; then
    die "'harness answer' needs a terminal — it asks questions. Run it from your shell."
  fi

  echo "$pending task(s) have questions only you can answer."
  echo "Answers are appended to the question in the task document; the next run folds them in."
  if answer_interactively "$files"; then
    echo
    echo "everything answered — continue with:  claude-box harness do --resume"
  else
    echo
    echo "some questions are still open; those tasks stay blocked until they are answered."
  fi
}

# An answered question is not a cleared question: the answer sits in the entry until the
# project-manager folds it into the task and deletes it. The host deliberately refuses to
# promote a task while any entry remains — an answer may change the work, or cancel it —
# so a resume that skipped the PM would stall forever on answered tasks.
answers_pending() {
  local files="$1" t
  local old_ifs="$IFS"; IFS=$'\n'
  for t in $files; do
    [ -n "$t" ] || continue
    if fm_list_items "$INSTANCE/$t" open_questions | grep -q ' --- '; then
      IFS="$old_ifs"; return 0
    fi
  done
  IFS="$old_ifs"; return 1
}

fold_answers() {
  local files="$1" list model sys effort name log
  list="$(printf '%s\n' "$files" | sed 's|^|- /|')"
  model="$(role_model project-manager)"
  effort="$(role_effort project-manager "$model")"
  sys="$(role_system_prompt project-manager)"
  name="$(unique_name "claude-box-h-$INSTANCE_SLUG-pm-fold")"
  log="$STATE_HOME/logs/$name.log"
  mkdir -p "$INSTANCE_STATE/exits"
  rm -f "$INSTANCE_STATE/exits/$name"

  local claude_args=(claude --permission-mode bypassPermissions --model "$model"
                     --output-format stream-json --verbose)
  [ -n "$effort" ] && claude_args+=(--effort "$effort")
  claude_args+=(--append-system-prompt "$sys" -p "The human has answered open questions on these tasks:

$list

For every entry in an open_questions list that contains ' --- ', the text after the delimiter is the human's answer. For each one:
  1. Fold the answer into the task where it belongs — # Context, acceptance_criteria, or # Notes — so the task is complete without the question.
  2. DELETE that entry from open_questions. No answered-question history is kept.
  3. If the answer says to skip, drop, defer or hand the work to someone else, set that task's status to cancelled and record why in # Notes. Do not implement work the human declined.
  4. If the answer raises a NEW question rather than settling it, leave a fresh numbered entry saying exactly what you still need. Do not invent an answer.
Adjust acceptance_criteria where the answer changes them. Do NOT set any task to ready — promotion is not yours. Then report, per task, what you folded in and what you changed.")

  resolve_target "$INSTANCE"
  EXTRA_RUN_ARGS=(-e IS_SANDBOX=1)
  note "folding your answers in ($model${effort:+, $effort})…"
  run_box_bg "$name" isolated "$log" "$INSTANCE_STATE/exits/$name" "${claude_args[@]}"
  wait_for_box "$name" "$INSTANCE_STATE/exits/$name" "$log" || true
  local why; why="$(box_failure_reason "$log" "$(cat "$INSTANCE_STATE/exits/$name" 2>/dev/null || true)")"
  if [ -n "$why" ]; then
    note "the fold-in box did not do the work: $why"
    tail -4 "$log" 2>/dev/null | sed 's/^/    /'
    return 1
  fi
  note "folded in — log: $log"
  return 0
}

# --- register the stack on GitHub ----------------------------------------------
# Opening a PR with `--base <dependency branch>` gives a correct stacked DIFF, which is the
# part that matters for review. It does not tell GitHub the PRs form a chain — `gh stack view`
# and the stack UI stay empty until someone links them. The host does that, because it is the
# only party that knows the whole chain: each agent only ever sees its own task.
task_chain() {
  # Ordered bottom-to-top: dependencies first, then the task itself. Depth-first, deduped.
  local task="${1#/}" seen="$2" dep
  case " $seen " in (*" $task "*) return 0 ;; esac
  seen="$seen $task"
  local deps; deps="$(fm_list_items "$INSTANCE/$task" depends_on 2>/dev/null)"
  local old_ifs="$IFS"; IFS=$'\n'
  for dep in $deps; do
    dep="${dep#/}"
    [ -f "$INSTANCE/$dep" ] || continue
    IFS="$old_ifs"
    task_chain "$dep" "$seen"
    IFS=$'\n'
  done
  IFS="$old_ifs"
  printf '%s\n' "$task"
}

link_stack() {
  local task="$1" repo="$2"
  local repo_dir="$ROOT/${repo##*/}"
  [ -d "$repo_dir/.git" ] || return 0
  command -v "$GH_BIN" >/dev/null 2>&1 || return 0

  local chain urls="" t pr
  chain="$(task_chain "$task" "" | awk '!seen[$0]++')"
  local old_ifs="$IFS"; IFS=$'\n'
  for t in $chain; do
    pr="$(fm_list_items "$INSTANCE/$t" pr | head -1)"
    [ -n "$pr" ] && urls="$urls $pr"
  done
  IFS="$old_ifs"

  # One PR is not a stack.
  local count; count="$(printf '%s\n' $urls | grep -c . || true)"
  [ "${count:-0}" -ge 2 ] || return 0

  note "  linking $count PRs into a stack on GitHub"
  if ( cd "$repo_dir" && "$GH_BIN" stack link $urls >/dev/null 2>&1 ); then
    note "    stacked: $(printf '%s ' $urls | sed 's|https://[^ ]*/pull/|#|g')"
  else
    note "    gh stack link failed — the PR bases are still correct, only the stack view is missing"
  fi
}

# --- the human closes work out --------------------------------------------------
# `done` is terminal: harness.sh's own reset keeps it, so no command here can undo one. It is
# also the one status whose evidence lives outside the panel — a merge button on GitHub, often
# pressed by someone who is not running this harness. So the human says it, from whatever state
# the document is in, and the host's job is to RECORD what was true at that moment rather than
# to argue: every PR is looked up and the answer goes into `# Notes` verbatim, merged or not.
# A done that carries "PR #12 was OPEN when this was marked" cannot mislead anyone later.
task_append_note() {
  local doc="$1" line="$2"
  python3 - "$doc" "$line" <<'PY_NOTE'
import sys
path, line = sys.argv[1], sys.argv[2]
text = open(path, errors="replace").read().rstrip("\n")
if "\n# Notes" in text or text.startswith("# Notes"):
    text += "\n\n" + line
else:
    text += "\n\n# Notes\n\n" + line
open(path, "w").write(text + "\n")
PY_NOTE
}

cmd_harness_done() {
  local inst="" target="" nopr=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance|--panel) inst="${2:-}"; shift 2 ;;
      --no-pr)            nopr=1; shift ;;
      -*)                 die "unknown flag for 'harness done': $1" ;;
      *)                  if [ -z "$target" ]; then target="$1"; else inst="$1"; fi; shift ;;
    esac
  done
  [ -n "$target" ] || die "'harness done' needs a task path, a project path, or a project slug"
  resolve_instance "$inst"

  # A bare project slug is what the dashboard's project table has to offer, so accept it.
  case "$target" in
    (*/*|*.md) ;;
    (*) [ -f "$INSTANCE/projects/$target/project.md" ] && target="projects/$target/project.md" ;;
  esac

  # Every refusal below RETURNS. This is reachable from the dashboard, where a die would take
  # the request down with nothing to show the human what stopped it.
  local doc
  doc="$(python3 - "$INSTANCE" "$target" <<'PY_RESOLVE'
import os, sys
inst = os.path.realpath(sys.argv[1])
doc = os.path.realpath(os.path.join(inst, sys.argv[2].lstrip("/")))
print(doc if doc.startswith(inst + os.sep) and os.path.isfile(doc) else "")
PY_RESOLVE
)"
  [ -n "$doc" ] || { note "not a document in this panel: $target"; return 1; }

  local kind
  if grep -q '^type: *Task' "$doc"; then kind=task
  elif grep -q '^type: *Project' "$doc"; then kind=project
  else note "not a Task or Project document: $target"; return 1
  fi

  local st; st="$(task_status "$doc")"
  [ "$st" = done ] && { echo "  ${target} is already done"; return 0; }

  # No status gate. Whatever state the document is in, the human is allowed to close it out —
  # what state it was in goes on the record instead of into a refusal.
  local evidence="was $st"
  if [ "$kind" = project ]; then
    local open_tasks
    open_tasks="$(find "$INSTANCE/$(dirname "${doc#"$INSTANCE"/}")/tasks" -type f -name '*.md' 2>/dev/null \
                  | while IFS= read -r f; do
                      case "$(task_status "$f")" in (done|cancelled) ;; (*) printf '%s ' "$(basename "$f")" ;; esac
                    done)"
    if [ -n "$open_tasks" ]; then
      evidence="$evidence; tasks not terminal at the time: ${open_tasks% }"
      note "note: these tasks are not done or cancelled — ${open_tasks% }"
    else
      evidence="$evidence; every task done or cancelled"
    fi
  elif [ "$nopr" = 1 ]; then
    evidence="$evidence; merges not checked (--no-pr)"
  else
    local prs; prs="$(fm_list_items "$doc" pr)"
    if [ -z "$prs" ]; then
      evidence="$evidence; no PR on this task"
    elif ! command -v "$GH_BIN" >/dev/null 2>&1; then
      evidence="$evidence; gh not on PATH, so the merges were never checked"
      note "gh is not on PATH — recording the merges as unchecked"
    else
      local p state merged=0 unmerged=""
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        state="$("$GH_BIN" pr view "$p" --json state --jq .state 2>/dev/null | tr -d '[:space:]')"
        printf '  %-60s %s\n' "$p" "${state:-unknown}"
        case "$state" in
          (MERGED) merged=$((merged + 1)) ;;
          (*)      unmerged="$unmerged$p ${state:-unknown}, " ;;
        esac
      done <<< "$prs"
      if [ -n "$unmerged" ]; then
        evidence="$evidence; NOT every PR was merged — ${unmerged%, }"
        note "recording that these PRs were not merged: ${unmerged%, }"
      else
        evidence="$evidence; $merged PR(s) merged, checked against gh"
      fi
    fi
  fi

  set_task_field "$doc" status done
  task_append_note "$doc" "A human marked this done on $(date +%Y-%m-%dT%H:%M:%SZ) — $evidence."
  echo "  ${target} is done ($evidence)"
  return 0
}

cmd_harness_stack() {
  local inst="" project="" task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance|--panel) inst="${2:-}"; shift 2 ;;
      --project)          project="${2:-}"; shift 2 ;;
      --task)             task="${2#/}"; shift 2 ;;
      -*)                 die "unknown flag for 'harness stack': $1" ;;
      *)                  inst="$1"; shift ;;
    esac
  done
  resolve_instance "$inst"

  local files t repo
  if [ -n "$task" ]; then
    files="$task"
  else
    files="$(cd "$INSTANCE" && find "projects${project:+/$project}" -type f -name '*.md' -path '*/tasks/*' 2>/dev/null | sort)"
  fi
  # Link from the deepest task that has a PR: linking the tip covers everything below it.
  local best="" best_depth=0 depth
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ "$(fm_list_count "$INSTANCE/$t" pr)" -gt 0 ] || continue
    depth="$(task_chain "$t" "" | awk '!seen[$0]++' | grep -c . || true)"
    if [ "${depth:-0}" -gt "$best_depth" ]; then best="$t"; best_depth="$depth"; fi
  done <<< "$files"

  [ -n "$best" ] || { echo "no task in scope has a pull request yet"; return 0; }
  repo="$(task_field "$INSTANCE/$best" target_repo)"
  echo "linking the stack that ends at $best"
  link_stack "$best" "$repo"
}

# --- a finished draft becomes ready for review ----------------------------------
# The draft flag means "not finished yet". Once qa has approved, the architect has not objected
# and CI is not failing, the change IS finished as far as any agent can take it — leaving it a
# draft hides completed work behind a flag nobody clears. Roles must not do this (they would
# mark their own work ready), so the host does it, and only when every condition is checkable.
pr_ready_if_finished() {
  local task="$1" repo="$2" doc="$INSTANCE/${task#/}"
  command -v "$GH_BIN" >/dev/null 2>&1 || return 0
  # Terminal states are decisions: a cancelled task with an approved draft PR must not be
  # revived into in-progress or in-review by a gate that only exists for live work.
  case "$(task_status "$doc")" in (done|cancelled) return 0 ;; esac

  local qa arch pr state draft checks
  qa="$(task_field "$doc" qa)"
  arch="$(task_field "$doc" arch)"
  [ "$qa" = approved ] || return 0
  [ "$arch" = changes-requested ] && return 0
  # Approved work that does not merge is not finished work. Marking it ready for review sends a
  # human to a PR GitHub will refuse — and it was silent about it.
  task_merge_state "$doc" "${task#/}" "$repo"
  if [ "$PR_MERGE_STATE" = CONFLICTING ]; then
    set_task_field "$doc" status in-progress
    note "    $(basename "$doc"): approved but CONFLICTING against ${PR_MERGE_BASE:-its base} — left as work, not review"
    return 0
  fi

  pr="$(fm_list_items "$doc" pr | head -1)"
  [ -n "$pr" ] || return 0

  state="$("$GH_BIN" pr view "$pr" --json state,isDraft --jq '.state + " draft=" + (.isDraft|tostring)' 2>/dev/null || true)"
  case "$state" in
    (*"draft=true"*) ;;
    (*) return 0 ;;                      # already ready for review, or not open
  esac
  case "$state" in (OPEN*) ;; (*) return 0 ;; esac

  # A failing check means it is not finished, whatever the review said.
  checks="$("$GH_BIN" pr checks "$pr" --json state --jq '[.[].state] | join(",")' 2>/dev/null || true)"
  case "$checks" in
    (*FAILURE*|*ERROR*|*CANCELLED*|*TIMED_OUT*|*ACTION_REQUIRED*)
      note "    $pr stays a draft — CI is failing"; return 0 ;;
  esac

  if "$GH_BIN" pr ready "$pr" >/dev/null 2>&1; then
    note "    marked $pr ready for review (qa approved, CI not failing)"
    case "$(task_status "$doc")" in
      (in-review) ;;
      (*) set_task_field "$doc" status in-review ;;
    esac
  else
    note "    could not mark $pr ready for review"
  fi
}

# --- status transitions the host can observe ------------------------------------
# Asking the role to set `status: in-progress` when it starts made the board a matter of
# whether an agent remembered a bookkeeping step — and it frequently did not, so a task
# being worked on still read `ready`, and a finished one still read `in-progress`. The host
# knows when it launched a box and what the document says afterwards, so the host writes the
# transitions it can VERIFY. The role keeps the ones that need judgement: blocked, and the
# qa/arch verdicts.
set_task_field() {
  local doc="$1" key="$2" value="$3"
  python3 - "$doc" "$key" "$value" <<'PY_SET'
import re, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, errors="replace").read()
end = text.index("\n---", 3) if text.startswith("---") else -1
if end < 0:
    raise SystemExit(0)
front, body = text[:end], text[end:]
if re.search(r"^%s:" % re.escape(key), front, re.M):
    front = re.sub(r"^%s:.*$" % re.escape(key), "%s: %s" % (key, value), front, count=1, flags=re.M)
else:
    front = front.rstrip("\n") + "\n%s: %s" % (key, value)
open(path, "w").write(front + body)
PY_SET
}

# Called when a box is launched for a task.
task_mark_working() {
  local doc="$1" role="$2" box="$3"
  # Any role starting on untouched work moves it off the shelf.
  case "$(task_status "$doc")" in
    (ready|draft) set_task_field "$doc" status in-progress ;;
  esac
  # An implementer dispatched at a BLOCKED task — the whole point of resuming one — means
  # that task is being built right now. Leaving it blocked made the board claim nothing was
  # happening while lead-dev worked, and left last attempt's reason on the card. A reviewer
  # is the exception: it reads an in-review task, so it must not claim to be building it.
  case "$role" in
    (qa-reviewer|architect|cataloguer|project-manager) ;;
    (*)
      case "$(task_status "$doc")" in
        (blocked|in-review)
          set_task_field "$doc" status in-progress
          [ -n "$(task_field "$doc" blocked_reason)" ] && set_task_field "$doc" blocked_reason ""
          ;;
      esac ;;
  esac
  # NOT assignee: that is the project-manager's routing decision, and overwriting it with
  # whichever role happens to be running rewrote the routing — after a design review the
  # pipeline then dispatched `architect` again instead of the implementer. `box` records who
  # is working right now; `assignee` records who the work belongs to.
  set_task_field "$doc" box "$box"
  set_task_field "$doc" started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# Called after the box exits: reconcile what the document claims against what exists.
task_reconcile() {
  local doc="$1" code="$2" prs status
  prs="$(fm_list_count "$doc" pr)"
  status="$(task_status "$doc")"
  set_task_field "$doc" box ""
  # A PR exists and nobody said otherwise: it is in review, draft or not.
  if [ "$prs" -gt 0 ] && [ "$status" = in-progress ]; then
    set_task_field "$doc" status in-review
    return 0
  fi
  # No PR and the box is gone: it is not "in progress" any more, whatever it says.
  if [ "$prs" -eq 0 ] && [ "$status" = in-progress ]; then
    local tries; tries="$(task_field "$doc" attempts)"; tries="${tries:-0}"
    case "$tries" in (''|*[!0-9]*) tries=0 ;; esac
    case "$code" in
      (0) set_task_field "$doc" status ready
          note "    no PR was opened — task returned to ready" ;;
      # A clock is not a verdict. A timeout, a stop (143) or a kill (137) says nothing about
      # whether the work is possible — the worktree still holds everything the box did — so
      # the task stays in-progress and the next --resume carries on where it left off.
      # Only after ATTEMPT_CAP such endings does it become a block worth a human's attention.
      (timeout|stalled|143|137)
          tries=$((tries + 1))
          set_task_field "$doc" attempts "$tries"
          if [ "$tries" -ge "$CLAUDE_BOX_TASK_ATTEMPTS" ]; then
            set_task_field "$doc" status blocked
            set_task_field "$doc" blocked_reason "ran out of time $tries times (last: $code) without opening a pull request"
            note "    $tries timeouts with no PR — task marked blocked"
          else
            set_task_field "$doc" blocked_reason "attempt $tries ended ($code) before a PR — resumable"
            note "    box ran out of time with no PR — left in-progress, resume continues it"
          fi ;;
      (*) set_task_field "$doc" status blocked
          set_task_field "$doc" blocked_reason "the box ended ($code) without opening a pull request"
          note "    box ended $code with no PR — task marked blocked" ;;
    esac
  fi
}

# A block the host wrote because a box stopped early is not a judgement about the work, so
# --resume picks it up again; a block a role reasoned its way to ("needs production creds")
# waits for --retry, i.e. for something about the world to change.
blocked_retryable() {
  case "$(task_field "$1" blocked_reason)" in
    # No reason at all is not a judgement — it is a document nobody finished writing. Neither
    # is the note board_normalise leaves on such a document: stamping it must not change how
    # the task is routed, and for one run it did — t4 was skipped by the same resume that had
    # just stamped it, because the stamp did not match this list.
    (""|"the box ended "*|"ran out of time "*|"attempt "*|"blocked without a stated reason"*) return 0 ;;
    (*) return 1 ;;
  esac
}

# `box:` names the container working a task right now. Stop the run and that name outlives
# the container, so the board keeps showing "working" for a box that no longer exists — and
# the in-flight markers keep counting against the cap. Both are host bookkeeping, so the host
# clears them the moment it can see the container is gone.
clear_dead_box_markers() {
  local t doc name
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    doc="$INSTANCE/$t"
    name="$(task_field "$doc" box)"
    [ -n "$name" ] || continue
    box_is_running "$name" && continue
    set_task_field "$doc" box ""
    note "  ${t}: cleared box $name — that container is gone"
  done <<< "$(cd "$INSTANCE" && find projects -type f -name '*.md' -path '*/tasks/*' 2>/dev/null | sort)"
  local m
  for m in "$INSTANCE_STATE/inflight"/*; do
    [ -e "$m" ] || continue
    name="$(cat "$m" 2>/dev/null || true)"
    [ -n "$name" ] && box_is_running "$name" && continue
    rm -f "$m"
  done
  return 0
}

# Documents that contradict themselves stall a board silently: "blocked" with no reason and
# an open pull request is not a block, it is a review nobody moved. Run before gathering
# work, so one pass of the truth the host can see beats a human editing frontmatter.
# Read-only about worktrees and branches — this only rewrites status fields.
board_normalise() {
  local scope="$1" t doc prs
  clear_dead_box_markers
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    doc="$INSTANCE/$t"
    # A verdict that parks work on a human is not one any more: CI is the source of truth.
    case "$(task_field "$doc" qa)" in
      (''|approved|changes-requested) ;;
      (*) set_task_field "$doc" qa changes-requested
          note "  $t: qa verdict handed verification to a human — recorded as changes-requested" ;;
    esac
    [ "$(task_status "$doc")" = blocked ] || continue
    [ -z "$(task_field "$doc" blocked_reason)" ] || continue
    prs="$(fm_list_count "$doc" pr)"
    if [ "$prs" -gt 0 ]; then
      set_task_field "$doc" status in-review
      note "  $t: blocked with no reason but PR open — moved to in-review"
    else
      # Phrased to match blocked_retryable: a note the host wrote is never a verdict.
      set_task_field "$doc" blocked_reason "the box ended without a stated reason"
      note "  $t: blocked with no reason — recorded as unexplained, resume will retry it"
    fi
  done <<< "$(cd "$INSTANCE" && find "$scope" -type f -name '*.md' -path '*/tasks/*' 2>/dev/null | sort)"
  return 0
}

# Does this task's pull request still merge into its base? Neither role noticed that t8 was
# CONFLICTING, and the reason is worth writing down: the worktree was CLEAN. A stacked child
# conflicts against a base that moved, which exists only on GitHub — `git status` in the box
# shows nothing. GitHub also computes `mergeable` LAZILY: it answers UNKNOWN for a few seconds
# after any push, so one look is not an answer. Ask, retry the unknown, and tell the box.
#
# Sets PR_MERGE_STATE to CONFLICTING | MERGEABLE | UNKNOWN | "" (no PR, or no gh).
# A base branch that keeps moving makes every child of it CONFLICTING, and paying an agent a
# round to run `git rebase` is paying for typing. So the host does the mechanical case itself:
# fetch, rebase, force-with-lease. It does NOT do the judgement case — a rebase that hits a real
# conflict is aborted and handed to the box, which is told about it in its prompt.
#
# Three refusals, each one a way this could destroy work:
#   * uncommitted changes in the worktree — rebasing over them loses them
#   * no worktree on the host — nothing to rebase in
#   * --force-with-lease, always — never overwrite a push this host has not seen
CLAUDE_BOX_AUTOREBASE="${CLAUDE_BOX_AUTOREBASE:-1}"

task_autorebase() {
  local task="$1" repo="$2" base="$3"
  [ "$CLAUDE_BOX_AUTOREBASE" = 1 ] || return 1
  [ -n "$repo" ] && [ -n "$base" ] || return 1
  local repo_dir="$ROOT/${repo##*/}" name wt gd
  name="$(worktree_name "$task")"
  wt="$ROOT/_wt/$name"
  gd="$repo_dir/.git/worktrees/$name"
  [ -d "$wt" ] && [ -d "$gd" ] || return 1

  local g=(git --git-dir "$gd" --work-tree "$wt")
  if [ -n "$("${g[@]}" status --porcelain 2>/dev/null)" ]; then
    note "    not rebasing $name automatically — the worktree has uncommitted changes"
    return 1
  fi
  ( cd "$repo_dir" && git fetch --quiet origin "$base" 2>/dev/null ) || true
  if "${g[@]}" rebase --quiet "origin/${base#origin/}" >/dev/null 2>&1; then
    local branch; branch="$("${g[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if ( cd "$wt" && "${g[@]}" push --quiet --force-with-lease origin "HEAD:refs/heads/$branch" >/dev/null 2>&1 ); then
      note "    rebased $name onto origin/${base#origin/} and pushed — the conflict was the base moving"
      return 0
    fi
    note "    rebased $name locally but the push was refused (someone else pushed) — leaving it to the box"
    return 1
  fi
  "${g[@]}" rebase --abort >/dev/null 2>&1 || true
  note "    $name does not rebase cleanly onto origin/${base#origin/} — a real conflict, for the box to resolve"
  return 1
}

# Conflicts a pairwise check cannot see. A stack is merged as a whole, so a task can merge
# cleanly into its own base and still be unmergeable: t8 added
# `.github/workflows/…-playwright-e2e.yml`, t1 further down the stack had already added a
# different version of that exact path, and add/add on one path is a conflict. t8 vs t3 was
# clean the whole time — the wrong question. Ask git to merge against every ancestor branch.
#
# Sets STACK_CONFLICTS to "<branch>: <path> <path>" lines, empty when the stack merges.
STACK_CONFLICTS=""
task_stack_conflicts() {
  local task="${1#/}" repo="$2"
  STACK_CONFLICTS=""
  [ -n "$repo" ] || return 0
  local repo_dir="$ROOT/${repo##*/}" gd="$ROOT/${repo##*/}/.git/worktrees/$(worktree_name "$task")"
  [ -d "$gd" ] || return 0
  local mine; mine="$(branch_for_task "$task")"
  local chain t br out
  chain="$(task_chain "$task" "" | awk '!seen[$0]++')"
  local old_ifs="$IFS"; IFS=$'\n'
  for t in $chain; do
    [ "${t#/}" = "$task" ] && continue
    br="$(branch_for_task "${t#/}")"
    IFS="$old_ifs"
    ( cd "$repo_dir" && git fetch --quiet origin "$br" 2>/dev/null ) || true
    git --git-dir "$gd" rev-parse --verify --quiet "origin/$br" >/dev/null 2>&1 || { IFS=$'\n'; continue; }
    # merge-tree exits non-zero on conflict and names the conflicted paths.
    if ! out="$(git --git-dir "$gd" merge-tree --write-tree --name-only \
                  "origin/$mine" "origin/$br" 2>/dev/null)"; then
      # Drop the tree oid on the first line; the rest are the conflicting paths.
      local paths; paths="$(printf '%s\n' "$out" | awk 'NR>1 { if ($0 == "") exit; print }' | tr '\n' ' ')"
      [ -n "$paths" ] && STACK_CONFLICTS="$STACK_CONFLICTS$br: $paths
"
    fi
    IFS=$'\n'
  done
  IFS="$old_ifs"
  [ -n "$STACK_CONFLICTS" ] && return 1
  return 0
}

PR_MERGE_STATE="" PR_MERGE_BASE=""
task_merge_state() {
  local doc="$1" task="${2:-}" repo="${3:-}" pr tries=0
  PR_MERGE_STATE="" PR_MERGE_BASE=""
  command -v "$GH_BIN" >/dev/null 2>&1 || return 0
  pr="$(fm_list_items "$doc" pr | head -1)"
  [ -n "$pr" ] || return 0

  # Ask git first when we can. GitHub's `mergeable` is recomputed lazily and lagged minutes
  # behind a force-push that had already made the branch merge cleanly — it still said
  # CONFLICTING for a branch whose base was, provably, an ancestor of its head. A base that is
  # an ancestor of the head is the definition of "nothing to conflict with", and it costs a
  # local rev-parse instead of a network round trip.
  if [ -n "$task" ] && [ -n "$repo" ]; then
    local gd="$ROOT/${repo##*/}/.git/worktrees/$(worktree_name "$task")"
    local base; base="$("$GH_BIN" pr view "$pr" --json baseRefName -q .baseRefName 2>/dev/null)"
    if [ -d "$gd" ] && [ -n "$base" ]; then
      PR_MERGE_BASE="$base"
      ( cd "$ROOT/${repo##*/}" && git fetch --quiet origin "$base" 2>/dev/null ) || true
      if git --git-dir "$gd" merge-base --is-ancestor "origin/$base" HEAD 2>/dev/null; then
        PR_MERGE_STATE=MERGEABLE
        return 0
      fi
    fi
  fi
  while [ "$tries" -lt 3 ]; do
    local out; out="$("$GH_BIN" pr view "$pr" --json mergeable,baseRefName \
                        -q '.mergeable + " " + .baseRefName' 2>/dev/null || true)"
    PR_MERGE_STATE="${out%% *}"; PR_MERGE_BASE="${out#* }"
    case "$PR_MERGE_STATE" in
      (CONFLICTING|MERGEABLE) return 0 ;;
      (*) tries=$((tries + 1)); sleep 3 ;;
    esac
  done
  return 0
}

# --- the host creates the worktree ---------------------------------------------
# Letting the role create its own worktree cost a whole run: it put it at
# <repo>/_wt/<name> — INSIDE the monorepo — so six thousand files showed up as untracked on
# main. The path, the base branch and the branch name are all facts the host already knows,
# so the host issues the command. The agent is told where to work, and told not to create
# one.
#
# It still runs INSIDE a box: git stores absolute paths in worktree metadata, so a
# host-created worktree would be unusable by the box that has to work in it.
TASK_WORKTREE="" TASK_BRANCH="" TASK_BASE=""

branch_for_task() {
  local task="$1" doc="$INSTANCE/$1" title slug project stem
  project="$(printf '%s' "${task#/}" | awk -F/ '{ if ($1 == "projects") print $2 }')"
  stem="$(basename "${task%.md}")"
  title="$(task_field "$doc" title)"
  # Name the branch after the change, not the role: a reviewer cares what it does.
  # Short enough to read in a PR list: a few words of the title, not the whole sentence.
  slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' \
            | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//' \
            | cut -c1-28 | sed 's/-[a-z0-9]*$//; s/-$//')"
  printf '%s/%s%s\n' "$(slug "$project")" "$stem" "${slug:+-$slug}"
}

# The branch a task should be built on top of.
#
# `depends_on` is the plan saying "this cannot exist without that". Basing every task on
# origin/<default> anyway produces sibling branches that each re-contain their dependency's
# work, and pull requests that all target main — which is not a stack, just a pile. So: if a
# dependency's branch exists and is not merged yet, build on it and open the PR against it.
task_base_branch() {
  local task="$1" repo_dir="$2" default="$3" dep dep_branch best=""
  local deps; deps="$(fm_list_items "$INSTANCE/${task#/}" depends_on)"
  [ -n "$deps" ] || { printf '%s\n' "origin/$default"; return 0; }

  local old_ifs="$IFS"; IFS=$'\n'
  for dep in $deps; do
    dep="${dep#/}"
    [ -f "$INSTANCE/$dep" ] || continue
    dep_branch="$(branch_for_task "$dep")"
    git -C "$repo_dir" rev-parse --verify --quiet "$dep_branch" >/dev/null 2>&1 || continue
    # A merged dependency is already in the default branch; stacking on it would be noise.
    git -C "$repo_dir" merge-base --is-ancestor "$dep_branch" "origin/$default" 2>/dev/null && continue
    if [ -z "$best" ]; then
      best="$dep_branch"
    elif git -C "$repo_dir" merge-base --is-ancestor "$best" "$dep_branch" 2>/dev/null; then
      # dep_branch already contains best, so it is further up the chain.
      best="$dep_branch"
    fi
  done
  IFS="$old_ifs"
  printf '%s\n' "${best:-origin/$default}"
}

# Sets TASK_WORKTREE (container path), TASK_BRANCH and TASK_BASE, creating the worktree if needed.
ensure_task_worktree() {
  local task="$1" repo="$2" doc="$INSTANCE/$1"
  TASK_WORKTREE="" TASK_BRANCH="" TASK_BASE=""
  [ -n "$repo" ] || return 0
  local repo_dir="$ROOT/${repo##*/}"
  [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ] || {
    note "no clone at $repo_dir — the role will have to sort the repo out itself"; return 0; }

  local name branch host_path ct_path repo_ct base
  name="$(worktree_name "$task")"
  branch="$(branch_for_task "$task")"
  host_path="$ROOT/_wt/$name"
  ct_path="$CONTAINER_WS/_wt/$name"
  repo_ct="$CONTAINER_WS/${repo##*/}"
  TASK_WORKTREE="$ct_path"; TASK_BRANCH="$branch"

  # Check for a stray worktree inside the repo FIRST — it is the failure that matters most,
  # and it must be cleaned whether or not the correct worktree already exists.
  if [ -d "$repo_dir/_wt" ]; then
    note "  removing a stray _wt inside $repo — a worktree must never live inside the repo"
    git -C "$repo_dir" worktree prune 2>/dev/null || true
    # This is the human's repo, so no rm -rf: registered worktrees go through git, which
    # refuses a dirty one, and only empty directories are removed after that.
    local stray
    for stray in "$repo_dir/_wt"/*; do
      [ -e "$stray" ] || continue
      if [ -f "$stray/.git" ]; then git -C "$repo_dir" worktree remove "$stray" >/dev/null 2>&1 || true; fi
      rmdir "$stray" 2>/dev/null || true
    done
    rmdir "$repo_dir/_wt" 2>/dev/null \
      || note "  $repo/_wt still has content (uncommitted work, or files git never registered) — left alone; clean it by hand"
  fi

  if [ -d "$host_path" ]; then
    TASK_BASE="$(task_base_branch "$task" "$repo_dir" \
      "$(b="$(git -C "$repo_dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"; printf '%s' "${b##*/}")")"
    note "  worktree exists: _wt/$name on $branch (base ${TASK_BASE:-origin/HEAD})"
    return 0
  fi

  # Base on the remote's default branch, never on whatever the local clone is parked on.
  base="$(git -C "$repo_dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  base="${base##*/}"
  [ -n "$base" ] || base="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

  # Stack on an unmerged dependency when the plan says this task needs one.
  local start; start="$(task_base_branch "$task" "$repo_dir" "$base")"
  TASK_BASE="$start"
  case "$start" in
    ("origin/$base") note "  creating worktree _wt/$name from origin/$base on branch $branch" ;;
    (*)              note "  creating worktree _wt/$name STACKED on $start (branch $branch)" ;;
  esac
  WORKDIR="$repo_ct"
  local wt_log="$STATE_HOME/harness/$INSTANCE_SLUG/worktree-$name.log"
  mkdir -p "$(dirname "$wt_log")"
  # An existing local branch is a previous attempt whose unpushed commits are what resume
  # continues from — check it out rather than deleting and recreating it from the base.
  if ! box_exec "set -e
    git -C '$repo_ct' fetch --quiet origin '$base' || git -C '$repo_ct' fetch --quiet origin || true
    mkdir -p '$CONTAINER_WS/_wt'
    git -C '$repo_ct' worktree prune || true
    if git -C '$repo_ct' show-ref --verify --quiet 'refs/heads/$branch'; then
      git -C '$repo_ct' worktree add '$ct_path' '$branch'
    else
      git -C '$repo_ct' worktree add -b '$branch' '$ct_path' '$start'
    fi" \
    > "$wt_log" 2>&1; then
    note "  worktree creation failed — see $wt_log"
    tail -3 "$wt_log" | sed 's/^/    /'
  fi

  if [ ! -d "$host_path" ]; then
    note "  worktree was not created at $host_path"
    TASK_WORKTREE=""; TASK_BRANCH=""
    return 1
  fi
  return 0
}

# --- stop everything -----------------------------------------------------------
# `claude-box stop --all` stops BOXES, and the driver then cheerfully dispatches the next
# task — so stopping a run took two commands and knowing that. One command now.
cmd_harness_stop() {
  local inst="" keep_lock=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance|--panel) inst="${2:-}"; shift 2 ;;
      --keep-lock)        keep_lock=1; shift ;;
      -*)                 die "unknown flag for 'harness stop': $1" ;;
      *)                  inst="$1"; shift ;;
    esac
  done
  resolve_instance "$inst"

  # 1. The drivers first. Killing boxes while a driver lives just starts the next task.
  local drivers
  drivers="$(pgrep -f 'claude-box harness (do|loop|tick)' 2>/dev/null || true)"
  if [ -n "$drivers" ]; then
    printf '%s\n' "$drivers" | while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      [ "$pid" = "$$" ] && continue
      kill "$pid" 2>/dev/null && note "stopped driver pid $pid"
    done
    sleep 1
  else
    note "no driver running"
  fi

  # 2. Then this panel's boxes.
  local names stopped=0 name
  names="$(engine_running_boxes | grep "^claude-box-h-$INSTANCE_SLUG-" || true)"
  if [ -n "$names" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      engine_stop_box "$name" && note "stopped $name"
      stopped=$((stopped + 1))
    done <<< "$names"
  fi
  [ "$stopped" = 0 ] && note "no boxes were running for this panel"

  # 3. A lock whose loop we just killed would block the next run.
  if [ "$keep_lock" = 0 ] && [ -f "$INSTANCE_STATE/lock/owner" ]; then
    local pid; pid="$(awk '{print $1}' "$INSTANCE_STATE/lock/owner" 2>/dev/null || true)"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$INSTANCE_STATE/lock"
      note "released the loop lock"
    fi
  fi

  # The containers are gone; the documents must stop claiming otherwise.
  clear_dead_box_markers

  echo
  echo "stopped. in-flight work is left where it is — resume with:"
  echo "  claude-box harness do --resume"
}

# --- history retention ---------------------------------------------------------
# Runs, box logs, per-box config dirs and the numbers derived from them (activity, cost by
# role) accumulate forever otherwise. They are diagnostics, not records — the record is the
# panel's documents and git. Kept for a week by default, purgeable on demand.
CLAUDE_BOX_HISTORY_DAYS="${CLAUDE_BOX_HISTORY_DAYS:-7}"

# prune_history <days> [--dry-run] — never touches a running box's files.
prune_history() {
  local days="${1:-$CLAUDE_BOX_HISTORY_DAYS}" dry="${2:-}"
  local cutoff running removed=0 f name
  case "$days" in ''|*[!0-9]*) days=7 ;; esac
  cutoff=$(( $(date +%s) - days * 86400 ))
  running="$(engine_running_boxes || true)"

  is_running() { printf '%s\n' "$running" | grep -qx "$1"; }

  # box logs
  for f in "$STATE_HOME/logs"/claude-box-*.log; do
    [ -f "$f" ] || continue
    name="$(basename "${f%.log}")"
    is_running "$name" && continue
    [ "$(file_mtime "$f")" -lt "$cutoff" ] || continue
    if [ "$dry" = "--dry-run" ]; then echo "  would remove log $name"; else rm -f "$f"; fi
    removed=$((removed + 1))
  done

  # per-box config dirs — each is a seeded ~/.claude, so these are the bulky ones
  for f in "$STATE_HOME/boxes"/*; do
    [ -d "$f" ] || continue
    name="$(basename "$f")"
    is_running "$name" && continue
    [ "$(file_mtime "$f")" -lt "$cutoff" ] || continue
    # The dir may hold the newest refresh token on this host; carry it back before it goes.
    if [ "$dry" = "--dry-run" ]; then echo "  would remove box dir $name"; else reclaim_credentials "$name"; rm -rf "$f"; fi
    removed=$((removed + 1))
  done

  # runs (ticks and `do` runs), and the exit records
  local base
  for base in "$STATE_HOME/harness"/*/ ; do
    [ -d "$base" ] || continue
    for f in "$base"ticks/*; do
      [ -d "$f" ] || continue
      [ "$(file_mtime "$f")" -lt "$cutoff" ] || continue
      if [ "$dry" = "--dry-run" ]; then echo "  would remove run $(basename "$f")"; else rm -rf "$f"; fi
      removed=$((removed + 1))
    done
    for f in "$base"exits/*; do
      [ -f "$f" ] || continue
      is_running "$(basename "$f")" && continue
      [ "$(file_mtime "$f")" -lt "$cutoff" ] || continue
      [ "$dry" = "--dry-run" ] || rm -f "$f"
    done
  done
  printf '%s\n' "$removed"
}

cmd_harness_purge() {
  local inst="" days="$CLAUDE_BOX_HISTORY_DAYS" all=0 yes=0 dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --days)             days="${2:-}"; shift 2 ;;
      --all)              all=1; shift ;;
      --dry-run)          dry=1; shift ;;
      -y|--yes)           yes=1; shift ;;
      --instance|--panel) inst="${2:-}"; shift 2 ;;
      -*)                 die "unknown flag for 'harness purge': $1" ;;
      *)                  inst="$1"; shift ;;
    esac
  done
  resolve_instance "$inst"
  [ "$all" = 1 ] && days=0

  if [ "$dry" = 1 ]; then
    echo "history older than ${days} day(s) — dry run:"
    prune_history "$days" --dry-run
    return 0
  fi

  echo "This removes box logs, per-box config dirs and run records older than ${days} day(s)"
  echo "from $STATE_HOME. Diagnostics only — your panel documents, git history and PRs are"
  echo "untouched, and a running box's files are skipped."
  if [ "$yes" != 1 ]; then
    if [ ! -t 0 ]; then die "refusing to purge non-interactively without -y"; fi
    printf 'Proceed? [y/N] '
    local reply; answer_open; reply="$(answer_read)"; answer_close; printf '\n'
    case "$reply" in (y|Y|yes|YES) ;; (*) echo "aborted"; return 1 ;; esac
  fi
  local n; n="$(prune_history "$days")"
  echo "purged $n item(s)"
}

# --- clean: throw the attempts away and start over -----------------------------
# When the conventions change — a branch naming scheme, a policy about when a PR gets
# opened — half-finished attempts are worth less than the confusion they cause. This
# removes the worktrees and branches and resets the task documents to `ready`, keeping the
# parts a human authored: the criteria, the answers, the questions.
cmd_harness_clean() {
  local inst="" project="" task="" yes=0 keep_remote=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance|--panel) inst="${2:-}"; shift 2 ;;
      --project)          project="${2:-}"; shift 2 ;;
      --task)             task="${2#/}"; shift 2 ;;
      -y|--yes)           yes=1; shift ;;
      --delete-remote)    keep_remote=0; shift ;;
      -*)                 die "unknown flag for 'harness clean': $1" ;;
      *)                  inst="$1"; shift ;;
    esac
  done
  resolve_instance "$inst"
  ensure_daemon

  local files
  if [ -n "$task" ]; then
    files="$task"
  else
    files="$(cd "$INSTANCE" && find "projects${project:+/$project}" -type f -name '*.md' -path '*/tasks/*' 2>/dev/null | sort)"
  fi
  [ -n "$files" ] || { echo "nothing to clean"; return 0; }

  # A box still holding one of these would keep writing into a worktree we are deleting.
  local running; running="$(engine_running_boxes | grep "^claude-box-h-$INSTANCE_SLUG-" || true)"
  [ -n "$running" ] && die "these boxes are still running — 'claude-box stop --all' first:
$(printf '%s\n' "$running" | sed 's/^/  /')"

  echo "About to discard work in progress on $INSTANCE:"
  local t doc wt_name repo_dir branch
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    doc="$INSTANCE/$t"
    wt_name="$(worktree_name "$t")"
    printf '  %-46s %-12s' "$t" "$(task_status "$doc")"
    [ -d "$ROOT/_wt/$wt_name" ] && printf ' worktree' || printf '         '
    printf '\n'
  done <<< "$files"
  echo
  echo "It removes the worktrees and local branches, clears pr:/qa: and the # Result"
  echo "section, and resets each task to ready. Criteria, questions and your answers stay."
  [ "$keep_remote" = 1 ] && echo "Remote branches are LEFT ALONE (--delete-remote to remove them too)."
  if [ "$yes" != 1 ]; then
    if [ ! -t 0 ]; then die "refusing to discard work non-interactively without -y"; fi
    printf 'Proceed? [y/N] '
    local reply; answer_open; reply="$(answer_read)"; answer_close; printf '\n'
    case "$reply" in (y|Y|yes|YES) ;; (*) echo "aborted"; return 1 ;; esac
  fi

  # Reset the DOCUMENTS first: it is instant, and it is what you need to start over. Then do
  # the filesystem work, which on a monorepo worktree means deleting ~200k files and can
  # take minutes — you should not be waiting on that to see a clean board.
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    python3 - "$INSTANCE/$t" <<'PY_RESET'
import re, sys
path = sys.argv[1]
text = open(path, errors="replace").read()
end = text.index("\n---", 3) if text.startswith("---") else -1
front, body = (text[:end], text[end:]) if end > 0 else (text, "")
# Terminal states are decisions, not attempts: a task you cancelled must stay cancelled,
# and a done task must not be rebuilt. Only in-flight attempts reset.
status = re.search(r"^status: *(.*)$", front, re.M)
if status and status.group(1).strip() in ("cancelled", "done"):
    print("kept %s at %s" % (path, status.group(1).strip()))
    raise SystemExit(0)
front = re.sub(r"^status: .*$", "status: ready", front, count=1, flags=re.M)
front = re.sub(r"^assignee:.*$", "assignee:", front, count=1, flags=re.M)
front = re.sub(r"^qa:.*$", "qa:", front, count=1, flags=re.M)
front = re.sub(r"^pr: \[[^\]]*\]", "pr: [ ]", front, count=1, flags=re.M | re.S)
# A # Result describes an attempt that no longer exists.
body = re.split(r"\n# Result", body)[0]
open(path, "w").write(front + body.rstrip() + "\n")
PY_RESET
  done <<< "$files"
  echo "task documents reset to ready (criteria, questions and your answers kept)"

  # Branches and worktrees.
  local t doc wt_name repo_dir branch legacy
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    doc="$INSTANCE/$t"
    wt_name="$(worktree_name "$t")"
    legacy="$(basename "${t%.md}")"
    repo_dir="$ROOT/$(task_field "$doc" target_repo | sed 's|.*/||')"
    [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ] || continue

    for branch in $(git -C "$repo_dir" branch --format='%(refname:short)' 2>/dev/null \
                      | grep -E "(^|/)$legacy(-|$)" || true); do
      git -C "$repo_dir" branch -D "$branch" >/dev/null 2>&1 && note "deleted branch $branch"
      if [ "$keep_remote" = 0 ]; then
        git -C "$repo_dir" push origin --delete "$branch" >/dev/null 2>&1 \
          && note "deleted remote branch $branch"
      fi
    done

    local wt
    for wt in "$wt_name" "$legacy"; do
      [ -d "$ROOT/_wt/$wt" ] || continue
      note "removing worktree _wt/$wt (a monorepo worktree is large; this takes a while)"
      git -C "$repo_dir" worktree remove --force "$ROOT/_wt/$wt" 2>/dev/null \
        || rm -rf "$ROOT/_wt/$wt"
    done
    git -C "$repo_dir" worktree prune 2>/dev/null || true
  done <<< "$files"

  echo
  echo "clean. start over with:  claude-box harness do --resume${project:+ --project $project}"
}

# `clean` discards an ATTEMPT and keeps the task. `delete` removes the documents
# themselves — the one operation the panel had no way to undo by hand without leaving
# dangling index links and orphaned worktrees behind.
#
# The panel is often a git repo with nothing committed and no remote, so a deleted
# document is gone for good. Everything therefore moves to a trash directory under the
# instance state by default; --purge is the explicit opt-out.
cmd_harness_delete() {
  local inst="" project="" task="" objective="" yes=0 keep_remote=1 dry=0 purge=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance|--panel) inst="${2:-}"; shift 2 ;;
      --project)          project="${2:-}"; shift 2 ;;
      --task)             task="${2#/}"; shift 2 ;;
      --objective)        objective="${2#/}"; shift 2 ;;
      -y|--yes)           yes=1; shift ;;
      --delete-remote)    keep_remote=0; shift ;;
      --dry-run)          dry=1; shift ;;
      --purge)            purge=1; shift ;;
      -*)                 die "unknown flag for 'harness delete': $1" ;;
      *)                  if [ -z "$inst" ] && [ -d "$1" ]; then inst="$1";
                          elif [ -z "$task" ] && [ -z "$project" ]; then
                            case "$1" in *.md) task="${1#/}" ;; *) project="$1" ;; esac
                          else die "unexpected argument: $1"; fi; shift ;;
    esac
  done
  resolve_instance "$inst"
  ensure_daemon

  local targets=0
  [ -n "$project" ]   && targets=$((targets + 1))
  [ -n "$task" ]      && targets=$((targets + 1))
  [ -n "$objective" ] && targets=$((targets + 1))
  [ "$targets" -eq 0 ] && die "say what to delete: --project <slug>, --task projects/<slug>/tasks/<id>.md, or --objective <slug>"
  [ "$targets" -gt 1 ] && die "--project, --task and --objective are different operations; pass one"

  # A slug is a directory NAME under projects/, never a path. This is the whole
  # containment check for the project case.
  local target_dir="" files=""
  if [ -n "$project" ]; then
    project="$(basename "$project")"
    case "$project" in ""|.|..) die "not a project slug: $project" ;; esac
    target_dir="projects/$project"
    [ -d "$INSTANCE/$target_dir" ] || die "no such project: $target_dir"
    files="$(cd "$INSTANCE" && find "$target_dir" -type f -name '*.md' -path '*/tasks/*' 2>/dev/null | sort)"
  elif [ -n "$objective" ]; then
    # An objective is a single document with no tasks, no worktree and no branch. It is
    # here rather than in its own command because everything that follows — trash, index
    # links, dangling references — is identical.
    objective="$(basename "$objective")"; objective="${objective%.md}"
    case "$objective" in ""|.|..) die "not an objective slug: $objective" ;; esac
    [ -f "$INSTANCE/objectives/$objective.md" ] || die "no such objective: objectives/$objective.md"
  else
    case "$task" in
      projects/*/tasks/*.md) ;;
      *) die "not a task path: $task (want projects/<slug>/tasks/<id>.md)" ;;
    esac
    case "$task" in *..*) die "not a task path: $task" ;; esac
    [ -f "$INSTANCE/$task" ] || die "no such task: $task"
    files="$task"
  fi

  # What is being removed, as one bundle-relative path. Everything below works off this.
  local removed="${target_dir:-${objective:+objectives/$objective.md}}"
  removed="${removed:-$task}"

  # A box still holding one of these would keep writing into a worktree we are removing,
  # and would rewrite the very document we just deleted.
  local running; running="$(engine_running_boxes | grep "^claude-box-h-$INSTANCE_SLUG-" || true)"
  [ -n "$running" ] && die "these boxes are still running — 'claude-box stop --all' first:
$(printf '%s\n' "$running" | sed 's/^/  /')"

  # Anything OUTSIDE what we are deleting that points INTO it. A task whose depends_on
  # names a document that no longer exists never becomes dispatchable, and nothing else
  # in the harness would tell you why.
  # A prefix match, so deleting a project also catches links to its project.md and index.md,
  # not only to its tasks.
  local refs
  refs="$(cd "$INSTANCE" && grep -rlF "/$removed" --include='*.md' projects objectives knowledge 2>/dev/null \
            | grep -v "^$removed" | sort || true)"

  echo "About to delete from $INSTANCE:"
  if [ -n "$project" ]; then
    echo "  $target_dir/  (the whole project directory)"
  elif [ -n "$objective" ]; then
    echo "  $removed  ($(task_field "$INSTANCE/$removed" status))"
  fi
  local t doc wt_name
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    doc="$INSTANCE/$t"
    wt_name="$(worktree_name "$t")"
    printf '  %-46s %-12s' "$t" "$(task_status "$doc")"
    [ -d "$ROOT/_wt/$wt_name" ] && printf ' worktree' || printf '         '
    local prs; prs="$(task_field "$doc" pr | tr -d '[] ')"
    [ -n "$prs" ] && printf ' pr:%s' "$prs"
    printf '\n'
  done <<< "$files"

  if [ -n "$refs" ]; then
    echo
    echo "These documents reference what you are deleting and will be left dangling:"
    printf '%s\n' "$refs" | sed 's/^/  /'
  fi

  echo
  local wt_count=0 t_c
  while IFS= read -r t_c; do
    [ -n "$t_c" ] || continue
    [ -d "$ROOT/_wt/$(worktree_name "$t_c")" ] && wt_count=$((wt_count + 1))
  done <<< "$files"
  if [ "$wt_count" -gt 0 ]; then
    echo "$wt_count worktree(s) go with it. A monorepo worktree is ~200k files, so this"
    echo "takes a minute or two each — the board clears first, the disk work runs after."
  fi
  echo "Open pull requests are NOT touched — close them yourself if they should not land."
  if [ "$purge" = 1 ]; then
    echo "--purge: documents are deleted outright, with no copy kept."
  else
    echo "Documents move to $INSTANCE_STATE/trash/ (--purge to delete outright)."
  fi
  [ "$keep_remote" = 1 ] && echo "Remote branches are LEFT ALONE (--delete-remote to remove them too)."

  if [ "$dry" = 1 ]; then echo; echo "--dry-run: nothing was deleted"; return 0; fi

  # A whole project is worth more than a y/N. Typing the slug is the difference between
  # confirming a thing and confirming a prompt.
  if [ "$yes" != 1 ]; then
    if [ ! -t 0 ]; then die "refusing to delete non-interactively without -y"; fi
    local reply; answer_open
    if [ -n "$project" ]; then
      printf 'Type the project slug to confirm (%s): ' "$project"
      reply="$(answer_read)"; answer_close; printf '\n'
      [ "$reply" = "$project" ] || { echo "aborted"; return 1; }
    else
      printf 'Proceed? [y/N] '
      reply="$(answer_read)"; answer_close; printf '\n'
      case "$reply" in (y|Y|yes|YES) ;; (*) echo "aborted"; return 1 ;; esac
    fi
  fi

  # Read what the filesystem cleanup needs BEFORE the documents move: target_repo lives in
  # the frontmatter, and it is gone once the document is in the trash.
  local legacy repo_dir branch wt plan
  plan="$(mktemp "${TMPDIR:-/tmp}/cb-delete.XXXXXX")"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    doc="$INSTANCE/$t"
    repo_dir="$ROOT/$(task_field "$doc" target_repo | sed 's|.*/||')"
    printf '%s\t%s\t%s\n' "$(worktree_name "$t")" "$(basename "${t%.md}")" "$repo_dir" >> "$plan"
  done <<< "$files"

  # The documents. These move FIRST: it is instant, and it is what makes the board correct.
  # The filesystem work below can take minutes per monorepo worktree, and nobody should be
  # staring at a project that is already deleted while it runs.
  if [ "$purge" = 1 ]; then
    rm -rf "${INSTANCE:?}/$removed"
    echo "deleted $removed"
  else
    local stamp trash; stamp="$(date +%Y%m%d-%H%M%S)"
    trash="$INSTANCE_STATE/trash/$stamp"
    mkdir -p "$trash/$(dirname "$removed")"
    mv "$INSTANCE/$removed" "$trash/$removed"
    echo "deleted $removed"
    echo "a copy is in $trash — restore with:"
    echo "  cp -R '$trash/$removed' '$INSTANCE/$removed'"
  fi

  # Index listings. An index.md line is `* [Title](/path/to/doc.md) - description`, so a
  # link to a document that no longer exists is a dead row on the board.
  local idx
  while IFS= read -r idx; do
    [ -n "$idx" ] || continue
    python3 - "$INSTANCE/$idx" "$removed" <<'PY_INDEX'
import sys
path, gone = sys.argv[1], sys.argv[2]
lines = open(path, errors="replace").read().splitlines(True)
kept = [ln for ln in lines if ("(/%s" % gone) not in ln and ("(%s" % gone) not in ln]
if len(kept) != len(lines):
    open(path, "w").write("".join(kept))
    print("  dropped %d link(s) from %s" % (len(lines) - len(kept), path))
PY_INDEX
  done <<< "$(cd "$INSTANCE" && find . -name 'index.md' -not -path './.git/*' 2>/dev/null | sed 's|^\./||' | sort)"

  # Now the slow part, off the plan captured before the documents moved.
  while IFS=$'\t' read -r wt_name legacy repo_dir; do
    [ -n "$wt_name" ] || continue
    [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ] || continue
    for wt in "$wt_name" "$legacy"; do
      [ -d "$ROOT/_wt/$wt" ] || continue
      note "removing worktree _wt/$wt (a monorepo worktree is large; this takes a while)"
      git -C "$repo_dir" worktree remove --force "$ROOT/_wt/$wt" 2>/dev/null \
        || rm -rf "$ROOT/_wt/$wt"
    done
    git -C "$repo_dir" worktree prune 2>/dev/null || true

    # After the worktree is gone: a branch checked out in one cannot be deleted.
    for branch in $(git -C "$repo_dir" branch --format='%(refname:short)' 2>/dev/null \
                      | grep -E "(^|/)$legacy(-|$)" || true); do
      git -C "$repo_dir" branch -D "$branch" >/dev/null 2>&1 && note "deleted branch $branch"
      if [ "$keep_remote" = 0 ]; then
        git -C "$repo_dir" push origin --delete "$branch" >/dev/null 2>&1 \
          && note "deleted remote branch $branch"
      fi
    done
  done < "$plan"
  rm -f "$plan"

  # Recomputed, not the list from before: the index pass above has already repaired every
  # link it owns, and naming those again sends you to look at a file that is already correct.
  refs="$(cd "$INSTANCE" && grep -rlF "/$removed" --include='*.md' projects objectives knowledge 2>/dev/null \
            | grep -v "^$removed" | sort || true)"
  if [ -n "$refs" ]; then
    echo
    echo "Still referencing what you deleted — fix these by hand:"
    printf '%s\n' "$refs" | sed 's/^/  /'
  fi
}

# The worktree directory for a task: project-scoped, because task ids repeat.
worktree_name() {
  local path="${1#/}" project stem
  stem="$(basename "${path%.md}")"
  project="$(printf '%s' "$path" | awk -F/ '{ if ($1 == "projects") print $2 }')"
  if [ -n "$project" ]; then printf '%s-%s\n' "$(slug "$project")" "$stem"; else printf '%s\n' "$stem"; fi
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
  # resolve_target FIRST: ensure_task_worktree runs a housekeeping box, and box_exec needs
  # MOUNT_SRC/WORKDIR set or it mounts nothing and every git command inside fails.
  resolve_target "$INSTANCE"
  ensure_task_worktree "$task" "$repo" || true
  model="$(role_model "$role")"
  effort="$(role_effort "$role" "$model")"
  sys="$(role_system_prompt "$role" "$repo")"
  name="$(unique_name "claude-box-h-$INSTANCE_SLUG-$(slug "$role")-$(slug "$(basename "${task%.md}")")")"
  log="$STATE_HOME/logs/$name.log"
  mkdir -p "$INSTANCE_STATE/exits" "$INSTANCE_STATE/inflight"
  rm -f "$INSTANCE_STATE/exits/$name"
  printf '%s\n' "$name" > "$INSTANCE_STATE/inflight/$(task_key "$task")"

  # No subagents in a role box. A subagent's output is a file the parent then waits for, and
  # a box that waits is a box burning its budget: one lead-dev spent eleven minutes in
  # `until [ -f <task output> ]`. The box IS the unit of parallelism here — the host runs
  # several of them — so the tool buys nothing and costs runs.
  local claude_args=(claude --permission-mode bypassPermissions --model "$model"
                     --output-format stream-json --verbose --disallowed-tools Task)
  [ -n "$effort" ] && claude_args+=(--effort "$effort")
  local where=""
  if [ -n "$TASK_WORKTREE" ]; then
    where="

Your worktree has already been created for you:
  path:   $TASK_WORKTREE
  branch: $TASK_BRANCH  (already checked out)
  base:   ${TASK_BASE:-the remote default branch}
Work THERE. Do not create another worktree, do not create another branch, and never place
a worktree inside the repository itself — that turns the whole checkout into untracked
files on the human's main branch.

Your branch is based on \`${TASK_BASE:-the default branch}\`. If that is NOT the repository's
default branch, this is a STACKED pull request: open it with \`gh pr create --base ${TASK_BASE#origin/}\`
so the diff shows only your change, and say in the body which PR it sits on top of. Opening it
against the default branch instead would show your dependency's work as if it were yours, which
is what makes a stack look like a pile."
  fi
  task_merge_state "$INSTANCE/$task" "$task" "$repo"
  # Mechanical first: if the only problem is that the base moved, fix it here and re-ask.
  if [ "$PR_MERGE_STATE" = CONFLICTING ] \
     && task_autorebase "$task" "$repo" "${PR_MERGE_BASE:-${TASK_BASE#origin/}}"; then
    # git just replayed this branch onto its base with no conflict, which settles the question
    # more authoritatively than GitHub's lazily-recomputed field — that still answers with the
    # pre-push value for a while, and warning the box about a conflict it no longer has would
    # send it looking for something that is not there.
    PR_MERGE_STATE=MERGEABLE
  fi
  local conflict=""
  if ! task_stack_conflicts "$task" "$repo"; then
    conflict="

## Your branch does not merge as part of its stack

Merging your branch against the other branches in this stack conflicts:

$(printf '%s' "$STACK_CONFLICTS" | sed 's/^/    /')

This is why your own base merges clean and GitHub still refuses: a stack is merged as a whole,
so two branches adding the SAME path with different content collide even when neither conflicts
with its own base.

**Shared infrastructure belongs to one task — the lowest one in the stack that needs it.** A CI
workflow, a fixture directory, a shared helper: if a branch below yours already adds that file,
do not add your own copy. Rebase onto it so you inherit it, and if it needs a change, make the
change there if that branch is yours to touch, or say what change it needs in your PR body. Fix
this before other work: nothing merges until it is gone."
  elif [ "$PR_MERGE_STATE" = CONFLICTING ]; then
    conflict="

## Your pull request does not merge

GitHub reports this task's pull request as CONFLICTING against \`${PR_MERGE_BASE:-its base}\`.
Your worktree is not where this shows up — it can be perfectly clean while the base branch has
moved underneath it, which is normal in a stack. Fix that FIRST, before any other work:

    git fetch origin
    git rebase origin/${PR_MERGE_BASE:-<base>}
    # resolve, then: git push --force-with-lease

A conflicting pull request cannot be merged or reviewed usefully, so nothing else you do this
round counts until it merges cleanly again."
  fi
  claude_args+=(--append-system-prompt "$sys"
                -p "$label${conflict}

Task document: $task (bundle-relative, this panel's root is your working directory).$where
Follow your role definition and the executor rules in your system prompt. Report by updating the task document.")

  resolve_target "$INSTANCE"
  EXTRA_RUN_ARGS=(-e IS_SANDBOX=1)
  note "  → $role on $(basename "$task") ($model${effort:+, $effort})"
  local status_before; status_before="$(task_status "$INSTANCE/$task")"
  task_mark_working "$INSTANCE/$task" "$role" "$name"
  run_box_bg "$name" isolated "$log" "$INSTANCE_STATE/exits/$name" "${claude_args[@]}"
  wait_for_box "$name" "$INSTANCE_STATE/exits/$name" "$log" || true
  code="$(cat "$INSTANCE_STATE/exits/$name" 2>/dev/null || echo unknown)"
  # A dead credential is not this task's problem, and it will kill every box after this one.
  # Put the document back the way it was and stop the run rather than marking nine tasks
  # blocked for a reason that has nothing to do with them.
  if box_auth_failed "$log"; then
    set_task_field "$INSTANCE/$task" status "$status_before"
    set_task_field "$INSTANCE/$task" box ""
    rm -f "$INSTANCE_STATE/inflight/$(task_key "$task")"
    die "the box could not authenticate — the shared Claude session is expired.

  $log

Nothing was charged to $(basename "$task"): its status is back to '$status_before'.

Log in once, in your own terminal (it needs a TTY):

  claude-box            # then /login, then exit

Then carry on where this stopped:

  claude-box harness do --resume"
  fi
  task_reconcile "$INSTANCE/$task" "$code"
  # A stacked PR's diff is already right; this is what makes GitHub show the chain.
  [ "$(fm_list_count "$INSTANCE/$task" pr)" -gt 0 ] && link_stack "$task" "$repo"
  # And if every gate now passes, the draft is finished work — hand it to the human.
  pr_ready_if_finished "$task" "$repo"
  reclaim_credentials "$name"
  rm -f "$INSTANCE_STATE/inflight/$(task_key "$task")"
  note "    exit $code — $log"
  [ "$code" = 0 ]
}

# One scalar out of the frontmatter. Three things this has to get right, each learned the
# hard way: a value may itself contain ": " (a `-F': *'` split truncated a blocked_reason at
# the first colon), a value may be quoted (`blocked_reason: ""` read back as the two-character
# string `""`, so an emptiness check said "not empty" and a stalled task never normalised),
# and the search stops at the closing `---` so prose in the body cannot impersonate a field.
task_field() {
  awk -v k="$2" '
    NR == 1 && $0 == "---" { next }
    $0 == "---" { exit }
    index($0, k ":") == 1 {
      v = substr($0, length(k) + 2)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      q = substr(v, 1, 1)
      if (length(v) > 1 && (q == "\"" || q == "'"'"'") && substr(v, length(v), 1) == q)
        v = substr(v, 2, length(v) - 2)
      print v; exit
    }
  ' "$1" 2>/dev/null
}

# Items of a YAML flow array, one per line. The PM writes these across MULTIPLE lines
# once they are longer than a few words:
#
#   open_questions: [
#     "Q1: …",
#     "Q2: …"
#   ]
#
# A single-line `awk -F': *'` on that yields "[" — which is how a blocking question got
# rendered to the user as a bare bracket, and how an emptiness check nearly passed for the
# wrong reason. Read the whole array.
fm_list_items() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PY_LIST'
import re, sys
path, key = sys.argv[1], sys.argv[2]
try:
    text = open(path, errors="replace").read()
except OSError:
    raise SystemExit(0)
# Frontmatter only: the body may legitimately mention the key in prose. Split on the
# CLOSING DELIMITER LINE, not on every "---" in the file — an answered question contains
# " --- " by design, and splitting on that truncated the frontmatter and hid every field
# after the first answer.
front = text
if text.startswith("---"):
    match_end = re.search(r"^---[ \t]*$", text[3:], re.M)
    front = text[3:3 + match_end.start()] if match_end else text[3:]
match = re.search(r"^%s:[ 	]*(.*?)$" % re.escape(key), front, re.M)
if not match:
    raise SystemExit(0)
rest = front[match.start(1):]
if not rest.lstrip().startswith("["):
    value = match.group(1).strip()
    if value:
        print(value)
        raise SystemExit(0)
    # A BLOCK list: `key:` on its own line, then indented `- item` lines. The
    # project-manager writes criteria this way because they are long, and reading only the
    # flow form counted them as zero — which silently disabled autonomy promotion (a task
    # with criteria looked unrefined) and hid open questions from `harness answer`.
    for line in front[match.end():].splitlines():
        if line.strip() and not line[:1].isspace():
            break                       # dedented: the next frontmatter key
        item = line.strip()
        if not item.startswith("- "):
            continue
        item = item[2:].strip()
        if item[:1] in "\"'" and item[-1:] == item[:1] and len(item) > 1:
            item = item[1:-1]
        if item:
            print(item)
    raise SystemExit(0)
depth, buf = 0, []
for ch in rest:
    if ch == "[":
        depth += 1
        if depth == 1:
            continue
    elif ch == "]":
        depth -= 1
        if depth == 0:
            break
    buf.append(ch)
inner = "".join(buf)
# Split on commas that are not inside quotes.
items, cur, quote = [], "", None
for ch in inner:
    if quote:
        if ch == quote:
            quote = None
        cur += ch
    elif ch in "\"'":
        quote = ch
        cur += ch
    elif ch == ",":
        items.append(cur)
        cur = ""
    else:
        cur += ch
items.append(cur)
for item in items:
    item = item.strip().strip("\n").strip()
    if item[:1] in "\"'" and item[-1:] == item[:1]:
        item = item[1:-1]
    if item:
        print(item)
PY_LIST
}

fm_list_count() { fm_list_items "$1" "$2" | grep -c . || true; }

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

# Is anything in scope still workable? A review that requests changes puts a task back in the
# queue BEHIND the cursor, so a single forward pass strands it until someone re-runs the
# command by hand. This is how the pipeline knows another pass is worth making.
scope_actionable() {
  local files="$1" t running
  running="$(engine_running_boxes || true)"
  local old_ifs="$IFS"; IFS=$'\n'
  for t in $files; do
    [ -n "$t" ] || continue
    case "$(task_status "$INSTANCE/$t")" in
      (ready|in-progress) ;;
      (*) continue ;;
    esac
    # Something already working it is not a reason for another pass. Box names end in the
    # task stem (plus unique_name's -N), so match that suffix: a substring match made t1
    # see t10's box as its own and stop the pass with t1 stranded.
    printf '%s\n' "$running" | grep -qE -- "-$(slug "$(basename "${t%.md}")")(-[0-9]+)?\$" && continue
    IFS="$old_ifs"; return 0
  done
  IFS="$old_ifs"; return 1
}

cmd_harness_do() {
  local inst="" desc="" project="" repo="" rounds="$CLAUDE_BOX_QA_ROUNDS" dry=0 resume=0 retry=0 only_task="" passes=3
  while [ $# -gt 0 ]; do
    case "$1" in
      --resume)           resume=1; shift ;;
      --retry|--include-blocked) resume=1; retry=1; shift ;;
      --task)             resume=1; only_task="${2#/}"; shift 2 ;;
      --instance|--panel) inst="${2:-}"; shift 2 ;;
      --project)          project="${2:-}"; shift 2 ;;
      --repo)             repo="${2:-}"; shift 2 ;;
      --max-rounds)       rounds="${2:-}"; shift 2 ;;
      --passes)           passes="${2:-}"; shift 2 ;;
      --dry-run)          dry=1; shift ;;
      -*)                 die "unknown flag for 'harness do': $1" ;;
      *)
        if [ -z "$inst" ] && [ -d "$1" ] && [ -f "$1/instance.config.json" ]; then inst="$1"
        elif [ -z "$desc" ]; then desc="$1"
        else desc="$desc $1"; fi
        shift ;;
    esac
  done
  if [ "$resume" = 0 ] && [ -z "$desc" ]; then
    die "usage: claude-box harness do [<panel>] \"<what you want>\" [--repo <name>] [--max-rounds N (default $CLAUDE_BOX_QA_ROUNDS)]
       claude-box harness do --resume [--project <slug>]     continue work already drafted"
  fi
  resolve_instance "$inst"
  ensure_daemon
  local mode; mode="$(autonomy_mode)"
  [ "$dry" = 1 ] || require_login
  if [ "$dry" != 1 ] && [ -n "$(gh_scopes)" ] && ! gh_has_scope workflow; then
    note "the shared gh token has no 'workflow' scope, so no box can add a CI job —
    a task whose verification needs one will block on that. Grant it once:
      gh auth refresh -h github.com -s workflow"
  fi

  if [ "$dry" = 1 ] && [ "$resume" = 1 ]; then
    echo "would resume work already drafted on $INSTANCE (autonomy: $mode):"
    if [ -n "$only_task" ]; then
      printf '  %-46s %s\n' "$only_task" "$(task_status "$INSTANCE/$only_task")"
    else
      ( cd "$INSTANCE" && find "projects${project:+/$project}" -type f -name '*.md' -path '*/tasks/*' 2>/dev/null | sort ) \
        | while IFS= read -r t; do
            local st note_; st="$(task_status "$INSTANCE/$t")"; note_=""
            if [ "$st" = blocked ] && blocked_retryable "$INSTANCE/$t"; then note_="  (retryable — resume takes it)"; fi
            printf '  %-46s %s%s\n' "$t" "$st" "$note_"
          done
      echo
      if [ "$retry" = 1 ]; then
        echo "  ready/in-progress/in-review/blocked are picked up; done and cancelled are skipped"
      else
        echo "  ready, in-progress, in-review and blocks the host wrote (a box that stopped early)"
        echo "  are picked up; done, cancelled and blocks a role reasoned to need --retry"
      fi
    fi
    return 0
  fi
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

  local created
  if [ "$resume" = 1 ]; then
    # Resume: work the panel already holds. Re-drafting would duplicate the project, so
    # this path never calls the project-manager.
    echo "── resuming ─────────────────────────────────────────────"
    local scope="projects"
    [ -n "$project" ] && scope="projects/$project"
    board_normalise "$scope"
    if [ -n "$only_task" ]; then
      [ -f "$INSTANCE/$only_task" ] || die "no task at $INSTANCE/$only_task"
      created="$only_task"
    else
      # --retry includes blocked work, which is what you want after changing a policy the
      # blocked task was judged against.
      created="$(cd "$INSTANCE" && find "$scope" -type f -name '*.md' -path '*/tasks/*' 2>/dev/null | sort | while IFS= read -r f; do
        case "$(task_status "$INSTANCE/$f")" in
          (draft|ready|in-progress|in-review) printf '%s\n' "$f" ;;
          # Written as an if, not as a test-and-printf: the latter leaves the loop's exit
          # status at 1 whenever the test fails, which fails the enclosing command
          # substitution and, under set -e, silently kills the whole run. That is exactly
          # what made --resume a no-op on a panel containing blocked tasks.
          # (No backticks in comments inside a command substitution, either — bash's parser
          # treats them as a nested substitution and swallows the rest of the file.)
          (blocked) if [ "$retry" = 1 ] || blocked_retryable "$INSTANCE/$f"; then printf '%s\n' "$f"; fi ;;
        esac
      done)"
    fi
    if [ -z "$created" ]; then
      echo "  nothing to resume in $scope — every task is done, cancelled, or blocked on a"
      echo "  reason a role gave (\`--retry\` re-dispatches those; \`harness status\` lists them)"
      return 0
    fi
    printf '%s\n' "$created" | while IFS= read -r t; do
      printf '  %-46s %s\n' "$t" "$(task_status "$INSTANCE/$t")"
    done

    # Answers you gave are still sitting in open_questions; until the PM folds them in and
    # clears them, the host will not promote — so do that first, in one box.
    if answers_pending "$created"; then
      echo
      echo "── folding in your answers ──────────────────────────────"
      fold_answers "$created" || true
      # Cancelled and still-blocked tasks drop out of the run here.
      created="$(printf '%s\n' "$created" | while IFS= read -r t; do
        case "$(task_status "$INSTANCE/$t")" in
          (draft|ready|in-progress|in-review) printf '%s\n' "$t" ;;
          (*) printf '  dropped %s (now %s)\n' "$t" "$(task_status "$INSTANCE/$t")" >&2 ;;
        esac
      done)"
    fi
  else
    # 1. Draft.
    echo "── drafting ─────────────────────────────────────────────"
    local before after
    before="$(mktemp)"; after="$(mktemp)"
    ( cd "$INSTANCE" && find projects -type f -name '*.md' 2>/dev/null | sort ) > "$before"
    # Not swallowed: when drafting fails, its diagnosis is the only useful output there is.
    cmd_harness_new "$INSTANCE" "$desc" --terse ${project:+--project "$project"} ${repo:+--repo "$repo"} || true
    ( cd "$INSTANCE" && find projects -type f -name '*.md' 2>/dev/null | sort ) > "$after"
    created="$(comm -13 "$before" "$after" | grep '/tasks/' || true)"
    rm -f "$before" "$after"

    if [ -z "$created" ]; then
      echo
      echo "no task documents were created — nothing downstream can run."
      echo "the drafting output above says why; a sharper request is the LAST thing to suspect."
      return 1
    fi
  fi

  # 2. Anything waiting on a human stops here: nothing downstream can answer it.
  local blocked=0 blocked_files="" t
  # After a fold-in the PM may have raised a NEW question; check the current state, not the
  # state we started from.
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ "$(fm_list_count "$INSTANCE/$t" open_questions)" -gt 0 ] || continue
    echo
    echo "  $INSTANCE/$t"
    echo "  is waiting on you:"
    fm_list_items "$INSTANCE/$t" open_questions | fold -s -w 88 | sed 's/^/    /'
    blocked=1
    blocked_files="$blocked_files$t"$'\n'
  done <<< "$created"

  if [ "$blocked" = 1 ]; then
    # Ask them here rather than sending the user off to hand-edit YAML — that was the
    # instruction, and it was bad advice.
    if [ -t 0 ]; then
      echo
      printf 'Answer them now? [Y/n] '
      local reply
      answer_open; reply="$(answer_read)"; answer_close
      printf '\n' 
      case "$reply" in
        (''|y|Y|yes|YES)
          if answer_interactively "$blocked_files"; then
            blocked=0
            echo
            echo "── continuing ───────────────────────────────────────────"
          fi ;;
      esac
    fi
  fi

  if [ "$blocked" = 1 ]; then
    echo
    echo "Those tasks stay blocked until the questions are answered:"
    echo "  claude-box harness answer                 # asks them one at a time"
    echo "  claude-box harness do --resume            # continue afterwards"
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
  TICK_DIR="$INSTANCE_STATE/ticks/do-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$TICK_DIR/logs"
  printf 'run %s\nkind do\ninstance %s\nstarted %s\nautonomy %s\n' \
    "$(basename "$TICK_DIR")" "$INSTANCE_SLUG" "$(date +%s)" "$mode" > "$TICK_DIR/summary.txt"
  autonomy_promote "$mode"

  # 4. Implement, then review, per task.
  local failures=0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    local doc="$INSTANCE/$t" role trepo round=1 st0
    st0="$(task_status "$doc")"
    case "$st0" in
      (ready) ;;
      (in-progress|in-review|blocked)
        # Resume and retry deliberately pick these up: a blocked task is exactly what you
        # re-run after changing the policy it was judged against.
        [ "$resume" = 1 ] || { echo "  skipping $t (status $st0)"; continue; } ;;
      (*) echo "  skipping $t (status $st0)"; continue ;;
    esac
    role="$(task_field "$doc" assignee)"
    case "$role" in ''|'~') role=lead-dev ;; esac
    role_is_known "$role" || role=lead-dev
    trepo="$(task_field "$doc" target_repo)"; trepo="${trepo##*/}"
    [ -n "$trepo" ] || trepo="$repo"

    # Design review, when the project-manager asked for one. Before implementation, because
    # a wrong approach caught here costs a paragraph and caught after merge costs a migration.
    local design; design="$(task_field "$doc" design_review)"
    local arch; arch="$(task_field "$doc" arch)"
    if [ "$design" = required ] && [ "$arch" != sound ] && [ "$st0" != in-review ]; then
      echo "── design review of $(basename "$t") ───────────────────"
      run_role_sync architect "$t" "$trepo" "Review the PROPOSED solution for this task before it is built (Mode A). Decide whether it is sound. Set the arch: field and write your reasoning under '## Architecture review' in # Notes." || true
      arch="$(task_field "$doc" arch)"
      if [ "$arch" != sound ]; then
        echo "  arch: ${arch:-no verdict} — not implementing this until the design is settled"
        failures=$((failures + 1))
        continue
      fi
      echo "  arch: sound — proceeding"
    fi

    if [ "$st0" = in-review ]; then
      echo "── resuming review of $(basename "$t") ─────────────────"
    else
      echo "── implementing $(basename "$t") ───────────────────────"
      local verb="Implement this task end to end."
      [ "$st0" = in-progress ] && verb="Continue this task from where it was left. Read its # Result and # Notes first, and do not redo work that is already committed."
      # The worktree survives between runs, so it can be behind what is on the remote — a
      # human rebasing the stack is normal. Start from the remote, not from local commits.
      verb="$verb

Your branch already exists on the remote and may have been rebased there since your last run
(a human maintaining a stack does this). Before you touch anything: \`git fetch origin\`, then
look at both directions. Commits only on the remote: \`git reset --hard origin/<your branch>\`
— the remote is the truth for what was published. Commits only here (\`git log origin/<your
branch>..HEAD\`): keep them, they are a previous attempt that never got pushed; rebase them
onto origin/<your branch> if that moved too. Never reset away commits that exist only locally.
Then check whether your base branch moved and rebase onto it if it did."
      [ "$st0" = blocked ] && verb="This task was left BLOCKED. Read its # Result and # Notes first: the work may already be written, committed and pushed. Do not redo it. The policy has changed — a blocked task still gets a pull request: open it as a DRAFT with a '## Blocked on' section listing exactly what is unmet and why, move any verification that needs a deployed environment or secrets into a CI job following the conventions of the nearest existing job in that repo, then set the task in-review with the PR URL. Only stay blocked if you cannot open a PR at all."
      run_role_sync "$role" "$t" "$trepo" "$verb" || true
    fi

    while [ "$round" -le "$rounds" ]; do
      local st; st="$(task_status "$doc")"
      [ "$st" = in-review ] || break
      # An approved verdict is a decision, not a cache to refill. Re-reviewing an approved PR
      # on every resume spent two boxes per task and, once, talked itself out of its own
      # approval — t2 went from approved back to changes-requested with nothing new in the
      # diff. Re-review is what --retry is for.
      if [ "$(task_field "$doc" qa)" = approved ] && [ "$retry" != 1 ]; then
        echo "  qa already approved — not reviewing it again (use --retry to force a re-review)"
        break
      fi
      echo "── reviewing $(basename "$t") (round $round) ───────────"
      run_role_sync qa-reviewer "$t" "$trepo" "Review the open pull request on this task against its acceptance criteria. Set the qa: field." || true
      local qa; qa="$(task_field "$doc" qa)"
      # Two values. A box that writes anything else ("pending") leaves the task in a state no
      # gate matches: no approval, no send-back, a draft PR nobody is working. Normalise it
      # here, where it happened, rather than at the next resume.
      case "$qa" in
        (approved|changes-requested) ;;
        ("") ;;
        (*) note "    qa wrote '$qa', which is not a verdict — recording changes-requested"
            set_task_field "$doc" qa changes-requested
            qa=changes-requested ;;
      esac
      [ "$qa" = approved ] && break
      echo "  qa: ${qa:-none} — sending it back"
      local back="The qa-reviewer requested changes. Address every point, then hand it back for review."
      # CI is the source of truth. "A human has to run this" is where every one of these
      # tasks stopped, and it is not a verdict — it is a job that does not exist yet. Any
      # verdict that is not `approved` comes back here, and anything the reviewer could not
      # check becomes CI work rather than someone's errand.
      if [ "$qa" != changes-requested ]; then
        back="The qa-reviewer could not verify this inside a box — it needs a deployed
environment, a secret or a browser. That is a gap in CI, and closing it is your work, not a
human's: wire the verification into a CI job, copying the conventions of the nearest existing
job in that repository (same workflow file, same secret names, same triggers). If the job
already exists and was skipped, make it run for this pull request. If it needs a secret that
does not exist yet, add the job referencing the name it should have and list that name under
'## Blocked on' in the PR body. Then say in the PR body which job proves which acceptance
criterion, and hand it back for review. Never ask a human to run anything locally."
      fi
      run_role_sync "$role" "$t" "$trepo" "$back" || true
      round=$((round + 1))
    done
    # "· t5 is in-review" told you nothing about why its PR is still a draft. If review rounds
    # ran out with a verdict outstanding, that is a decision the run made — print it.
    if [ "$round" -gt "$rounds" ] && [ "$(task_field "$doc" qa)" != approved ]; then
      echo "  review budget spent ($rounds rounds) and qa still says $(task_field "$doc" qa) —"
      echo "  the PR stays a draft; resume continues the same rounds, or raise --max-rounds"
    fi

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

    # 6. Curate what it taught, once per task. The cataloguer was configured, given a model
    # tier and a role file, and then never dispatched by anything — so `knowledge/` stayed at
    # its template while every learning went to the memory tier instead. A finished task is
    # exactly the moment its finding is still legible, and that moment was passing unused.
    if [ "$(task_field "$doc" qa)" = approved ] \
       && [ -z "$(task_field "$doc" catalogued)" ] \
       && [ -f "$INSTANCE/.claude/agents/cataloguer.md" ]; then
      echo "── cataloguing $(basename "$t") ─────────────────────────"
      # Stamped before the box runs: a cataloguer that times out must not make every later
      # resume re-catalogue the same task. Curation is not worth a second box.
      set_task_field "$doc" catalogued "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      run_role_sync cataloguer "$t" "$trepo" "This task has been accepted by review. Curate what it
established into this panel's knowledge base, following your role definition: write or update the
document that belongs (a Finding for a decision or a gotcha, a Service/Frontend App page for a
boundary that is now real, a Runbook for a procedure someone will repeat), and update
\`knowledge/index.md\` so it can be found. One document is a good outcome; none is fine if the
task taught nothing durable — say so and stop. Do not touch product code, do not touch the pull
request, and do not restate the task." || true
    fi

    final="$(task_status "$doc")"
    case "$final" in
      done) echo "  ✓ $t is done" ;;
      *)    echo "  · $t is $final"; failures=$((failures + 1)) ;;
    esac
  done <<< "$created"

  # A run with no summary is a "?" row on the dashboard, which is worse than a zero.
  local worked=0 done_n=0 blocked_n=0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    worked=$((worked + 1))
    case "$(task_status "$INSTANCE/$t")" in
      (done)             done_n=$((done_n + 1)) ;;
      (blocked|draft)    blocked_n=$((blocked_n + 1)) ;;
    esac
  done <<< "$created"
  {
    printf 'run %s\nkind do\ninstance %s\nfinished %s\nautonomy %s\n' \
      "$(basename "$TICK_DIR")" "$INSTANCE_SLUG" "$(date +%s)" "$mode"
    printf 'tasks %s\naccepted %s\nrejected 0\ndone %s\nblocked %s\n' \
      "$worked" "$worked" "$done_n" "$blocked_n"
    printf 'pending_memory %s\n' "$(command ls "$INSTANCE/.harness/pending"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  } > "$TICK_DIR/summary.txt"
  printf '%s\n' "$(basename "$TICK_DIR")" > "$INSTANCE_STATE/last-tick"

  # Another pass, if the work came back. Bounded: --passes (default 3), and each pass only
  # runs while something is actually actionable, so a stuck task costs one attempt, not a loop.
  if [ "$passes" -gt 1 ] && scope_actionable "$created"; then
    echo
    echo "── another pass (work came back for more) ───────────────"
    cmd_harness_do "$INSTANCE" --resume ${project:+--project "$project"} ${only_task:+--task "$only_task"} \
      --max-rounds "$rounds" --passes "$((passes - 1))" ${repo:+--repo "$repo"}
    return $?
  fi

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
  claude-box harness do     --resume [--project <slug>]  continue drafted work, no
                                                       re-drafting
  claude-box harness new    [<panel>] "<what you want>"   just draft the documents
  claude-box harness answer [<panel>] [--project <slug>]  answer the PM's blocking
                                                       questions, one prompt at a time
  claude-box harness done   <task path | project path | project slug> [<panel>] [--no-pr]
                                                       close work out yourself, from any
                                                       state: records what every PR on it
                                                       was at that moment, then sets done
  claude-box harness clean  [<panel>] [--project <slug>] [-y]
                                                       discard attempts: remove worktrees
                                                       and branches, reset tasks to ready
  claude-box harness delete [<panel>] --project <slug> | --task <path>
                            | --objective <slug>
                            [-y] [--dry-run] [--purge] [--delete-remote]
                                                       remove the documents themselves,
                                                       with their worktrees and branches;
                                                       moves them to trash unless --purge
  claude-box harness purge  [--days N | --all] [-y]    delete logs, runs and box dirs
                                                       (auto: older than 7 days each tick)
  claude-box harness tick   [<instance>] [--dry-run]   one PM tick, then dispatch
  claude-box harness loop   [<instance>] [gap]         tick, wait, sleep, repeat (locked)
  claude-box harness stack  [<panel>] [--project <slug>]  link dependent PRs into a stack
  claude-box harness stop   [<panel>]                  stop the driver AND its boxes
  claude-box harness status [<instance>]               lock, in-flight, last tick, queues
  claude-box harness autonomy [gated|promote|full]     who promotes and who merges
  claude-box harness memory [<panel>]                  review pending learnings
  claude-box harness memory --list                     what is in memory, and pending
  claude-box harness memory --accept <file> | --drop <file>
  claude-box harness ui     [<panel>] [--port N] [--actions]   local dashboard

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
    answer)        cmd_harness_answer "$@" ;;
    done)          cmd_harness_done "$@" ;;
    clean)         cmd_harness_clean "$@" ;;
    delete)        cmd_harness_delete "$@" ;;
    purge)         cmd_harness_purge "$@" ;;
    stop)          cmd_harness_stop "$@" ;;
    stack)         cmd_harness_stack "$@" ;;
    do)            cmd_harness_do "$@" ;;
    autonomy)      cmd_harness_autonomy "$@" ;;
    tick)          cmd_harness_tick "$@" ;;
    loop)          cmd_harness_loop "$@" ;;
    status)        cmd_harness_status "$@" ;;
    memory)        cmd_harness_memory "$@" ;;
    ui)            cmd_harness_ui "$@" ;;
    ""|-h|--help)  harness_usage ;;
    *)             die "unknown harness subcommand '$sub' (try: init do new answer done stack stop clean delete purge tick loop status autonomy memory ui)" ;;
  esac
}
