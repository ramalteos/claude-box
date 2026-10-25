# Harness: role agents in boxes

Six roles, each running in its own container, driven from the host over a **control
panel**: a directory of markdown documents (objectives, projects, tasks, knowledge) that
lives beside your repos. The runner reference is the [top-level README](../README.md).

| Role | Does | Tier → model | Effort |
| --- | --- | --- | --- |
| `project-manager` | Reconciles documents against live git/gh state, refines drafts, decides what to dispatch, reflects merges | `deep` → opus | `xhigh` |
| `architect` | Judges whether a solution is sound, before it is built and again on the PR. Verdict only; writes no product code | `deep` → opus | `xhigh` |
| `lead-dev` | Implements features and fixes in a product repo, opens a PR | `standard` → sonnet | `high` |
| `qa-reviewer` | Writes tests, reviews an open PR against the task's acceptance criteria | `deep` → opus | `xhigh` |
| `devops` | CI, deploys, images, infra, observability | `standard` → sonnet | `high` |
| `cataloguer` | Turns merged work into knowledge-base entries | `standard` → sonnet | `medium` |

Tiers map to model aliases in the panel's `instance.config.json` (`light` → haiku,
`standard` → sonnet, `deep` → opus, `apex` → fable; no role uses `apex` by default), so a
panel follows the latest model in each family without edits. `roleTiers` and `roleEffort`
move a role; `fallbackModel` adds `--fallback-model` to every box. Effort is omitted for
the `light` tier, which rejects the flag.

