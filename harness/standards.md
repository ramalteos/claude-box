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

## The PR itself

- Small enough to review in one sitting. If it is not, it is a stack (`gh stack`).
- The description says what changed, why, and how it was verified — with the acceptance
  criteria as a checklist so the reviewer checks the task, not the prose.
- No unrelated reformatting. A whitespace sweep in the same commit as a behaviour change
  hides the behaviour change.
- No commented-out code, no debug output, no TODO without an owner and a task.
