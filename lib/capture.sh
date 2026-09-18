#!/usr/bin/env bash
# Re-captures goldens for one bot, or all of them. Run this to establish the
# baseline, and again (after review) to re-baseline an intentional change.
set -uo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bots.sh
. "${HARNESS_ROOT}/lib/bots.sh"
for bot in ${@:-$ALL_BOTS}; do
    "${HARNESS_ROOT}/lib/run-bot.sh" "$bot"
done
