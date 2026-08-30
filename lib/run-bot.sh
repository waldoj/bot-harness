#!/usr/bin/env bash
#
# Runs one bot against the shims and records the requests it would have sent.
#
# The bot is copied into a throwaway sandbox first. Every bot begins with
# `cd "$(dirname "$0")"`, so running one in place would let it write history
# files, download media and mutate state inside the real repo. Nothing here
# touches ~/Documents/Git/<bot> after the initial copy.

set -uo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="${BOT_REPO_ROOT:-$HOME/Documents/Git}"

BOT="${1:?usage: run-bot.sh <bot-name> [output-dir]}"
OUT_DIR="${2:-${HARNESS_ROOT}/goldens/${BOT}}"

# Locate the bot's entry point: most are post.sh, two are not
SRC="${REPO_ROOT}/${BOT}"
[ -d "$SRC" ] || { echo "No such bot repo: $SRC" >&2; exit 1; }

ENTRY=""
for candidate in post.sh bot.sh mastobot.sh; do
    [ -f "${SRC}/${candidate}" ] && ENTRY="$candidate" && break
done
[ -n "$ENTRY" ] || { echo "No entry script found in $SRC" >&2; exit 1; }

# Sandbox: copy the bot somewhere disposable, excluding the git metadata and
# any large media that the shims will supply instead.
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/botharness.${BOT}.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT
rsync -a --exclude '.git' --exclude '*.mp4' --exclude '*.m4v' \
      --exclude '*.mp3' --exclude '*.wav' --exclude 'clips/' \
      "${SRC}/" "${SANDBOX}/" 2>/dev/null || cp -R "${SRC}/." "${SANDBOX}/"

# Seed any per-bot state the fixtures provide (files.txt, history.txt, config)
STATE="${HARNESS_ROOT}/fixtures/${BOT}/state"
[ -d "$STATE" ] && cp -R "${STATE}/." "${SANDBOX}/"

# Inject test credentials, so the sandboxed copy never needs the real ones.
# Placeholder-style values are replaced too, so a bot whose committed copy has
# {{MASTODON_TOKEN}} still runs.
CONF="${HARNESS_ROOT}/fixtures/${BOT}/config.env"
[ -f "$CONF" ] && . "$CONF"
sed -i.bak \
    -e 's|^MASTODON_TOKEN=.*|MASTODON_TOKEN="test-mastodon-token"|' \
    -e 's|^MASTODON_SERVER=.*|MASTODON_SERVER="https://mastodon.social"|' \
    -e 's|^BLUESKY_APP_PASSWORD=.*|BLUESKY_APP_PASSWORD="test-app-password"|' \
    -e 's|^BLUESKY_PASSWORD=.*|BLUESKY_PASSWORD="test-app-password"|' \
    "${SANDBOX}/${ENTRY}" && rm -f "${SANDBOX}/${ENTRY}.bak"

# Fresh capture directory
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

export HARNESS_CAPTURE="$OUT_DIR"
export HARNESS_FIXTURES="${HARNESS_ROOT}/fixtures"
export HARNESS_BOT="$BOT"
export HARNESS_FROZEN_TIME="${HARNESS_FROZEN_TIME:-2026-01-15T12:00:00Z}"

# Shims first on PATH. They are real files, so `command -v` preflight checks
# in the bots still succeed.
export PATH="${HARNESS_ROOT}/shims:${PATH}"

# Pin the locale the way BOUS does, so character counting matches production
if locale -a 2>/dev/null | grep -qxi 'C\.UTF-*8'; then
    export LC_ALL="C.UTF-8"
else
    export LC_ALL="en_US.UTF-8"
fi

# Run the bot, capturing its own output alongside the requests
(
    cd "$SANDBOX" || exit 1
    bash "./${ENTRY}"
) > "${OUT_DIR}/stdout.txt" 2> "${OUT_DIR}/stderr.txt"
BOT_EXIT=$?

printf '%s\n' "$BOT_EXIT" > "${OUT_DIR}/exit-code.txt"
rm -f "${OUT_DIR}/.seq"

REQ_COUNT=$(ls "${OUT_DIR}"/*.request 2>/dev/null | wc -l | tr -d ' ')
printf '%-22s exit=%-3s requests=%-3s' "$BOT" "$BOT_EXIT" "$REQ_COUNT"
if grep -q '^HARNESS: no fixture' "${OUT_DIR}/stderr.txt" 2>/dev/null; then
    MISSING=$(grep -c '^HARNESS: no fixture' "${OUT_DIR}/stderr.txt")
    printf '  [%s unmatched endpoint(s)]' "$MISSING"
fi
printf '\n'
exit 0
