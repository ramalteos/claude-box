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
timestamp: <ISO 8601>
---
```

Body: `# Context` (why this exists, what "done" looks like).

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
qa:                             # approved | changes-requested — set ONLY by qa-reviewer
timestamp: <ISO 8601>
---
```

Body headings, in this order: `# Context`, `# Notes` (refinement by the
project-manager), `# Result` (written by the role that did the work).

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
| `in-progress` | A role box is working it. | project-manager on dispatch, then the role |
| `in-review` | PR open, awaiting review or merge. | the implementing role |
| `blocked` | Blocked on something external; says what in `# Notes`. | anyone |
| `cancelled` | Abandoned or superseded. Terminal. | you, project-manager |
| `done` | Every PR on the task is merged. | project-manager reflecting reality, or you |

**Mapping to OKF's own task statuses**, for anything that reads the bundle generically:
`draft`/`ready` → `todo`, `in-progress`/`in-review`/`blocked` → `in_progress`,
`done`/`cancelled` → `done`. The extra states exist to hold the two human gates, which
OKF has no concept of.

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

## Memory tiers

| Tier | Location | Grows by |
| --- | --- | --- |
| Global | `<state>/harness/memory/` | you accepting a proposal |
| This panel's knowledge base | `knowledge/` | the `cataloguer`, directly |
| Repo-local | `<repo>/.harness/memory/` | you accepting a proposal |

Role boxes propose into `.harness/pending/`; `claude-box harness memory` is where a
proposal becomes memory. The knowledge base is the exception — the cataloguer writes
it directly, because an index that lags behind merged work is worse than no index.
