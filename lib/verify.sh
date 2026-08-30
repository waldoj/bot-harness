#!/usr/bin/env bash
#
# Compares a bot's current requests against its committed goldens.
#
# This is the safety net for the refactor: after a bot is rewritten to use the
# shared library, its requests must still match what the original produced,
# byte for byte. Any difference is either a bug or a deliberate change that
# should be reviewed and re-baselined.

set -uo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOT="${1:?usage: verify.sh <bot-name>}"

GOLDEN="${HARNESS_ROOT}/goldens/${BOT}"
[ -d "$GOLDEN" ] || { echo "No goldens for $BOT. Run capture.sh first." >&2; exit 1; }

ACTUAL=$(mktemp -d "${TMPDIR:-/tmp}/verify.${BOT}.XXXXXX")
trap 'rm -rf "$ACTUAL"' EXIT

"${HARNESS_ROOT}/lib/run-bot.sh" "$BOT" "$ACTUAL" > /dev/null 2>&1

FAILED=0

# Compare the request sequence. stdout/stderr are deliberately excluded: they
# carry incidental noise (set -x traces, progress output) that is not part of
# the contract with Bluesky or Mastodon.
GOLDEN_REQS=$(ls "${GOLDEN}"/*.request 2>/dev/null | wc -l | tr -d ' ')
ACTUAL_REQS=$(ls "${ACTUAL}"/*.request 2>/dev/null | wc -l | tr -d ' ')

if [ "$GOLDEN_REQS" != "$ACTUAL_REQS" ]; then
    printf 'FAIL %-20s request count changed: %s -> %s\n' "$BOT" "$GOLDEN_REQS" "$ACTUAL_REQS"
    FAILED=1
else
    for g in "${GOLDEN}"/*.request; do
        [ -f "$g" ] || continue
        name=$(basename "$g")
        if ! diff -u "$g" "${ACTUAL}/${name}" > /dev/null 2>&1; then
            printf 'FAIL %-20s %s differs:\n' "$BOT" "$name"
            diff -u "$g" "${ACTUAL}/${name}" | sed 's/^/    /'
            FAILED=1
        fi
    done
fi

# The exit code is part of the contract too: a bot that used to succeed must
# still succeed.
GOLDEN_EXIT=$(cat "${GOLDEN}/exit-code.txt" 2>/dev/null || echo "?")
ACTUAL_EXIT=$(cat "${ACTUAL}/exit-code.txt" 2>/dev/null || echo "?")
if [ "$GOLDEN_EXIT" != "$ACTUAL_EXIT" ]; then
    printf 'FAIL %-20s exit code changed: %s -> %s\n' "$BOT" "$GOLDEN_EXIT" "$ACTUAL_EXIT"
    FAILED=1
fi

if [ "$FAILED" -eq 0 ]; then
    printf 'PASS %-20s %s requests match\n' "$BOT" "$GOLDEN_REQS"
fi
exit "$FAILED"
