# claude-box

Run the **Claude Code CLI inside a container sandbox** on macOS (Apple Silicon). The
agent's filesystem and network blast radius stay off the host while your existing
credentials (Claude login, `gh` token, SSH agent) are forwarded in. One command runs
one box; `run -n N` fans a prompt out over N git worktrees; `headless` is the seam an
external orchestrator drives; the [harness](harness/README.md) runs role agents over a
task board.

Works with **Docker** or Apple **`container`**; the runner detects which you have.

## Requirements

- macOS on Apple Silicon.
- One engine: Docker (Desktop or any daemon your `docker` CLI reaches), **or** macOS 26
  with the `container` CLI (`brew install --cask container`) and Rosetta
  (`softwareupdate --install-rosetta`) for its buildkit VM.
- A Claude account Claude Code can log in with. No Anthropic API key is needed.

## Install

The runner is one script that finds its image context, harness and roles next to its
real path, so link it onto your PATH from a clone:

```sh
ln -s "$PWD/claude-box" ~/.local/bin/claude-box   # engine auto-detected: Docker, then container
ln -s "$PWD/abox"       ~/.local/bin/abox         # same runner, engine pinned to Apple container
claude-box build                                   # build the image, once
claude-box                                         # a box on the current directory; /login once inside
```

`abox <args>` is exactly `CLAUDE_BOX_ENGINE=container claude-box <args>`. Keep both when
your `claude-box` should stay on Docker. Every command below accepts either name.

From inside the clone, `./claude-box` works too; from the repos root `./claude-box` is the
*directory* and the shell says permission denied, which is not a broken script.

## Commands

```sh
claude-box build                              # build (or rebuild) the image
claude-box                                    # run claude on the current directory
claude-box <dir>                              # run claude on <dir>
claude-box [<dir>] <args>                     # pass args to claude (--resume, --model …)
claude-box [<dir>] shell                      # bash inside the sandbox

claude-box headless [<dir>] --name <box> --prompt-file <f> [--worktree <id> [--branch <b>]]
                    [--system-prompt-file <f>] [--model <m>] [--effort <e>]
claude-box headless [<dir>] --worktree <id> --remove

claude-box run -n 4 [<dir>] "<prompt>"        # fan out 4 headless boxes over 4 worktrees
claude-box results <run-id>                   # exit code, commits and diffstat per box
claude-box cleanup [-y] <run-id>              # remove that run's worktrees and branches

claude-box ps                                 # running boxes
claude-box logs [-f] [--raw] <box>            # one box's log, rendered (or the raw stream)
claude-box stop <box> | --all                 # stop one box, or every box
claude-box stop --daemon                      # stop the engine daemon/VM (takes every box with it)

claude-box harness <subcommand> …             # role agents over a panel: see harness/README.md
claude-box role <role> [flags]                # one role box by hand
```

The target directory defaults to the current one. When the first argument is an
existing directory it is the target and is dropped from the arguments given to `claude`.

## Engines

Detection prefers Docker and falls back to Apple `container`; `CLAUDE_BOX_ENGINE=docker|container`
forces one (`fake` is the engine the tests use). The runner starts the engine's daemon
when it is down: Docker Desktop is launched and waited for, `container system start`
otherwise.

The two CLIs look alike and are not compatible, so every difference lives in the
`engine_*` helpers of the runner, never at a call site:

| | Docker | Apple `container` |
| --- | --- | --- |
| CPU cap | `--cpus` (`-c` there is `--cpu-shares`, a weight) | `-c` |
| SSH agent | fixed path `/run/host-services/ssh-auth.sock`; a bind mount of `$SSH_AUTH_SOCK` does not work | bind-mount `$SSH_AUTH_SOCK` |
| Egress | NATed by Docker's VM | needs host IP forwarding, see [Networking](#networking-apple-container-only) |
| Daemon | `open -a Docker` | `container system start` |

## What a box sees

### Repos and paths

