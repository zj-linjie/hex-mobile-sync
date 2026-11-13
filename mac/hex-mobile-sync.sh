#!/bin/bash
#
# hex-mobile-sync.sh: export Hex vocabulary and text rules to a shared folder
# for the Hex Mobile iPhone app, apply vocabulary terms added on the iPhone,
# and import queued transfers through the Hex CLI.
#
# Compatible with macOS /bin/bash 3.2 and BSD userland. Requires jq.
#
# Usage: hex-mobile-sync.sh [--once] [--dry-run] [--verbose] [--help]
#
# Exit codes:
#   0  done (bundle written or already up to date)
#   1  fatal error: hex CLI or jq missing, CLI error, unreadable data, write failure
#   2  usage error
#   3  Hex is not running and the read-only settings.json fallback is unreadable
#   4  done with warnings: invalid pending file moved aside, unsupported pending
#      schema, pending entries not applied, or transfer import/receipt failures
#
# Environment overrides (see mac/README.md):
#   HEX_CLI               path to the hex CLI
#   HEX_MOBILE_SYNC_DIR   sync folder (default: iCloud Drive/Hex Mobile)
#   HEX_SETTINGS_FILE     Hex settings.json, read only when Hex is not running
#   HEX_MOBILE_LOG        log file (rotated at 1 MB)
#   HEX_MOBILE_STATE_DIR  lock and notification state
#   HEX_MOBILE_NOTIFY_CMD notification command (default: osascript); "none" disables
#   HEX_CLI_TIMEOUT       seconds before a hex CLI call is killed (default 60)

set -euo pipefail

readonly PROG="hex-mobile-sync"
readonly SCHEMA_VERSION=1
readonly LOG_MAX_BYTES=1048576
# Versions of the hex CLI JSON reply format this script understands. A reply
# with another version is refused (the previous bundle is kept) instead of
# being read with guessed keys.
readonly SUPPORTED_CLI_REPLY_VERSIONS="[4]"

HEX_CLI="${HEX_CLI:-/Applications/Hex.app/Contents/MacOS/hex}"
HEX_MOBILE_SYNC_DIR="${HEX_MOBILE_SYNC_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Hex Mobile}"
HEX_SETTINGS_FILE="${HEX_SETTINGS_FILE:-$HOME/Library/Application Support/hex/settings.json}"
HEX_MOBILE_LOG="${HEX_MOBILE_LOG:-$HOME/Library/Logs/hex-mobile-sync.log}"
HEX_MOBILE_STATE_DIR="${HEX_MOBILE_STATE_DIR:-$HOME/Library/Application Support/hex-mobile-sync}"
HEX_MOBILE_NOTIFY_CMD="${HEX_MOBILE_NOTIFY_CMD:-/usr/bin/osascript}"
HEX_CLI_TIMEOUT="${HEX_CLI_TIMEOUT:-60}"
case "$HEX_CLI_TIMEOUT" in '' | *[!0-9]* | 0) HEX_CLI_TIMEOUT=60 ;; esac

readonly BUNDLE_NAME="hex-mobile-sync.json"
readonly PENDING_NAME="pending-vocabulary.json"

DRY_RUN=0
VERBOSE=0
WARNINGS=0
TMP_DIR=""
LOCK_DIR=""

usage() {
    cat <<'EOF'
Usage: hex-mobile-sync.sh [--once] [--dry-run] [--verbose] [--help]

Exports Hex vocabulary, language and dictation modes (without post_processing)
to hex-mobile-sync.json in the sync folder, and applies pending-vocabulary.json
written by the iPhone app through `hex vocabulary add` when Hex is running.
Imports complete queued transfers through `hex transfers import`, then writes
an atomic receipt for the iPhone to read before it deletes the shared payload.

Options:
  --once      Run a single sync pass and exit. This is the default; the flag
              exists so launchd and manual invocations can be explicit.
  --dry-run   Read everything, write nothing: no bundle, no `vocabulary add`,
              no pending rewrite, no transfer import or receipt, no notification.
              Prints the bundle to stdout and planned transfers to stderr.
  --verbose   Also print log lines to stderr.
  --help      Show this help.

Environment:
  HEX_CLI               hex CLI (default /Applications/Hex.app/Contents/MacOS/hex)
  HEX_MOBILE_SYNC_DIR   sync folder (default iCloud Drive/Hex Mobile)
  HEX_SETTINGS_FILE     Hex settings.json, read-only fallback when Hex is not running
  HEX_MOBILE_LOG        log file (default ~/Library/Logs/hex-mobile-sync.log)
  HEX_MOBILE_STATE_DIR  lock and notification state
                        (default ~/Library/Application Support/hex-mobile-sync)
  HEX_MOBILE_NOTIFY_CMD notification command (default /usr/bin/osascript, "none" = off)
  HEX_CLI_TIMEOUT       seconds before a hex CLI call is killed (default 60)

Privacy: the log holds counts and entry numbers, never vocabulary terms or
spellings, unless --verbose is given.

Exit codes:
  0  done (bundle written or already up to date)
  1  fatal error (CLI or jq missing, CLI error, unreadable data, write failure)
  2  usage error
  3  Hex not running and the settings.json fallback is unreadable
  4  done with warnings (invalid or unsupported pending file, entries not applied,
     transfer import or receipt failure)
EOF
}

