# Control panel — instructions

This directory is a **control panel**, not product code. Work happens in the repos
under the repos root (`reposRoot` in `instance.config.json`); this panel holds the
objectives, projects, tasks and knowledge that drive it.

## The loop

```
you write a task (draft) → project-manager refines it → YOU promote to ready
  → project-manager dispatches a role box → role implements, opens a PR
  → qa-reviewer reviews it → YOU merge
```

Run it from the host, not from inside a session:

```sh
claude-box harness tick <this-dir>            # one tick
claude-box harness loop <this-dir> 10m        # keep ticking, under a lock
claude-box harness ui   <this-dir>            # watch it
claude-box harness memory <this-dir>          # review proposed learnings
```

Your two gates — promoting `draft → ready`, and merging — are enforced by the host,
not by politeness. See `SCHEMA.md`.

## Conventions for role agents working in the repos

These apply to every role. They exist because several boxes may be working different
tasks in the same repo at the same time.

1. **Read `instance.config.json` first** for `reposRoot`, `org` and your model tier.
   The repos root is the same path inside your box as on the host.
2. **Detect the default branch** — `git -C <repo> symbolic-ref refs/remotes/origin/HEAD`
   or `gh repo view --json defaultBranchRef`. Do not assume `main`.
3. **Your worktree is created for you — do not create one.** The harness makes it before
   your box starts, at `<reposRoot>/_wt/<project-slug>-<task-id>`, on a branch named for the
   change (`<project-slug>/<task-id>-<slug>`), based on `origin/<default-branch>`. Its path
   and branch are given to you in your instructions. Work there.

   If you ever do create one: **never inside the repository.** A worktree at
   `<repo>/_wt/...` turns the entire checkout into thousands of untracked files on the
   human's main branch — this happened, and it cost a whole run.

4. **Use the store that is already configured. Never pass `--store-dir`.**
   `~/.npmrc` in the box points pnpm at a store on the mounted workspace, shared across
   boxes and warm between runs, on the same filesystem as `node_modules` so pnpm hardlinks
   instead of copying. A private per-worktree store forces a **cold download of the entire
   dependency tree on every task** — for a monorepo that is many minutes of pure waste, and
   it was the single biggest time sink in early runs. pnpm locks its own store; concurrent
   installs are safe.

   Install the narrowest scope that works: `pnpm install --filter <app>...` rather than a
   full workspace install. And never `git checkout -- pnpm-lock.yaml` followed by a fresh
   full install to "clean up" — that throws away the warm state and rebuilds from nothing.
5. **Push early, then open the pull request immediately** — as a draft, before the work is
   finished. Then keep committing and pushing to it. A box can time out, hit a rate limit
   or be stopped; if the PR only gets opened at the end, all of that becomes invisible work
   on a branch nobody looks at. A draft PR that grows is strictly better than a perfect PR
   that never happens.
6. **Conventional commits** (`feat:`, `fix:`, `chore:`, `docs:`, `test:`, `ci:`).

   **When a repo's own git hook cannot run in a box.** Many repos install husky hooks that
   assume a developer laptop — `brew install gitleaks`, a GUI keychain, a VPN — and they
   replace ours, so they hang or fail here through no fault of your change. If a hook fails
   for an environmental reason (a missing tool the box cannot install, a network fetch, a
   timeout), retry once, then commit with `--no-verify` and **say so in the PR body**,
   naming the hook and the error. Secrets are still caught: claude-box's pre-push hook
   scans on every push regardless of what the repo's hooks did.

   Never use `--no-verify` to get past a hook that is failing **because of your change** —
   a lint error, a type error, a real secret. That is the hook doing its job.
7. **Stage by explicit path. Never `git add -A` or `git add .`.** Commit the files the
   task needed and nothing else. Planning notes, spec documents, task copies, scratch
   files and anything under `.harness/`, `_wt/`, `docs/superpowers/` or `.pnpm-store/` is
   process exhaust — it is not part of the deliverable and the pre-commit hook will refuse
   it. If you produced notes worth keeping, they belong in the task document or a learning
   proposal, not in the product repo.