The repos root is `~/Documents/GitHub` (`CLAUDE_BOX_ROOT`), mounted at the **same path
relative to `$HOME`** inside the box: the container runs as root, so
`/root/Documents/GitHub`. A path copied from one side works on the other, git worktree
admin files stay valid on both sides, and a panel's `reposRoot: ~/Documents/GitHub` needs
no translation. `/workspace` and `/root/workspace` are symlinks to the mount, kept for
absolute paths baked into older worktrees, agent definitions and session history.

Mount and working directory are separate:

- **Target under the root**: the whole root is mounted, so sibling repos stay reachable,
  and claude's working directory is the target's subpath. That is what lets a project's
  `.claude/agents` load while its sibling clones remain available.
- **Target elsewhere**: that directory alone is mounted at the same container path.

### Config isolation and state

Every box has a name (`claude-box-<slug>`, shown by `ps`) and its own Claude config
directory under the runner's state dir, seeded from the shared config (`settings.json`,
`CLAUDE.md`, `plugins/`, `agents/`, `commands/`, `skills/`; never session state). The
shared login is linked into it, so one `/login` serves every box; a token a box refreshes
(refresh tokens rotate, so the last refresh is the only valid one) is carried back to the
shared login when the next box starts. The plain interactive box keeps the whole shared directory, so
`--resume` and history work, unless another running box already holds it; then it gets an
isolated one and says so. `CLAUDE_BOX_ISOLATE=1` forces isolation, `CLAUDE_BOX_NAME=<name>`
names a box.

| Where | What |
| --- | --- |
| `~/Library/Application Support/claude-box/` (`CLAUDE_BOX_CONFIG_HOME`) | the sandbox's own Claude config and login, mounted as `/root/.claude`; separate from your host `~/.claude` |
| `~/Library/Application Support/claude-box-state/` (`CLAUDE_BOX_STATE`) | per-box config dirs, runs, logs, locks, harness state, global memory; a sibling of the config dir because the config dir is mounted into boxes |

### Auth and forwarded environment

- Claude: the login file above. `/login` once in any interactive box; headless boxes
  cannot answer a prompt. `ANTHROPIC_API_KEY` is forwarded when exported, and then
  Claude Code bills the key instead of the login.
- GitHub: the host's `gh auth token` as `GH_TOKEN`, and `GITHUB_REGISTRY_ACCESS_TOKEN` for
  GitHub Packages. The token is the host's full token, readable by every agent in the box,
  with unrestricted egress; launch with `GH_TOKEN=<scoped-token> claude-box …` when that
  is too much.
- SSH: the host agent socket is forwarded (private keys never enter the box) and
  `~/.ssh/known_hosts` is mounted read-only.
- Git identity (`GIT_AUTHOR_*`, `GIT_COMMITTER_*`) from the host `git config`, and `TZ`.
  The host `~/.gitconfig` itself is not mounted.
