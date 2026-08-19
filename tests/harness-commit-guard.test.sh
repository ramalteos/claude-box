#!/usr/bin/env bash
# The pre-commit hook is the only thing standing between an over-broad `git add` and a
# product repo's history. Runs the real hook against a real repo, on the host.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox
trap teardown_sandbox EXIT

HOOK="$REPO_DIR/githooks/pre-commit"
REPO="$SANDBOX/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config core.hooksPath "$(dirname "$HOOK")"
git -C "$REPO" config user.name t
git -C "$REPO" config user.email t@t
printf 'x\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm init 2>/dev/null

try_commit() {  # try_commit <path> [<content>]
  mkdir -p "$REPO/$(dirname "$1")"
  printf '%s\n' "${2:-content}" > "$REPO/$1"
  git -C "$REPO" add -f "$1" >/dev/null 2>&1
  local out; out="$(git -C "$REPO" commit -m "add $1" 2>&1)"; local code=$?
  git -C "$REPO" reset -q >/dev/null 2>&1
  rm -f "$REPO/$1"
  printf '%s' "$out"
  return $code
}

# Legitimate work must not be impeded.
assert_ok "ordinary source is committed" bash -c 'cd "$1" && printf "export const a=1;\n" > src.js && git add src.js && git commit -qm "feat: a"' _ "$REPO"

# Agent scratch must be refused, by path.
for p in docs/superpowers/specs/2026-01-01-x-design.md \
         .harness/pending/note.md \
         .claude-box-runs/r1/x.txt \
         _wt/task-1/file.txt \
         .pnpm-store/v11/x \
         CLAUDE.local.md \
         .claude/settings.local.json \
         CLAUDE.original.md; do
  if try_commit "$p" >/dev/null 2>&1; then
    fail "refuses $p" "the commit succeeded"
  else
    ok "refuses $p"
  fi
done

out="$(try_commit docs/superpowers/specs/plan.md 2>&1 || true)"
assert_contains "the refusal names the offending path" "$out" "docs/superpowers/specs/plan.md"
assert_contains "the refusal says how to proceed deliberately" "$out" "CLAUDE_BOX_ALLOW_SCRATCH=1"

# A deliberate override must work — the guard is against accidents, not a lock.
mkdir -p "$REPO/docs/superpowers"
printf 'x\n' > "$REPO/docs/superpowers/keep.md"
git -C "$REPO" add -f docs/superpowers/keep.md >/dev/null 2>&1
if CLAUDE_BOX_ALLOW_SCRATCH=1 git -C "$REPO" commit -qm "docs: deliberate" >/dev/null 2>&1; then
  ok "CLAUDE_BOX_ALLOW_SCRATCH=1 overrides it"
else
  fail "CLAUDE_BOX_ALLOW_SCRATCH=1 overrides it" "still refused"
fi

# A repo of its own docs must not be caught by a loose pattern.
assert_ok "an ordinary docs/ path is fine" bash -c 'cd "$1" && mkdir -p docs/adr && printf "x\n" > docs/adr/001.md && git add docs/adr/001.md && git commit -qm "docs: adr"' _ "$REPO"

summary