# ---------------------------------------------------------------- logging

# Rotates the main log and the launchd stderr log (<log>.launchd, where WARN
# and ERROR lines are echoed when the job runs under launchd) at 1 MB.
rotate_log() {
    local file size
    for file in "$HEX_MOBILE_LOG" "$HEX_MOBILE_LOG.launchd"; do
        [ -f "$file" ] || continue
        size=$(stat -f %z "$file" 2>/dev/null || echo 0)
        if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
            mv -f "$file" "$file.1" 2>/dev/null || true
        fi
    done
}

log() {
    local level="$1"
    shift
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [$level] $*"
    if [ "$VERBOSE" -eq 1 ] || [ "$level" = "ERROR" ] || [ "$level" = "WARN" ]; then
        printf '%s\n' "$line" >&2
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    # Logging must never abort a sync: report a broken log path once on stderr.
    if ! printf '%s\n' "$line" >>"$HEX_MOBILE_LOG" 2>/dev/null; then
        printf '%s: cannot write log %s\n' "$PROG" "$HEX_MOBILE_LOG" >&2
    fi
}

info() { log INFO "$@"; }
warn() { WARNINGS=1; log WARN "$@"; }
error() { log ERROR "$@"; }
# Details that may contain vocabulary terms: only logged with --verbose.
detail() { [ "$VERBOSE" -eq 1 ] && log INFO "$@"; return 0; }

# notify KEY MESSAGE: macOS notification, at most once per KEY per local day.
# The per-day stamp lives in the state directory, or in TMPDIR when the state
# directory is not writable (so that failure is not notified on every run).
notify() {
    local key="$1" message="$2" stamp today
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ "$HEX_MOBILE_NOTIFY_CMD" = "none" ] && return 0
    today=$(date +%Y-%m-%d)
    if [ -d "$HEX_MOBILE_STATE_DIR" ] && [ -w "$HEX_MOBILE_STATE_DIR" ]; then
        stamp="$HEX_MOBILE_STATE_DIR/notified-$key"
    else
        stamp="${TMPDIR:-/tmp}/hex-mobile-sync-$(id -u)-notified-$key"
    fi
    if [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null || true)" = "$today" ]; then
        log INFO "notification '$key' already shown today"
        return 0
    fi
    # AppleScript string literal: escape backslashes and double quotes.
    local escaped
    escaped=$(printf '%s' "$message" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    if "$HEX_MOBILE_NOTIFY_CMD" -e "display notification \"$escaped\" with title \"Hex Mobile Sync\"" >/dev/null 2>&1; then
        printf '%s\n' "$today" >"$stamp" 2>/dev/null || true
    else
        log WARN "notification command failed: $HEX_MOBILE_NOTIFY_CMD"
    fi
}

die() {
    local code="$1"
    shift
    error "$*"
    exit "$code"
}

# shellcheck disable=SC2329  # invoked through trap
cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------- helpers

# Atomic write: SRC_TMP is moved over DEST (same directory, so mv is a rename).
atomic_replace() {
    local src="$1" dest="$2" tmp
    tmp="$(dirname "$dest")/.$(basename "$dest").tmp.$$"
    cp "$src" "$tmp" && mv -f "$tmp" "$dest"
}

# hex_cli ARGS...: the hex CLI under a watchdog. A call still running after
# HEX_CLI_TIMEOUT seconds is killed by SIGALRM (exit status 142). perl ships
# with macOS; `alarm` survives `exec`, so the CLI itself is what gets killed.
hex_cli() {
    /usr/bin/perl -e 'my $t = shift @ARGV; alarm $t; exec { $ARGV[0] } @ARGV or exit 127' \
        "$HEX_CLI_TIMEOUT" "$HEX_CLI" "$@"
}

# run_cli OUTFILE ARGS...: run the hex CLI, stdout to OUTFILE, stderr to OUTFILE.err.
# Returns the CLI exit code without tripping set -e. A timeout is logged,
# notified once a day and returned as 1, so the previous bundle is kept.
run_cli() {
    local out="$1" rc=0
    shift
    hex_cli "$@" >"$out" 2>"$out.err" || rc=$?
    if [ "$rc" -eq 142 ]; then
        error "hex $1 $2 timed out after ${HEX_CLI_TIMEOUT}s"
        notify cli-timeout "The Hex CLI did not answer within ${HEX_CLI_TIMEOUT} seconds. Is Hex responding?"
        return 1
    fi
    return "$rc"
}

