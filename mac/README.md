# Mac side: `hex-mobile-sync.sh`

Exports Hex vocabulary, dictation language and dictation modes to the shared
folder the iPhone app reads, applies vocabulary terms added on the iPhone,
and imports complete queued transfers into the running Hex app.
Runs as a per-user launchd agent. macOS `/bin/bash` 3.2, BSD tools and `jq`
(shipped as `/usr/bin/jq` on recent macOS, otherwise `brew install jq`).

## Files in the sync folder

| File | Written by | Read by |
|---|---|---|
| `hex-mobile-sync.json` | this script | iPhone app |
| `pending-vocabulary.json` | iPhone app | this script |
| `pending-vocabulary.invalid-<UTC timestamp>.json` | this script (invalid pending file moved aside) | you |
| `transfers/<uuid>/manifest.json` | iPhone app or share extension | this script and Hex CLI |
| `transfers/<uuid>/body.txt` and other attachments | iPhone app or share extension | Hex CLI |
| `transfers/<uuid>/receipt.json` | this script after successful import | iPhone app (then removes the shared payload) |

Formats are specified in [`docs/PLAN.md`](../docs/PLAN.md#sync-file-format-hex-mobile-syncjson-written-by-the-mac-script).
Transfer manifests and receipts use schema 1 from [`docs/TRANSFERS-PRD.md`](../docs/TRANSFERS-PRD.md#同步文件夹).

## What a run does

1. Checks `jq` and the `hex` CLI (missing CLI: exit 1, log, one notification per day).
2. Creates the sync folder if missing (only the folder itself, never its parents).
3. Takes a lock in the state folder, so bursts of launchd events do not overlap.
4. Reads through the CLI, all with `--json`: `hex vocabulary list`,
   `hex settings get dictation_processing`, `hex settings get transcription`.
   If the CLI exits 3 (Hex not running) it reads Hex's `settings.json` read-only
   instead and marks the bundle `"via": "settings-file"`.
5. Applies `pending-vocabulary.json` when Hex is running (see below).
6. Builds the bundle from a whitelist of fields: `post_processing` (LLM prompt and
   model) and any unknown key are never exported; the script refuses to write if
   `post_processing` appears anywhere in the result.
7. Writes `hex-mobile-sync.json` atomically (temp file + rename in the same
   folder), only when its content other than `exported_at` changed.
8. Scans `transfers/*/manifest.json` and imports complete queued items (see below).

`app_version` comes from `hex --version`, or from the app's `Info.plist` if that fails.
Terms whose `sounds_like` is `null` in Hex are exported with `[]`.

## Pending vocabulary

For each entry of `pending-vocabulary.json` (`schema_version` 1):

- The term is trimmed; spellings are trimmed, split on commas (the CLI takes a
  comma-separated list) and de-duplicated.
- An entry is **already present** when Hex has the same term and every spelling
  of the entry. Terms and spellings are compared like the iPhone does
  (`TermIdentity`): whitespace runs collapsed, trimmed, case-insensitive with
  Unicode case folding (`PERCHÉ` matches `Perché`). Present entries are dropped
  without calling the CLI.
- If the term exists but some spellings are new, only the missing spellings are
  sent, under Hex's own spelling of the term: `hex vocabulary add --sounds-like="a,b" <term>`
  (the CLI adds spellings to an existing term). The `=` form keeps a spelling
  that starts with `-` from being parsed as an option; a term starting with
  `-` is passed after `--` for the same reason. A new term is sent with all its
  spellings, or without `--sounds-like` when it has none.
- Every successful add is recorded in the run's vocabulary snapshot, so a later
  entry of the same file that is a case variant of it only adds new spellings.
- Applied and present entries are removed from the file; failed entries stay for
  the next run (exit 4, one notification per day). If Hex quits mid-way (exit 3),
  the remaining entries stay. An emptied file is kept as
  `{"entries": [], "schema_version": 1}`, not deleted.
- The file is re-read before it is rewritten. An applied entry is removed only
  if it still has the applied content (same `id`, term and spellings, or an
  identical object when it has no `id`), so entries the iPhone added, or
  spellings it merged into an existing entry, during the run are kept.
- When Hex is not running nothing is applied and the file is left as it is.
- Invalid JSON (or not an object with an `entries` array) is moved aside to
  `pending-vocabulary.invalid-<ts>.json` (exit 4, log, notification).
  A `schema_version` newer than 1 is left untouched (exit 4, log, notification).
- Entries without a usable `term` are dropped with a warning.

## Transfers

After the vocabulary steps, the script skips held items, directories with an
existing receipt, unreadable or iCloud dataless files, incomplete manifests,
and attachments whose local byte count differs from the manifest. It accepts
schema 1 only; missing, newer or invalid schemas are logged once per item per
run and left untouched. Attachment names must be safe filenames and the UUID
must match its directory.

For each complete queued item, while Hex is running, it calls
`hex transfers import --dir <absolute directory> --json`. Only exit 0 with
`imported: true`, or `imported: false` and `reason: "already"`, produces a
receipt. The script writes it through a temporary file and rename in the same
directory, with `schema_version: 1`, `id`, UTC `delivered_at`, and `hex_version`
from `hex --version` (`unknown` if unavailable). It keeps the manifest and
attachments for the iPhone to delete after reading the receipt.

A `held` reply leaves the item without a receipt. Exit 3 stops further imports
for that pass, keeps queued items and logs once. Other failures or unexpected
replies keep the item for retry, log only its UUID and status, and return exit 4
after the pass. Transfer text, attachment bytes and CLI error output are never
logged, including with `--verbose`.

## Usage

```sh
mac/hex-mobile-sync.sh --once --verbose     # one pass, log lines also on stderr
mac/hex-mobile-sync.sh --dry-run --verbose  # read only; prints the bundle to stdout
```

| Flag | Effect |
|---|---|
| `--once` | single pass and exit; this is the default, the flag makes it explicit (used by launchd) |
| `--dry-run` | writes nothing: no bundle, no log, no `vocabulary add`, no pending rewrite or move, no transfer import or receipt, no notification. Prints the bundle to stdout and planned transfer UUIDs to stderr |
| `--verbose` | log lines also on stderr (warnings and errors always are), and vocabulary terms and spellings in the log |
| `--help` | usage, environment and exit codes |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | done: bundle written or already up to date (also when Hex is not running and the fallback worked) |
| 1 | fatal: `jq` or the hex CLI missing, CLI error, unreadable data, write failure. The previous bundle is kept |
| 2 | usage error |
| 3 | Hex not running and the `settings.json` fallback is missing or invalid |
| 4 | done with warnings: invalid or future-schema pending file, pending entries not applied, transfer import or receipt failure |

### Environment

| Variable | Default |
|---|---|
| `HEX_CLI` | `/Applications/Hex.app/Contents/MacOS/hex` |
| `HEX_MOBILE_SYNC_DIR` | `~/Library/Mobile Documents/com~apple~CloudDocs/Hex Mobile` |
| `HEX_SETTINGS_FILE` | `~/Library/Application Support/hex/settings.json` (read only, fallback) |
| `HEX_MOBILE_LOG` | `~/Library/Logs/hex-mobile-sync.log`, rotated to `.1` at 1 MB (the launchd stderr file `<log>.launchd` too) |
| `HEX_MOBILE_STATE_DIR` | `~/Library/Application Support/hex-mobile-sync` (lock, notification stamps) |
| `HEX_MOBILE_NOTIFY_CMD` | `/usr/bin/osascript`; `none` disables notifications |
| `HEX_CLI_TIMEOUT` | `60`: seconds before a hex CLI call is killed |

### CLI reply format

The script reads the CLI's JSON replies only when they carry a supported
`version` (currently `4`, the format of Hex 3.1) and the expected shape: an
`entries` array for `vocabulary list`, a `settings` array containing
`dictation_processing.default_mode` for `settings get dictation_processing`.
Any other reply is refused: exit 1, the previous bundle is kept, one
notification per day. When Hex changes its reply format, update
`SUPPORTED_CLI_REPLY_VERSIONS` in the script after checking the new shape.

### Log privacy

By default the log holds counts and entry numbers (`pending entry #2 added to
Hex`), never vocabulary terms, spellings or CLI output. `--verbose` adds them,
for debugging. Read the log before attaching it to a bug report anyway.
Transfer logs always contain only validated UUIDs and fixed status messages.

## Error handling

| Error | Detection | Response | Fallback | Alert |
|---|---|---|---|---|
| hex CLI missing | executable check | exit 1 | none | log + notification (once a day) |
| Hex not running | CLI exit 3 | read `settings.json` read-only, keep pending | exit 3 if unreadable | log |
| CLI error | non-zero exit | exit 1, previous bundle kept | none | log |
| Unsupported CLI reply | `version` or shape check | exit 1, previous bundle kept | none | log + notification (once a day) |
| CLI hangs | watchdog (`HEX_CLI_TIMEOUT`) | kill the call, exit 1, previous bundle kept | none | log + notification (once a day) |
| State folder not writable | `mkdir`/`-w` check | exit 1 | none | log + notification (stamp in `TMPDIR`) |
| Lock cannot be created | `mkdir` fails and no lock exists | exit 1 | none | log + notification |
| Sync folder missing | `-d` check | create it once | exit 1 if its parent is missing | log |
| Invalid pending JSON | `jq` validation | move aside | none | log + notification |
| `vocabulary add` fails | non-zero exit | keep the entry | retried next run | log + notification, exit 4 |
| Concurrent run | lock directory | exit 0 | stale lock (>10 min) removed | log |

## launchd agent

```sh
mac/install.sh                        # label io.github.hexmobile.sync
mac/install.sh --label org.example.hexsync --sync-dir "/path/to/folder"
mac/install.sh --print                # render the plist to stdout, change nothing
mac/uninstall.sh [--label LABEL] [--purge]
```

`install.sh` copies the script to `~/Library/Application Support/hex-mobile-sync/`,
renders `io.github.hexmobile.sync.plist.template` into
`~/Library/LaunchAgents/<label>.plist` and loads it with
`launchctl bootstrap gui/<uid>`. The agent runs at load, every 900 seconds, and
whenever Hex's `settings.json` or `pending-vocabulary.json` changes (`WatchPaths`).
`uninstall.sh` runs `launchctl bootout` and removes the plist; the sync folder is
never touched, the log and state only with `--purge`.

To verify on a real install: `WatchPaths` on a file inside iCloud Drive fires
only once the file is downloaded locally; the 15-minute interval covers the rest.

## Tests

```sh
tests/mac/test-sync.sh
```

Uses a stub `hex` CLI (`tests/mac/fixtures/hex`) with synthetic data; it never
calls the real Hex, launchd or iCloud Drive.
Transfer checks cover held/queued delivery, receipt idempotency, importer
failures and replies, dry runs, stopped Hex, incomplete and unreadable files,
and simulated iCloud dataless flags. Real iCloud hydration and native-app
delivery still need device verification.
