#!/usr/bin/env bash
# The dashboard's markup and its render code are edited separately, and a stale
# getElementById returns null rather than failing loudly — one missing id blanked every
# section below the first. This checks they agree, and that the JS parses.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PAGE="$REPO_DIR/harness/ui/index.html"

missing="$(python3 - "$PAGE" <<'PY'
import re, sys
page = open(sys.argv[1]).read()
ids = set(re.findall(r'id="([A-Za-z0-9_-]+)"', page))
used = set(re.findall(r'getElementById\("([A-Za-z0-9_-]+)"\)', page))
print("\n".join(sorted(used - ids)))
PY
)"
if [ -z "$missing" ]; then ok "every element the render touches exists in the markup"
else fail "every element the render touches exists in the markup" "missing: $(printf '%s' "$missing" | tr '\n' ' ')"; fi

if command -v node >/dev/null 2>&1; then
  python3 - "$PAGE" > "$TMPDIR/page.js" <<'PY'
import sys
s = open(sys.argv[1]).read()
print(s[s.index('<script>') + 8:s.rindex('</script>')])
PY
  if node --check "$TMPDIR/page.js" 2>/dev/null; then ok "the page script parses"
  else fail "the page script parses" "$(node --check "$TMPDIR/page.js" 2>&1 | head -3)"; fi
  rm -f "$TMPDIR/page.js"
else
  ok "the page script parses (skipped — no node)"
fi

# The API version the page expects must match what the server sends, or the page tells the
# user to restart for no reason — or worse, trusts fields that are not there.
page_v="$(sed -n 's/.*API_EXPECTED = \([0-9]*\).*/\1/p' "$PAGE" | head -1)"
srv_v="$(sed -n 's/^API_VERSION = \([0-9]*\).*/\1/p' "$REPO_DIR/harness/ui/server.py" | head -1)"
assert_eq "the page and server agree on the API version" "$page_v" "$srv_v"

# --- the markdown renderer must not become an injection path -------------------
# Task documents are written by AGENTS and the page carries an action token, so a document
# containing HTML must render as TEXT. The checks live in tests/md-check.js.
if command -v node >/dev/null 2>&1; then
  python3 - "$PAGE" > "$TMPDIR/md-src.js" <<'PY'
import sys
s = open(sys.argv[1]).read()
js = s[s.index('<script>') + 8:s.rindex('</script>')]
# Two disjoint pieces: the escaper and the renderer. Nothing else.
esc_start = js.index('const esc =')
esc_end = js.index(';', js.index('}[c]))', esc_start)) + 1
md_start = js.index('function md(src)')
md_end = js.index('let rawTask = null;')
print(js[esc_start:esc_end])
print(js[md_start:md_end])
PY
  out="$(node "$REPO_DIR/tests/md-check.js" "$TMPDIR/md-src.js" 2>&1)"
  if [ "$out" = "OK" ]; then ok "markdown renders structure but never live HTML from a document"
  else fail "markdown renders structure but never live HTML from a document" "$(printf '%s' "$out" | head -4)"; fi
  rm -f "$TMPDIR/md-src.js"
else
  ok "markdown renderer checks (skipped — no node)"
fi

# --- stalled must be distinguishable from working ------------------------------
# `in-progress` with a box running and `in-progress` with nothing running look identical on a
# board, and the second is the state that quietly wastes a day: a review round ended with
# changes requested, the run moved on, and the task just sits there.
if command -v node >/dev/null 2>&1; then
  python3 - "$PAGE" > "$TMPDIR/board.js" <<'PY'
import sys
s = open(sys.argv[1]).read()
js = s[s.index('<script>') + 8:s.rindex('</script>')]
# From the top of the script: the render depends on constants defined above esc().
print(js[:js.index('async function poll()')])
PY
  cat >> "$TMPDIR/board.js" <<'JS'
const els = {};
// Any id, created on demand: enumerating them here duplicated the markup-consistency check
// above and broke every time a section was added.
const makeEl = () => ({ textContent: "", innerHTML: "", hidden: false, dataset: {},
                        classList: { add() {}, remove() {}, contains: () => false } });
global.document = { getElementById: id => (els[id] = els[id] || makeEl()), querySelectorAll: () => [], addEventListener(){} };
global.window = {}; global.setInterval = () => 0;
const base = { api: 11, instance: "/p", lock:{}, cap:{}, spend:{}, boxes:[], projects:[], logs:[],
               ticks:[], runs:[], timeline:[], role_stats:[], roles:[], pending:[], rejected:[],
               memory:{global:[],repo:[],kb:{index:"",docs:[]}}, jira:{}, errors:[] };
const stalled = { ...base, tasks:[{ path:"projects/p/tasks/t1.md", id:"t1", title:"T", status:"in-progress",
  project:"p", repo:"r", prs:[], pr_status:[], criteria:[], questions:[], unanswered:[], depends_on:[],
  qa:"changes-requested", working:false, stalled:true, next_action:"needs another round",
  next_command:"claude-box harness do --task /projects/p/tasks/t1.md" }],
  attention:[{ kind:"stalled", task:"projects/p/tasks/t1.md", title:"T", detail:"needs another round",
               action:"claude-box harness do --task /projects/p/tasks/t1.md", open:"task" }] };