# check_reply FILE STATUS [SETTING_KEY]: the CLI reply is a JSON object with
# the expected status, a supported reply version and the expected shape:
# an `entries` array for vocabulary, a `settings` array (containing
# SETTING_KEY when given) for settings.
check_reply() {
    jq -e --arg s "$2" --arg k "${3:-}" --argjson versions "$SUPPORTED_CLI_REPLY_VERSIONS" '
        type == "object" and .status == $s
        and (.version as $v | any($versions[]; . == $v))
        and (if $s == "vocabulary" then (.entries | type) == "array"
             elif $s == "settings" then (.settings | type) == "array"
                 and ($k == "" or any(.settings[]; type == "object" and .key == $k))
             else true end)' "$1" >/dev/null 2>&1
}

# reply_problem FILE: short description of an unexpected reply for the log.
reply_problem() {
    jq -r '"status \(.status // "none" | tostring), version \(.version // "none" | tostring)"' "$1" 2>/dev/null ||
        printf 'not JSON'
}

# unexpected_reply WHAT FILE RC: log and notify (once a day) a CLI failure or
# an unsupported reply format.
unexpected_reply() {
    local what="$1" file="$2" rc="$3"
    if [ "$rc" -ne 0 ]; then
        error "hex $what failed (exit $rc): $(head -c 300 "$file.err" 2>/dev/null || true)"
    else
        error "hex $what returned an unsupported reply ($(reply_problem "$file")); keeping the previous bundle"
        notify cli-reply "Unsupported reply from the Hex CLI. Update hex-mobile-sync; the iPhone keeps the last synced rules."
    fi
}

hex_app_version() {
    local v="" plist
    v=$(hex_cli --version 2>/dev/null | awk 'NR == 1 { print $2 }') || v=""
    if [ -z "$v" ]; then
        plist="${HEX_CLI%/MacOS/*}/Info.plist"
        if [ -f "$plist" ]; then
            v=$(plutil -extract CFBundleShortVersionString raw "$plist" 2>/dev/null || true)
        fi
    fi
    printf '%s' "$v"
}

# ---------------------------------------------------------------- export

