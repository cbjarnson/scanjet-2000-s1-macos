#!/bin/zsh
# Local checks only; no downloads, system writes or scanner sessions.
set -euo pipefail
ROOT=${0:A:h:h}
HELPER="$ROOT/scanjet-recovery.zsh"
scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/scanjet-helper-tests.XXXXXX")
trap '/bin/rm -rf -- "$scratch"' EXIT
expect_failure() {
  local expected="$1"; shift
  if "$@" > "$scratch/result.txt" 2>&1; then
    print -u2 'Expected refusal but command succeeded.'; exit 1
  fi
  /usr/bin/grep -F -- "$expected" "$scratch/result.txt" >/dev/null \
    || { /bin/cat "$scratch/result.txt"; exit 1; }
  print -- "PASS: $expected"
}
/bin/zsh -n "$HELPER"
/bin/zsh "$HELPER" help >/dev/null
expect_failure 'Unknown command' /bin/zsh "$HELPER" unexpected
expect_failure 'verify requires one app path' /bin/zsh "$HELPER" verify
expect_failure 'Expected a real HP Scanner 4.app directory' /bin/zsh "$HELPER" verify "$scratch/missing.app"
/bin/mkdir "$scratch/empty.app"
expect_failure 'missing, extra, or unexpected entries' /bin/zsh "$HELPER" verify "$scratch/empty.app"
/bin/ln -s "$scratch/empty.app" "$scratch/link.app"
expect_failure 'Expected a real HP Scanner 4.app directory' /bin/zsh "$HELPER" verify "$scratch/link.app"
expect_failure 'Local package does not exist' /bin/zsh "$HELPER" prepare --package "$scratch/missing.pkg"
expect_failure 'Use prepare' /bin/zsh "$HELPER" prepare --invalid
print 'PASS: syntax, help, and seven refusal checks. No system files changed.'
