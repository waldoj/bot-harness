#!/usr/bin/env bash
# Re-captures goldens for one bot, or all of them. Run this to establish the
# baseline, and again (after review) to re-baseline an intentional change.
set -uo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALL_BOTS="bot-vacation botgov BOUS covid-wastewater dreambot featuring-super-cat finds-you moonstriker rejected-plates"
for bot in ${@:-$ALL_BOTS}; do
    "${HARNESS_ROOT}/lib/run-bot.sh" "$bot"
done