8. **A protected branch takes changes through a pull request.** Never `git push` to the
   default branch, `main`, `master`, `develop`, `next` or `production` — the image's
   pre-push hook refuses it. Push your branch and open a PR.
9. **Never merge**, and never promote a task to `ready`.
10. **No secrets, no customer PII** in any document, commit, PR body or knowledge doc.
   If you need a value that looks like a credential, reference where it lives instead.
11. **Report in the task document**: set `status`, fill `# Result` with what changed,
   how you verified it, and the PR link. Then stop. Your final message is read by a
   machine — state what happened and what it means for the task's state.
12. **Blocked is a real answer.** If the acceptance criteria cannot be met, or the task
    is ambiguous enough that guessing would waste a review cycle, set `status: blocked`,
    say precisely what you need in `# Notes`, and stop. Do not redefine the task.

## Code standards

Every role's system prompt carries the standards document — single responsibility, DRY with
the rule of three, KISS, and current practice for types, errors, async, tests, migrations,
observability and security. It ships with claude-box, so an update reaches every panel.

To use your own instead, put a `STANDARDS.md` at this panel's root; it replaces the shipped
one outright.

## Stacked pull requests

Two different situations, and they are handled differently.

**A task that depends on another task.** The harness reads `depends_on` and bases your
worktree on that dependency's branch when it is not merged yet. Your instructions name the
base. When the base is not the repository's default branch, this is a **stacked PR**:

```sh
gh pr create --base <the base branch named in your instructions> --draft   # if blocked
```

Getting this wrong is the common failure: opening it against the default branch instead makes
your PR contain the dependency's work as well, so a reviewer sees a pile of two changes and
cannot tell whose is whose. Say in the body which PR yours sits on top of, and that it should
be merged after it.

**One task whose own change is a chain** — a refactor that enables the feature, a schema
change before its consumer. Build it as a local stack:

```sh
gh stack init                 # start a stack on the base branch
gh stack add <next-branch>    # a branch on top of the current stack
gh stack submit               # push every branch and open/update the PRs
gh stack view / gh stack sync
```

Each PR in the chain stands on its own: its own description, its own green tests, and a note
saying which PR it sits on. Reviewers read the bottom first.

`gh stack merge` exists — **do not use it.** Merging is the human's, or the host's under
autonomy. Report every PR URL in the task's `pr:` list, bottom first.

## Jira, when the panel has it enabled

If `instance.config.json` has `jira.enabled: true` and your task carries a `jira:` key, keep
that issue honest as you work. You have the Atlassian connector in your box; no token is
needed.

- **Starting**: transition the issue to In Progress. Read the available transitions first —
  do not guess a status name that this project's workflow does not have.
- **Opening a PR**: transition to In Review (or the nearest equivalent) and comment with the
  PR link and one line on what to look at. If it is a draft, say what is still blocked.
- **Blocked**: comment with the reason and what would unblock it. Say it in the issue, not
  only in the task document — the issue is what a human is watching.
- **Never**: close an issue yourself, paste a secret or customer data into a ticket, or open
  a new issue for work that already has one.

Nor do you mark your own draft PR ready for review. The host does that once qa has approved and
CI is not failing — marking your own work ready is the review equivalent of merging it.

If the task has no `jira:` key, do not create an issue — that is the project-manager's job,
and two roles creating tickets produces duplicates.

## Learnings

When you learn something a future agent would want to know, propose it — one file per
proposal in `.harness/pending/<slug>.md`:

```markdown
---
tier: global | repo
repo: <repo-name>          # required when tier is repo
evidence: <task path, PR link or file:line>
---

One or two sentences, phrased as an instruction to a future agent.
```

Propose only what changes what a future agent would *do*. Skip anything it could read
off the code just as easily. Nothing becomes memory until a human accepts it.
