# Code standards

These hold for every role, in every repo. They are written to be *checkable* — a reviewer
should be able to point at a line and say which one it breaks. Where an existing file
disagrees with a rule here, match the file's conventions and note the divergence; a diff
that fights its surroundings costs more to review than it saves.

## Single responsibility

- A function does one thing at one level of abstraction. If you cannot name it without
  "and", split it.
- A module has one reason to change. When a file needs edits for two unrelated reasons —
  a new payment provider *and* a new email template — it is two files.
- A function that both decides and acts is two functions. Return the decision; act on it in
  the caller. Decisions are testable without mocks; actions are not.
- Constructors and module top-level do not perform I/O. Wire dependencies in, so a test can
  substitute them without a framework.

## Don't repeat yourself — with the rule of three

- Duplicated **knowledge** is the bug: two places that must change together and only one
  gets changed. Duplicated *text* is often fine.
- **Two occurrences: leave them.** Three: abstract. Premature abstraction is more expensive
  than duplication, because duplication is visible and a wrong abstraction is load-bearing.
- Never abstract across a boundary you do not own. Two services that happen to validate an
  email the same way do not share a validator; they share a requirement that may diverge.
- One source of truth per fact: a type, a constant, a migration, a config key. If a value
  appears in code and in a config file, one of them is derived.

## Keep it simple

- Solve the problem in the task. Not the general case, not the next three tasks. There is
  no credit for a plugin architecture nobody asked for.
- Prefer the boring construct: a function over a class, a class over a framework, an array
  over a cache, a straight line over a state machine. Reach for the complex one when the
  simple one has failed, and say in the PR body what failed.
- Delete rather than comment out. Git remembers.
- No speculative configuration. A flag with one value is a constant with extra steps.
- Fewer dependencies. Before adding one: is it in the standard library, is it already in
  this repo's lockfile, is it more than fifty lines of work? Every dependency is a supply
  chain, a licence, and an upgrade you will do later.

## Modern practice (2026)

- **Types at the edges.** Validate untrusted input where it enters and parse it into a
  typed shape; do not pass raw request bodies inward. TypeScript: no `any` in a public
  signature, `unknown` plus a parse instead. Python: annotate and let the checker run in CI.
- **Errors carry context and are handled where they can be.** No empty `catch`, no
  swallowing, no logging-and-rethrowing at every layer. Fail fast, include the identifiers
  a reader needs, and never put a secret or PII in a message.
- **Async without leaks.** Every await has a timeout or a cancellation path; every spawned
  task is awaited or explicitly detached. No unbounded concurrency over a list you did not
  size — bound it.
- **Immutability by default.** Prefer returning new values to mutating arguments. Reserve
  mutation for a hot path you have measured.
- **Tests are the specification.** Cover the behaviour the task names, plus the failure
  path. A test that passes against both the correct and the broken implementation is worse
  than none: verify it fails before you make it pass. Test through the public surface, not
  private internals, so a refactor does not rewrite the suite.
- **Migrations and schema changes are reversible and ordered.** Additive first, backfill,
  then remove — never a single deploy that both writes a new shape and stops writing the
  old one.
- **Observability is part of the change.** A code path that can fail in production emits
  enough to diagnose it: a structured log with identifiers, a metric if it is a rate, a
  trace span if it crosses a service.
- **Security is not a later task.** No secrets in code, fixtures, logs or PR bodies.
  Parameterised queries only. Authorise on the server for every request, never on a
  client-supplied role. Pin and verify anything you download in a build.
- **Accessibility and i18n for anything user-facing.** Semantic elements, labelled
  controls, keyboard reachable, contrast checked; no string concatenation for sentences that
  will be translated.
- **Performance where it is measured.** No optimisation without a number. State the
  complexity when a loop touches a collection that grows, and avoid the N+1 query — that
  one is not premature, it is a defect.

## Verification belongs in CI, not on your machine