The roles, the document schema and the panel template ship in this repo
(`harness/roles/`, `harness/template/`). The document protocol is compatible with an
[ai-bridge](https://github.com/alteos-gmbh/claude-code-setup) instance: same frontmatter,
statuses and human gates, so an existing instance works as a panel unchanged.

## Commands

```sh
claude-box harness init [<dir>] [--org X] [--email Y] [--no-git] [--keep-roles]
                                                  # stamp or refresh a panel (default $CLAUDE_BOX_ROOT/_panel)
claude-box harness do  [<panel>] "<what you want>" [--repo <name>] [--max-rounds N] [--dry-run]
                                                  # draft → implement → review → merge, driven to completion
claude-box harness do  --resume [--project <slug>] [--passes N] [--dry-run]
                                                  # continue drafted work, no re-drafting
claude-box harness new [<panel>] "<what you want>" [--project <slug>] [--repo <name>]
                                                  # just draft the documents
claude-box harness answer [<panel>] [--project <slug>]   # answer the PM's blocking questions
claude-box harness done <task path | project path | slug> [--no-pr]   # close work out yourself
claude-box harness clean  [<panel>] [--project <slug>] [-y]   # discard attempts: worktrees, branches, tasks back to ready
claude-box harness delete [<panel>] --project <slug> | --task <path> | --objective <slug> [-y] [--dry-run] [--purge] [--delete-remote]
claude-box harness purge  [--days N | --all] [-y]   # delete logs, runs and box dirs (auto: older than 7 days each tick)
claude-box harness tick   [<panel>] [--dry-run]     # one PM tick, then dispatch
claude-box harness loop   [<panel>] [gap]           # tick, wait, sleep, repeat, under a lock
claude-box harness stack  [<panel>] [--project <slug>]   # link dependent PRs into a stack
claude-box harness stop   [<panel>]                 # stop the driver and its boxes
claude-box harness status [<panel>]                 # lock, autonomy, in-flight, last tick, queues
claude-box harness autonomy [gated|promote|full]    # who promotes and who merges
claude-box harness memory [<panel>] | --list | --accept <file> | --drop <file>
claude-box harness ui     [<panel>] [--port N] [--actions]   # dashboard, default port 7777
claude-box role <role> [--instance <dir>] [--task <path>] [--repo <name>] [--tier <tier>] [--prompt <text>] [--detach] [--dry-run]
```

`<panel>` resolves in this order: the argument, `$CLAUDE_BOX_PANEL`, the current
directory if it is a panel, the only panel under `$CLAUDE_BOX_ROOT`. With one panel you
never type its path. A panel is `instance.config.json` + `SCHEMA.md` + `.claude/agents`.

## Set up a panel

```sh
claude-box harness init --org <your-gh-org> --email you@example.com
```

That stamps `$CLAUDE_BOX_ROOT/_panel` as a local git repo (`--no-git` for a plain
directory). `init` is idempotent and keeps two things apart: it **refreshes the
machinery** (roles, `SCHEMA.md`) on every run so a fix reaches every panel, and **never
touches your data** (config, projects, objectives, knowledge, log). `--keep-roles` leaves
an edited role alone. Pass a directory to keep several panels; the harness then asks
which one instead of guessing.

The panel is not this repo on purpose: it holds your task queue and knowledge base,
which version at a different rate than the tool and which you may keep private or share
with a team.

| | What | Who maintains it |
| --- | --- | --- |
| `claude-box` | the tool: runner, roles, template, tests | this repo |
| `_panel` | your data: objectives, projects, tasks, knowledge | you; it is the work |
| a target repo | the product code the agents change | already yours |

A panel is an [OKF v0.1](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)
knowledge bundle. Three spec rules the harness holds you to: `index.md` files carry no
frontmatter (only the bundle root, and only `okf_version`), cross-links are
bundle-relative and start with `/`, and unknown types and fields are tolerated, which is
why the task lifecycle can be richer than OKF's `todo`/`in_progress`/`done`.

## One request, driven to completion

```sh
claude-box harness do "add rate limiting to the quote endpoint"
```

The host drives the chain itself, because it launches every box and sees each one exit;
the only wait is CI, which gets a bounded poll (`CLAUDE_BOX_CI_TIMEOUT`, default 900 s).

```
project-manager drafts the documents
  → host promotes the refined drafts                  (autonomy: promote or full)
  → architect judges the design                       (only when the task says design_review: required)
  → the assigned role implements, in its own box
  → qa-reviewer reviews it
      ↳ changes requested? back to the implementer, up to --max-rounds (default 10, CLAUDE_BOX_QA_ROUNDS)
  → wait for CI, then the host merges                 (autonomy: full)
```

It stops where a human is genuinely required:

| Exit | Why it stopped | What to do |
| --- | --- | --- |
| `2` | the PM raised an `open_question` that nothing downstream can answer | it offers to ask you there and then; otherwise `harness answer` |
| `3` | autonomy is `gated`, so promotion is yours | promote, or `harness autonomy promote` |
| `0` | the task reached `done` | nothing |

`do` is for one request in the foreground: no polling, no idle ticks, no cost while
nothing happens. `loop` is a scheduler for a queue (several projects, CI finishing later,
questions answered tomorrow); every tick spends a project-manager box whether or not
anything changed, so run it over a backlog, not an idle panel.

### Creating work without running it

`harness new "<sentence>"` has the project-manager write the project and task documents:
it decides whether the work belongs in an existing project, splits it into independently
reviewable slices, fills `acceptance_criteria`, and raises `open_questions` where a
decision is yours. Everything it writes is `status: draft`; it cannot promote.
`--project <slug>` adds to an existing project, `--repo <name>` names the target. A
hand-written task at `projects/<slug>/tasks/<id>.md` with `status: draft` works too;
`SCHEMA.md` in the panel has the shape.

### Answering a blocking question

A numbered `open_questions` entry keeps a task unpromotable. `harness do` offers to ask
you on the spot; otherwise `harness answer` prompts for each open question and appends
the answer to its line (`"Q1: which region? --- eu-central-1"`), which the
project-manager folds in and clears on its next pass.

### Resuming

```sh
claude-box harness do --resume                     # everything unfinished
claude-box harness do --resume --project <slug>    # just that project
claude-box harness do --resume --dry-run           # what it would pick up
```

Resume never drafts, so it cannot duplicate a project. It first runs one project-manager
box to fold your answers into the tasks, clear the entries, and cancel any task whose
answer said to skip it. Then it takes `ready`, `in-progress` and `in-review` tasks, skips
`done`, `cancelled` and `blocked`, continues an `in-progress` task from its `# Result`
rather than restarting it, and makes another pass whenever something in scope becomes
actionable again, up to `--passes` (default 3).

### Closing work out yourself

```sh
claude-box harness done projects/<slug>/tasks/t1.md          # a task, from any state
claude-box harness done projects/<slug>/project.md           # a whole project
claude-box harness done <slug>                               # same project, by slug
claude-box harness done projects/<slug>/tasks/t1.md --no-pr  # do not ask gh
```

Nothing in the harness writes `done` on its own; even `autonomy full`, which merges,
leaves the status alone. `done` records what was true: every URL in the task's `pr:` is
looked up with `gh` and the answer goes into `# Notes` verbatim, one of
`4 PR(s) merged, checked against gh`, `NOT every PR was merged — <url> OPEN`, or
`no PR on this task`. `done` is terminal; `harness clean` keeps it. The dashboard's
**mark done** button runs this command.

## Lifecycle rules

### Verdicts

`qa:` has two values, because CI is the source of truth:

| `qa:` | Meaning | Next |
| --- | --- | --- |
| `approved` | every criterion met, with a CI run as the evidence | merge (the host does it under autonomy `full`) |
| `changes-requested` | a defect against the criteria, or a criterion no CI job proves yet | another implementation round |

There is no verdict that hands verification to a person. A criterion a box cannot check
(a deployed environment, a secret, a browser) is a CI job that does not exist yet;
writing it is work, so it comes back as `changes-requested` with the job named. A job
that needs a secret nobody has granted is still written, referencing the name it should
have, and that name is listed under `## Blocked on` in the PR body.

### The design gate

A task with `design_review: required` is not implemented until the `architect` has
written `arch: sound`. On `arch: changes-requested` it goes back to `draft` for the
project-manager to rework. The project-manager requires a review when the work sets a
precedent (a new service or package, a schema or public API change, work crossing a repo
boundary, a migration, a new dependency, a pattern the codebase lacks) and not for a bug
fix or a change that follows an existing pattern. The architect is told to say when
things are fine; a reviewer that always finds problems gets ignored.

### Rounds live in the task document

The implementer reads the task document before every round: the qa-reviewer's findings
go in `# Review`, the architect's in `# Design review`, never as PR comments and never
through `gh pr review`, whose `--request-changes` and `--approve` notify people and change
the merge state. The PR has two agent-written surfaces: the body, rewritten in place each
round, and one comment, posted once the change is finished, naming what proves each
criterion.

### Reading CI

- Skipped is not failed. In a monorepo most jobs are path-filtered; a PR is judged by
  whether a check that ran failed, and by `mergeStateStatus`.
- Every failing check counts, required or not. `mergeStateStatus` is extra context,
  never the gate.
- A red check is not automatically the PR's fault. For every failing check the dashboard
  asks whether the same check already fails on the base branch and splits *caused by this
  change* (the task is marked stalled with the check names) from *already failing on
  `<base>`*. Roles are told the same: never make a check green by skipping a test,
  loosening an assertion or disabling the job; reproduce a failure locally before
  guessing; "it's flaky" needs two runs' evidence.

### Objectives and the cataloguer

Every project gets `objectives/<slug>.md`: the goal in one line, **Why now**, **Done when**
(two to four checkable statements), **Not doing**; the project document points at it with
`objective:`, and `status: met` cites what proves each line. Once `qa: approved` is on a
task, the host dispatches one cataloguer box, stamps `catalogued:` on the document so it
never happens twice, and lets it write into `knowledge/`: a Finding, a Service page, or a
Runbook. None is fine when the task taught nothing durable.

## How a tick works

A tick runs the project-manager in a box, reads the dispatch intents it wrote, validates
each, launches a box per accepted intent, waits, and checks that nobody promoted a task.

### Intents, not the engine socket

A role box cannot launch containers. It writes `.harness/intents/<name>.json`; the host
launches the box. Mounting the engine socket into a box would hand a sandboxed agent the
host daemon. Every dispatch therefore exists as a file before a container does, so a tick
is replayable and a bad dispatch is inspectable, and the host can refuse one: the role
must be listed in `instance.config.json`, the task path must stay inside the panel, the
task's frontmatter must say `ready`, the target repo must be a git repo under the root,
no box may already own the task, and both caps must have room. Refusals land in
`.harness/intents/rejected/` with the reason. `maxAgentsInFlight` is intersected with
what the host can afford (memory budget ÷ per-box memory); the smaller number wins.

### Autonomy

```sh
claude-box harness autonomy            # current mode
claude-box harness autonomy promote    # the host promotes refined drafts
claude-box harness autonomy full       # the host merges too
claude-box harness autonomy gated      # take both back
```

| Mode | Promotion | Merge |
| --- | --- | --- |
| `gated` (default) | you | you |
| `promote` | the host, once a task has criteria and no open questions | you |
| `full` | the host | the host, if every machine gate passes |

The switch lives in the runner's state directory on the host, not in the panel, so an
agent cannot grant itself autonomy by editing a file. Promotion is never done by a role
in any mode: the host snapshots task statuses around every box and **reverts** any
`draft → ready` a role wrote, recording it in the tick's `violations.tsv`; the image's
policy denies `gh pr merge` outright. Every machine gate on a `full` merge is required:
`qa: approved` written by a qa-reviewer box that did not write the code; the PR open and
mergeable; every CI check succeeded, and a PR with no checks at all is refused; at most
`CLAUDE_BOX_MAX_MERGES_PER_TICK` (default 3) merges per tick. No gate covers whether the
task was specified correctly; everything is recoverable through git, which is not the
same as prevented.

### The lock

The lock is a directory in the state dir holding the driver's pid: a second loop against
the same panel cannot start, and a dead holder's lock is reclaimed. `harness stop` stops
the driver and its boxes.

## Memory

| Tier | Lives in | Scope | How it grows |
| --- | --- | --- | --- |
| Global | `<state>/harness/memory/` | every repo and panel | you accept a proposal |
| Panel knowledge base | `<panel>/knowledge/` | this panel's services, findings, runbooks | the `cataloguer`, directly |
| Repo-scoped | `<panel>/memory/repos/<repo>/` | one product repo | you accept a proposal |

Every role box gets all three read-only, later tiers overriding earlier ones, capped at
`CLAUDE_BOX_MEMORY_MAX` characters (default 8000). The knowledge base is referenced, not
inlined: its `index.md` is the lookup surface. A product repo that ships its own
`.harness/memory/` is read too, never written.

Role boxes never write memory. They propose into `<panel>/.harness/pending/`:

```markdown
---
tier: global | repo
repo: <repo-name>          # required when tier is repo
evidence: <task path, PR link or file:line>
---

One or two sentences, phrased as an instruction to a future agent.
```

`harness memory` reviews the queue (`[a]ccept [e]dit [d]rop [s]kip [q]uit`); an accepted
`repo` proposal lands in `<panel>/memory/repos/<repo>/`, never in the product checkout.
Commit the panel to share learnings with a team. The knowledge base is deliberately
outside this gate: the cataloguer writes it directly, because an index that lags behind
merged work is worse than no index.

## Watching boxes

Headless boxes run with `--output-format stream-json --verbose`, because the default text
output prints nothing until the run finishes. `harness/render-log.py` renders the stream:

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

A box silent for `CLAUDE_BOX_STALL_TIMEOUT` seconds (default 420) counts as stuck; a box
older than `CLAUDE_BOX_ROLE_TIMEOUT` (default 2700) is stopped, and a task that times out
`CLAUDE_BOX_TASK_ATTEMPTS` times (default 3) blocks.

### Dashboard

```sh
claude-box harness ui --port 7777      # http://127.0.0.1:7777
claude-box harness ui --actions        # the page may also act, with a token minted per start
```

- **Waiting on you**: every unanswered question, first.
- **Projects**: title, repo, task counts by state, how many are waiting.
- **Board**: tasks by status; a task opens as a rendered plan (criteria, questions with
  answers, PR links with CI state, dependencies, the document as markdown with a raw
  toggle). Documents are agent-written and the page holds an action token, so everything
  is escaped and no document markup is ever inserted; there is a test for that.
- **Boxes in flight**: role, task, elapsed, newest action, running token estimate, live
  log tail. **Logs**: every recent box, running or finished.
- **Roles**: what each is for, model and effort, whether it is working now, runs,
  failures, total and average cost and time.
- **Memory**: what is in each tier, readable in full; proposals with **accept** and
  **drop** when actions are enabled, routed through `harness memory`.
- Refused dispatches with reasons; run history badging any reverted promotion.

It polls a read-only JSON endpoint over the same files the harness writes, bound to
`127.0.0.1` with no external assets. Token-shaped strings are redacted before any log or
proposal is served.

## What a role box can reach

A box gets its own `~/.claude`, seeded from the sandbox config, not your host `~/.claude`.
Plugins, commands and skills are not seeded by default: process frameworks add planning
gates a headless box cannot answer and write plan documents into whatever repo they run in
(`CLAUDE_BOX_SEED_PLUGINS=1` seeds them; `CLAUDE_BOX_HOST_PLUGINS=1` mounts the host
plugins read-only). Stacked PRs need no skill: `gh-stack` is in the image and the
workflow is in the roles. The image's hooks (secret scanning, scratch paths, no direct
push to a protected branch) apply to every box; see the
[runner README](../README.md#git-hooks-baked-into-the-image).

### Code standards every role reads

`harness/standards.md` goes into every role's system prompt: single responsibility, DRY
with the rule of three, KISS, current practice for types at the edges, error context,
bounded async, immutability, tests as specification, reversible migrations,
observability, security, accessibility, measured performance, and PR hygiene. A panel
that puts `STANDARDS.md` at its root replaces the shipped one.

### Installs

Roles use the box's shared pnpm store (warm between runs, hardlinked into
`node_modules`), never `--store-dir`, install the narrowest scope (`--filter <app>...`),
and never reset `pnpm-lock.yaml` to reinstall from scratch.

