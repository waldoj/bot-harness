# bot-harness

Test harness for the bots. Records what each bot *would* send to Bluesky and
Mastodon, without sending anything, so that refactoring them is verifiable
rather than hopeful.

## Why

The bots post 1–5 times daily to live accounts and had no tests. Extracting
their shared logic into a common library means editing nine working programs at
once. This harness captures each bot's current network behaviour as a set of
golden files; after a bot is rewritten, its requests must still match.

## How it works

Each bot is run in a disposable sandbox with a set of shims early on `PATH`:

| Shim | Replaces | Why |
|---|---|---|
| `curl` | all network I/O | records the request, returns a canned response |
| `aws`  | S3 access | serves a fixture listing and local sample media |
| `date` | the clock | freezes `createdAt` so goldens are byte-stable |
| `shuf`/`gshuf` | random selection | returns the first line instead |
| `sort` | `sort -R` only | strips the random flag; ordinary sorts pass through |

The shims are real executables rather than shell functions, because several
bots preflight their dependencies with `command -v`, which a function would not
satisfy.

**The bots are not modified.** They call `curl` exactly as in production. The
only substitution is what `curl` resolves to on `PATH`, so the code under test
is the code that runs live.

Bots are copied to a temp dir before running, because each one begins with
`cd "$(dirname "$0")"` and would otherwise write history files and download
media into the real repo.

## Usage

    ./lib/capture.sh                 # baseline every bot
    ./lib/capture.sh BOUS            # baseline one bot
    ./lib/verify-all.sh              # check every bot against its goldens
    ./lib/verify.sh BOUS             # check one bot
    ./tests/test-shims.sh            # test the harness itself

`verify` exits non-zero and prints a diff when a request changes.

## What the goldens cover

39 requests across nine bots: session creation, blob and media upload,
processing-job polling, and the final post record for each service. The
assertions that matter most are in the post payloads — `text`, `alt`,
`aspectRatio`, `mimeType`, blob refs, `createdAt` format, and Mastodon's
multipart form fields.

Credentials are redacted at capture time, so goldens are safe to commit.

## Adding a fixture

If a bot calls an endpoint with no fixture, the shim says so on stderr and
names the file to create. Responses are matched most-specific-first:

    fixtures/<bot>/<endpoint-slug>.<seq>.json   # a single call
    fixtures/<bot>/<endpoint-slug>.json         # that bot
    fixtures/_shared/<endpoint-slug>.json       # all bots

A sibling `<slug>.status` file containing an HTTP status drives failure-path
tests (401, 429, 500).

Per-bot input state — `files.txt`, `history.txt`, sqlite databases — lives in
`fixtures/<bot>/state/` and is copied into the sandbox before each run.

## Limitations

Golden tests prove a request is well-formed and unchanged. They cannot prove
Bluesky or Mastodon still *accepts* it — an upstream API change passes these
tests and fails in production. That is what the failure notifications in the
shared library are for; the two are complementary.