A box has no cloud credentials, no VPN route and no deployed environment, and it must not
be given them to satisfy a test. So:

- **Read the pipeline; do not re-run it.** A check that ran on the PR head is the evidence.
  Reproducing it inside a box produces weaker evidence — no cloud credentials, no deployed
  environment, no browser — and costs a review round. Run something locally only when no job
  covers it and you are writing the job.
- **Shared infrastructure belongs to one task.** A CI workflow, a fixture directory, a shared
  helper: the lowest task in the stack that needs it owns it, and every task above inherits it
  through its base. Check before you write one — `git log --oneline <base>..` and a look at the
  branches below you. Two branches adding the same path with different content merges cleanly
  against each of their own bases and still blocks the stack, because a stack is merged as a
  whole: that is how one PR ended up with `CONFLICT (add/add)` on a workflow file nobody
  thought was contested.
- **A YAML file outside `.github/workflows/` is not CI.** If a workflow cannot be pushed because
  the token lacks the `workflow` scope, say so under `## Blocked on` with the file you would have
  added. Parking it in a neighbouring directory produces a green PR that proves nothing.
- **Anything that needs a deployed environment, a secret store or a real integration is
  verified by a CI job, not by a local run.** Add or extend the job in the same PR, and
  follow the conventions the repo already uses for that kind of suite — copy the shape of
  the nearest existing job (same triggers, same secret wiring, same reporter) rather than
  inventing one.
- **What you verify locally** is what needs nothing external: build, type-check, lint,
  unit tests, and the failure paths you can force by unsetting a variable or stubbing a
  boundary. Say exactly what you ran.
- **Never fake the evidence.** Do not paste an invented run, do not mark a criterion met
  because it "should" pass, and do not weaken a criterion so it passes locally. If the
  evidence can only come from CI, the PR is where that evidence appears — after it runs.

## When a check fails, find out whose failure it is

A red check is not automatically your fault, and treating it as though it is leads to changing
code that was never broken. Before touching anything:

1. **Ask whether the base branch already fails it.**
   `gh api repos/<owner>/<repo>/commits/<base>/check-runs --jq '.check_runs[] | select(.conclusion=="failure") | .name'`
   A check that is red on the base is somebody else's problem. Say so in the PR, name the
   check, and move on — do not fix it under cover of your change.
2. **Otherwise reproduce it locally.** Run the same command the job runs. If it passes locally
   and fails in CI, say which and what differs (environment, credentials, a service the box
   cannot reach) rather than guessing.
3. **Fix the cause, not the signal.** Never skip a test, loosen an assertion, add a retry, mark
   something `continue-on-error`, or edit the workflow to stop running a job — unless the task
   is explicitly about that job. Making a check green without making the code right is worse
   than leaving it red, because the next person believes it.
4. **Flakiness is a claim that needs evidence.** Re-run once. If it then passes, say it is
   flaky, name the job, and quote both outcomes. Do not call a failure flaky to move on.

**Skipped is not failed.** In a monorepo most jobs are path-filtered, so the majority of checks
skip on any given PR — that is the system working. Judge a PR by whether a check that *ran*
failed, and by what the repository's own branch protection says, not by how many skipped.

## Always open the pull request

**A blocked task still gets a PR.** Work that exists only on a branch is invisible: nobody
reviews it, CI never runs it, and the next agent cannot build on it.

- If the code is complete but some evidence is missing, open the PR **as a draft**
  (`gh pr create --draft`) and put a **`## Blocked on`** section at the top of the body:
  what is unmet, why it cannot be met here, and precisely what unblocks it. Then set the
  task `in-review` and record the PR URL.
- If the change does not build or its unit tests fail, that is not a draft — fix it, or if
  the task itself is wrong, set `status: blocked` with the reason and open no PR.
- Never open a PR that presents unmet criteria as met. The draft flag plus the
  `## Blocked on` section is how you stay honest and still hand the work over.
