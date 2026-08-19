# Claude Code CLI sandbox — Linux/arm64, runs under Apple `container`.
# Node is provided by Vite+ (VoidZero), NOT the base image. Build: ./claude-box build
FROM docker.io/library/debian:bookworm-slim

# Base tools (no node here — Vite+ installs it)
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates curl bash ripgrep less jq openssh-client gnupg \
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
# at build time. If a future version gates the repo behind auth, install it at
# container start instead.
RUN gh extension install github/gh-stack

# --- gitleaks (secret scanner) — distributed as a static Go binary -----------
# Not in Debian repos; pull the release tarball matching the image arch
# (Apple `container` → linux/arm64, but resolve dynamically so x86 builds work).
ARG GITLEAKS_VERSION=8.21.2
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        arm64) gl_arch=arm64 ;; \
        amd64) gl_arch=x64 ;; \
        *) echo "unsupported arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${gl_arch}.tar.gz" \
        | tar -xz -C /usr/local/bin gitleaks; \
    chmod +x /usr/local/bin/gitleaks; \
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
# pnpm global installs land in PNPM_HOME; put it on PATH so `claude` resolves.
ENV PNPM_HOME=/root/.local/share/pnpm
ENV PATH=$PNPM_HOME/bin:$PATH
# pnpm v11 blocks dependency build scripts by default; --allow-build lets
# claude-code run its postinstall (which downloads the platform-native binary).
RUN corepack enable \
 && corepack prepare pnpm@latest --activate \
 && pnpm add -g --allow-build=@anthropic-ai/claude-code @anthropic-ai/claude-code

# --- pnpm: persistent shared store + private-registry auth -------------------
# Two settings are baked into the USER-level ~/.npmrc (= a trusted source); a
# third, OPTIONAL piece — which @scopes are private — is deployment-specific and
# is supplied out-of-band, so NO org/scope name is hardcoded in the image:
#
#  store-dir  — the container is ephemeral (--rm), so a store on the container fs
#    is wiped and re-downloaded every run. Point pnpm at a dir INSIDE the bind-
#    mounted workspace: same (virtiofs) filesystem as node_modules (so pnpm can
#    hardlink instead of copy), survives container exit, and is a real host dir.
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
      'store-dir=/root/workspace/.pnpm-store' \
      '//npm.pkg.github.com/:_authToken=${GITHUB_REGISTRY_ACCESS_TOKEN}' \
      > /root/.npmrc \
 && if [ -f /tmp/npmrc.d/registries.npmrc ]; then \
      cat /tmp/npmrc.d/registries.npmrc >> /root/.npmrc; \
    fi \
 && rm -rf /tmp/npmrc.d

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

# The workspace bind-mount lives at ~/workspace so the host and the container
# share the same *relative* path: `~/workspace/repos/<x>` resolves identically on
# both sides, and a path copied from one works in the other.
#
# /workspace stays as a compatibility symlink — absolute `/workspace/...` paths
# are baked into things we cannot rewrite from here: git worktree `gitdir` files
# in existing clones, agent definitions and slash commands in the control-plane
# bundle, and Claude Code session history. The symlink keeps both spellings
# valid, so switching the mount is not a flag day.
RUN mkdir -p /root/workspace && ln -sfn /root/workspace /workspace

WORKDIR /root/workspace
CMD ["claude"]
