# claude-box — project instructions

`claude-box` builds and runs the **Claude Code CLI sandbox image** (Debian base +
`gh` + the `gh-stack` extension + gitleaks + Vite+/Node + pnpm + Claude Code). It
runs under **Docker or Apple `container`** — the runner auto-detects, Docker
first, and `CLAUDE_BOX_ENGINE` forces one. The image is defined in `Dockerfile`
and launched by the `claude-box` runner script; see `README.md` for usage.

Beyond the single interactive box, the runner is an orchestrator: named boxes
(`ps`/`logs`/`stop`), per-box config isolation, and `run -n N` to fan out N
headless boxes over N git worktrees (`results`, `cleanup`).

On top of that sits the **harness** (`harness/`): role agents — `project-manager`,
`lead-dev`, `qa-reviewer`, `devops`, `cataloguer` — each running in its own box, under
a real cross-session lock, with reviewed memory and a localhost dashboard. The roles,
schema and panel template ship IN THIS REPO (`harness/roles/`, `harness/template/`);
`claude-box harness init <dir>` stamps a panel. The document protocol is deliberately
compatible with an ai-bridge instance, which can be used as a panel unmodified. See
`docs/superpowers/specs/2026-08-19-claude-box-harness-design.md`.

The repos root is `$CLAUDE_BOX_ROOT`, default `~/Documents/GitHub`, mounted at the
same path relative to `$HOME` inside the box.

## Git workflow — commit directly to the default branch

**This repo commits directly to `main` and pushes — NO feature branches, NO pull
requests.** It is personal infrastructure co-edited with the user; a PR/review flow
adds overhead with no benefit here. **Do not open PRs against this repo.** Just
stage, commit to `main`, and push.

## After changing the image

`Dockerfile`, `settings.json`, `entrypoint.sh`, `update-claude.sh` and
`githooks/` all live IN the image — changes take effect only after a rebuild
(`./claude-box build` on the host). Committing alone does not update a running
sandbox. The `claude-box` runner itself is host-side and takes effect immediately.

## Harness invariants — do not soften these

- **A box never talks to the container engine.** Role boxes write dispatch intents;
  only the host launches containers. Mounting the engine socket into a box is a
  sandbox escape, not a shortcut.
- **The host validates every intent** before spending a container, and **reverts** any
  `draft → ready` a role writes. Prompt wording is not enforcement.
- **Nothing enters global or repo-local memory without a human accepting it.** Roles
  propose into `.harness/pending/`.
- `tests/run-all.sh` must stay runnable with no containers and no tokens — that is what
  `CLAUDE_BOX_ENGINE=fake` is for. If a change needs a real box to test, say so rather
  than making the suite spend money.
- **`harness init` refreshes machinery, never instance data.** Roles and `SCHEMA.md`
  are claude-box's and get overwritten on every run so a fix reaches every panel;
  config, projects, objectives, knowledge and the log belong to the user and are never
  clobbered. There is a test for exactly this.

## Engine differences are not optional detail

Docker and Apple `container` differ in ways that fail silently, not loudly: `-c`
is `--cpus` on one and `--cpu-shares` on the other, and Docker Desktop cannot
bind-mount the host SSH agent socket. Every such difference belongs in the
`engine_*` helpers in `claude-box`, never inline at a call site.