- Do not merge, and do not mark a draft ready for review yourself — a human or CI clears
  the block.

## Write for a reader with thirty seconds

Everything an agent writes for a human — PR bodies, review comments, task results — is read by
someone deciding what to do next. Length is not thoroughness; it is work pushed onto the reader.
Measured examples from this panel: a 1,615-word PR body and 1,200-word review comments. Both
should have been a fifth of that.

**Rules that apply to all of it.**

- **No chronology.** "First I read X, then I tried Y, then I discovered Z" is your process, not
  information. State the conclusion.
- **Do not restate the task.** The reader has it. Do not paraphrase acceptance criteria back.
- **Do not explain what the diff shows.** Point at `path:line` instead of quoting or narrating
  code.
- **Say each thing once.** A fact in the body, the comment and the task document is one fact
  and two copies.
- **No hedging paragraphs.** If something is uncertain, one line saying what would settle it.
- **Cite, do not transcribe.** `tresor/src/external/vault/aws-util.ts:42` beats a paragraph
  explaining what that file does.

### PR body — target 200 words, hard cap 400

```markdown
## What changed
- one line per change, 3–6 bullets

## Verified
- `pnpm --filter x lint` → clean
- `pnpm --filter x test` → 34 passed
- what you could NOT verify here, in one line

## Blocked on            ← only when something is unmet
- criterion 11 — needs a run against a deployed env; a CI job with the vault secrets settles it

## Acceptance criteria
- [x] criterion, copied verbatim
- [ ] criterion — settled by CI, not here
```

### Review findings go in the task document, not in a PR comment

**Agents talk to each other through the task document.** The implementer reads it before every
round, so a review posted there arrives just as fast — and the pull request stays a record a
human can read, instead of a thread of machines negotiating. A four-round review that comments
each time buries the one comment that matters under three that are already resolved.

So, per round: write the findings into the task's `# Review` section and set `qa:`. **Do not
comment on the pull request. Do not use `gh pr review`** — `--request-changes` and `--approve`
are GitHub review events; they notify humans and change the merge state, and neither is yours to
spend on an internal round.

Same rule for every role. The architect's verdict, devops' notes, the cataloguer's findings:
task document. The pull request has exactly two agent-written surfaces, below.

#### 1. The PR body — edited in place, never appended

One body, kept current. Each round **rewrites** it (`gh pr edit --body-file`), so it always
describes the change as it stands now, including `## Blocked on` while something is unmet. A body
that grows a "Round 3 update" section per round is a changelog of a conversation nobody needs.

#### 2. One comment, and only when it is finished — target 150 words, hard cap 300

When the change is done — every criterion met, CI green — post **one** comment saying what proves
it. Nothing before that.

```markdown
**Verified** — all 11 criteria met.

- criteria 1–9: unit suite, `pnpm --filter configuration-studio-v2 test` → 34 passed
  ([run](link))
- criteria 10–11: `e2e-configuration-studio` job on this PR → 12 passed ([run](link))

Two rounds of changes: fixture auth was racing across workers, and the sign-out helper waited on
a toast that path never emits. Both fixed in `e2e/fixtures.ts` and `login-page.ts`.
```

Findings only in the review section, at most five blocking ones ranked; if there are more, say
"3 more of the same kind in `<dir>`". If a verified comment from a previous approval already
exists, edit it (`gh pr comment --edit-last`) rather than adding a second.

### Task `# Result` — at most 12 lines

What changed, what was verified, what remains, the PR link. Nothing else; the PR body carries
the detail.

## The PR itself

- Small enough to review in one sitting. If it is not, it is a stack (`gh stack`).
- The description says what changed, why, and how it was verified — with the acceptance
  criteria as a checklist so the reviewer checks the task, not the prose.
- No unrelated reformatting. A whitespace sweep in the same commit as a behaviour change
  hides the behaviour change.
- No commented-out code, no debug output, no TODO without an owner and a task.
