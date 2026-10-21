# claude-box

Run the **Claude Code CLI inside a container sandbox** on macOS (Apple Silicon).
Keeps the agent's filesystem and network blast radius off the host while reusing
your existing host credentials — and runs **N boxes in parallel**, each on its own
git worktree, when one task wants several attempts at once.

Works with **Docker** or Apple **`container`**; the runner detects which you have.

## Files

- **`Dockerfile`** — the sandbox image (`claude-box:latest`). Debian base plus
  `git`, `git-lfs`, `curl`, `ripgrep`, `jq`, `less`, `tmux`, `procps`,
  `build-essential` + `python3` (node-gyp), `openssh-client`, the GitHub CLI
  (`gh`) with the **`gh-stack`** extension, **gitleaks**, Node via **Vite+**
  (VoidZero), pnpm via the Vite+ shim (corepack when present), and Claude Code.
- **`claude-box`** — the runner. Picks an engine, starts its daemon, mounts your
  workspace, wires auth, and launches boxes (single, headless, or fanned out).
- **`entrypoint.sh`** — container entrypoint; decides what to run, finishes the
  runtime wiring, and refreshes Claude Code when the command is `claude`.
- **`update-claude.sh`** — the refresh itself, installed as `claude-box-update`
  inside the image so you can also run it by hand from a shell.
