#!/usr/bin/env bash
# A protected branch takes changes through a PR. Tested against real git with a real
# remote, because this is the one command that could put unreviewed agent work on trunk.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT

HOOKS="$REPO_DIR/githooks"
ORIGIN="$SANDBOX/origin.git"
WORK="$SANDBOX/work"

git init -q --bare "$ORIGIN"
git init -q "$WORK"
git -C "$WORK" config core.hooksPath "$HOOKS"
git -C "$WORK" config user.name t
git -C "$WORK" config user.email t@t
git -C "$WORK" remote add origin "$ORIGIN"
printf 'x\n' > "$WORK/README.md"
git -C "$WORK" add README.md
git -C "$WORK" commit -qm init
git -C "$WORK" branch -M main

push() { git -C "$WORK" push "$@" 2>&1; }

# Trunk names must be refused whether or not origin/HEAD is known locally.
out="$(push origin main || true)"
assert_contains "pushing main is refused" "$out" "refusing to push directly to"
assert_contains "the refusal names the branch" "$out" " main"
assert_contains "it says what to do instead" "$out" "gh pr create"
assert_fails "nothing reached the remote" bash -c 'git -C "$1" rev-parse --verify refs/heads/main' _ "$ORIGIN"

for b in master develop next production trunk release; do
  git -C "$WORK" branch -f "$b" main >/dev/null 2>&1
  if push origin "$b:$b" >/dev/null 2>&1; then
    fail "pushing $b is refused" "it went through"
  else
    ok "pushing $b is refused"
  fi
done

# A feature branch is the normal path and must be unimpeded.
git -C "$WORK" checkout -q -b lead-dev/t1-add-test
printf 'y\n' >> "$WORK/README.md"
git -C "$WORK" commit -qam "test: add"
assert_ok "a feature branch pushes fine" bash -c 'git -C "$1" push -q -u origin HEAD' _ "$WORK"

# Tags are not the concern.
git -C "$WORK" tag v0.0.1
assert_ok "a tag pushes fine" bash -c 'git -C "$1" push -q origin v0.0.1' _ "$WORK"

# Once origin/HEAD is known, the remote's own default is protected by name.
git -C "$WORK" remote set-head origin lead-dev/t1-add-test 2>/dev/null || \
  git -C "$WORK" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/lead-dev/t1-add-test
out="$(push origin HEAD:refs/heads/t1-add-test || true)"
assert_contains "the remote's declared default is protected too" "$out" "refusing to push directly to"

# A human who means it can override.
git -C "$WORK" checkout -q main
if CLAUDE_BOX_ALLOW_DIRECT_PUSH=1 git -C "$WORK" push -q origin main 2>/dev/null; then
  ok "CLAUDE_BOX_ALLOW_DIRECT_PUSH=1 overrides it"
else
  fail "CLAUDE_BOX_ALLOW_DIRECT_PUSH=1 overrides it" "still refused"
fi

# --- secrets are caught at push, not only at commit --------------------------
# A repo that sets its own core.hooksPath replaces our pre-commit hook, and several such
# hooks cannot run in a box at all (`brew install gitleaks`). Push is therefore the gate
# that always runs.
if command -v gitleaks >/dev/null 2>&1; then
  git -C "$WORK" checkout -q -b feat/t9-secret-probe
  printf 'const token = "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8";\n' > "$WORK/leak.ts"
  git -C "$WORK" add leak.ts
  git -C "$WORK" -c core.hooksPath=/dev/null commit -qm "feat: add token"   # commit hook bypassed
  out="$(push origin HEAD 2>&1 || true)"
  assert_contains "a secret is refused at push even if the commit hook was bypassed" "$out" "gitleaks found a secret"
  assert_fails "the branch did not reach the remote" \
    bash -c 'git -C "$1" rev-parse --verify refs/heads/feat/t9-secret-probe' _ "$ORIGIN"
  assert_ok "the documented bypass works for a false positive" \
    bash -c 'CLAUDE_BOX_SKIP_GITLEAKS=1 git -C "$1" push -q origin HEAD' _ "$WORK"
else
  ok "a secret is refused at push (skipped — gitleaks not on this host)"
fi

summary