# The jq filter that builds the bundle from normalized inputs. Whitelists fields,
# so post_processing (LLM prompt and model) and unknown keys never leave the Mac.
# shellcheck disable=SC2016
readonly BUNDLE_FILTER='
def strs: if type == "array" then map(select(type == "string")) else [] end;
def repls: if type == "array"
    then map(select(type == "object" and (.matched_phrase | type) == "string")
             | {matched_phrase, output: (.output // "" | tostring)})
    else [] end;
def mode: {
    name: (.name // "" | tostring),
    applications: (.applications | strs),
    browser_hosts: (.browser_hosts | strs),
    replacements: (.replacements | repls),
    transformations: (.transformations | strs)
};
{
    schema_version: $schema,
    exported_at: $now,
    source: { app: "Hex", app_version: (if $app_version == "" then null else $app_version end), via: $via },
    language: (if ($language | type) == "string" and $language != "" then $language else null end),
    vocabulary: ($vocab
        | if type == "array" then . else [] end
        | map(select(type == "object" and (.term | type) == "string" and .term != "")
              | {term, sounds_like: (.sounds_like | strs)})),
    default_mode: (($default_mode // {name: "Global"}) | mode | del(.applications, .browser_hosts)),
    modes: ($modes | if type == "array" then map(select(type == "object") | mode) else [] end)
}'

# export_via_cli DIR: writes vocab.json, default_mode.json, modes.json, language.json.
# Returns 0, 3 (Hex not running) or 1 (CLI error).
export_via_cli() {
    local d="$1" rc=0
    # Called as `export_via_cli … || rc=$?`, so set -e is off in here: every
    # step that can fail returns explicitly.
    run_cli "$d/vocab.raw" vocabulary list --json || rc=$?
    [ "$rc" -eq 3 ] && return 3
    if [ "$rc" -ne 0 ] || ! check_reply "$d/vocab.raw" vocabulary; then
        unexpected_reply "vocabulary list --json" "$d/vocab.raw" "$rc"
        return 1
    fi
    jq '.entries' "$d/vocab.raw" >"$d/vocab.json" || return 1

    rc=0
    run_cli "$d/dp.raw" settings get dictation_processing --json || rc=$?
    [ "$rc" -eq 3 ] && return 3
    if [ "$rc" -ne 0 ] || ! check_reply "$d/dp.raw" settings dictation_processing.default_mode; then
        unexpected_reply "settings get dictation_processing --json" "$d/dp.raw" "$rc"
        return 1
    fi
    jq '[.settings[] | select(.key == "dictation_processing.default_mode") | .value] | first // null' "$d/dp.raw" >"$d/default_mode.json" || return 1
    jq '[.settings[] | select(.key == "dictation_processing.modes") | .value] | first // []' "$d/dp.raw" >"$d/modes.json" || return 1

    # Language is optional: an older Hex without the key still exports.
    rc=0
    run_cli "$d/tr.raw" settings get transcription --json || rc=$?
    [ "$rc" -eq 3 ] && return 3
    if [ "$rc" -eq 0 ] && check_reply "$d/tr.raw" settings transcription.language; then
        jq '[.settings[] | select(.key == "transcription.language") | .value] | first // null' "$d/tr.raw" >"$d/language.json" || return 1
    else
        info "transcription language not available from the CLI (exit $rc); exporting language null"
        printf 'null\n' >"$d/language.json"
    fi
    return 0
}

# export_via_settings_file DIR: read-only fallback when Hex is not running.
export_via_settings_file() {
    local d="$1"
    if [ ! -r "$HEX_SETTINGS_FILE" ]; then
        error "Hex is not running and $HEX_SETTINGS_FILE is not readable"
        return 3
    fi
    if ! jq -e 'type == "object"' "$HEX_SETTINGS_FILE" >/dev/null 2>&1; then
        error "Hex is not running and $HEX_SETTINGS_FILE is not valid JSON"
        return 3
    fi
    jq '.vocabulary // []' "$HEX_SETTINGS_FILE" >"$d/vocab.json"
    jq '.dictation_processing.default_mode // null' "$HEX_SETTINGS_FILE" >"$d/default_mode.json"
    jq '.dictation_processing.modes // []' "$HEX_SETTINGS_FILE" >"$d/modes.json"
    jq '.transcription.language // null' "$HEX_SETTINGS_FILE" >"$d/language.json"
    return 0
}

build_bundle() {
    local d="$1" via="$2" out="$3"
    jq -n -S \
        --argjson schema "$SCHEMA_VERSION" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg app_version "$(hex_app_version)" \
        --arg via "$via" \
        --slurpfile vocab_in "$d/vocab.json" \
        --slurpfile dm_in "$d/default_mode.json" \
        --slurpfile modes_in "$d/modes.json" \
        --slurpfile lang_in "$d/language.json" \
        "\$vocab_in[0] as \$vocab | \$dm_in[0] as \$default_mode | \$modes_in[0] as \$modes | \$lang_in[0] as \$language | $BUNDLE_FILTER" \
        >"$out"
}

# ---------------------------------------------------------------- pending vocabulary

# Term identity shared with the iPhone (TermIdentity in HexMobileCore):
# whitespace runs collapsed to one space, trimmed, compared case-insensitively
# with Unicode case folding (Oniguruma "i" on an escaped literal). The length
# check keeps one-to-many folds such as "ß"/"ss" apart, as Swift's lowercased() does.
# shellcheck disable=SC2016
readonly JQ_IDENTITY='
def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
def squash: gsub("\\s+"; " ") | trim;
def rx: gsub("(?<c>[.*+?^${}()|\\[\\]\\\\/-])"; "\\\(.c)");
def same($a; $b): ($a | tostring | squash) as $x | ($b | tostring | squash) as $y
    | ($x | length) == ($y | length) and ($y | test("^" + ($x | rx) + "$"; "i"));
'

# Normalized view of a pending entry: trimmed term, spellings split on commas
# (the CLI takes a comma-separated list), trimmed, non-empty, de-duplicated.
# shellcheck disable=SC2016
readonly PENDING_NORMALIZE="$JQ_IDENTITY"'
{
    id: (.id // null),
    term: (.term | squash),
    sounds_like: ((.sounds_like // [])
        | if type == "array" then . else [] end
        | map(select(type == "string") | split(",")[] | squash | select(. != ""))
        | reduce .[] as $s ([]; if any(.[]; same(.; $s)) then . else . + [$s] end))
}'

# Spellings of ENTRY missing from the current vocabulary for the same term.
# Output: {"present": bool, "hex_term": <Hex spelling of the term or null>, "missing": [..]}
# shellcheck disable=SC2016
readonly PENDING_DIFF="$JQ_IDENTITY"'
($vocab | map(select(type == "object" and same(.term // ""; $e.term)))) as $hits
| ($hits | map(.sounds_like // [] | .[] | select(type == "string"))) as $known
| { present: ($hits | length > 0),
    hex_term: ($hits[0].term // null),
    missing: [ $e.sounds_like[] | . as $s | select(($known | any(.[]; same(.; $s))) | not) ] }'

# After a successful add: record TERM and its new spellings in vocab.json, so
# later entries of the same run (for example a case variant) see them.
# shellcheck disable=SC2016
readonly VOCAB_RECORD_ADD="$JQ_IDENTITY"'
($spellings | split(",") | map(select(. != ""))) as $new
| if any(.[]; type == "object" and same(.term // ""; $t))
  then map(if type == "object" and same(.term // ""; $t) then .sounds_like = ((.sounds_like // []) + $new) else . end)
  else . + [{term: $t, sounds_like: $new}] end'

# apply_pending DIR HEX_RUNNING
apply_pending() {
    local d="$1" running="$2"
    local pending="$HEX_MOBILE_SYNC_DIR/$PENDING_NAME"
    [ -f "$pending" ] || { info "no pending vocabulary"; return 0; }

    if ! jq -e 'type == "object" and ((.entries // []) | type == "array")' "$pending" >/dev/null 2>&1; then
        local aside
        aside="$HEX_MOBILE_SYNC_DIR/pending-vocabulary.invalid-$(date -u +%Y%m%dT%H%M%SZ).json"
        warn "invalid pending vocabulary JSON: moving it to $(basename "$aside")"
        if [ "$DRY_RUN" -eq 0 ]; then
            mv -f "$pending" "$aside" || { error "cannot move $pending aside"; return 1; }
            notify invalid-pending "Invalid pending-vocabulary.json moved aside as $(basename "$aside")."
        fi
        return 0
    fi

    local schema
    schema=$(jq -r '.schema_version // 1' "$pending")
    case "$schema" in
        '' | *[!0-9]*) schema=999 ;;
    esac
    if [ "$schema" -gt "$SCHEMA_VERSION" ]; then
        warn "pending vocabulary schema_version $schema is newer than supported ($SCHEMA_VERSION); left untouched"
        notify unsupported-pending "pending-vocabulary.json uses a newer format. Update hex-mobile-sync."
        return 0
    fi

    local total
    total=$(jq '(.entries // []) | length' "$pending")
    if [ "$total" -eq 0 ]; then
        info "pending vocabulary is empty"
        return 0
    fi
    if [ "$running" -ne 1 ]; then
        info "Hex is not running: $total pending vocabulary entries kept for the next run"
        return 0
    fi

    # Work on a snapshot; applied.json collects the indexes (into .entries) that are done.
    cp "$pending" "$d/pending.snapshot" || { error "cannot read $pending"; return 1; }
    printf '[]\n' >"$d/applied.json"
    local i=0 entry norm diff present missing term rc failed=0 stopped=0
    while [ "$i" -lt "$total" ]; do
        entry=$(jq -c --argjson i "$i" '.entries[$i]' "$d/pending.snapshot")
        if ! printf '%s' "$entry" | jq -e 'type == "object" and (.term | type) == "string" and (.term | test("\\S"))' >/dev/null 2>&1; then
            warn "pending entry #$i has no term: dropped"
            jq --argjson i "$i" '. + [$i]' "$d/applied.json" >"$d/applied.next" && mv -f "$d/applied.next" "$d/applied.json"
            i=$((i + 1))
            continue
        fi
        norm=$(printf '%s' "$entry" | jq -c "$PENDING_NORMALIZE")
        diff=$(jq -c -n --argjson e "$norm" --slurpfile v "$d/vocab.json" "\$v[0] as \$vocab | $PENDING_DIFF")
        present=$(printf '%s' "$diff" | jq -r '.present')
        missing=$(printf '%s' "$diff" | jq -r '.missing | join(",")')
        # Reuse Hex's own spelling of an existing term, so adding spellings
        # never creates a case variant of it.
        term=$(printf '%s' "$diff" | jq -r --arg t "$(printf '%s' "$norm" | jq -r '.term')" '.hex_term // $t')

        if [ "$present" = "true" ] && [ -z "$missing" ]; then
            info "pending entry #$i already present in Hex: dropped"
            detail "pending entry #$i is '$term'"
        elif [ "$DRY_RUN" -eq 1 ]; then
            # Dry runs are interactive and write no log file.
            if [ -n "$missing" ]; then
                info "dry run: would add '$term' with sounds-like '$missing'"
            else
                info "dry run: would add '$term'"
            fi
            i=$((i + 1))
            continue
        else
            rc=0
            # Documented form: hex vocabulary add <term> --sounds-like "a,b".
            # The spellings use the --sounds-like=VALUE form, so a value
            # starting with "-" is not read as an option; a term starting with
            # "-" goes after "--" for the same reason.
            set -- "$term"
            case "$term" in -*) set -- -- "$term" ;; esac
            if [ -n "$missing" ]; then
                run_cli "$d/add.out" vocabulary add "--sounds-like=$missing" "$@" || rc=$?
            else
                run_cli "$d/add.out" vocabulary add "$@" || rc=$?
            fi
            if [ "$rc" -eq 3 ]; then
                info "Hex stopped while applying pending vocabulary: remaining entries kept"
                stopped=1
                break
            elif [ "$rc" -ne 0 ]; then
                warn "hex vocabulary add failed for pending entry #$i (exit $rc)"
                detail "pending entry #$i is '$term'; CLI said: $(head -c 300 "$d/add.out.err" 2>/dev/null || true)"
                failed=$((failed + 1))
                i=$((i + 1))
                continue
            fi
            info "pending entry #$i added to Hex${missing:+ with new spellings}"
            detail "pending entry #$i is '$term'${missing:+ (sounds like: $missing)}"
            if ! jq --arg t "$term" --arg spellings "$missing" "$VOCAB_RECORD_ADD" "$d/vocab.json" >"$d/vocab.next" ||
                ! mv -f "$d/vocab.next" "$d/vocab.json"; then
                error "cannot update the vocabulary snapshot"
                return 1
            fi
        fi
        jq --argjson i "$i" '. + [$i]' "$d/applied.json" >"$d/applied.next" && mv -f "$d/applied.next" "$d/applied.json"
        i=$((i + 1))
    done

    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    if [ "$(jq 'length' "$d/applied.json")" -gt 0 ]; then
        rewrite_pending "$d" "$pending" || return 1
    fi
    if [ "$failed" -gt 0 ]; then
        notify apply-failed "$failed pending vocabulary term(s) could not be added to Hex. See the log."
    fi
    [ "$stopped" -eq 1 ] && info "pending vocabulary apply interrupted"
    return 0
}

# Remove applied entries. The iPhone may have appended entries, or merged new
# spellings into an existing entry (same id), while we were working, so
# re-read the file and drop an entry only when it still has the content that
# was applied: same id with the same term and spellings, or the exact original
# object. A changed entry stays for the next run.
rewrite_pending() {
    local d="$1" pending="$2"
    if ! jq -e 'type == "object" and ((.entries // []) | type == "array")' "$pending" >/dev/null 2>&1; then
        warn "pending file changed to invalid JSON during apply; left for the next run"
        return 0
    fi
    # Snapshot of the applied entries, taken from the copy read before applying.
    jq -c --slurpfile idx "$d/applied.json" '[(.entries // []) as $e | $idx[0][] | $e[.]]' \
        "$d/pending.snapshot" >"$d/applied.entries" || { error "cannot list applied entries"; return 1; }
    jq -S --slurpfile applied "$d/applied.entries" '
        ($applied[0]) as $done
        | .schema_version = (.schema_version // 1)
        | .entries = [ (.entries // [])[]
            | . as $x
            | select(($done | any(.[];
                (.id != null and .id == $x.id and .term == $x.term
                    and (.sounds_like // []) == ($x.sounds_like // []))
                or . == $x)) | not) ]' \
        "$pending" >"$d/pending.next" || { error "cannot compute remaining pending entries"; return 1; }
    atomic_replace "$d/pending.next" "$pending" || { error "cannot rewrite $pending"; return 1; }
    info "pending vocabulary: $(jq 'length' "$d/applied.entries") applied, $(jq '.entries | length' "$d/pending.next") remaining"
}

# ---------------------------------------------------------------- transfers

# Check metadata before reading: opening an iCloud dataless file may download
# it. A readable placeholder's advertised size alone is not proof of delivery.
transfer_file_ready() {
    local flags
    [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ] || return 1
    flags=$(stat -f %Sf "$1" 2>/dev/null) || return 1
    case "$flags" in *dataless* | *offline*) return 1 ;; esac
    return 0
}

transfer_attachments_ready() {
    local manifest="$1" dir="$2" name bytes size
    # NUL-delimited fields preserve spaces, tabs and newlines in filenames.
    while IFS= read -r -d '' name && IFS= read -r -d '' bytes; do
        transfer_file_ready "$dir/$name" || return 1
        size=$(stat -f %z "$dir/$name" 2>/dev/null) || return 1
        [ "$size" = "$bytes" ] || return 1
    done < <(jq -j '.attachments[] | .name, "\u0000", (.bytes | tostring), "\u0000"' "$manifest")
    return 0
}

import_transfers() {
    local d="$1" running="$2" manifest dir id status rc version="" receipt_tmp
    local stopped_logged=0
    for manifest in "$HEX_MOBILE_SYNC_DIR"/transfers/*/manifest.json; do
        dir=${manifest%/manifest.json}
        [ -d "$dir" ] && [ ! -L "$dir" ] || continue
        [ ! -e "$dir/receipt.json" ] && [ ! -L "$dir/receipt.json" ] || continue
        transfer_file_ready "$manifest" || continue
        # Snapshot so validation and attachment enumeration use the same data.
        cp "$manifest" "$d/transfer.manifest" 2>/dev/null || continue
        if ! jq -e 'type == "object"' "$d/transfer.manifest" >/dev/null 2>&1; then
            info "transfer skipped: status=partial-manifest"
            continue
        fi
        if ! jq -e '.schema_version == 1' "$d/transfer.manifest" >/dev/null 2>&1; then
            info "transfer skipped: status=unsupported-schema"
            continue
        fi
        # Reject unsafe names before touching attachments. IDs are UUIDs and
        # match their directory; log only validated IDs, never manifest text.
        if ! jq -e --arg dirname "${dir##*/}" '
            (.id | type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"))
            and .id == $dirname and (.status == "held" or .status == "queued")
            and (.created_at | type == "string") and (.title | type == "string")
            and (.note | type == "string") and (.attachments | type == "array")
            and all(.attachments[];
                type == "object"
                and (.name | type == "string" and length > 0
                    and . != "." and . != ".." and . != "manifest.json" and . != "receipt.json"
                    and (contains("/") | not) and (contains("\u0000") | not))
                and (.uti | type == "string")
                and (.bytes | type == "number" and . >= 0 and . == floor)
                and (.kind == "text" or .kind == "image" or .kind == "file"))
        ' "$d/transfer.manifest" >/dev/null 2>&1; then
            info "transfer skipped: status=invalid-manifest"
            continue
        fi
        id=$(jq -r '.id' "$d/transfer.manifest")
        status=$(jq -r '.status' "$d/transfer.manifest")
        [ "$status" = "queued" ] || continue
        transfer_attachments_ready "$d/transfer.manifest" "$dir" || continue
        # Resolve even a relative sync-folder override to an absolute CLI path.
        dir=$(cd "$dir" && pwd -P) || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            printf 'dry run: would import transfer id=%s status=queued\n' "$id" >&2
            continue
        fi
        if [ "$running" -ne 1 ]; then
            if [ "$stopped_logged" -eq 0 ]; then
                info "transfers queued: Hex is not running"
                stopped_logged=1
            fi
            continue
        fi
        rc=0
        run_cli "$d/transfer.reply" transfers import --dir "$dir" --json || rc=$?
        if [ "$rc" -eq 3 ]; then
            running=0
            info "transfers queued: Hex is not running"
            stopped_logged=1
            continue
        elif [ "$rc" -ne 0 ]; then
            warn "transfer id=$id status=import-failed"
            continue
        fi
        if jq -e 'type == "object" and .imported == false and .reason == "held"' "$d/transfer.reply" >/dev/null 2>&1; then
            info "transfer id=$id status=held"
            continue
        fi
        if ! jq -e 'type == "object" and (.imported == true or (.imported == false and .reason == "already"))' "$d/transfer.reply" >/dev/null 2>&1; then
            warn "transfer id=$id status=invalid-reply"
            continue
        fi
        if [ -z "$version" ]; then
            version=$(hex_cli --version 2>/dev/null | awk 'NR == 1 { print $2 }') || version=""
            version=${version:-unknown}
        fi
        # The phone may delete an item meanwhile. Never recreate its directory.
        receipt_tmp=$(mktemp "$dir/.receipt.json.XXXXXX" 2>/dev/null) || {
            warn "transfer id=$id status=receipt-failed"; continue;
        }
        if ! jq -n --arg id "$id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg version "$version" \
            '{schema_version: 1, id: $id, delivered_at: $now, hex_version: $version}' >"$receipt_tmp" ||
            ! mv -f "$receipt_tmp" "$dir/receipt.json"; then
            rm -f "$receipt_tmp"
            warn "transfer id=$id status=receipt-failed"
            continue
        fi
        info "transfer id=$id status=delivered"
    done
}

# ---------------------------------------------------------------- main

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --once) ;;
            --dry-run) DRY_RUN=1 ;;
            --verbose | -v) VERBOSE=1 ;;
            --help | -h) usage; exit 0 ;;
            *) printf '%s: unknown option: %s\n\n' "$PROG" "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done

    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$(dirname "$HEX_MOBILE_LOG")" 2>/dev/null || true
        rotate_log
        # The state directory holds the lock and the notification stamps: a
        # failure here must be loud, or every run would look like a lock held
        # by another run.
        if ! mkdir -p "$HEX_MOBILE_STATE_DIR" 2>/dev/null || [ ! -w "$HEX_MOBILE_STATE_DIR" ]; then
            notify state-dir "hex-mobile-sync cannot write its state folder. See the log."
            die 1 "state directory is missing or not writable: $HEX_MOBILE_STATE_DIR"
        fi
    fi

    command -v jq >/dev/null 2>&1 || die 1 "jq not found in PATH ($PATH)"

    if [ ! -x "$HEX_CLI" ]; then
        notify cli-missing "Hex CLI not found at $HEX_CLI. Is Hex installed?"
        die 1 "hex CLI not found or not executable: $HEX_CLI"
    fi

    # Sync folder: create the leaf once, never its parents (if iCloud Drive
    # itself is missing, creating it would hide a real configuration problem).
    if [ ! -d "$HEX_MOBILE_SYNC_DIR" ]; then
        local parent
        parent=$(dirname "$HEX_MOBILE_SYNC_DIR")
        [ -d "$parent" ] || die 1 "parent of sync folder does not exist: $parent (is iCloud Drive enabled?)"
        if [ "$DRY_RUN" -eq 1 ]; then
            info "dry run: would create sync folder $HEX_MOBILE_SYNC_DIR"
        else
            mkdir "$HEX_MOBILE_SYNC_DIR" || die 1 "cannot create sync folder $HEX_MOBILE_SYNC_DIR"
            info "created sync folder $HEX_MOBILE_SYNC_DIR"
        fi
    fi

    trap cleanup EXIT
    trap 'exit 1' INT TERM HUP

    # One run at a time (launchd WatchPaths can fire in bursts).
    if [ "$DRY_RUN" -eq 0 ]; then
        LOCK_DIR="$HEX_MOBILE_STATE_DIR/lock"
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            # Only an existing lock means a concurrent (or stale) run; any
            # other mkdir failure is an error, not a silent skip.
            if [ ! -d "$LOCK_DIR" ]; then
                LOCK_DIR=""
                notify lock "hex-mobile-sync cannot create its lock. See the log."
                die 1 "cannot create lock in $HEX_MOBILE_STATE_DIR"
            fi
            local age
            age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || date +%s) ))
            if [ "$age" -gt 600 ]; then
                log WARN "removing stale lock ($age s old)"
                rmdir "$LOCK_DIR" 2>/dev/null || true
                mkdir "$LOCK_DIR" 2>/dev/null || { LOCK_DIR=""; die 1 "cannot take lock"; }
            else
                LOCK_DIR=""
                info "another run is in progress; exiting"
                exit 0
            fi
        fi
    fi

    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hex-mobile-sync.XXXXXX") || die 1 "cannot create temp dir"

    local rc=0 via="cli" running=1
    export_via_cli "$TMP_DIR" || rc=$?
    if [ "$rc" -eq 3 ]; then
        running=0
        via="settings-file"
        info "Hex is not running: reading $HEX_SETTINGS_FILE read-only"
        rc=0
        export_via_settings_file "$TMP_DIR" || rc=$?
        [ "$rc" -eq 0 ] || exit "$rc"
    elif [ "$rc" -ne 0 ]; then
        exit 1
    fi

    # Pending vocabulary first, so the bundle already contains the new terms.
    local before
    before=$(jq -S -c '.' "$TMP_DIR/vocab.json")
    apply_pending "$TMP_DIR" "$running" || exit 1
    if [ "$running" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] && [ -f "$TMP_DIR/applied.json" ]; then
        rc=0
        export_via_cli "$TMP_DIR" || rc=$?
        if [ "$rc" -eq 3 ]; then
            # Hex quit between the two reads: the first snapshot is still valid.
            info "Hex stopped before re-export; using the earlier snapshot"
            printf '%s\n' "$before" >"$TMP_DIR/vocab.json"
        elif [ "$rc" -ne 0 ]; then
            exit 1
        fi
    fi

    build_bundle "$TMP_DIR" "$via" "$TMP_DIR/bundle.json" || die 1 "cannot build the sync bundle"
    if jq -e '[.. | objects | has("post_processing")] | any' "$TMP_DIR/bundle.json" >/dev/null; then
        die 1 "internal error: post_processing in the bundle; refusing to write"
    fi

    local dest="$HEX_MOBILE_SYNC_DIR/$BUNDLE_NAME" terms
    terms=$(jq '.vocabulary | length' "$TMP_DIR/bundle.json")
    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry run: $terms vocabulary terms, via $via; bundle printed to stdout"
        cat "$TMP_DIR/bundle.json"
    elif [ -f "$dest" ] && [ "$(jq -S -c 'del(.exported_at)' "$dest" 2>/dev/null || true)" = "$(jq -S -c 'del(.exported_at)' "$TMP_DIR/bundle.json")" ]; then
        info "bundle unchanged ($terms terms, via $via)"
    else
        atomic_replace "$TMP_DIR/bundle.json" "$dest" || die 1 "cannot write $dest"
        info "bundle written: $terms terms, via $via"
    fi

    import_transfers "$TMP_DIR" "$running"

    [ "$WARNINGS" -eq 1 ] && exit 4
    exit 0
}

main "$@"
