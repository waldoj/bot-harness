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

echo "pds parsing:"
. "$LIB/bluesky.sh"
SESSION='{"accessJwt":"t","did":"did:plc:x","didDoc":{"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://test.host.bsky.network"}]}}'
check "extracts host" "test.host.bsky.network" "$(bsky_pds_host_from_session "$SESSION")"
check "extracts did" "did:plc:x" "$(bsky_did "$SESSION")"
bsky_pds_host_from_session '{"accessJwt":"t"}' >/dev/null 2>&1
check "fails without didDoc" "1" "$?"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