render(stalled);
const board = els.board.innerHTML, att = els.attention.innerHTML;
const bad = [];
if (!board.includes("stalled")) bad.push("board does not mark a stalled task");
if (!board.includes("needs another round")) bad.push("board does not say what is needed");
if (!att.includes("harness do --task")) bad.push("needs-you row does not give the command");
const working = { ...stalled, tasks:[{ ...stalled.tasks[0], working:true, stalled:false, next_action:"" }], attention:[] };
render(working);
if (!els.board.innerHTML.includes("working")) bad.push("board does not mark a working task");
if (els.board.innerHTML.includes(">stalled<")) bad.push("a working task is marked stalled");
if (bad.length) { console.log("FAIL\n" + bad.join("\n")); process.exit(1); }
console.log("OK");
JS
  out="$(node "$TMPDIR/board.js" 2>&1)"
  if [ "$out" = "OK" ]; then ok "the board distinguishes stalled from working and states the next step"
  else fail "the board distinguishes stalled from working and states the next step" "$(printf '%s' "$out" | head -4)"; fi
  rm -f "$TMPDIR/board.js"
else
  ok "board rendering checks (skipped — no node)"
fi

# --- every list must be bounded ------------------------------------------------
# Sections grow with the work: eight ready tasks, forty logs, sixty activity rows. Unbounded
# containers turn the page into a scroll-hunt, so each list scrolls inside itself.
python3 - "$PAGE" > "$TMPDIR/css-check.txt" <<'PY'
import re, sys
page = open(sys.argv[1]).read()
css = page[page.index('<style>'):page.index('</style>')]
problems = []

# Containers that hold a growing list, and the rule each one needs.
def rule(selector):
    # ALL declarations for a selector, not the first block: properties are often split, and
    # checking only the first block reports a bounded container as unbounded.
    return " ".join(m.group(1) for m in
                    re.finditer(r'(?:^|\})\s*' + re.escape(selector) + r'\s*\{([^}]*)\}',
                                css, re.M | re.S))

for selector in (".scroll", ".grid.bounded", ".col"):
    body = rule(selector)
    if "max-height" not in body:
        problems.append(f"{selector} has no max-height — it will grow without limit")
    if "overflow" not in body:
        problems.append(f"{selector} does not scroll")

# A bounded table without a sticky header scrolls the column names away.
if "position: sticky" not in rule(".scroll thead th"):
    problems.append(".scroll thead th is not sticky")

# Every list container in the markup must use one of the bounded classes.
ids = re.findall(r'<div class="([^"]*)" id="(projects|board|logs|ticks|timeline|rolestats|memory|attention|rejected|boxes|pending)"', page)
for classes, ident in ids:
    if not any(c in classes for c in ("scroll", "bounded", "board")):
        problems.append(f'#{ident} uses class "{classes}" — not a bounded container')

print("\n".join(problems) if problems else "OK")
PY
out="$(cat "$TMPDIR/css-check.txt")"
if [ "$out" = "OK" ]; then ok "every list is bounded, scrolls internally, and keeps its header"
else fail "every list is bounded, scrolls internally, and keeps its header" "$(printf '%s' "$out" | head -4)"; fi
rm -f "$TMPDIR/css-check.txt"

# --- a collapsed section must look like a section ------------------------------
# As bare uppercase labels in whitespace, collapsed <details> read as stray text rather than
# something clickable.
css_sec="$(python3 - "$PAGE" <<'PY'
import re, sys
page = open(sys.argv[1]).read()
css = page[page.index('<style>'):page.index('</style>')]
def rule(sel):
    return " ".join(m.group(1) for m in re.finditer(
        r'(?:^|\})\s*' + re.escape(sel) + r'\s*\{([^}]*)\}', css, re.M | re.S))
problems = []
box = rule('details.sec')
if 'border' not in box or 'background' not in box:
    problems.append('a collapsed section has no card border/background')
head = rule('details.sec > summary')
if 'cursor: pointer' not in head or 'padding' not in head:
    problems.append('the section header is not an obviously clickable bar')
if 'rotate' not in rule('details.sec[open] > summary::before'):
    problems.append('there is no open/closed indicator')
if 'background' not in rule('details.sec > summary:hover'):
    problems.append('the header has no hover affordance')
print("; ".join(problems) if problems else "OK")
PY
)"
assert_eq "a collapsed section reads as a clickable panel" "$css_sec" "OK"

# --- no use-before-definition in render() --------------------------------------
# `const` is hoisted into a temporal dead zone, so calling a helper defined further down
# throws "Cannot access 'n' before initialization" — at runtime, in the browser, with the
# whole page blank below the first section. Nothing else catches that.
order="$(python3 - "$PAGE" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
js = s[s.index('<script>') + 8:s.rindex('</script>')]
body = js[js.index('function render(s) {'):js.index('async function poll()')]
defs = {}
for m in re.finditer(r'^\s*(?:const|let)\s+([A-Za-z_$][\w$]*)', body, re.M):
    defs.setdefault(m.group(1), m.start())
