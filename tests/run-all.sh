#!/usr/bin/env bash
# Run every harness test. No containers, no tokens: the tests drive the runner with
# CLAUDE_BOX_ENGINE=fake, which records what would have been launched.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

failed=0
for t in tests/*.test.sh; do
  printf '\n== %s\n' "$(basename "$t")"
  bash "$t" || failed=1
done

if [ "$failed" -eq 0 ]; then
  printf '\nall harness tests passed\n'
else
  printf '\nSOME TESTS FAILED\n' >&2
fi
exit "$failed"
