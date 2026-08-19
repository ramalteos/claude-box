# Claude Code CLI sandbox — runs under Docker or Apple `container`.
# Node is provided by Vite+ (VoidZero), NOT the base image. Build: ./claude-box build
#
# Pinning: the version-bearing inputs are ARGs so a build can be pinned without
# editing this file — e.g.
#   docker build --build-arg DEBIAN_REF=debian@sha256:<digest> \
#                --build-arg GITLEAKS_SHA256=<sha> ...
# The defaults track moving tags (that is what keeps the toolchain current); the
# ARGs are what you set when you need the same bits twice.
ARG DEBIAN_REF=debian:bookworm-slim
FROM docker.io/library/${DEBIAN_REF}

# Base tools (no node here — Vite+ installs it).
#   procps        — `ps`/`free`, needed to diagnose the OOM-freeze the VM sizing
#                   notes describe; absent from -slim images.
#   build-essential + python3 — node-gyp's toolchain. Without them any dependency
#                   with a native addon fails to install, mid-task.
#   tmux          — running several things side by side inside one box.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git git-lfs ca-certificates curl bash ripgrep less jq openssh-client gnupg \
        procps build-essential python3 tmux unzip \
    && rm -rf /var/lib/apt/lists/*

# --- GitHub CLI (`gh`) — not in Debian repos, so add its official apt source --
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# --- gh `stack` extension (GitHub's official stacked-PRs preview; the extension
# repo is public, but actually creating stacks needs your org/account enabled for
# the preview) — bake it into the trusted image so agents get the CLI without a
# reactive runtime fetch (which the tool-use classifier blocks). No auth is needed
# at build time. Set GH_STACK_REF to pin a tag/commit.
ARG GH_STACK_REF=
RUN if [ -n "$GH_STACK_REF" ]; then \
      gh extension install github/gh-stack --pin "$GH_STACK_REF"; \
    else \
      gh extension install github/gh-stack; \
    fi

# --- gitleaks (secret scanner) — distributed as a static Go binary -----------
# Not in Debian repos; pull the release tarball matching the image arch
# (Apple `container` → linux/arm64, but resolve dynamically so x86 builds work).
# The download is checked against the release's own checksums file, which catches
# a truncated or corrupted transfer. That is NOT supply-chain pinning — the
# release publisher controls both files — so pass GITLEAKS_SHA256 to hard-pin a
# digest you have verified yourself.
ARG GITLEAKS_VERSION=8.21.2
ARG GITLEAKS_SHA256=
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        arm64) gl_arch=arm64 ;; \
        amd64) gl_arch=x64 ;; \
        *) echo "unsupported arch" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}"; \
    tarball="gitleaks_${GITLEAKS_VERSION}_linux_${gl_arch}.tar.gz"; \
    curl -fsSL -o "/tmp/${tarball}" "${base}/${tarball}"; \
    if [ -n "${GITLEAKS_SHA256}" ]; then \
        echo "${GITLEAKS_SHA256}  /tmp/${tarball}" | sha256sum -c -; \
    else \
        curl -fsSL -o /tmp/gl-sums.txt "${base}/gitleaks_${GITLEAKS_VERSION}_checksums.txt"; \
        awk -v f="${tarball}" '$2 == f { print $1 "  /tmp/" f }' /tmp/gl-sums.txt > /tmp/gl-want.txt; \
        test -s /tmp/gl-want.txt; \
        sha256sum -c /tmp/gl-want.txt; \
    fi; \
    tar -xzf "/tmp/${tarball}" -C /usr/local/bin gitleaks; \
    chmod +x /usr/local/bin/gitleaks; \
    rm -f "/tmp/${tarball}" /tmp/gl-sums.txt /tmp/gl-want.txt; \
    gitleaks version

# --- Vite+ (VoidZero unified toolchain) manages the Node.js runtime ----------
# Docker RUN steps don't source shell profiles, so put VP_HOME/bin (where the
# `vp` binary + node/corepack/pnpm shims live) on PATH explicitly.
ENV VP_HOME=/root/.vite-plus
ENV PATH=$VP_HOME/bin:$PATH
RUN curl -fsSL https://vite.plus | bash

# Vite+ manages Node by default and auto-installs the latest LTS on first use of
# its shims (node/corepack), so no explicit `vp env install` step is needed.

# --- pnpm via corepack, then Claude Code -------------------------------------
# TWO pnpm global dirs, and the order on PATH is the point:
#
#   /root/pnpm-global        — bind-mounted from the host by the runner. This is
#     where the start-time `claude-box-update` installs, so the update PERSISTS.
#     Previously the update landed on the container filesystem and was discarded
#     with the --rm container, so every start re-downloaded and re-installed it —
#     multiplied by every box in a fan-out, all contending for one pnpm store.
#
#   /root/.local/share/pnpm  — the baseline baked in at build time. It sits
#     SECOND on PATH, so it is the offline fallback when the mounted dir is empty
#     (first ever run) or the update failed.
ARG PNPM_VERSION=latest
ENV PNPM_BASELINE_HOME=/root/.local/share/pnpm
ENV PNPM_HOME=/root/pnpm-global
ENV PATH=/root/pnpm-global/bin:/root/.local/share/pnpm/bin:$PATH
# pnpm v11 blocks dependency build scripts by default; --allow-build lets
# claude-code run its postinstall (which downloads the platform-native binary).
RUN corepack enable \
 && corepack prepare "pnpm@${PNPM_VERSION}" --activate \
 && PNPM_HOME="$PNPM_BASELINE_HOME" pnpm add -g \
      --allow-build=@anthropic-ai/claude-code @anthropic-ai/claude-code \
 && mkdir -p /root/pnpm-global/bin

# A LOGIN shell (`bash -l`, and anything that sources /etc/profile) RESETS PATH,
# which drops the two pnpm dirs the ENV above puts first — so `claude` and
# `pnpm -g` resolve from the default CMD but not from a login shell. Re-assert
# them there too, idempotently.
RUN printf '%s\n' \
      'case ":$PATH:" in' \
      '  *":/root/pnpm-global/bin:"*) ;;' \
      '  *) PATH="/root/pnpm-global/bin:/root/.local/share/pnpm/bin:$PATH" ;;' \
      'esac' \
      'export PATH' \
      > /etc/profile.d/claude-box-path.sh

# --- pnpm: persistent shared store + private-registry auth -------------------
# Two settings are baked into the USER-level ~/.npmrc (= a trusted source); a
# third, OPTIONAL piece — which @scopes are private — is deployment-specific and
# is supplied out-of-band, so NO org/scope name is hardcoded in the image:
#
#  store-dir  — the container is ephemeral (--rm), so a store on the container fs
#    is wiped and re-downloaded every run. The value baked in here is only a
#    fallback: the runner always passes CLAUDE_BOX_STORE_DIR and the entrypoint
#    re-points pnpm at it, because the right store depends on what was mounted —
#    inside the mounted root (same filesystem as node_modules, so pnpm hardlinks
#    instead of copying) or, for a target outside the root, a host-side store dir
#    so it does not litter the user's own project directory with a .pnpm-store.
#
#  _authToken — pnpm REFUSES to expand ${ENV} in credentials read from a project
#    .npmrc (it's committed, so expanding could leak the token to a hostile
#    registry). It DOES expand them in a user-level ~/.npmrc. So the auth line
#    must live here, not in the repo. The literal ${GITHUB_REGISTRY_ACCESS_TOKEN}
#    is written verbatim (single quotes) and resolved AT RUNTIME from the env var
#    the runner forwards — no secret is baked into the image. This authenticates
#    ANY scope's packages on GitHub Packages, so it is registry- not org-specific.
#
#  scope→registry mappings — put lines like
#    `@your-scope:registry=https://npm.pkg.github.com/` in `registries.npmrc`
#    (gitignored; copy `registries.npmrc.example` to start). The glob COPY never
#    fails on a fresh clone because the committed .example always matches; only
#    the real file, if present, is appended to ~/.npmrc.
COPY registries.npmrc* /tmp/npmrc.d/
RUN printf '%s\n' \
      'store-dir=/root/.pnpm-store' \
      '//npm.pkg.github.com/:_authToken=${GITHUB_REGISTRY_ACCESS_TOKEN}' \
      > /root/.npmrc \
 && if [ -f /tmp/npmrc.d/registries.npmrc ]; then \
      cat /tmp/npmrc.d/registries.npmrc >> /root/.npmrc; \
    fi \
 && rm -rf /tmp/npmrc.d

# --- git: identity comes from the runner, hygiene comes from here -------------
# The host ~/.gitconfig is NOT mounted (macOS-only paths and credential helpers);
# the runner passes GIT_AUTHOR_*/GIT_COMMITTER_* through as env instead. What the
# image sets is what should hold in every box:
#
#  safe.directory  — the workspace arrives as a bind mount whose ownership git may
#    read as "dubious"; without this every git call in the box fails.
#  core.hooksPath  — a gitleaks pre-commit gate. gitleaks was already in the image
#    but wired to nothing; an agent in auto/bypass mode is exactly the caller that
#    should not be able to commit a secret. A repo that sets its own core.hooksPath
#    (husky and friends) still wins — repo config overrides global.
#  pre-commit  — gitleaks, plus a refusal to commit agent scratch (plans, specs, worktree
#    and store directories). An over-broad `git add` is how process exhaust gets into a
#    product repo's history.
#  pre-push    — a protected branch takes changes through a pull request. The roles are
#    told to open one and the policy layer denies `gh pr merge`, but neither stops
#    `git push origin main`; this does.
COPY githooks/pre-commit githooks/pre-push /usr/local/share/claude-box/githooks/
RUN chmod +x /usr/local/share/claude-box/githooks/pre-commit \
              /usr/local/share/claude-box/githooks/pre-push \
 && git config --global --add safe.directory '*' \
 && git config --global core.hooksPath /usr/local/share/claude-box/githooks \
 && git config --global init.defaultBranch main