problems = []
for name, pos in defs.items():
    for use in re.finditer(r'(?<![\w$.])' + re.escape(name) + r'\s*\(', body):
        if use.start() < pos:
            problems.append("%s used before it is defined" % name)
            break
print("; ".join(problems) if problems else "OK")
PY
)"
assert_eq "render() never calls a helper before defining it" "$order" "OK"


# A poll must not scroll you away from what you are reading: innerHTML resets scrollTop, so
# render is wrapped and every scroll container needs a stable id to be restored by.
html="$(cat "$PAGE")"
assert_contains "the poll preserves scroll position" "$html" "keepScroll(() => render(body))"
assert_contains "board columns carry a stable id" "$html" 'id="col-${esc('
assert_ok "every .scroll container has an id" bash -c '
  html="$1"
  # class="scroll" with no id= on the same tag is an unrestorable container.
  bad="$(printf "%s" "$html" | grep -o "<div class=\"scroll\"[^>]*>" | grep -v "id=" || true)"
  [ -z "$bad" ] || { printf "%s\n" "$bad"; exit 1; }' _ "$PAGE"


# In flight comes first: on a working panel it is the answer to "what is going on".
order_boxes="$(printf "%s" "$html" | grep -n 'id="sec-boxes"' | cut -d: -f1)"
order_att="$(printf "%s" "$html" | grep -n 'id="sec-attention"' | cut -d: -f1)"
order_board="$(printf "%s" "$html" | grep -n 'id="sec-board"' | cut -d: -f1)"
assert_ok "in flight is above needs you" bash -c '[ "$1" -lt "$2" ]' _ "$order_boxes" "$order_att"
assert_ok "needs you is above the board" bash -c '[ "$1" -lt "$2" ]' _ "$order_att" "$order_board"

# Every top region collapses, and the choice survives a reload.
for sid in sec-boxes sec-attention sec-board sec-prs sec-projects; do
  assert_contains "$sid is collapsible" "$html" "<details class=\"sec\" id=\"$sid\""
done
assert_contains "collapse state is remembered" "$html" 'store.set(key, d.open ? "1" : "0")'
assert_contains "the attention list is bounded tighter than the rest" "$html" 'class="scroll tight" id="attention"'


# Re-rendering identical markup still tears the DOM down and rebuilds it, which on a 3s poll
# reads as cards blinking while you scroll. Every list goes through the compare-first helper.
assert_contains "the DOM is only touched when markup changed" "$html" "el.__html === html"
assert_ok "no list assigns innerHTML directly in render" bash -c '
  bad="$(printf "%s" "$1" | grep -n "getElementById(\"[a-z]*\")\.innerHTML" | grep -v logname || true)"
  [ -z "$bad" ] || { printf "%s\n" "$bad"; exit 1; }' _ "$html"
# Repo-scoped memory belongs to the panel, so accepting one never writes into a checkout.
assert_contains "the dashboard reads panel-owned repo memory" \
  "$(cat "$REPO_DIR/harness/ui/server.py")" 'INSTANCE / "memory" / "repos"'


# A card you cannot name is a card you have to open a file to identify.
assert_contains "board cards print the task id" "$html" 'class="tid">${esc(t.id'
assert_contains "and needs-you rows do too" "$html" 'class="tid">${esc(a.id)}'
assert_contains "the id tag is styled" "$html" ".tid {"


# The why behind each project had no writer and no reader: an empty directory nobody asked about.
assert_contains "objectives have their own section" "$html" 'id="sec-objectives"'
assert_contains "and an empty state that says who writes them" "$html" "project-manager writes"
assert_contains "the knowledge row counts documents by kind" "$html" "s.knowledge && s.knowledge.kinds"


# Inline handlers take agent-written ids and titles as JS string literals. esc() is not enough
# there: the entities decode before the JS parses, so a quote in an id closed the string on a
# page that carries the action token. Every handler argument goes through jsq() instead.
assert_contains "handler arguments are JSON-quoted" "$html" "const jsq = (s) => esc(JSON.stringify("
assert_eq "no inline handler quotes an esc() value" "$(grep -c "'\${esc(" "$PAGE")" "0"
# jiraUrl was local to render() but the task drawer renders outside it: ReferenceError on any
# task with a jira key.
assert_contains "jiraUrl is defined at top level" "$html" "const jiraUrl = (key) => (state && state.jira"
# localStorage throws with site data blocked; a preference must never blank the page.
assert_eq "no bare localStorage call outside the guarded helper" \
  "$(grep 'localStorage\.' "$PAGE" | grep -vc 'try {')" "0"


# The knowledge base was one row inside the collapsed Memory panel, which is not a section.
assert_contains "knowledge has its own section" "$html" 'id="sec-knowledge"'
assert_contains "its documents open in the drawer" "$html" "function showKnowledge(path)"
assert_contains "and the empty state names who fills it" "$html" "cataloguer</code> box"

summary