- **`settings.json`** — Claude Code policy settings baked into the image at build
  time (see [Baked-in settings](#baked-in-settings-settingsjson)).
- **`githooks/pre-commit`** — image-wide gitleaks gate (see
  [Secret scanning](#secret-scanning)).
- **`registries.npmrc.example`** — template for your private `@scope` mappings
  (see [Private registry auth](#private-registry-auth-github-packages)).
- **`harness/`** — the role-agent harness: `roles/` (the role definitions),
  `template/` (what `harness init` stamps: schema, panel instructions, knowledge
  base), `harness.sh` (the executor), `overlay.md` (the prompt overlay every role box
  gets), `ui/` (the dashboard). See [Harness](#harness-role-agents-in-boxes).
- **`tests/`** — harness tests, run with `tests/run-all.sh`. They use a fake engine,
  so they spend no containers and no tokens.

## Install

The runner is a single script. Put it on your PATH so it works from anywhere — including
from inside the repos it operates on:

```sh
ln -s "$PWD/claude-box" ~/.local/bin/claude-box     # from a clone of this repo
claude-box harness status
```

It resolves its own real path through symlinks, so the harness roles, template and build
context are found wherever you link it from. Running it as `./claude-box` from inside the
clone works too — just note that from the repos root, `./claude-box` is the *directory*,
which is a permission-denied from your shell, not a broken script.

## Usage

```sh
claude-box build                        # build (or rebuild) the image
claude-box                                # run claude on the CURRENT directory
claude-box <dir>                          # run claude on <dir>
claude-box [<dir>] <args>                 # pass args to claude (--resume, --model …)
claude-box [<dir>] shell                  # drop into a bash shell inside the sandbox

claude-box run -n 4 [<dir>] "<prompt>"    # fan out 4 headless boxes over 4 worktrees
claude-box ps                             # list running boxes
claude-box logs -f <box>                  # follow one box's output
claude-box results <run-id>               # exit code, commits and diffstat per box
claude-box cleanup <run-id>               # remove that run's worktrees and branches

claude-box stop <box>                     # stop one box
claude-box stop --all                     # stop every box
claude-box stop --daemon                  # stop the engine's daemon/VM itself

claude-box harness do "<what you want>"    # draft → implement → review → merge
claude-box harness tick                   # one PM tick, then dispatch role boxes
claude-box harness loop 10m               # keep ticking, under a real lock
claude-box harness status                 # lock, autonomy, in-flight, last tick
claude-box harness autonomy [mode]        # who promotes and who merges
claude-box harness memory                 # review proposed learnings
claude-box harness ui                     # dashboard on localhost
```

`stop --all` stops boxes only. Shutting down the whole daemon is now a separate,
explicit flag — with several boxes running, killing the daemon takes all of them
with it.

## Headless seam (`headless`)

One box, one prompt, one optional worktree, in the foreground, the box's exit code passed
through. This is what an external orchestrator drives — [claude-graph](../claude-graph)
runs its architect/coder/qa/reviewer graph through it — so that the orchestrator never
sees a container path or an engine flag.

```sh
claude-box headless <repo> --name graph-t1-coder-1 --worktree t1 \
    --prompt-file p.md --system-prompt-file s.md --model opus --effort high
claude-box headless <repo> --worktree t1 --remove          # drop the tree, keep the branch
```

`--worktree <id>` creates `<mount>/.claude-box-runs/<id>` on the branch `claude-box/<id>`
(or `--branch <name>`, fixed by the first call) in-container on the first call (same
convention as `run`) and reuses it after; the
command prints `worktree=`, `branch=`, `base=` and `box=` lines before the claude stream
starts, and `base=` stays the ORIGINAL branch point even after the repo's HEAD moves.
Prompts come from files, read on the host, so there is no quoting to get wrong. The box
runs `claude --permission-mode bypassPermissions --output-format stream-json` with
`IS_SANDBOX=1`, exactly like a `run` box.

## Engines (Docker or Apple `container`)

Detection prefers **Docker**, falls back to Apple **`container`**; override with
`CLAUDE_BOX_ENGINE=docker|container`. `abox` is the same runner with the engine pinned to
Apple `container`, for a PATH that already has `claude-box` on Docker:
`ln -s "$PWD/abox" ~/.local/bin/abox`. The runner starts the engine's daemon if it
is down (Docker Desktop is launched and waited for).

The two CLIs look alike and are not compatible, so every difference is funnelled
through one set of `engine_*` helpers:

| | Docker | Apple `container` |
| --- | --- | --- |
| CPU cap | `--cpus` (`-c` there means **`--cpu-shares`**, a weight, not a cap) | `-c` |
| SSH agent | fixed magic path `/run/host-services/ssh-auth.sock` — a plain bind mount of `$SSH_AUTH_SOCK` does **not** work | bind-mount `$SSH_AUTH_SOCK` as a file |
| Egress | NATed by Docker's own VM | needs host IP forwarding — see [networking note](#networking-note-apple-container-only) |
| Daemon | `open -a Docker` | `container system start` |

## Parallel fan-out (`run`)

```sh
./claude-box run -n 4 "make the failing e2e suite green; commit when it passes"
./claude-box results r20260819-142230
```

Each box gets **its own git worktree and branch** (`claude-box/<run-id>-<i>`), cut
from the target repo's current HEAD, so N boxes can attack one prompt without
fighting over a working tree. They run headless (`claude -p`) in
`bypassPermissions` mode — nothing can answer a permission prompt in a headless
box, and the sandbox is what makes that acceptable.

Details worth knowing:

- **Worktrees are created from inside a box, not on the host.** Git stores
  absolute paths in worktree admin files, and the host's path for the mount
  (`/Users/<you>/workspace/…`) does not exist inside the container. Creating them
  in-container means the paths are container paths, which is the side that runs
  the work. On the host those worktrees will look broken — that is expected.
- The target must be a git repo. Worktrees land in `.claude-box-runs/<run-id>/`
  under the mount root, and are added to `.git/info/exclude` when that root is the
  repo itself.
- `results` reports each box's exit code, its commits since the base SHA, its
  diffstat, and how many paths it left uncommitted.
- `cleanup` deletes the worktrees **and** the branches — uncommitted work and
  unmerged commits go with them, so it asks first (`-y` to skip the prompt).
- Claude Code refuses `bypassPermissions` when running as root, which the box
  always is, so headless boxes get `IS_SANDBOX=1` — the "the containment is already
  there" signal. Interactive boxes do not: they have a human who can answer.
- Claude Code is refreshed **once per run**, before the boxes start, and the boxes
  are told to skip their own check. N simultaneous installs into one bind-mounted
  pnpm global dir is a race, not parallelism.
- Extra flags for every box: `CLAUDE_BOX_RUN_ARGS="--output-format stream-json --verbose"`.

## One box per task (config isolation)

A single shared `~/.claude` was fine for one interactive box, but N boxes writing
the same `history.jsonl`, `projects/`, `todos/` and `shell-snapshots/` clobber
each other. So:

- Every box gets a **name** (`claude-box-<slug>`, visible in `ps`) and its own
  config dir under the runner's state dir, seeded from your shared config
  (`settings.json`, `CLAUDE.md`, `plugins/`, `agents/`, `commands/`, `skills/` —
  not session state).
- The **shared credentials file is bind-mounted over the top**, so you still log
  in once and a refreshed token is still shared.
- The plain interactive box keeps the **whole** shared dir, so `--resume` and
  history behave as before — unless another running box already holds it, in which
  case it is told so and gets an isolated dir instead. Force isolation with
  `CLAUDE_BOX_ISOLATE=1`, or name a box with `CLAUDE_BOX_NAME=<name>`.

Runner state lives in `~/Library/Application Support/claude-box-state/` — a
**sibling** of the credentials dir, not a subdir, because that dir is mounted into
the box and one box has no business reading another's state.

## Where your repos land

The root is **`~/Documents/GitHub`** (override with `CLAUDE_BOX_ROOT`), and it is
mounted at the **same path relative to `$HOME`** inside the box — the container runs
as root, so `/root/Documents/GitHub`. That equality is the point: `~/Documents/GitHub/<repo>`
resolves identically on the host and in the box, a path copied from one works in the
other, git worktree `gitdir` files stay valid on both sides, and an ai-bridge
`instance.config.json` with `reposRoot: ~/Documents/GitHub` needs no translation.

`/workspace` and `/root/workspace` remain **symlinks** to the mount, created by the
entrypoint, because absolute `/workspace/...` paths are baked into things the image
can't rewrite: worktree admin files in existing clones, agent definitions and slash
commands, and Claude Code session history.

Mount root and working dir are decoupled:

- **Target under the root** → the **whole root** is mounted (so sibling repos stay
  reachable) and claude's working dir is set to the target's subpath. That
  combination is what lets a project's `.claude/agents` load while its sibling
  clones remain available.
- **Target anywhere else** → that directory itself is mounted at the same container
  path, and pnpm's store moves to a host-side dir so it does not litter your project.

## Harness: role agents in boxes

Six roles, each running in **its own container**, driven from the host:

| Role | Does | Tier → model | Effort |
| --- | --- | --- | --- |
| `project-manager` | Reconciles documents against live git/gh state, refines drafts, decides what to dispatch, reflects merges | `deep` → opus | `xhigh` |
| `architect` | Judges whether a solution is **sound** — before it is built, and again on the PR. Verdict only; writes no product code | `deep` → opus | `xhigh` |
| `lead-dev` | Implements features and fixes in a product repo, opens a PR | `standard` → sonnet | `high` |
| `qa-reviewer` | Writes tests, and reviews an open PR against the task's acceptance criteria | `deep` → opus | `xhigh` |
| `devops` | CI, deploys, images, infra, observability | `standard` → sonnet | `high` |
| `cataloguer` | Turns merged work into knowledge-base entries | `standard` → sonnet | `medium` |

Tier names map to model aliases in `instance.config.json` (`light`/`standard`/`deep`/`apex`
→ haiku/sonnet/opus/fable; no role uses `apex` by default), so a panel follows the latest
model in each family without edits. Effort is passed as `--effort`: `xhigh` for the roles
whose judgement you are paying for, `high` for implementation, `medium` for the cataloguer. It is **omitted for the
`light`/haiku tier**, which rejects the flag — so a role moved to `light` silently
loses its effort setting rather than erroring. Set `fallbackModel` to add
`--fallback-model` to every box.

The roles, the document schema and the panel template all live **in this repo**
(`harness/roles/`, `harness/template/`) — there is nothing to clone. The document
protocol is deliberately compatible with an
[ai-bridge](https://github.com/alteos-gmbh/claude-code-setup) instance: same
frontmatter, same statuses, same two human gates. If you already run one, point the
harness at it and nothing in it needs to change.

### One request, driven to completion

```sh
./claude-box harness do "add rate limiting to the quote endpoint"
```

This is the command for "I asked for one thing, finish it". The host drives the whole
chain itself, because it launches every box and sees each one exit — there is nothing to
poll for:

```
project-manager drafts the documents
  → host promotes the refined drafts        (autonomy: promote or full)
  → the assigned role implements, in its own box
  → qa-reviewer reviews it
      ↳ changes requested? back to the implementer, up to --max-rounds (default 2)
  → wait for CI, then the host merges       (autonomy: full)
```

It stops early, with a distinct exit code, wherever a human is genuinely required:

| Exit | Why it stopped | What to do |
| --- | --- | --- |
| `2` | the PM raised an `open_question` — nothing downstream can answer it | it offers to ask you there and then; otherwise `harness answer` |
| `3` | autonomy is `gated`, so promotion is yours | promote, or `harness autonomy promote` |
| `0` | the task reached `done` | nothing |

### Jira

Work is mirrored into Jira when the panel asks for it. **No credential is forwarded** — the
account's Atlassian connector is available inside every box already (`claude mcp list` shows
`claude.ai Atlassian Rovo: ✔ Connected`), so the boxes can read and write Jira with the same
access you have.

```json
"jira": {
  "enabled": true,
  "site": "your-org.atlassian.net",
  "project": "DPT",
  "epicIssueType": "Epic", "storyIssueType": "Story", "subtaskIssueType": "Subtask",
  "labels": ["agent"]
}
```

| Panel | Jira |
| --- | --- |
| project | **Epic**, key recorded in `jira_epic:` on `project.md` |
| task | **Story**, key recorded in `jira:` on the task |
| separable steps inside a task | **Sub-tasks**, only where they are genuinely separable |

**One direction: the panel drives Jira.** The panel is the source of truth for what the work
is; Jira is where the organisation tracks it. Two-way sync is how tracker integrations rot.

Who does what:

- The **project-manager** creates the epic and the stories, copies the **acceptance criteria
  in full** into each ticket (a reviewer must be able to check the ticket without opening the
  panel), records the keys, and searches for an existing issue before creating anything — a
  duplicate ticket is worse than a missing one, because two people then think they own it.
- The **role doing the work** keeps its own issue honest: In Progress when it starts, In
  Review with the PR link when it opens one, a comment with the reason when it blocks. It
  reads the available transitions first rather than guessing a status this workflow lacks,
  and it never closes an issue or opens a second one.
- The **project-manager reconciles every tick** — a task at `in-review` whose story still
  says To Do is drift, and drift is what makes people stop trusting a tracker.

The dashboard shows each task's key (and each project's epic) as a link straight into Jira.

Nothing here is testable without a real Jira: the checks cover the plumbing — config,
fields, links — not the MCP calls. Probe it with one cheap run before trusting it with a
backlog.

### `blocked` with green CI is a real state, not a contradiction

The `qa:` verdict has two values, because **CI is the source of truth**:

| `qa:` | Meaning | Next |
| --- | --- | --- |
| `approved` | every criterion met, with a CI run as the evidence | merge (the host does it under autonomy `full`) |
| `changes-requested` | a defect against the criteria, or a criterion no CI job proves yet | another implementation round |

There is no verdict that hands verification to a person. A criterion a box cannot check —
needs a deployed environment, a secret, a browser — is a **CI job that does not exist yet**,
and writing it is work like any other, so it comes back as `changes-requested` with the job
named. The host enforces that: any verdict other than `approved` is sent back with
instructions to wire the check into CI, copying the nearest existing job in that repository.
If the job needs a secret nobody has granted, the job still gets written, referencing the name
it should have, and that name is listed under `## Blocked on` in the PR body — a value waiting
to be filled in, not an errand waiting for a human.

### Objectives, and who writes them

Every project gets `objectives/<slug>.md`: the goal in one line, **Why now**, **Done when** (two
to four checkable statements), **Not doing**. The project-manager writes it while drafting and
keeps it current; the project document points at it with `objective:`. `status: met` is a claim
about the world, so it cites what proves each "done when" line.

### The cataloguer runs when work is accepted

Once `qa: approved` is on a task, the host dispatches one cataloguer box for it, stamps
`catalogued:` on the document so it never happens twice, and lets it write into `knowledge/` —
a Finding for a decision or a gotcha, a Service page for a boundary that is now real, a Runbook
for a procedure someone will repeat. One document is a good outcome; none is fine when the task
taught nothing durable. Before this, the role was configured and never dispatched, so
`knowledge/` sat at its template while every learning went to the memory tier instead.

### Rounds happen in the task document, not in the PR thread

A review round is two boxes talking. The implementer reads the task document before every round,
so the qa-reviewer's findings go in `# Review` and the architect's in `# Design review` — not as
PR comments, and never through `gh pr review`, whose `--request-changes` and `--approve` are
review events that notify people and change the merge state.

The pull request has two agent-written surfaces: the **body**, rewritten in place each round so
it always describes the change as it stands (including `## Blocked on`), and **one comment**,
posted only once the change is finished, naming what proves each criterion. Four rounds of
commenting buries the one comment a human needs under three that are already resolved.

### The design gate

A task whose frontmatter carries `design_review: required` is **not implemented** until the
`architect` has judged the approach and written `arch: sound`. On `arch: changes-requested`
it goes back to `draft` for the project-manager to rework — nothing is built. The architect
looks for the findings that only exist before code: does this belong here, does it already
exist elsewhere, is the boundary right, what does it couple, is it reversible, does it match
the codebase's own conventions.

The project-manager requires a review when the work **sets a precedent** — a new service or
package, a schema or public API change, work crossing a repo boundary, a migration, a new
dependency, a pattern the codebase does not have — and not for a bug fix or a change that
follows an existing pattern. A gate that fires on everything is a tax that teaches everyone
to route around it.

It is also told to say when things are fine: `arch: sound` with what was verified. A reviewer
that always finds problems gets ignored.

### Reading CI honestly

Two mistakes are easy here and the dashboard used to make both.

**Skipped is not failed.** In a monorepo most jobs are path-filtered, so the majority of checks
skip on any given PR — that is the system working, not a problem. A PR is judged by whether a
check that *ran* failed, and by `mergeStateStatus` — GitHub's own answer about the repository's
required checks — rather than by counting skips.

**Every failing check counts, required or not.** A check that ran and failed is worth fixing
whichever way branch protection is configured — the harness never filters on "required".
`mergeStateStatus` is reported as extra context (GitHub saying *blocked*, *behind*, *dirty*), never
as the gate.

**A red check is not automatically the PR's fault.** For every failing check the dashboard asks
whether the same check is already failing on the base branch, and splits them:

- *caused by this change* — the check passes on the base, so this PR broke it. The task is
  marked stalled with the check names.
- *already failing on `<base>`* — somebody else's problem, reported and not treated as this
  PR's work.

The roles are told the same, because this is where an agent does real damage: it will otherwise
"fix" code it never broke, or make a check green by skipping a test, loosening an assertion or
disabling the job. The standards forbid all three, require reproducing a failure locally before
guessing, and treat "it's flaky" as a claim needing two runs' evidence.

### Answering a blocking question

When the project-manager needs a decision only you can make, it records a numbered
`open_questions` entry and the task stays unpromotable. `harness do` offers to ask you on
the spot; otherwise:

```sh
claude-box harness answer                          # every open question, one prompt each
claude-box harness answer --project <slug>         # just that project
```

Each answer is appended to its own question line — `"Q1: which region? --- eu-central-1"` —
which is the form the project-manager folds in and clears on its next pass. Editing the
YAML by hand works too, but the arrays are multi-line and quoted, so let the tool do it.

### Closing work out yourself

Nothing in the harness writes `done` on its own — even `autonomy full`, which merges, leaves
the status alone. If you merge a PR yourself (a protected branch, a review someone else has to
click), or you simply decide a piece of work is finished, tell the panel:

```sh
claude-box harness done projects/<slug>/tasks/t1.md    # a task, from whatever state it is in
claude-box harness done projects/<slug>/project.md     # a whole project
claude-box harness done <slug>                         # same project, by slug
claude-box harness done projects/<slug>/tasks/t1.md --no-pr   # do not even ask gh
```

It never refuses on status: draft, in-progress, blocked, even cancelled can be closed out —
that call is yours. What it does instead is **record what was true**. Every URL in the task's
`pr:` is looked up with `gh`, and the answer goes into `# Notes` verbatim:

- `4 PR(s) merged, checked against gh`
- `NOT every PR was merged — https://…/pull/3 OPEN`
- `no PR on this task`, or `gh not on PATH, so the merges were never checked`

So a `done` can never quietly imply a merge that did not happen, which matters because `done`
is terminal — `harness clean` keeps it. On a project it records which of its tasks were not yet
done or cancelled. The dashboard's **mark done** button, on any task card and on any project
row, runs exactly this command.

### Resuming

```sh
claude-box harness do --resume                     # everything unfinished
claude-box harness do --resume --project <slug>    # just that project
claude-box harness do --resume --dry-run           # what it would pick up
```

**It keeps going while work comes back.** A review that requests changes puts a task back
behind the cursor, so a single forward pass stranded it until someone noticed and re-ran the
command. `--resume` now makes another pass whenever something in scope is actionable again,
bounded by `--passes` (default 3) — so a task that keeps bouncing costs a few attempts, not a
loop.

Resume never calls the project-manager to draft, so it cannot duplicate a project — which
re-running `harness do "<same text>"` would. It takes `ready`, `in-progress` and
`in-review` and skips `done`, `cancelled` and `blocked`; a task already `in-progress` is
*continued* ("read its `# Result` first, don't redo committed work") rather than restarted.

**Answers are folded in first.** An answered question still occupies its `open_questions`
entry, and the host refuses to promote a task while any entry remains — an answer can
change the work, or cancel it. So resume runs one project-manager box to fold your answers
into the tasks, clear the entries, and **cancel any task whose answer said to skip it**.
Cancelled tasks then drop out of the run. Without that pass a resume would stall silently
on every answered task.

### Watching a box work

Headless boxes run with `--output-format stream-json --verbose`. That is not a detail: the
default text output prints **nothing until the run finishes**, so a seven-minute box looked
hung and its log held a single line. The stream lands raw in the log file and
`harness/render-log.py` turns it into something readable:

```
·   session started
    thinking…
→   Bash  pnpm --filter configuration-studio-v2 exec playwright install
    ok
→   Write  apps/configuration-studio-v2/playwright.config.ts
»   Scaffolded the config and the login page object; running the suite now
✓   finished: success in 512.4s, 34 turn(s), $2.9104
```

```sh
claude-box logs -f <box>          # rendered, follows
claude-box logs --raw <box>       # the underlying stream-json
```

The dashboard renders the same feed in its log drawer, and each in-flight card shows the
newest action plus a running token estimate — so a working box and a stuck box no longer
look identical.

### Dashboard

The only wait in the whole pipeline is CI, which runs on someone else's schedule — that
gets a bounded poll (`CLAUDE_BOX_CI_TIMEOUT`, default 900s) and then hands off to the loop
rather than blocking forever.

#### `do` versus `loop`

They are for different shapes of work, and using the wrong one is the mistake this section
exists to prevent:

- **`harness do "<request>"`** — one request, start to finish, in the foreground. No
  polling, no idle ticks, no cost when nothing is happening. This is what you want for
  "add rate limiting".
- **`harness loop 10m`** — a scheduler for a *queue*: several projects in flight, CI that
  finishes minutes later, questions you answer tomorrow, work arriving over days. Every
  tick spends a project-manager box whether or not anything changed, so a short gap on an
  idle panel burns tokens for no reason.

Run `do` when you have a request. Run `loop` when you have a backlog.

### Create work from a sentence

```sh
./claude-box harness new ~/Documents/GitHub/_panel "add rate limiting to the quote endpoint"
```

The project-manager writes the project and task documents for you — deciding whether
the work belongs in an existing project, splitting it into independently reviewable
slices, filling `acceptance_criteria`, and raising `open_questions` where a decision is
genuinely yours. Everything it writes is `status: draft`; it cannot promote, so the gate
stays with you. `--project <slug>` adds to an existing project, `--repo <name>` names the
target, `--dry-run` shows the ask without spending a box.

You can still hand-write a task document — `SCHEMA.md` in the panel has the shape — but
you never have to.

### Set up a panel

```sh
./claude-box harness init --org <your-gh-org> --email you@example.com
```

That stamps `$CLAUDE_BOX_ROOT/_panel`. **You do not pass the path again** — every
harness command resolves the panel in this order: the argument you give it,
`$CLAUDE_BOX_PANEL`, the current directory if it is a panel, or the only panel under the
root. With one panel, `harness tick` and friends take no arguments at all. Pass a
directory to `init` when you want several (work vs. side project); the harness then asks
which one rather than guessing.

### Why the panel is not this repo

Three separate things, and only two of them are yours:

| | What it is | Who maintains it |
| --- | --- | --- |
| `claude-box` | the tool: runner, roles, template, tests | this repo, updated when the tooling changes |
| `_panel` | **your data**: objectives, projects, tasks, knowledge | it *is* the work — the way a ticket tracker is, not maintenance |
| a target repo | the product code the agents change | already yours |

The panel is deliberately not a subdirectory of this repo. It holds your task queue and
knowledge base, which version at a different rate than the tool, and which you may want
private, or shared with a team, while the tool stays generic. `harness init` makes it a
local git repo so the knowledge base is a record rather than a snapshot — `--no-git` if
you would rather it were a plain directory. It never needs a remote.

A **control panel** is an [OKF v0.1](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
knowledge bundle: a directory tree of markdown documents — objectives, projects, tasks,
knowledge — that drives work in the repos beside it. Three spec rules the harness holds
you to, because breaking them silently degrades the bundle: `index.md` files carry no
frontmatter (only the bundle root, and only `okf_version`), cross-links are
bundle-relative and start with `/`, and unknown types and fields are tolerated — which
is why the task lifecycle can be richer than OKF's own `todo`/`in_progress`/`done`. `init` is idempotent, and
the split is the thing to remember: it **refreshes the machinery** (roles,
`SCHEMA.md`) on every run so a fix reaches every panel, and **never touches your
data** (config, projects, objectives, knowledge, log). `--keep-roles` if you have
edited a role and want it left alone.

Then write a task at `projects/<slug>/tasks/<id>.md` with `status: draft`, promote it
yourself, and tick.

What running the roles as boxes buys over in-session subagents:

- **Isolation.** Each role gets its own container, context window and log, so one
  role cannot exhaust another's context and a crash takes down one box.
- **A real lock.** The lock is a directory in the state dir holding the driver's pid:
  a second loop against the same panel cannot start, and a dead holder's lock is
  reclaimed rather than wedging the panel. (ai-bridge's own `pm-loop` documents this
  guarantee as per-session only, with avoiding a second loop left to the human.)
- **A cap that means something.** `maxAgentsInFlight` is intersected with what the
  host can actually afford (`memory budget ÷ per-box memory`), so the smaller number
  wins instead of being assumed.

### The loop

```sh
./claude-box harness do   "<what you want>"    # draft → implement → review → merge
./claude-box harness new  "<what you want>"    # just draft the documents
./claude-box harness tick                     # one tick
./claude-box harness tick --dry-run           # show, don't spend
./claude-box harness loop 10m                 # keep going
```

A tick is: run the project-manager in a box → read the dispatch intents it wrote →
validate each → launch a box per accepted intent → wait → check nobody promoted a
task. The panel argument defaults to the current directory and must be a panel
(`instance.config.json` + `SCHEMA.md` + `.claude/agents`) under the root — one stamped
by `harness init`, or an existing ai-bridge instance.

### Why intents instead of the engine socket

A role box **cannot launch containers**. It writes a dispatch intent —
`.harness/intents/<name>.json` — and the host launches the box. Mounting the engine
socket into a box would hand a sandboxed agent control of the host daemon, which is a
sandbox escape, not a feature.

The indirection pays for itself twice over: every dispatch exists as a file before a
container does, so a tick is replayable and a bad dispatch is inspectable; and the
host can **refuse** one for free. An intent is rejected unless the role is listed in
`instance.config.json`, the task path stays inside the instance, the task's own
frontmatter says `ready` (a human promoted it), the target repo is a git repo under
the root, no box already owns that task, and both caps have room. Refusals land in
`.harness/intents/rejected/` with the reason, which the next tick reads.

### Autonomy: handing the gates to the host

```sh
./claude-box harness autonomy            # what mode am I in
./claude-box harness autonomy promote    # stop approving drafts
./claude-box harness autonomy full       # stop approving merges too
./claude-box harness autonomy gated      # take both back
```

| Mode | Promotion | Merge |
| --- | --- | --- |
| `gated` (default) | you | you |
| `promote` | the host, once a task has criteria and no open questions | you |
| `full` | the host | the host, if every machine gate passes |

**The switch lives in the runner's state directory on the host, not in the panel.** That
is the design, not an implementation detail: a box only ever has its own config dir
mounted, so an agent cannot grant itself autonomy — not by editing `instance.config.json`,
not by writing a file, not by persuading the project-manager. ai-bridge gates this on a
file inside the bundle; moving it outside makes it enforceable rather than conventional.

Promotion is still never done by a role, in any mode — the host does it, so the
revert-guard stays armed and a role that writes `ready` is still caught and logged.

Every machine gate on a `full` merge, all required:

- the task carries `qa: approved`, written by a qa-reviewer box that did not write the code
- the PR is open and mergeable
- every CI check succeeded — and **a PR with no checks at all is refused**, because that
  is absence of evidence, not evidence of passing
- at most `CLAUDE_BOX_MAX_MERGES_PER_TICK` (default 3) merges per tick, so a bad night
  cannot merge forty PRs

What no gate covers: whether the task was specified correctly. An agent that satisfies a
wrong acceptance criterion produces a green, approved, merged mistake. Everything is
recoverable through git; recoverable is not the same as prevented.

### The two gates in `gated` mode

The image's policy `deny` list blocks `gh pr merge` outright. Promotion `draft →
ready` is an ordinary file edit, so no permission rule can stop it — instead the host
snapshots task statuses around every box and **reverts** any promotion a role wrote,
recording it in the tick's `violations.tsv`. Enforcement is the host's check, not the
overlay's wording.

### Memory: three tiers, and a gate on two of them

| Tier | Lives in | Scope | How it grows |
| --- | --- | --- | --- |
| Global | `<state>/harness/memory/` | every repo and instance | you accept a proposal |
| Panel knowledge base | `<panel>/knowledge/` | this panel's services, findings, runbooks | the `cataloguer`, directly |
| Repo-scoped | `<panel>/memory/repos/<repo>/` | one product repo | you accept a proposal |

Repo-scoped memory lives in the **panel**, not in the product repo. Accepting a learning must
never modify a checkout the human did not ask us to touch — an earlier version wrote into
`<repo>/.harness/memory/` and left a dozen untracked files in a monorepo working tree, which is
the pollution without the sharing, since nothing ever committed them. Commit the panel to share
learnings with a team. A repo that *does* want to publish its own learnings can still keep
`.harness/memory/` — the harness reads it and never writes there.

Every role box gets all three read-only, in that order, later tiers overriding
earlier ones, capped at `CLAUDE_BOX_MEMORY_MAX` characters (default 8000) so memory
cannot crowd out the task. The knowledge base is **referenced, not inlined**: its
`index.md` is a lookup surface, so the preamble points there and lets the role open
only what it needs rather than bulk-reading the directory.

Role boxes never write memory. They propose:

```markdown
---
tier: global | repo
repo: <repo-name>          # required when tier is repo
evidence: <task path, PR link or file:line>
---

One or two sentences, phrased as an instruction to a future agent.
```

Proposals queue in `<instance>/.harness/pending/`. Accept them with:

```sh
./claude-box harness memory <instance>     # [a]ccept [e]dit [d]rop [s]kip [q]uit
```

Accepting a `repo` proposal writes it into the product repo, where it shows up in a
normal diff. **The panel's knowledge base is deliberately outside this gate** — the
`cataloguer` writes it directly, because an index that lags behind merged work is
worse than no index. The trade is explicit: the tier with the most churn is the
unreviewed one.

### Watching a box work

Headless boxes run with `--output-format stream-json --verbose`. That is not a detail: the
default text output prints **nothing until the run finishes**, so a seven-minute box looked
hung and its log held a single line. The stream lands raw in the log file and
`harness/render-log.py` turns it into something readable:

```
·   session started
    thinking…
→   Bash  pnpm --filter configuration-studio-v2 exec playwright install
    ok
→   Write  apps/configuration-studio-v2/playwright.config.ts
»   Scaffolded the config and the login page object; running the suite now
✓   finished: success in 512.4s, 34 turn(s), $2.9104
```

```sh
claude-box logs -f <box>          # rendered, follows
claude-box logs --raw <box>       # the underlying stream-json
```

The dashboard renders the same feed in its log drawer, and each in-flight card shows the
newest action plus a running token estimate — so a working box and a stuck box no longer
look identical.

### Dashboard

```sh
./claude-box harness ui <instance> --port 7777      # http://localhost:7777
```

Live view of what the agents are doing:

- **Waiting on you** — every unanswered question, first, because it blocks everything else
- **Projects** — one row each: title, repo, task counts by state, how many are waiting
- **Board** — tasks by status; click one for its **rendered plan**: acceptance criteria as a
  numbered list, questions with your answers highlighted, PR links with CI state,
  dependencies, and the task document as formatted markdown (with a `raw` toggle). Task
  documents are agent-written and the page holds an action token, so the renderer escapes
  everything first and never inserts markup from a document — there is a test for that
- **Boxes in flight** — role, task, a ticking elapsed counter, live log tail
- **Logs** — every recent box, running or finished, openable; a finished box's log is
  exactly when you want to read it
- **Roles** — every role this panel can dispatch: what it is for, which model and effort it
  runs on, whether it is working something right now, and what it has cost (runs, failures,
  total, average cost and time). One table for "who exists" and "what they cost"
- **Memory** — what is actually *in* memory, per tier (global, repo-scoped, the knowledge
  base index), each readable in full in the drawer. Proposals sit above it with **accept**
  and **drop** buttons when actions are enabled — acceptance routes through the same
  `harness memory` command the terminal uses
- Refused dispatches with reasons, and run history badging any reverted promotion It polls a read-only JSON endpoint that reads the same files
the harness writes, so there is no second source of truth to drift.

Bound to `127.0.0.1` only, no external assets, nothing published — your task titles
and repo names stay on the machine. Token-shaped strings are redacted before any log
or proposal is served, because the harness forwards real credentials into every box
and a browser tab is the wrong place for one to surface.

### What a role box can and cannot reach

A box gets its own `~/.claude`, seeded from `~/Library/Application Support/claude-box` —
**not** your host `~/.claude`. That decoupling is deliberate, and two defaults follow from
it:

- **Plugins, commands and skills are not seeded** into role boxes. A role box should be
  deterministic, and process frameworks are the opposite here: they add planning gates a
  headless box cannot answer, and several of them write plan or spec documents into
  whatever repo they run in. `CLAUDE_BOX_SEED_PLUGINS=1` seeds them from the box config
  when you want them.
- **Your host plugins are not mounted.** `CLAUDE_BOX_HOST_PLUGINS=1` bind-mounts
  `~/.claude/plugins` read-only into the box, when you specifically want a host skill in
  there.

Stacked PRs need no skill: the `gh-stack` extension is in the image and the workflow is in
the roles.

### A protected branch only takes pull requests

The image installs a **pre-push hook** that refuses a direct push to the remote's declared
default branch, or to `main`, `master`, `trunk`, `develop`, `next`, `production` or
`release`. The roles were already told to open a PR and the policy layer already denied
`gh pr merge` and force-pushes — but none of that stops `git push origin main`, which is
the one command that could put unreviewed agent work on your trunk. Now it fails, names the
branch, and prints the two commands to do it properly.

```sh
CLAUDE_BOX_ALLOW_DIRECT_PUSH=1 git push origin main   # a human who means it
```

Tags are unaffected, and feature branches push normally.

### Code standards every role reads

`harness/standards.md` goes into every role's system prompt: single responsibility, DRY
**with the rule of three** (two occurrences stay, three get abstracted — a wrong
abstraction is load-bearing in a way duplication is not), KISS, and current practice for
types at the edges, error context, bounded async, immutability, tests-as-specification,
reversible migrations, observability, security, accessibility, and measured performance.
Plus PR hygiene: small enough to review in one sitting, or a stack.

It ships with claude-box rather than the panel, so an edit reaches every panel at once. A
panel that wants its own puts `STANDARDS.md` at its root and that replaces the shipped one
outright.

### Agent scratch never reaches a product repo

The image's pre-commit hook refuses staged paths that are process exhaust rather than
deliverable — `docs/superpowers/`, `.harness/`, `.claude-box-runs/`, `_wt/`,
`.pnpm-store/`, `CLAUDE.local.md`, `.claude/settings.local.json`, `*.original.md` — and
names what it refused. Roles are also told to stage by explicit path and never
`git add -A`, but the hook is what enforces it.

```sh
CLAUDE_BOX_ALLOW_SCRATCH=1 git commit …   # when one of those genuinely belongs
```

### Knobs

| Env var | Default | What it does |
| --- | --- | --- |
| `CLAUDE_BOX_ROOT` | `~/Documents/GitHub` | the repos root, mounted with `$HOME`-relative parity |
| `CLAUDE_BOX_ROLE_TIMEOUT` | `2700` | seconds before a wedged box is stopped |
| `CLAUDE_BOX_MEMORY_MAX` | `8000` | character cap on the memory preamble |
| `CLAUDE_BOX_STATE` | `~/Library/Application Support/claude-box-state` | runner state, locks, global memory |
| `CLAUDE_BOX_SEED_PLUGINS` | `0` | seed plugins/commands/skills into role boxes |
| `CLAUDE_BOX_HOST_PLUGINS` | `0` | mount your host `~/.claude/plugins` read-only |
| `CLAUDE_BOX_CI_TIMEOUT` | `900` | how long `harness do` waits on CI before handing off |
| `CLAUDE_BOX_MAX_MERGES_PER_TICK` | `3` | ceiling on autonomous merges per tick |

### Tests

```sh
tests/run-all.sh
```

96 checks over `harness init` (machinery refreshes, your data never does), intent
validation including ai-bridge's `<org>/<repo>` spelling, caps and idempotency, memory
tiering and acceptance routing, lock contention and stale reclaim, prompt assembly, a
whole tick, and the promotion guard. They run against `CLAUDE_BOX_ENGINE=fake`, a stub engine
that records what would have been launched — so the suite spends no containers and no
tokens. One boundary is **not** covered automatically: a real `claude` process
writing a real task document. That needs a logged-in box and costs tokens per run, so
it is checked by hand.

## Baked-in settings (`settings.json`)

`settings.json` in this repo is the Claude Code policy for the box. It is copied
into the image at build time, so **edits take effect on the next
`./claude-box build`** — nothing to configure on the host.

It does two things: starts every session in **auto** permission mode (the box is
already a sandbox, so per-tool prompts buy nothing), and **denies the operations
the sandbox cannot undo**. Deleting files is contained by the sandbox; force-push,
merging a PR and deleting a repo are not — they reach GitHub.

```json
{
  "permissions": {
    "defaultMode": "auto",
    "deny": ["Bash(git push --force:*)", "Bash(gh pr merge:*)", "…"]
  }
}
```

> Deny rules are **prefix** matches, so `git push --force origin main` is caught
> but `git push origin main --force` (flag last) is not. Treat the list as a
> guardrail against the obvious accident, not a sandbox boundary.

The file is copied to `/etc/claude-code/managed-settings.json` rather than into
`$CLAUDE_CONFIG_DIR`, for two reasons: `/root/.claude` is bind-mounted from the
host, so an image-baked file there is shadowed at run time; and Claude Code
honours `defaultMode: "auto"` only from **policy**, **user**, or `--settings`
sources — project/local settings are ignored as repo-controllable. The policy
path sits outside every mount, so it applies however `claude` starts, including
by hand after `./claude-box shell`.

> Because it is the policy layer, it wins over the host-side user config in
> `~/Library/Application Support/claude-box` — which is what makes this repo the
> single source of truth, but also means anything you add here can no longer be
> changed from inside a session. Keep it to what the box should enforce.
> (shift+tab still switches mode for the session at hand.)

## Secret scanning

gitleaks was in the image already but wired to nothing. It is now the image's
global `core.hooksPath` **pre-commit** hook, so every repo the box touches gets
the gate with no per-repo setup. It matters most for headless boxes: they run in
`bypassPermissions` mode with a forwarded GitHub token and nobody reading the diff.

```sh
CLAUDE_BOX_SKIP_GITLEAKS=1 git commit …   # skip the scan once
git commit --no-verify                    # skip all hooks
```

A repo that sets its own `core.hooksPath` (husky and friends) overrides the hook —
repo config beats global config.

## Keeping Claude Code updated

The image bakes in a pinned Claude Code at **build** time; `entrypoint.sh` moves
it forward on container **start**, but only when that start is actually launching
`claude`:

| How you start it                     | Refresh? |
| ------------------------------------ | -------- |
| `./claude-box [<dir>] [<claude args>]` | yes    |
| `./claude-box [<dir>] shell`, or any explicit command | no |

Two rules keep it honest, both learned from a real failure — a dangling shim plus a fresh
stamp left a box unable to start `claude` at all, and the "fallback to the baseline" claim
was fiction because a broken shim on the mounted dir *shadows* the working baseline:

- **Verify before stamping.** The stamp is written only after `claude --version` actually
  runs. An install that finishes but does not work is discarded.
- **The global install owns its store.** pnpm's global `node_modules` is a symlink farm
  into the store, so if the store path moves — and it depends on what was mounted — every
  link dangles. The global install therefore uses a store *inside* the persisted dir, where
  the two move together. Project installs keep the workspace store, which is what lets
  pnpm hardlink into `node_modules`.

A broken persisted install is detected at start, discarded, and reinstalled; if that
fails, the mounted shim is removed so the image baseline takes over for real.

Two things make it cheap rather than wasteful:

- The update installs into **`/root/pnpm-global`, which is bind-mounted from the
  host**, so it persists instead of dying with the `--rm` container. The
  build-time baseline stays underneath it on `PATH` as the offline fallback.
- A **stamp file** skips the check when one ran recently
  (`CLAUDE_BOX_UPDATE_TTL`, default 6h). Without both, every start re-installed
  Claude Code and threw it away — times N for a fan-out, all contending for one
  pnpm store.

```sh
claude-box-update              # inside the box: check now (respects the TTL)
claude-box-update --force      # ignore the stamp
CLAUDE_BOX_SKIP_UPDATE=1 ./claude-box <dir>   # skip it entirely (fast offline start)
```

The refresh is **best-effort and non-fatal**: offline or behind a VPN that has
dropped egress it warns and falls back to the installed version.

> Because this lives in the image, run `./claude-box build` once to pick up
> entrypoint changes; every start after that self-updates.

## VM sizing (memory & CPUs)

Each **background agent** is another full Claude Code (Node) process plus the
tools it spawns, so parallel agent fan-out multiplies the RAM and CPU the box
needs. A hard 4G cap let a few concurrent agents exhaust the VM's memory — with
no swap that means an OOM kill (leaving the parent hung on a dead child) or
thrashing, both of which present as the box **freezing**.

Defaults are now derived from the host — **8 GiB (or a quarter of host RAM,
whichever is smaller) and 4 CPUs** — and `run -n N` divides a **budget** across
the N boxes instead of handing each the single-box default, which would
oversubscribe the host:

| Env var | Default | Effect |
| --- | --- | --- |
| `CLAUDE_BOX_MEM` | `8G` capped at host/4 | per-box memory; set explicitly and it wins everywhere, including fan-out |
| `CLAUDE_BOX_CPUS` | `4` | per-box CPU cap (fan-out divides host CPUs, max 4) |
| `CLAUDE_BOX_FANOUT_MEM_PCT` | `60` | share of host RAM a whole fan-out may claim |
| `CLAUDE_BOX_MIN_BOX_GIB` | `3` | below this the fan-out refuses to start and tells you the max `-n` |

```sh
CLAUDE_BOX_MEM=16G CLAUDE_BOX_CPUS=8 ./claude-box <dir>
```

To confirm memory is the bottleneck during a freeze, watch usage from inside the
box (`./claude-box shell`, then `watch -n1 'free -m; ps aux --sort=-%mem | head'`
— `procps` is in the image for exactly this) — if available memory collapses
toward zero as the freeze hits, raise `CLAUDE_BOX_MEM`.

## Auth

Decoupled and persistent: sandbox credentials live on the host at
`~/Library/Application Support/claude-box/` (bind-mounted to `/root/.claude`), so
you `/login` once and never again. The host Keychain and any Claude Code agents
running outside the container are never touched. GitHub uses the existing
`gh auth token`; SSH forwards the host agent (private keys never enter the
sandbox), with `~/.ssh/known_hosts` mounted read-only so host-key verification
doesn't prompt. `ANTHROPIC_API_KEY` is forwarded when set, for boxes driven by
something that has one.

**Git identity** is passed through as `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, read from
your host `git config`. The host `~/.gitconfig` itself is still not mounted (it is
full of macOS-only paths and credential helpers) — but the box no longer has *no*
identity, so agent commits land attributed. Per-repo config still overrides it.
`TZ` is forwarded too, so the box agrees with you about what "today" is.

> **The sandbox contains the filesystem, not your GitHub account.** `GH_TOKEN` is
> your full host token, in the box's environment, readable by every agent in it,
> with unrestricted egress. The `deny` list blocks the obvious irreversible
> commands, but if that token's reach makes you uncomfortable, launch with a
> narrower one: `GH_TOKEN=<scoped-token> ./claude-box …`.

## Why installs were slow (and are not any more)

Three things were making every task pay a cold start, and the first was my own convention:

- **A private per-worktree pnpm store.** The roles were told to pass
  `--store-dir <worktree>/.pnpm-store` to avoid concurrent-install corruption. pnpm locks
  its own store, so that guard bought nothing and cost everything: a **full cold download of
  the monorepo's dependency tree on every single task**. Roles now use the store already
  configured in the box — on the mount, shared, warm between runs, hardlinked into
  `node_modules` — and are told never to pass `--store-dir`.
- **Corepack re-downloading the repo's pinned pnpm.** `COREPACK_HOME` now lives in the
  persisted pnpm dir, so `packageManager: pnpm@9.15.4` is fetched once per host.
- **A two-minute command timeout inside the box**, which pushed agents into `nohup` +
  polling gymnastics around every install. The managed settings now set
  `BASH_DEFAULT_TIMEOUT_MS=600000` and `BASH_MAX_TIMEOUT_MS=1800000`, so a long install runs
  inline and the agent can just read its output.

Roles are also told to install the narrowest scope (`--filter <app>...`) and never to
`git checkout -- pnpm-lock.yaml` and reinstall from scratch to tidy up — that throws away
exactly the warm state that makes the next run fast.

## pnpm store (persistent + shared)

The container runs with `--rm`, so anything on its own filesystem is lost on exit.
The image sets pnpm's `store-dir` to `/root/workspace/.pnpm-store`, which — being
the bind-mounted workspace — persists as a real host dir, sits on the same
filesystem as `node_modules` (so pnpm hardlinks instead of copies), and is shared
with the host.

When the box is pointed at a target **outside** `~/workspace`, that path would
materialise as a `.pnpm-store` inside your own project directory. Those boxes get
a shared store from the runner's state dir instead (mounted at `/root/.pnpm-store`,
re-pointed by the entrypoint). It is a separate mount, so pnpm copies rather than
hardlinks there — the trade for not littering your project.

## Private registry auth (GitHub Packages)

Private scoped packages published to GitHub Packages (`npm.pkg.github.com`) need a
token. The runner forwards the host's `GITHUB_REGISTRY_ACCESS_TOKEN` into the box,
and the **image's user-level `/root/.npmrc`** carries the auth line that references
it:

```
//npm.pkg.github.com/:_authToken=${GITHUB_REGISTRY_ACCESS_TOKEN}
```

This must be at the **user level**, not in a repo's `.npmrc`: pnpm v11 refuses to
expand `${ENV}` in credentials read from a project (committed) `.npmrc`. The token
is resolved at runtime from the forwarded env var, so nothing secret is baked into
the image. Make sure `GITHUB_REGISTRY_ACCESS_TOKEN` is exported in the shell where
you launch `claude-box`.

### Declaring which scopes are private

The auth line above authenticates *any* scope on GitHub Packages, but which
`@scope` actually resolves there is deployment-specific, so it is **not** baked
into the image. List your scopes in `registries.npmrc` in this folder — one per
line, gitignored so no org name is committed:

```
@your-scope:registry=https://npm.pkg.github.com/
```

Copy `registries.npmrc.example` to `registries.npmrc` to start. A fresh clone with
no `registries.npmrc` still builds (the committed `.example` keeps the glob `COPY`
from failing) — you just get no private scopes until you add one.

## Reproducible builds

The version-bearing inputs are build ARGs, so a build can be pinned without
editing the Dockerfile:

```sh
docker build -t claude-box:latest \
  --build-arg DEBIAN_REF=debian@sha256:<digest> \
  --build-arg GITLEAKS_VERSION=8.21.2 --build-arg GITLEAKS_SHA256=<sha256> \
  --build-arg PNPM_VERSION=10.15.0 --build-arg GH_STACK_REF=<tag> .
```

The defaults deliberately track moving tags — that is what keeps the toolchain
current. The gitleaks download is always verified against the release's own
checksums file, which catches a corrupt transfer; that is **not** supply-chain
pinning (the publisher controls both files), which is what `GITLEAKS_SHA256` is
for. `curl https://vite.plus | bash` remains an unpinned install script.

## Networking note (Apple `container` only)

Apple `container` puts the sandbox on a vmnet subnet behind `bridge100`; reaching
the internet needs the **host** to forward those packets out `en0`. A VPN (e.g.
AWS Client VPN) zeroes `net.inet.ip.forwarding` on connect and doesn't restore it
— so the container silently loses egress (looks like a hang at
"Checking connectivity…"). The runner detects this and re-enables forwarding via
`sudo sysctl -w net.inet.ip.forwarding=1` only when it's off.

To keep that prompt-free, install a scoped sudoers rule (validate with
`visudo -c -f` first):

```
# /etc/sudoers.d/claude-box-ipforward   (0440 root:wheel)
<you> ALL=(root) NOPASSWD: /usr/sbin/sysctl -w net.inet.ip.forwarding=1
```

Docker Desktop NATs through its own VM and needs none of this.

## Requirements

macOS on Apple Silicon, plus **either** Docker (Desktop or any daemon your
`docker` CLI can reach) **or** macOS 26 with the `container` CLI and Rosetta
(`softwareupdate --install-rosetta`) for its buildkit VM.