- Plugins, commands and skills are not seeded into headless boxes by default.
  `CLAUDE_BOX_SEED_PLUGINS=host` copies the host's `~/.claude/plugins` registry and its
  `enabledPlugins` into each box (paths rewritten to the box's config dir);
  `CLAUDE_BOX_SEED_PLUGINS=1` seeds the sandbox config's own plugins, commands and
  skills. Plugin OAuth tokens are never copied from the host: a plugin that needs one is
  authorised in the sandbox login.

### Sizing

Each background agent is another full Claude Code process. Defaults derive from the host:
8 GiB or a quarter of host RAM, whichever is smaller, and 4 CPUs per box; `run -n N`
divides a budget across the boxes instead of giving each the single-box default.

| Env var | Default | Effect |
| --- | --- | --- |
| `CLAUDE_BOX_MEM` | `8G`, capped at host/4 | per-box memory; set explicitly it wins everywhere, including fan-out |
| `CLAUDE_BOX_CPUS` | `4` | per-box CPU cap (fan-out divides host CPUs, max 4) |
| `CLAUDE_BOX_FANOUT_MEM_PCT` | `60` | share of host RAM a whole fan-out may claim |
| `CLAUDE_BOX_MIN_BOX_GIB` | `3` | below this a fan-out refuses to start and names the max `-n` |

A box that freezes under load is usually out of memory (no swap in the VM, so an OOM
kill or thrashing). `claude-box shell`, then `watch -n1 'free -m; ps aux --sort=-%mem | head'`
confirms it; raise `CLAUDE_BOX_MEM`.

## Headless seam (`headless`)

One box, one prompt, one optional worktree, in the foreground, the box's exit code
passed through. An external orchestrator drives this and never sees a container path
or an engine flag; [claude-graph](https://github.com/raj-mehra/claude-graph) runs its
pm → architect → coder → qa → reviewer graph through it.

```sh
claude-box headless <repo> --name graph-t1-coder-1 --worktree t1 --branch claude-graph/t1 \
    --prompt-file p.md --system-prompt-file s.md --model opus --effort high
claude-box headless <repo> --worktree t1 --remove      # drop the tree, keep the branch
```

- `--worktree <id>` creates `<mount>/.claude-box-runs/<id>` on branch `claude-box/<id>`
  (or `--branch <name>`; fixed by the first call) inside the box on the first call and
  reuses it after, like `run`.
- Before the claude stream the command prints `worktree=`, `branch=`, `base=` and `box=`
  lines. `base=` stays the original branch point even after the repo's HEAD moves.
- Prompts come from files read on the host, so there is nothing to quote. The box runs
  `claude --permission-mode bypassPermissions --output-format stream-json --verbose`
  with `IS_SANDBOX=1`, exactly like a `run` box.

## Parallel fan-out (`run`)

```sh
claude-box run -n 4 "make the failing e2e suite green; commit when it passes"
claude-box results r20260819-142230
claude-box cleanup r20260819-142230
```

Each box gets its own git worktree and branch (`claude-box/<run-id>-<i>`), cut from the
target repo's HEAD, so N boxes attack one prompt without sharing a working tree. They run
`claude -p` in `bypassPermissions` mode; nothing can answer a permission prompt in a
headless box, and the sandbox is what makes that acceptable.

- Worktrees are created from inside a box, not on the host: git stores absolute paths in
  worktree admin files, and the box's paths are the ones that run the work. On the host
  those worktrees look broken; that is expected.
- The target must be a git repo. Worktrees land in `.claude-box-runs/<run-id>/` under the
  mount root and are added to `.git/info/exclude` when that root is the repo itself.
- `results` reports each box's exit code, commits since the base SHA, diffstat and
  uncommitted paths. `cleanup` deletes worktrees **and** branches, so it asks first
  (`-y` skips the prompt).
- Claude Code refuses `bypassPermissions` as root, which the box always is, so headless
  boxes get `IS_SANDBOX=1`. Interactive boxes do not; they have a human.
- Claude Code is refreshed once per run, before the boxes start; N simultaneous installs
  into one bind-mounted pnpm dir would be a race.
- `CLAUDE_BOX_RUN_ARGS="…"` adds flags to every box.

## The image

`Dockerfile` builds `claude-box:latest` (`CLAUDE_BOX_IMAGE`): Debian plus `git`,
`git-lfs`, `curl`, `ripgrep`, `jq`, `less`, `tmux`, `procps`, `build-essential`, `python3`,
`openssh-client`, the GitHub CLI with the `gh-stack` extension, gitleaks, Node via Vite+,
pnpm, and Claude Code. `entrypoint.sh` finishes the runtime wiring on every start.
Anything that lives in the image (`Dockerfile`, `settings.json`, `entrypoint.sh`,
`update-claude.sh`, `githooks/`) takes effect on the next `claude-box build`; the
runner itself is host-side and takes effect immediately.

### Policy settings (`settings.json`)

Copied into the image as `/etc/claude-code/managed-settings.json`, the policy layer, so
it applies however `claude` starts and cannot be changed from inside a session. It
starts every session in `auto` permission mode (the box is the sandbox) and denies what
the sandbox cannot undo: force-push, `gh pr merge`, repo deletion. Deny rules are prefix
matches (`git push --force origin main` is caught, `git push origin main --force` is not),
so treat the list as a guardrail, not the boundary. It also sets
`BASH_DEFAULT_TIMEOUT_MS=600000` and `BASH_MAX_TIMEOUT_MS=1800000` so a long install
runs inline.

### Git hooks baked into the image

The image's global `core.hooksPath` gives every repo three gates with no per-repo setup.
A repo that sets its own `core.hooksPath` (husky and friends) overrides them.

| Hook | Refuses | Override |
| --- | --- | --- |
| pre-commit, gitleaks | a commit that adds a secret | `CLAUDE_BOX_SKIP_GITLEAKS=1 git commit …` |
| pre-commit, scratch | staged `docs/superpowers/`, `.harness/`, `.claude-box-runs/`, `_wt/`, `.pnpm-store/`, `CLAUDE.local.md`, `.claude/settings.local.json`, `*.original.md` | `CLAUDE_BOX_ALLOW_SCRATCH=1 git commit …` |
| pre-push | a direct push to the remote's default branch or to `main`, `master`, `trunk`, `develop`, `next`, `production`, `release` | `CLAUDE_BOX_ALLOW_DIRECT_PUSH=1 git push …` |

`git commit --no-verify` skips all hooks. Tags and feature branches push normally.

### Keeping Claude Code current

The image bakes in a pinned Claude Code; `entrypoint.sh` moves it forward on a start that
launches `claude` (not on `shell` or an explicit command). The install goes into
`/root/pnpm-global`, bind-mounted from the state dir, so it persists across `--rm`
containers, with the image baseline underneath on `PATH` as the offline fallback. A stamp
skips the check for `CLAUDE_BOX_UPDATE_TTL` seconds (default 21600, 6 h). The stamp is
written only after `claude --version` runs; a broken persisted install is discarded and
reinstalled, and if that fails the shim is removed so the baseline takes over. The refresh
is best-effort: offline it warns and uses what is installed.

```sh
claude-box-update            # inside the box: check now (respects the TTL)
claude-box-update --force    # ignore the stamp
CLAUDE_BOX_SKIP_UPDATE=1 claude-box <dir>   # skip it for this start
```

### pnpm store

The container is `--rm`, so the store must live on a mount. With the root mounted, the
store is `<root>/.pnpm-store` (`~/Documents/GitHub/.pnpm-store`): the same filesystem as
`node_modules`, so pnpm hardlinks, warm between runs, shared with the host. A target
outside the root gets a shared store from the state dir mounted at `/root/.pnpm-store`
instead, so your project is not littered; that is a separate mount, so pnpm copies there.
`COREPACK_HOME` sits in the persisted pnpm dir, so a repo's pinned pnpm is fetched once
per host. Roles never pass `--store-dir`.

### Private registries (GitHub Packages)

The image's `/root/.npmrc` carries
`//npm.pkg.github.com/:_authToken=${GITHUB_REGISTRY_ACCESS_TOKEN}`, resolved at run time
from the forwarded variable; nothing secret is in the image, and it must be user-level
because pnpm refuses `${ENV}` credentials in a project `.npmrc`. Which scopes resolve
there is yours: copy `registries.npmrc.example` to `registries.npmrc` (gitignored) and
list `@scope:registry=https://npm.pkg.github.com/` lines; the build works without it.

### Reproducible builds

Version-bearing inputs are build args, so a build can be pinned without editing the
Dockerfile:

```sh
docker build -t claude-box:latest \
  --build-arg DEBIAN_REF=debian@sha256:<digest> \
  --build-arg GITLEAKS_VERSION=8.21.2 --build-arg GITLEAKS_SHA256=<sha256> \
  --build-arg PNPM_VERSION=10.15.0 --build-arg GH_STACK_REF=<tag> .
```

Defaults track moving tags on purpose. The gitleaks download is checked against the
release's checksums file (a corrupt transfer), which is not supply-chain pinning; that is
what `GITLEAKS_SHA256` is for. `curl https://vite.plus | bash` stays an unpinned install.

## Harness

Role agents (`project-manager`, `architect`, `lead-dev`, `qa-reviewer`, `devops`,
`cataloguer`), each in its own box, driving work on a control panel of markdown
documents. `claude-box harness do "<what you want>"` takes one request from draft to
merged PR; `harness loop` schedules a backlog. Everything about it, including its
commands, gates, memory tiers and dashboard, is in [harness/README.md](harness/README.md).

## Environment variables

Runner:

| Env var | Default | What it does |
| --- | --- | --- |
| `CLAUDE_BOX_ENGINE` | `auto` | `docker`, `container`, `fake`, or auto-detect (Docker first) |
| `CLAUDE_BOX_ROOT` | `~/Documents/GitHub` | repos root, mounted with `$HOME`-relative parity |
| `CLAUDE_BOX_CONFIG_HOME` | `~/Library/Application Support/claude-box` | the sandbox's Claude config and login |
| `CLAUDE_BOX_STATE` | `~/Library/Application Support/claude-box-state` | runner state: box configs, runs, logs, locks, memory |
| `CLAUDE_BOX_IMAGE` | `claude-box:latest` | image to run |
| `CLAUDE_BOX_NAME` | | name this box |
| `CLAUDE_BOX_ISOLATE` | | `1`: give the interactive box its own config dir |
| `CLAUDE_BOX_RUN_ARGS` | | extra flags for every `run` box |
| `CLAUDE_BOX_SEED_PLUGINS` | `0` | `host`: the host's enabled plugins into each box; `1`: the sandbox config's plugins/commands/skills |
| `CLAUDE_BOX_SKIP_UPDATE` | | `1`: skip the Claude Code refresh |
| `CLAUDE_BOX_UPDATE_TTL` | `21600` | seconds between refresh checks |
| `CLAUDE_BOX_MEM`, `CLAUDE_BOX_CPUS`, `CLAUDE_BOX_FANOUT_MEM_PCT`, `CLAUDE_BOX_MIN_BOX_GIB` | see [Sizing](#sizing) | |

Inside the box (hooks): `CLAUDE_BOX_SKIP_GITLEAKS`, `CLAUDE_BOX_ALLOW_SCRATCH`,
`CLAUDE_BOX_ALLOW_DIRECT_PUSH`, see [Git hooks](#git-hooks-baked-into-the-image).
Harness knobs are listed in [harness/README.md](harness/README.md#knobs).

## Networking (Apple `container` only)

Apple `container` puts the sandbox on a vmnet subnet behind `bridge100`; reaching the
internet needs the host to forward those packets out `en0`. A VPN client (AWS Client VPN,
for one) zeroes `net.inet.ip.forwarding` on connect and does not restore it, so the box
silently loses egress and looks hung at "Checking connectivity…". The runner detects
this and runs `sudo sysctl -w net.inet.ip.forwarding=1` only when forwarding is off. To
keep that prompt-free, install a scoped sudoers rule (validate with `visudo -c -f`):

```
# /etc/sudoers.d/claude-box-ipforward   (0440 root:wheel)
<you> ALL=(root) NOPASSWD: /usr/sbin/sysctl -w net.inet.ip.forwarding=1
```

Docker Desktop NATs through its own VM and needs none of this.

## Tests

```sh
tests/run-all.sh
```

Harness, headless seam, hooks, updater and dashboard tests, all against
`CLAUDE_BOX_ENGINE=fake`, a stub engine that records what would have been launched: no
containers, no tokens. One boundary is not covered: a real `claude` process writing a
real task document needs a logged-in box and is checked by hand.

## Repository layout

| Path | What |
| --- | --- |
| `claude-box`, `abox` | the runner, and the Apple-`container` alias for it |
| `Dockerfile`, `entrypoint.sh`, `update-claude.sh`, `settings.json`, `githooks/` | the image |
| `registries.npmrc.example` | template for private `@scope` registry mappings |
| `harness/` | `harness.sh` (the executor), `roles/`, `template/` (what `harness init` stamps), `overlay.md`, `standards.md`, `ui/`, `README.md` |
| `tests/` | the fake engine and the test suite |
