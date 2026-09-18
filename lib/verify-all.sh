#!/usr/bin/env bash
# Verifies every bot against its goldens. Exits non-zero if any differ.
set -uo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bots.sh
. "${HARNESS_ROOT}/lib/bots.sh"
RC=0
for bot in ${@:-$ALL_BOTS}; do
    "${HARNESS_ROOT}/lib/verify.sh" "$bot" || RC=1
done
exit "$RC"
