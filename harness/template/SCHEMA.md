# Schema — documents and the task lifecycle

This control panel is an **OKF v0.1 knowledge bundle**: a directory tree of markdown
files with YAML frontmatter and markdown links, readable by humans, parseable by
agents, diffable in git. The harness reads these documents, role agents write them,
and the lifecycle below is the contract between the two.

It is also compatible with an
[ai-bridge](https://github.com/alteos-gmbh/claude-code-setup) instance — same
frontmatter fields, same statuses, same two human gates — so an existing instance can
be used as a panel unmodified.

## Three OKF rules that are easy to get wrong

1. **`index.md` files carry NO frontmatter.** They are directory listings: a
   `# Heading`, then `* [Title](/path/to/doc.md) - one-line description`. The only
   exception is the bundle-root `index.md`, which may declare `okf_version: "0.1"`.
2. **Cross-links are bundle-relative and start with `/`** — `/services/policy/overview.md`,
   `/projects/<slug>/tasks/<id>.md`. They survive file moves, and they are what a graph
   view turns into edges. The harness accepts both spellings in a dispatch intent's
   `task` field and normalises the leading slash away.
3. **Unknown types and fields are tolerated.** Add fields freely; consumers ignore what
   they do not understand. That is why the lifecycle below can be richer than OKF's own
   `todo`/`in_progress`/`done` without breaking anything.

## type: Project — `/projects/<slug>/project.md`

```yaml
---
type: Project
title: <what shipping this achieves>
description: <one line>
kind: build | research          # build ships code; research produces documents
status: active | paused | done
target_repo: <org>/<repo>       # build only; the default for this project's tasks
jira_epic:                      # the epic tracking this project, e.g. DPT-1200
objective: /objectives/<slug>.md  # why this project exists and how we will know it worked
timestamp: <ISO 8601>
---
```

Body: `# Context` (why this exists, what "done" looks like).

## type: Objective — `/objectives/<slug>.md`

```yaml
---
type: Objective
status: active | met | abandoned
projects: [ "/projects/<slug>/index.md" ]
timestamp: <ISO 8601>
---
```

Body, ten lines at most: the goal in one line, **Why now** (what it costs us today), **Done
when** (two to four checkable statements — a number, a behaviour, a gate that passes), and
**Not doing** (the neighbouring work someone would otherwise assume is included).

The project-manager writes it when it drafts a project and keeps it current; `status: met` is a
claim about the world, so it cites what proves each "done when" statement. A project without an
objective is work whose value nobody stated.

## type: Task — `/projects/<slug>/tasks/<id>.md`

```yaml
---
type: Task
title: <imperative summary>
description: <one line>
kind: build | research          # inherits the project's kind when omitted
status: draft                   # see the lifecycle below
assignee:                       # role slug, set by the project-manager on dispatch
model:                          # optional: a tier (light|standard|deep) or a model alias
target_repo: <org>/<repo>       # inherits the project's when omitted
targets: [ /services/<name>/overview.md, ... ]   # OKF: the concepts this task touches
tags: [ <tag>, ... ]
resource: <repo-path or URI of the asset this concerns>
depends_on: [ /projects/<slug>/tasks/<id>.md, ... ]   # bundle-relative
acceptance_criteria: [ "<testable outcome>", ... ]
open_questions: [ "Q1: <question that blocks this>", ... ]
pr: [ ]                         # PR URL(s), set by the implementing role
qa:                             # approved | changes-requested
                                # set ONLY by qa-reviewer
design_review:                  # required — the project-manager asks for an architecture review
arch:                           # sound | changes-requested — set ONLY by architect
box:                            # the box working this task right now — written by the HOST
started_at:                     # when that box started — written by the HOST
blocked_reason:                 # one line, when the host can see why
jira:                           # the issue tracking this task, e.g. DPT-1234
timestamp: <ISO 8601>
---
```

Body headings, in this order: `# Context`, `# Notes` (refinement by the
project-manager), `# Result` (written by the role that did the work), `# Review`
(the qa-reviewer's findings for the round), `# Design review` (the architect's).

**Roles hand work to each other here, not in the pull request.** A review round is a
conversation between two boxes: the implementer reads this document before every round, so
findings belong in `# Review`, and the pull request keeps one body — rewritten in place, never
appended — plus a single comment once the change is finished. A PR that collects a comment per
round buries the one comment a human needs under three that are already resolved. `gh pr review`
is not an agent's to spend: `--request-changes` and `--approve` are review events that notify
people and change the merge state.

**`target_repo` accepts `<org>/<repo>` or a bare `<repo>`.** Either way it must
resolve to a clone directly under the repos root; the harness normalises it and
refuses anything that is a path, a URL, or a different org than the instance's.

**Answering an open question.** Append ` --- <answer>` to the question line, in the
task document:

```yaml
open_questions: [ "Q1: which region should we default to? --- eu-central-1" ]
```

The next tick folds the answer into the task and deletes the entry. A draft with
unanswered questions is not promotable.

## Task lifecycle

```
draft ──│ YOU promote │──► ready ──► in-progress ⇄ in-review ──► done
                                          └─ changes requested ─┘

  any active state ⇄ blocked      (returns to its previous status when cleared)
  any state ──► cancelled         (terminal)
```

| Status | Meaning | Who may set it |
| --- | --- | --- |
| `draft` | Initial state. Refined when `acceptance_criteria` are filled and `open_questions` is empty. Awaiting your approval. | you, project-manager |
| `ready` | Approved for execution. | **you only** |
| `in-progress` | A role box is working it. | **the host**, when it launches the box |
| `in-review` | PR open, awaiting review or merge. | the implementing role, or **the host** once a PR URL exists |
| `blocked` | Blocked on something external; says what in `# Notes`. | anyone |
| `cancelled` | Abandoned or superseded. Terminal. | you, project-manager |
| `done` | Every PR on the task is merged. | project-manager reflecting reality, or you — `harness done <task>`, or the dashboard's **mark done** button. Yours from any state: the command never refuses on status, and records in `# Notes` what every PR on the task actually was at that moment, merged or not |

**Mapping to OKF's own task statuses**, for anything that reads the bundle generically:
`draft`/`ready` → `todo`, `in-progress`/`in-review`/`blocked` → `in_progress`,
`done`/`cancelled` → `done`. The extra states exist to hold the two human gates, which
OKF has no concept of.

### Who writes a status

The host writes the transitions it can **verify**: `in-progress` when it launches a box,
`in-review` once a PR URL exists, back to `ready` if a box ended cleanly without opening one,
`blocked` if a box died without one. Depending on an agent to remember a bookkeeping step
made the board unreliable — a task being worked on still read `ready`, a finished one still
read `in-progress`.

Roles write the statuses that need judgement — `blocked` with a reason — and the verdict
fields `qa:` and `arch:`. Nobody but the human (or the host under autonomy) writes `ready`.

### A finished draft is handed over automatically

A role opens a PR as a **draft** when it could not settle every criterion. Once `qa: approved`
is written, the architect has not objected, and no CI check is failing, the change is finished as
far as any agent can take it — so **the host marks the PR ready for review** and moves the task
to `in-review`. Roles never do this themselves: a role marking its own work ready for review is
the review equivalent of merging your own PR.

It stays a draft while a check fails and while `qa` says anything other than `approved`.

### The qa verdict has two values, and CI is the source of truth

| `qa:` | What it means | Who acts next |
| --- | --- | --- |
| `approved` | every criterion met, with a CI run as the evidence | the host merges it under autonomy `full`, otherwise you |
| `changes-requested` | a defect against the criteria, **or** a criterion no CI job proves yet | the implementing role, another round |

No third value. A criterion that cannot be checked inside a box is a job that does not exist
yet, and writing that job is work — so it is `changes-requested`, with the job named. The host
enforces this: any verdict that is not `approved` sends the task back with instructions to wire
the verification into CI. A suite no job runs is a suite nobody runs.

The third one matters because it is not a failure and not an agent's turn. A task in that state
with **green CI is normal**: the checks that ran passed, and the missing evidence is the part CI
did not run. Re-dispatching a role will not change it.

### The design gate

A task whose frontmatter says `design_review: required` is not implemented until the
`architect` has judged the approach and written `arch: sound`. On `arch: changes-requested`
the task goes back to `draft` for the project-manager to rework — nothing is built.

The project-manager asks for a review when the work sets a precedent: a new service or
package, a schema or public API change, anything crossing a repo boundary, a migration, a
new external dependency, or a pattern the codebase does not already have. It does not ask
for one on a bug fix, a test, or a change that follows an existing pattern — a gate that
fires on everything is a tax, not a check.

### Autonomy

By default both gates below are yours. `claude-box harness autonomy promote|full` hands
them to the host — never to a role. The switch lives in the runner's state directory on
the host, which no box can write, so an agent cannot grant itself autonomy.

| Mode | Promotion | Merge |
| --- | --- | --- |
| `gated` (default) | you | you |
| `promote` | the host, once a task has criteria and no open questions | you |
| `full` | the host | the host, if every machine gate passes |

The machine gates on a `full` merge, all required: the task carries `qa: approved` from a
qa-reviewer box that did not write the code; the PR is open and mergeable; every CI check
has succeeded, and **a PR with no checks at all is refused** rather than treated as
passing; and at most `CLAUDE_BOX_MAX_MERGES_PER_TICK` merges happen per tick.

What no gate covers: whether the task was specified correctly in the first place. An
agent that satisfies a wrong criterion produces a green, approved, merged mistake.

### The two gates are yours by default

1. **`draft → ready`.** No role may promote a task, in any autonomy mode. The harness snapshots statuses
   around every box and reverts a promotion a role wrote, recording it in that tick's
   `violations.tsv`.
2. **Merging.** No role merges. `gh pr merge` is denied at the policy layer inside
   every box.

Everything else — refining, dispatching, implementing, reviewing, reporting — runs
without you.

## Knowledge concepts — `/knowledge/<group>/<slug>.md`

OKF concept documents. Use the spec's types where one fits, and the panel's own where
none does:

```yaml
---
type: Service            # OKF: Service | Frontend App | BFF | API Endpoint | Data Entity | Event
                         # panel: Finding | Runbook | Team
title: Policy Service
description: One line, shown in the index listing.
resource: services-monorepo/services/policy    # canonical repo path or URI
tags: [service]
status: stub             # concepts: stub | documented   (findings: current | superseded)
source: /projects/<slug>/tasks/<id>.md         # what produced this
timestamp: <ISO 8601>
---
```

Body headings for a Service overview, per OKF's template: `# Responsibility`,
`# APIs / Interfaces`, `# Data owned`, `# Events`, `# Depends on` — with detail split
into `apis/<endpoint>.md`, `data/<entity>.md`, `events/<event>.md` sub-concepts rather
than one growing file.

`/knowledge/index.md` is the **lookup surface**: a listing, no frontmatter, one line
per document. Scan it and open only what you need — never bulk-read `knowledge/`. The
`cataloguer` maintains it.

**No customer PII in any document here.**

## Jira

When `jira.enabled` is true in `instance.config.json`, work is **mirrored** into Jira. The
panel stays the source of truth for what the work is; Jira is where the organisation tracks
it. One direction only — the panel drives Jira. Two-way sync is how tracker integrations rot.

| Panel | Jira |
| --- | --- |
| project | **Epic** — key recorded in `jira_epic:` on `project.md` |
| task | **Story** (or Task/Bug, by nature) — key recorded in `jira:` on the task |
| separable steps inside one task | **Sub-tasks** under that story, only when they are genuinely separable |

Status mirroring, by whoever is doing the work:

| Panel status | Jira |
| --- | --- |
| `in-progress` | transition to In Progress |
| `in-review` | transition to In Review (or the nearest equivalent), comment with the PR link |
| `blocked` | comment with the reason; flag the issue if the workflow supports it |
| `done` | transition to Done |
| `cancelled` | close as won't do, with the reason |

Access comes from the account's Atlassian connector, which is available inside every box —
no token is forwarded and none is stored in the panel.

## Memory tiers

| Tier | Location | Grows by |
| --- | --- | --- |
| Global | `<state>/harness/memory/` | you accepting a proposal |
| This panel's knowledge base | `knowledge/` | the `cataloguer`, directly |
| Repo-scoped | `<panel>/memory/repos/<repo>/` | you accepting a proposal |

Role boxes propose into `.harness/pending/`; `claude-box harness memory` is where a
proposal becomes memory. The knowledge base is the exception — the cataloguer writes
it directly, because an index that lags behind merged work is worse than no index.