## Jira

Work is mirrored into Jira when the panel asks for it. No credential is forwarded: the
account's Atlassian connector is available inside every box (`claude mcp list` shows it
connected), so boxes read and write Jira with your access.

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
| project | Epic, key recorded in `jira_epic:` on `project.md` |
| task | Story, key recorded in `jira:` on the task |
| separable steps inside a task | Sub-tasks, only where genuinely separable |

One direction: the panel drives Jira. The project-manager creates the epic and stories,
copies the acceptance criteria in full into each ticket, records the keys, searches for
an existing issue before creating one, and reconciles drift every tick. The role doing
the work keeps its own issue honest (In Progress, In Review with the PR link, a comment
when it blocks), reads the available transitions rather than guessing, and never closes
an issue or opens a second one. The dashboard links each task and project to Jira. Only
the plumbing is testable without a real Jira; probe it with one cheap run first.

## Knobs

| Env var | Default | What it does |
| --- | --- | --- |
| `CLAUDE_BOX_PANEL` | | the panel, when not given as an argument |
| `CLAUDE_BOX_ROLE_TIMEOUT` | `2700` | seconds before a wedged box is stopped |
| `CLAUDE_BOX_STALL_TIMEOUT` | `420` | seconds of silence before a box counts as stuck; `0` disables |
| `CLAUDE_BOX_TASK_ATTEMPTS` | `3` | timeouts before a task blocks |
| `CLAUDE_BOX_QA_ROUNDS` | `10` | review rounds per `do` run (`--max-rounds`) |
| `CLAUDE_BOX_CI_TIMEOUT` | `900` | seconds `do` waits on CI before handing off |
| `CLAUDE_BOX_MAX_MERGES_PER_TICK` | `3` | ceiling on autonomous merges per tick |
| `CLAUDE_BOX_AUTOREBASE` | `1` | rebase a behind PR branch with `--force-with-lease`, never over uncommitted changes |
| `CLAUDE_BOX_MEMORY_MAX` | `8000` | character cap on the memory preamble |
| `CLAUDE_BOX_BOX_GRACE` | `45` | seconds a fresh dispatch counts as running before its box appears |
| `CLAUDE_BOX_HISTORY_DAYS` | `7` | runs, logs and box dirs older than this are purged each tick |
| `CLAUDE_BOX_MAX_REPOS` | `80` | repos under the root listed in every role's prompt |
| `CLAUDE_BOX_GH` | `gh` | the `gh` binary |
| `CLAUDE_BOX_TTY` | `/dev/tty` | where interactive prompts read from (tests point it at a file) |

Runner-wide knobs (`CLAUDE_BOX_ROOT`, `CLAUDE_BOX_STATE`, sizing, plugins) are in the
[runner README](../README.md#environment-variables).

## Tests

```sh
tests/run-all.sh
```

Covers `harness init` (machinery refreshes, your data never does), intent validation
including ai-bridge's `<org>/<repo>` spelling, caps and idempotency, memory tiering and
acceptance routing, lock contention and stale reclaim, prompt assembly, a whole tick, the
promotion guard, `do`, `answer`, `done`, `delete`, the dashboard page and actions, the
commit and push guards, the updater and the headless seam, all against
`CLAUDE_BOX_ENGINE=fake`.
