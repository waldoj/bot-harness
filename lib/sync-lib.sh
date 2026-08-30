#!/usr/bin/env bash
#
# Copies the canonical library into each converted bot, or reports drift.
#
# The library is vendored rather than submoduled, so each bot repo holds its
# own copy and stays self-contained for cron. The cost of that choice is nine
# copies that can fall out of step; this script is what keeps them honest.
#
#     ./lib/sync-lib.sh            copy into every converted bot
#     ./lib/sync-lib.sh --check    report drift, change nothing, exit 1 if any
#     ./lib/sync-lib.sh BOT...     copy into the named bots only
#
# A bot counts as converted when it already has lib/botlib. Nothing is created
# in a bot that has not been converted yet, so running this cannot accidentally
# vendor the library into all nine.

set -uo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="${BOT_REPO_ROOT:-$HOME/Documents/Git}"
SOURCE="${HARNESS_ROOT}/lib/botlib"

ALL_BOTS="bot-vacation botgov BOUS covid-wastewater dreambot featuring-super-cat finds-you moonstriker rejected-plates"

CHECK_ONLY="no"
if [ "${1-}" = "--check" ]; then
    CHECK_ONLY="yes"
    shift
fi

[ -d "$SOURCE" ] || { echo "No library at $SOURCE" >&2; exit 1; }

DRIFTED=0
SYNCED=0
SKIPPED=0

for bot in ${@:-$ALL_BOTS}; do
    target="${REPO_ROOT}/${bot}/lib/botlib"

    if [ ! -d "${REPO_ROOT}/${bot}" ]; then
        printf 'SKIP %-20s no such repo\n' "$bot"
        SKIPPED=$(( SKIPPED + 1 ))
        continue
    fi

    # Not yet converted: leave it alone rather than vendoring a library it has
    # no way to use
    if [ ! -d "$target" ]; then
        SKIPPED=$(( SKIPPED + 1 ))
        continue
    fi

    if diff -r "$SOURCE" "$target" > /dev/null 2>&1; then
        printf 'OK   %-20s up to date\n' "$bot"
        continue
    fi

    if [ "$CHECK_ONLY" = "yes" ]; then
        printf 'DRIFT %-19s vendored copy differs:\n' "$bot"
        diff -r "$SOURCE" "$target" 2>&1 | sed 's/^/    /'
        DRIFTED=$(( DRIFTED + 1 ))
        continue
    fi

    rm -rf "$target"
    mkdir -p "${REPO_ROOT}/${bot}/lib"
    cp -R "$SOURCE" "${REPO_ROOT}/${bot}/lib/"
    printf 'SYNC %-20s updated\n' "$bot"
    SYNCED=$(( SYNCED + 1 ))
done

if [ "$CHECK_ONLY" = "yes" ]; then
    if [ "$DRIFTED" -gt 0 ]; then
        printf '\n%d bot(s) have a stale vendored library. Run ./lib/sync-lib.sh\n' "$DRIFTED" >&2
        exit 1
    fi
    printf '\nAll vendored copies match (%d not yet converted).\n' "$SKIPPED"
fi

exit 0
