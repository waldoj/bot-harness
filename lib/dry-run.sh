#!/usr/bin/env bash
#
# Shows what a bot would post, in readable form, without sending anything.
#
#     ./lib/dry-run.sh rejected-plates
#     ./lib/dry-run.sh BOUS --raw     # also dump the full request files
#
# This is the same machinery as verify.sh -- the bot runs against the shims, so
# no traffic leaves the machine -- but the output is the post itself rather
# than a pass/fail. Use it to eyeball text, alt text and media before trusting
# a change; use verify.sh to check nothing regressed.
#
# The bot's own environment still matters. If a bot shells out to something
# that is missing locally (a Python module, ffmpeg), the post will show the
# consequences of that failure rather than what production would send. The
# summary calls out an empty post body or alt text for exactly that reason.

set -uo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOT="${1:?usage: dry-run.sh <bot-name> [--raw]}"
RAW="${2-}"

OUT=$(mktemp -d "${TMPDIR:-/tmp}/dryrun.${BOT}.XXXXXX")
trap 'rm -rf "$OUT"' EXIT

if ! "${HARNESS_ROOT}/lib/run-bot.sh" "$BOT" "$OUT" > /dev/null 2>&1; then
    echo "Could not run $BOT" >&2
    exit 1
fi

EXIT_CODE=$(cat "${OUT}/exit-code.txt" 2>/dev/null || echo "?")

printf '%s would post the following. Nothing was sent.\n\n' "$BOT"

WARNINGS=""

# Walk the captured requests in order, describing the ones a human cares about
for f in "$OUT"/*.request; do
    [ -f "$f" ] || continue

    endpoint=$(grep '^endpoint:' "$f" | cut -d' ' -f2-)
    host=$(grep '^host:' "$f" | cut -d' ' -f2-)

    case "$endpoint" in
        */api/v1/statuses)
            # Mastodon post. The body is recorded as a form for most bots and
            # as a urlencoded body for the few using --data; either way the
            # status line is `  status=`, and a multi-line post continues on
            # the following indented lines until the next unindented key.
            #
            # awk rather than sed: BSD sed needs -E for alternation, and the
            # continuation lines make this a small state machine anyway.
            text=$(awk '
                /^  status=/ { sub(/^  status=/, ""); print; instatus = 1; next }
                # A following indented line continues the post -- unless it is
                # itself another field, such as media_ids[]=
                instatus && /^  / && !/^  [A-Za-z_]+(\[\])?=/ {
                    sub(/^  /, ""); print; next
                }
                instatus { instatus = 0 }
            ' "$f")
            media=$(sed -n 's/^  media_ids\[\]=//p' "$f" | tr '\n' ' ')

            printf 'MASTODON  (%s)\n' "$host"
            if [ -z "$text" ]; then
                # Not flagged: several bots post media with no body on purpose,
                # so an empty status is only suspicious when the alt text is
                # empty too -- which is checked at the upload instead.
                printf '  text:  (empty -- the media is the post)\n'
            else
                # Indent continuation lines under the label, so a multi-line
                # post reads as one block rather than running to the margin
                printf '  text:  %s\n' "$(printf '%s' "$text" | sed '2,$s/^/         /')"
            fi
            [ -n "$media" ] && printf '  media: %s\n' "$media"
            printf '\n'
            ;;

        */api/v[12]/media)
            alt=$(sed -n 's/^  description=//p' "$f")
            printf 'MASTODON MEDIA UPLOAD\n'
            if [ -z "$alt" ]; then
                printf '  alt:   (empty)\n'
                WARNINGS="${WARNINGS}  - Mastodon alt text is empty\n"
            else
                printf '  alt:   %s\n' "$alt"
            fi
            printf '\n'
            ;;

        */api/v1/statuses/*/reblog)
            # dreambot boosts rather than posts, so there is no body to show;
            # the id is the whole of the action
            printf 'MASTODON BOOST  (%s)\n' "$host"
            printf '  status: %s\n\n' \
                "$(printf '%s' "$endpoint" | sed -e 's#.*/statuses/##' -e 's#/reblog##')"
            ;;

        */com.atproto.repo.createRecord)
            printf 'BLUESKY   (%s)\n' "$host"
            body=$(sed -n '/^body:/,$p' "$f" | sed '1d;s/^  //')

            text=$(printf '%s' "$body" | jq -r '.record.text // ""' 2>/dev/null)
            if [ -z "$text" ]; then
                # As with Mastodon: an empty body is deliberate for the
                # media-only bots, so the alt text is what gets checked
                printf '  text:  (empty -- the media is the post)\n'
            else
                printf '  text:  %s\n' "$text"
            fi

            # Alt text lives in a different place per embed type
            alt=$(printf '%s' "$body" \
                | jq -r '(.record.embed.images[0].alt // .record.embed.alt // "")' 2>/dev/null)
            if [ -n "$alt" ]; then
                printf '  alt:   %s\n' "$alt"
            elif [ "$(printf '%s' "$body" | jq -r '.record.embed // "none"' 2>/dev/null)" != "none" ]; then
                printf '  alt:   (empty)\n'
                WARNINGS="${WARNINGS}  - Bluesky alt text is empty\n"
            fi

            embed=$(printf '%s' "$body" | jq -r '.record.embed["$type"] // "none"' 2>/dev/null)
            printf '  embed: %s\n' "$embed"
            printf '  repo:  %s\n' "$(printf '%s' "$body" | jq -r '.repo // "?"' 2>/dev/null)"
            printf '\n'
            ;;
    esac
done

printf 'exit code: %s\n' "$EXIT_CODE"

if [ -n "$WARNINGS" ]; then
    printf '\nWorth a look:\n'
    printf '%b' "$WARNINGS"
    printf '\nAn empty field is usually the local environment rather than the bot:\n'
    printf 'a missing Python module or media tool makes the bot post what it could\n'
    printf 'still assemble. Check the bot on the machine that actually runs it.\n'
fi

if [ "$RAW" = "--raw" ]; then
    printf '\n--- full requests ---\n\n'
    for f in "$OUT"/*.request; do
        [ -f "$f" ] || continue
        printf '=== %s ===\n' "$(basename "$f")"
        cat "$f"
        printf '\n'
    done
fi