# Keep ALL Claude config + credentials under one dir so a single bind-mount
# persists the login across container restarts (decoupled from the host).
ENV CLAUDE_CONFIG_DIR=/root/.claude

# --- Baked-in Claude Code settings (starts every session in AUTO mode) --------
# `settings.json` in this repo is the single source of truth for how Claude Code
# behaves in the box; it is copied in at BUILD time, so edits need a rebuild.
#
# It lands on the POLICY path, not $CLAUDE_CONFIG_DIR, for two reasons:
#   * /root/.claude is bind-mounted from the host, so a settings file baked in
#     there would be shadowed at run time — the image cannot seed it.
#   * Claude Code accepts `defaultMode: "auto"` ONLY from policy, user, or
#     --settings sources; project/local settings are ignored as repo-controllable.
# The policy path lives outside every mount, so it applies to `claude` however
# it starts: the default CMD, runner args, or typed after `./claude-box shell`.
#
# Policy settings OVERRIDE the host-side user config, so keep this file to what
# the box should enforce — anything listed here can no longer be changed from
# inside a session (shift+tab still switches mode for the session at hand).
COPY settings.json /etc/claude-code/managed-settings.json

# Entrypoint refreshes Claude Code to the latest release when a container START
# actually launches `claude` (the build only pins a baseline), then execs the
# CMD/args. An explicit command — `shell`/bash and friends — skips the refresh
# and can run `claude-box-update` by hand instead. The refresh is best-effort:
# an offline start falls back to the version already installed. Skip it for
# `claude` too with -e CLAUDE_BOX_SKIP_UPDATE=1. The entrypoint also re-attaches
# bare runner flags to `claude` (runner args replace CMD), so `./claude-box
# --resume` and arg passthrough keep working.
COPY update-claude.sh /usr/local/bin/claude-box-update
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/claude-box-update /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# The runner bind-mounts the host's known_hosts to /root/.ssh/known_hosts; make
# sure the directory exists with sane perms rather than relying on the mount to
# create it.
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# The bind-mount lands at the same path relative to $HOME as on the host — for the
# default root, /root/Documents/GitHub — so `~/Documents/GitHub/<repo>` resolves
# identically on both sides and a path copied from one works in the other.
#
# The mount path therefore follows CLAUDE_BOX_ROOT and cannot be baked in here.
# /workspace and /root/workspace stay as compatibility symlinks to it — absolute
# `/workspace/...` paths are baked into things we cannot rewrite from here: git
# worktree `gitdir` files in existing clones, agent definitions and slash
# commands, and Claude Code session history — but the entrypoint creates them at
# run time from CLAUDE_BOX_MOUNT.
RUN mkdir -p /root/workspace

WORKDIR /root
CMD ["claude"]
