#!/usr/bin/env bash
# Verifies every bot against its goldens. Exits non-zero if any differ.
set -uo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALL_BOTS="bot-vacation botgov BOUS covid-wastewater dreambot featuring-super-cat finds-you moonstriker rejected-plates"
RC=0
for bot in ${@:-$ALL_BOTS}; do
    "${HARNESS_ROOT}/lib/verify.sh" "$bot" || RC=1
done
exit "$RC"
