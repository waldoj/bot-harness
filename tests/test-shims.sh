#!/usr/bin/env bash
# Tests for the harness itself. If the shims are wrong, every golden is wrong,
# so these run first.
set -uo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL+1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HARNESS_CAPTURE="$TMP/cap"
export HARNESS_FIXTURES="${HARNESS_ROOT}/fixtures"
export HARNESS_BOT="_test"
export PATH="${HARNESS_ROOT}/shims:$PATH"

echo "date shim:"
check "freezes ISO-8601 UTC" "2026-01-15T12:00:00Z" \
    "$(HARNESS_FROZEN_TIME=2026-01-15T12:00:00Z date -u +%Y-%m-%dT%H:%M:%SZ)"
check "passes through other formats" "2026" \
    "$(HARNESS_FROZEN_TIME=2026-01-15T12:00:00Z date -u +%Y 2>/dev/null || date +%Y)"

echo "sort shim:"
printf 'c\na\nb\n' > "$TMP/in.txt"
check "strips -R (deterministic)" "a b c" "$(sort -R "$TMP/in.txt" | tr '\n' ' ' | sed 's/ $//')"
check "normal sort still sorts"   "a b c" "$(sort "$TMP/in.txt"    | tr '\n' ' ' | sed 's/ $//')"

echo "shuf shim:"
check "returns first line" "c" "$(shuf -n 1 "$TMP/in.txt")"

echo "curl shim:"
curl -s -X POST "https://mastodon.social/api/v1/statuses" \
     -H "Authorization: Bearer supersecret" \
     -d '{"status":"hello"}' > /dev/null 2>&1
REQ="$HARNESS_CAPTURE/001.request"
check "records the endpoint" "/api/v1/statuses" "$(grep '^endpoint:' "$REQ" | cut -d' ' -f2-)"
check "records the method"   "POST"             "$(grep '^method:' "$REQ" | cut -d' ' -f2-)"
check "redacts credentials"  "0"                "$(grep -c 'supersecret' "$REQ")"

# Two curl calls racing for a sequence number must get different ones. Bots
# invoke curl inside $(...), and a command substitution can still be finishing
# as the next call starts; when claiming a number was not atomic, both wrote
# the same .request file and one request disappeared from the capture. That
# silently weakened every golden, so it is worth a test of its own.
RACE_DIR="$TMP/race"
mkdir -p "$RACE_DIR"
(
    export HARNESS_CAPTURE="$RACE_DIR"
    for n in 1 2 3 4 5 6; do
        curl -s "https://mastodon.social/api/v1/statuses?n=${n}" > /dev/null 2>&1 &
    done
    wait
)
check "concurrent calls get distinct seqs" "6" \
    "$(ls "$RACE_DIR"/*.request 2>/dev/null | wc -l | tr -d ' ')"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
