#!/usr/bin/env bash
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib/botlib" && pwd)"
PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; PASS=$((PASS+1))
    else printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

. "$LIB/core.sh"

echo "redaction:"
add_redaction "supersecrettoken123"
check "redacts a known value" "token=<REDACTED>" "$(redact 'token=supersecrettoken123')"
check "redacts bearer tokens" "Authorization: Bearer <REDACTED>" "$(redact 'Authorization: Bearer abc.def.ghi')"
check "leaves ordinary text" "hello world" "$(redact 'hello world')"
add_redaction "aa+bb/cc=dd.ee-ff"
check "handles regex metacharacters" "x=<REDACTED>" "$(redact "x=aa+bb/cc=dd.ee-ff")"
check "ignores short values" "$(printf 'cat')" "$(add_redaction 'cat'; redact 'cat')"

echo "prefix mapping:"
. "$LIB/secrets.sh"
check "hyphen to underscore" "REJECTED_PLATES" "$(secrets_prefix_for rejected-plates)"
check "uppercases" "BOUS" "$(secrets_prefix_for BOUS)"
check "mixed" "BOT_VACATION" "$(secrets_prefix_for bot-vacation)"

echo "secrets loading:"
FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures" && pwd)/secrets.env"
# The fixture is committed at 644, so loading it outside the harness must be
# refused and inside it must succeed. Both directions matter: a guard that
# never fires and a guard that always fires look identical from one test.
(
    export BOT_SECRETS_FILE="$FIXTURE" HARNESS_CAPTURE="/tmp/botlib-test-cap"
    load_secrets rejected-plates > /dev/null 2>&1
    printf '%s|%s' "$BLUESKY_HANDLE" "$MASTODON_TOKEN"
) > /tmp/botlib-secrets-out 2>/dev/null
check "loads under harness" "{{BLUESKY_HANDLE}}|test-mastodon-token" \
    "$(cat /tmp/botlib-secrets-out)"

( export BOT_SECRETS_FILE="$FIXTURE"; unset HARNESS_CAPTURE
  load_secrets rejected-plates ) > /dev/null 2>&1
check "refuses loose permissions outside harness" "1" "$?"

# The permission check has to work with both stat dialects. On Linux
# `stat -f` is valid but means "filesystem info", so a BSD-first fallback
# succeeds with output that is not a mode -- which broke a real production run
# with "8#: invalid integer constant". Simulate GNU stat to cover that path.
GNUSTAT="$(mktemp -d)"
cat > "$GNUSTAT/stat" <<'STATEOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
    /usr/bin/stat -c '%a' "$3" 2>/dev/null || /usr/bin/stat -f '%Lp' "$3"
    exit $?
fi
if [ "$1" = "-f" ]; then
    printf '  File: "%s"\n    ID: 0 Namelen: 255 Type: ext2/ext3\n' "$3"
    exit 0
fi
exit 1
STATEOF
chmod +x "$GNUSTAT/stat"

SECRETS600="$(mktemp)"
cp "$FIXTURE" "$SECRETS600"
chmod 600 "$SECRETS600"

(
    export PATH="$GNUSTAT:$PATH" BOT_SECRETS_FILE="$SECRETS600"
    unset HARNESS_CAPTURE
    load_secrets rejected-plates > /dev/null 2>&1
    printf '%s' "$MASTODON_SERVER"
) > /tmp/botlib-gnustat-out 2>/dev/null
check "loads a 600 file under GNU stat" "https://mastodon.social" \
    "$(cat /tmp/botlib-gnustat-out)"

rm -rf "$GNUSTAT" "$SECRETS600"

# bsky_await_video builds an optional auth array, and expanding an empty array
# under `set -u` aborts on bash 3.2 -- which is what macOS ships. Several bots
# run with `set -euo pipefail`, so this killed featuring-super-cat's poll
# outright. Exercised in a subshell with -u on and no jwt argument.
(
    set -u
    . "$LIB/core.sh"
    . "$LIB/bluesky.sh"
    # No fixtures here, so the call fails at curl -- the point is that it gets
    # that far rather than dying on an unbound variable
    BSKY_POLL_ATTEMPTS=1 BSKY_POLL_DELAY=0 \
        bsky_await_video "testjob" > /dev/null 2>/tmp/botlib-setu-err
) || true
check "empty auth array survives set -u" "no" \
    "$(grep -q 'unbound variable' /tmp/botlib-setu-err 2>/dev/null && echo yes || echo no)"

echo "pds parsing:"
. "$LIB/bluesky.sh"
SESSION='{"accessJwt":"t","did":"did:plc:x","didDoc":{"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://test.host.bsky.network"}]}}'
check "extracts host" "test.host.bsky.network" "$(bsky_pds_host_from_session "$SESSION")"
check "extracts did" "did:plc:x" "$(bsky_did "$SESSION")"
bsky_pds_host_from_session '{"accessJwt":"t"}' >/dev/null 2>&1
check "fails without didDoc" "1" "$?"

echo "http_request failure detail:"
# Exercises http_request against the real curl shim, which is what gives a
# failed masto_/bsky_ call a status and body to report instead of nothing.
# The shim's <slug>.status file drives the failure path -- see shims/curl.
HTTP_FIXTURES="$(mktemp -d)"
HTTP_CAPTURE="$(mktemp -d)"
mkdir -p "${HTTP_FIXTURES}/_shared"
printf '{"error":"rate limited"}' > "${HTTP_FIXTURES}/_shared/api_v1_statuses.json"
printf '429' > "${HTTP_FIXTURES}/_shared/api_v1_statuses.status"

(
    export PATH="${LIB}/../../shims:$PATH"
    export HARNESS_FIXTURES="$HTTP_FIXTURES" HARNESS_CAPTURE="$HTTP_CAPTURE" HARNESS_BOT="_none"
    . "$LIB/core.sh"
    http_request -X POST "https://mastodon.example/api/v1/statuses" > /tmp/botlib-http-out 2>/dev/null
    printf '%s|%s|%s' "$?" "$BOTLIB_LAST_STATUS" "$BOTLIB_LAST_BODY"
) > /tmp/botlib-http-result

check "reports status and body on a 4xx" "1|429|{\"error\":\"rate limited\"}" \
    "$(cat /tmp/botlib-http-result)"

printf '{"id":"1"}' > "${HTTP_FIXTURES}/_shared/api_v1_statuses.json"
rm -f "${HTTP_FIXTURES}/_shared/api_v1_statuses.status"

(
    export PATH="${LIB}/../../shims:$PATH"
    export HARNESS_FIXTURES="$HTTP_FIXTURES" HARNESS_CAPTURE="$HTTP_CAPTURE" HARNESS_BOT="_none"
    . "$LIB/core.sh"
    out=$(http_request -X POST "https://mastodon.example/api/v1/statuses")
    printf '%s|%s|%s|%s' "$?" "$out" "$BOTLIB_LAST_STATUS" "$BOTLIB_LAST_BODY"
) > /tmp/botlib-http-result

check "prints body and leaves status/body unset on success" '0|{"id":"1"}||' \
    "$(cat /tmp/botlib-http-result)"

rm -rf "$HTTP_FIXTURES" "$HTTP_CAPTURE" /tmp/botlib-http-out /tmp/botlib-http-result

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
