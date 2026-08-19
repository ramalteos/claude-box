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
3. **Work in your own worktree**, never in the repo's main working tree:
   `git -C <repo> worktree add -b <branch> <reposRoot>/_wt/<task-id> <base>`.
   Branch name: `<role>/<task-id>-<short-slug>`.
4. **Use a private package store** so a sibling box's install cannot corrupt yours:
   `pnpm install --store-dir <worktree>/.pnpm-store`.
5. **Push early**, then keep pushing. A box that dies with unpushed commits has lost
   the work.
6. **Conventional commits** (`feat:`, `fix:`, `chore:`, `docs:`, `test:`). No AI
   attribution, no co-author trailers, no `--no-verify` — the pre-commit hook is there on
   purpose.
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

When a task's change is genuinely a chain — a refactor that enables a feature, a schema
change before the code that uses it — do not ship one large PR and do not ship two
unrelated ones. Use `gh stack` (the extension is in the image):

```sh
gh stack init                 # start a stack on the default branch
# commit the first slice, then:
gh stack add <next-branch>    # a branch on top of the current stack
gh stack submit               # push every branch and open/update the PRs
gh stack view                 # see the chain
gh stack sync                 # after the bottom PR merges or trunk moves
```

Each PR in the stack must stand on its own: its own description, its own tests green, and
a body that says which PR it sits on top of. Reviewers read the bottom first.

`gh stack merge` exists — **do not use it.** Merging is the human's, or the host's under
autonomy. Submit the stack and report the PR URLs in the task's `pr:` list, bottom first.

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
