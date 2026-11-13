#!/bin/bash
#
# Tests for mac/hex-mobile-sync.sh and mac/install.sh against a stub hex CLI.
# Never touches the real Hex, iCloud Drive, ~/Library/Logs or launchd.
#
# Usage: tests/mac/test-sync.sh        (exit 0 when every test passes)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/mac/hex-mobile-sync.sh"
INSTALL="$ROOT/mac/install.sh"
FIXTURES="$HERE/fixtures"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/hex-mobile-sync-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CURRENT=""

# ---------------------------------------------------------------- harness

setup() {
    CURRENT="$1"
    T="$WORK/$PASS-$FAIL-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
    mkdir -p "$T/state" "$T/stub" "$T/home" "$T/tmp"
    cp "$FIXTURES"/*.json "$T/stub/"
    mkdir "$T/sync"
    export STUB_HEX_STATE="$T/stub"
    export STUB_HEX_MODE="running"
    unset STUB_HEX_ADD_FAIL STUB_HEX_APPEND_PENDING STUB_HEX_MERGE_PENDING STUB_HEX_SLEEP HEX_CLI_TIMEOUT
    unset STUB_HEX_TRANSFER_RC STUB_HEX_TRANSFER_REPLY STUB_HEX_VERSION_FAIL
    export HEX_CLI="$FIXTURES/hex"
    export HEX_MOBILE_SYNC_DIR="$T/sync"
    export HEX_SETTINGS_FILE="$T/stub/settings.json"
    export HEX_MOBILE_LOG="$T/sync.log"
    export HEX_MOBILE_STATE_DIR="$T/state"
    export HEX_MOBILE_NOTIFY_CMD="$FIXTURES/notify-recorder"
    export NOTIFY_RECORD="$T/notifications.log"
    export HOME="$T/home"
    # Per-test TMPDIR: the script's temp dir and its fallback notification stamps.
    export TMPDIR="$T/tmp"
    BUNDLE="$T/sync/hex-mobile-sync.json"
    PENDING="$T/sync/pending-vocabulary.json"
}

# run [args...]: runs the script, sets RC, OUT (stdout) and ERR (stderr) files.
run() {
    RC=0
    OUT="$T/stdout"
    ERR="$T/stderr"
    /bin/bash "$SCRIPT" "$@" >"$OUT" 2>"$ERR" || RC=$?
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s: %s\n' "$CURRENT" "$*"
    if [ -f "${ERR:-/nonexistent}" ]; then
        sed 's/^/        stderr: /' "$ERR" | tail -n 5
    fi
    return 1
}

pass() {
    PASS=$((PASS + 1))
    printf 'ok    %s\n' "$CURRENT"
}

expect_rc() { [ "$RC" -eq "$1" ] || fail "exit $RC, expected $1"; }
expect_jq() { jq -e "$2" "$1" >/dev/null 2>&1 || fail "jq '$2' is false on $(basename "$1")"; }
expect_no_text() { ! grep -q -- "$2" "$1" || fail "'$2' found in $(basename "$1")"; }
expect_text() { grep -q -- "$2" "$1" || fail "'$2' not found in $(basename "$1")"; }
add_calls() { grep -c '^vocabulary add' "$STUB_HEX_STATE/calls.log" 2>/dev/null || true; }
notifications() { if [ -f "$NOTIFY_RECORD" ]; then wc -l <"$NOTIFY_RECORD" | tr -d ' '; else echo 0; fi; }

write_pending() { printf '%s\n' "$1" >"$PENDING"; }

# Each test is a function; a failed expectation returns 1 and the next test runs.
t() {
    local name="$1" fn="$2"
    setup "$name"
    if "$fn"; then pass; fi
}

# ---------------------------------------------------------------- tests

test_help_and_usage() {
    run --help
    expect_rc 0 || return 1
    expect_text "$OUT" "Exit codes" || return 1
    run --bogus
    expect_rc 2
}

test_export_via_cli() {
    run --once
    expect_rc 0 || return 1
    expect_jq "$BUNDLE" '.schema_version == 1' || return 1
    expect_jq "$BUNDLE" '.source == {app: "Hex", app_version: "9.8.7", via: "cli"}' || return 1
    expect_jq "$BUNDLE" '.language == "it"' || return 1
    expect_jq "$BUNDLE" '.exported_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' || return 1
    expect_jq "$BUNDLE" '[.vocabulary[].term] == ["Kubernetes", "PostgreSQL", "Perché"]' || return 1
    expect_jq "$BUNDLE" '.vocabulary[2].sounds_like == []' || return 1
    expect_jq "$BUNDLE" '.default_mode == {name: "Global", replacements: [{matched_phrase: "new paragraph", output: "\n\n"}, {matched_phrase: "smiley face", output: ":)"}], transformations: ["lowercase"]}' || return 1
    expect_jq "$BUNDLE" '.modes == [{name: "Terminal", applications: ["Terminal", "Example Shell"], browser_hosts: [], replacements: [], transformations: ["no-trailing-punctuation", "fixture-custom-command"]}]' || return 1
    expect_jq "$BUNDLE" '[.. | objects | has("post_processing")] | any | not' || return 1
    expect_no_text "$BUNDLE" "FIXTURE-SECRET-PROMPT" || return 1
    expect_no_text "$BUNDLE" "fixture-model" || return 1
    expect_text "$HEX_MOBILE_LOG" "bundle written: 3 terms, via cli" || return 1
    [ -z "$(find "$T/sync" -name '.*tmp*')" ] || fail "temporary file left in the sync folder"
}

test_idempotent_second_run() {
    run --once
    expect_rc 0 || return 1
    touch -t 202001010000 "$BUNDLE"
    local before after
    before=$(stat -f %m "$BUNDLE")
    run --once
    expect_rc 0 || return 1
    after=$(stat -f %m "$BUNDLE")
    [ "$before" = "$after" ] || fail "bundle rewritten although content is unchanged" || return 1
    expect_text "$HEX_MOBILE_LOG" "bundle unchanged" || return 1
    # A real change is written.
    jq '.entries += [{term: "Terraform", sounds_like: ["terra form"]}]' "$STUB_HEX_STATE/vocabulary-list.json" >"$T/v" &&
        mv "$T/v" "$STUB_HEX_STATE/vocabulary-list.json"
    run --once
    expect_rc 0 || return 1
    after=$(stat -f %m "$BUNDLE")
    [ "$before" != "$after" ] || fail "bundle not rewritten after a vocabulary change" || return 1
    expect_jq "$BUNDLE" '.vocabulary | length == 4'
}

test_fallback_when_hex_not_running() {
    export STUB_HEX_MODE="stopped"
    write_pending '{"schema_version":1,"entries":[{"id":"a1","term":"Terraform","sounds_like":["terra form"],"created_at":"2026-01-01T00:00:00Z"}]}'
    cp "$PENDING" "$T/pending.orig"
    run --once
    expect_rc 0 || return 1
    expect_jq "$BUNDLE" '.source.via == "settings-file"' || return 1
    expect_jq "$BUNDLE" '[.vocabulary[].term] == ["Grafana", "OpenTelemetry"]' || return 1
    expect_jq "$BUNDLE" '.language == "en"' || return 1
    expect_jq "$BUNDLE" '.default_mode.replacements == [{matched_phrase: "full stop", output: "."}]' || return 1
    expect_jq "$BUNDLE" '[.. | objects | has("post_processing")] | any | not' || return 1
    expect_no_text "$BUNDLE" "FIXTURE-SECRET-PROMPT" || return 1
    cmp -s "$PENDING" "$T/pending.orig" || fail "pending file changed while Hex is not running" || return 1
    [ "$(add_calls)" -eq 0 ] || fail "vocabulary add called while Hex is not running" || return 1
    expect_text "$HEX_MOBILE_LOG" "kept for the next run"
}

test_fallback_unreadable_settings() {
    export STUB_HEX_MODE="stopped"
    export HEX_SETTINGS_FILE="$T/does-not-exist.json"
    run --once
    expect_rc 3 || return 1
    [ ! -f "$BUNDLE" ] || fail "bundle written without data"
}

test_fallback_invalid_settings() {
    export STUB_HEX_MODE="stopped"
    printf 'not json\n' >"$HEX_SETTINGS_FILE"
    run --once
    expect_rc 3
}

test_pending_apply() {
    write_pending '{
      "schema_version": 1,
      "entries": [
        {"id": "n1", "term": "Terraform", "sounds_like": ["terra form", "tera form"], "created_at": "2026-01-01T00:00:00Z"},
        {"id": "p1", "term": "kubernetes", "sounds_like": ["Cube Nettis"], "created_at": "2026-01-01T00:00:00Z"},
        {"id": "s1", "term": " postgresql ", "sounds_like": ["post gress", "postgres q l"], "created_at": "2026-01-01T00:00:00Z"},
        {"id": "b1", "term": "-dash-term", "sounds_like": [], "created_at": "2026-01-01T00:00:00Z"}
      ]
    }'
    run --once
    expect_rc 0 || return 1
    [ "$(add_calls)" -eq 3 ] || fail "expected 3 vocabulary add calls, got $(add_calls)" || return 1
    expect_text "$STUB_HEX_STATE/calls.log" "^vocabulary add --sounds-like=terra form,tera form Terraform$" || return 1
    # Existing term (other case, extra spaces) with one new spelling: only the
    # missing spelling is sent, under Hex's own spelling of the term.
    expect_text "$STUB_HEX_STATE/calls.log" "^vocabulary add --sounds-like=postgres q l PostgreSQL$" || return 1
    expect_text "$STUB_HEX_STATE/calls.log" "^vocabulary add -- -dash-term$" || return 1
    expect_no_text "$STUB_HEX_STATE/calls.log" "add.*kubernetes" || return 1
    expect_jq "$PENDING" '.schema_version == 1 and .entries == []' || return 1
    expect_jq "$BUNDLE" '[.vocabulary[].term] | index("Terraform") != null' || return 1
    expect_jq "$BUNDLE" '.vocabulary[] | select(.term == "PostgreSQL") | .sounds_like == ["post gress", "postgres q l"]' || return 1
    expect_text "$HEX_MOBILE_LOG" "pending entry #1 already present in Hex: dropped" || return 1
    # Without --verbose the log carries no vocabulary terms or spellings.
    expect_no_text "$HEX_MOBILE_LOG" "Terraform" || return 1
    expect_no_text "$HEX_MOBILE_LOG" "terra form" || return 1
    expect_no_text "$HEX_MOBILE_LOG" "Kubernetes" || return 1
    [ "$(notifications)" -eq 0 ] || fail "unexpected notification"
}

test_pending_spelling_starting_with_dash() {
    write_pending '{"schema_version":1,"entries":[{"id":"d1","term":"Alpha","sounds_like":["-al fa"]}]}'
    run --once
    expect_rc 0 || return 1
    expect_text "$STUB_HEX_STATE/calls.log" "^vocabulary add --sounds-like=-al fa Alpha$" || return 1
    expect_jq "$PENDING" '.entries == []' || return 1
    expect_jq "$BUNDLE" '.vocabulary[] | select(.term == "Alpha") | .sounds_like == ["-al fa"]'
}

test_pending_unicode_case_and_variants() {
    write_pending '{"schema_version":1,"entries":[
        {"id":"u1","term":"PERCHÉ","sounds_like":[]},
        {"id":"z1","term":"Zeta","sounds_like":["z"]},
        {"id":"z2","term":"zeta","sounds_like":["Z", "zed"]}]}'
    run --once
    expect_rc 0 || return 1
    # PERCHÉ matches the existing Perché (Unicode case folding): no add.
    expect_no_text "$STUB_HEX_STATE/calls.log" "PERCH" || return 1
    # zeta is a case variant of Zeta added earlier in the same run: only the
    # missing spelling is sent, under the first spelling of the term.
    [ "$(add_calls)" -eq 2 ] || fail "expected 2 vocabulary add calls, got $(add_calls)" || return 1
    expect_text "$STUB_HEX_STATE/calls.log" "^vocabulary add --sounds-like=z Zeta$" || return 1
    expect_text "$STUB_HEX_STATE/calls.log" "^vocabulary add --sounds-like=zed Zeta$" || return 1
    expect_jq "$BUNDLE" '[.vocabulary[].term | select(ascii_downcase == "zeta")] == ["Zeta"]' || return 1
    expect_jq "$PENDING" '.entries == []'
}

test_pending_merged_during_apply_survives() {
    export STUB_HEX_MERGE_PENDING="$PENDING"
    write_pending '{"schema_version":1,"entries":[{"id":"m1","term":"Omega","sounds_like":["oh mega"]}]}'
    run --once
    expect_rc 0 || return 1
    # The iPhone merged a spelling into m1 during the apply: the entry stays.
    expect_jq "$PENDING" '.entries == [{id: "m1", term: "Omega", sounds_like: ["oh mega", "new spelling"]}]' || return 1
    run --once
    expect_rc 0 || return 1
    expect_jq "$PENDING" '.entries == []' || return 1
    expect_jq "$BUNDLE" '.vocabulary[] | select(.term == "Omega") | .sounds_like == ["oh mega", "new spelling"]'
}

test_pending_all_present() {
    write_pending '{"schema_version":1,"entries":[{"id":"p1","term":"Perché","sounds_like":[]}]}'
    run --once
    expect_rc 0 || return 1
    [ "$(add_calls)" -eq 0 ] || fail "vocabulary add called for a present term" || return 1
    expect_jq "$PENDING" '.entries == []'
}

test_pending_add_failure_keeps_entry() {
    export STUB_HEX_ADD_FAIL="Broken"
    write_pending '{"schema_version":1,"entries":[
        {"id":"f1","term":"Broken","sounds_like":["bro ken"]},
        {"id":"n1","term":"Terraform","sounds_like":[]}]}'
    run --once
    expect_rc 4 || return 1
    expect_jq "$PENDING" '[.entries[].id] == ["f1"]' || return 1
    [ "$(notifications)" -eq 1 ] || fail "expected one notification, got $(notifications)" || return 1
    expect_text "$NOTIFY_RECORD" "could not be added"
}

test_pending_hex_stops_during_apply() {
    export STUB_HEX_MODE="stop-on-add"
    write_pending '{"schema_version":1,"entries":[
        {"id":"p1","term":"Kubernetes","sounds_like":[]},
        {"id":"n1","term":"Terraform","sounds_like":[]},
        {"id":"n2","term":"Ansible","sounds_like":[]}]}'
    run --once
    expect_rc 0 || return 1
    # The already-present entry is dropped, the two new ones are kept.
    expect_jq "$PENDING" '[.entries[].id] == ["n1", "n2"]' || return 1
    expect_jq "$BUNDLE" '.source.via == "cli"'
}

test_pending_appended_during_apply() {
    export STUB_HEX_APPEND_PENDING="$PENDING"
    write_pending '{"schema_version":1,"entries":[{"id":"n1","term":"Terraform","sounds_like":[]}]}'
    run --once
    expect_rc 0 || return 1
    expect_jq "$PENDING" '[.entries[].id] == ["late-entry"]'
}

test_pending_invalid_json() {
    printf '{"schema_version": 1, "entries": [ broken\n' >"$PENDING"
    run --once
    expect_rc 4 || return 1
    [ ! -f "$PENDING" ] || fail "invalid pending file not moved" || return 1
    [ "$(find "$T/sync" -name 'pending-vocabulary.invalid-*.json' | wc -l | tr -d ' ')" -eq 1 ] ||
        fail "moved-aside file not found" || return 1
    [ -f "$BUNDLE" ] || fail "bundle not written" || return 1
    [ "$(notifications)" -eq 1 ] || fail "expected one notification" || return 1
    # Same problem again on the same day: logged, not notified again.
    sleep 1
    printf '[]\n' >"$PENDING"
    run --once
    expect_rc 4 || return 1
    [ "$(notifications)" -eq 1 ] || fail "notification not deduplicated ($(notifications))"
}

test_pending_future_schema() {
    write_pending '{"schema_version":2,"entries":[{"id":"n1","term":"Terraform"}]}'
    cp "$PENDING" "$T/pending.orig"
    run --once
    expect_rc 4 || return 1
    cmp -s "$PENDING" "$T/pending.orig" || fail "future pending file was modified" || return 1
    [ "$(add_calls)" -eq 0 ] || fail "applied entries from a future schema"
}

test_missing_cli() {
    export HEX_CLI="$T/no-such-hex"
    run --once
    expect_rc 1 || return 1
    expect_text "$HEX_MOBILE_LOG" "hex CLI not found" || return 1
    [ "$(notifications)" -eq 1 ] || fail "expected one notification" || return 1
    run --once
    [ "$(notifications)" -eq 1 ] || fail "missing-CLI notification not deduplicated" || return 1
    [ ! -f "$BUNDLE" ] || fail "bundle written without a CLI"
}

test_cli_error_keeps_old_bundle() {
    run --once
    expect_rc 0 || return 1
    cp "$BUNDLE" "$T/bundle.orig"
    printf '{"version":4,"status":"error","code":"boom"}\n' >"$STUB_HEX_STATE/vocabulary-list.json"
    run --once
    expect_rc 1 || return 1
    cmp -s "$BUNDLE" "$T/bundle.orig" || fail "bundle changed after a CLI error"
}

test_unsupported_reply_keeps_old_bundle() {
    run --once
    expect_rc 0 || return 1
    cp "$BUNDLE" "$T/bundle.orig"
    # A future reply format: version 5 and settings as an object.
    printf '%s\n' '{"version":5,"status":"settings","settings":{"dictation_processing.default_mode":{"name":"Global"}}}' \
        >"$STUB_HEX_STATE/settings-dictation-processing.json"
    run --once
    expect_rc 1 || return 1
    cmp -s "$BUNDLE" "$T/bundle.orig" || fail "bundle changed after an unsupported reply" || return 1
    expect_text "$HEX_MOBILE_LOG" "unsupported reply" || return 1
    [ "$(notifications)" -eq 1 ] || fail "expected one notification, got $(notifications)" || return 1
    # Supported version but missing key: refused too.
    printf '%s\n' '{"version":4,"status":"settings","settings":[]}' >"$STUB_HEX_STATE/settings-dictation-processing.json"
    run --once
    expect_rc 1 || return 1
    cmp -s "$BUNDLE" "$T/bundle.orig" || fail "bundle changed after a reply without default_mode" || return 1
    # Vocabulary reply without an entries array.
    cp "$FIXTURES/settings-dictation-processing.json" "$STUB_HEX_STATE/"
    printf '%s\n' '{"version":4,"status":"vocabulary","terms":[]}' >"$STUB_HEX_STATE/vocabulary-list.json"
    run --once
    expect_rc 1 || return 1
    cmp -s "$BUNDLE" "$T/bundle.orig" || fail "bundle changed after a vocabulary reply without entries"
}

test_cli_timeout() {
    export STUB_HEX_SLEEP=5 HEX_CLI_TIMEOUT=1
    local started=$SECONDS
    run --once
    expect_rc 1 || return 1
    [ $((SECONDS - started)) -lt 4 ] || fail "timeout did not stop the CLI call" || return 1
    expect_text "$HEX_MOBILE_LOG" "timed out after 1s" || return 1
    [ "$(notifications)" -eq 1 ] || fail "expected one notification, got $(notifications)" || return 1
    [ ! -f "$BUNDLE" ] || fail "bundle written after a timeout"
}

test_state_dir_not_writable() {
    export HEX_MOBILE_STATE_DIR="$T/no-such-parent/state"
    touch "$T/no-such-parent"
    run --once
    expect_rc 1 || return 1
    expect_text "$HEX_MOBILE_LOG" "state directory is missing or not writable" || return 1
    [ "$(notifications)" -eq 1 ] || fail "expected one notification, got $(notifications)" || return 1
    [ ! -f "$BUNDLE" ] || fail "bundle written without a lock"
}

test_dry_run_writes_nothing() {
    write_pending '{"schema_version":1,"entries":[{"id":"n1","term":"Terraform","sounds_like":[]}]}'
    cp "$PENDING" "$T/pending.orig"
    run --dry-run --verbose
    expect_rc 0 || return 1
    [ ! -f "$BUNDLE" ] || fail "dry run wrote the bundle" || return 1
    [ ! -f "$HEX_MOBILE_LOG" ] || fail "dry run wrote the log" || return 1
    cmp -s "$PENDING" "$T/pending.orig" || fail "dry run changed the pending file" || return 1
    [ "$(add_calls)" -eq 0 ] || fail "dry run called vocabulary add" || return 1
    expect_jq "$OUT" '.vocabulary | length == 3' || return 1
    expect_text "$ERR" "would add 'Terraform'"
}

test_sync_dir_created_once() {
    rmdir "$T/sync"
    run --once
    expect_rc 0 || return 1
    [ -f "$BUNDLE" ] || fail "bundle not written in the new folder" || return 1
    expect_text "$HEX_MOBILE_LOG" "created sync folder" || return 1
    export HEX_MOBILE_SYNC_DIR="$T/missing-parent/Hex Mobile"
    run --once
    expect_rc 1 || return 1
    [ ! -d "$T/missing-parent" ] || fail "created a missing parent folder"
}

test_log_rotation() {
    # 1.1 MB of filler in the log.
    dd if=/dev/zero bs=1024 count=1100 2>/dev/null | tr '\0' 'x' >"$HEX_MOBILE_LOG"
    run --once
    expect_rc 0 || return 1
    [ -f "$HEX_MOBILE_LOG.1" ] || fail "log not rotated" || return 1
    [ "$(stat -f %z "$HEX_MOBILE_LOG")" -lt 10000 ] || fail "new log not small" || return 1
    # The launchd stderr log is rotated too.
    dd if=/dev/zero bs=1024 count=1100 2>/dev/null | tr '\0' 'x' >"$HEX_MOBILE_LOG.launchd"
    run --once
    expect_rc 0 || return 1
    [ -f "$HEX_MOBILE_LOG.launchd.1" ] || fail "launchd log not rotated"
}

test_lock_skips_concurrent_run() {
    mkdir "$HEX_MOBILE_STATE_DIR/lock"
    run --once
    expect_rc 0 || return 1
    [ ! -f "$BUNDLE" ] || fail "ran while another run held the lock" || return 1
    rmdir "$HEX_MOBILE_STATE_DIR/lock"
    run --once
    expect_rc 0 || return 1
    [ ! -d "$HEX_MOBILE_STATE_DIR/lock" ] || fail "lock not released"
}

test_install_print_renders_valid_plist() {
    local plist="$T/agent.plist"
    RC=0
    /bin/bash "$INSTALL" --print --label org.example.test --sync-dir "$T/a & b/Hex Mobile" >"$plist" 2>"$T/stderr" || RC=$?
    expect_rc 0 || return 1
    plutil -lint "$plist" >/dev/null || fail "rendered plist is invalid" || return 1
    [ "$(plutil -extract Label raw "$plist")" = "org.example.test" ] || fail "label not rendered" || return 1
    [ "$(plutil -extract StartInterval raw "$plist")" = "900" ] || fail "StartInterval not 900" || return 1
    [ "$(plutil -extract RunAtLoad raw "$plist")" = "true" ] || fail "RunAtLoad not true" || return 1
    [ "$(plutil -extract WatchPaths.1 raw "$plist")" = "$T/a & b/Hex Mobile/pending-vocabulary.json" ] ||
        fail "pending file not watched" || return 1
    [ "$(plutil -extract EnvironmentVariables.HEX_MOBILE_SYNC_DIR raw "$plist")" = "$T/a & b/Hex Mobile" ] ||
        fail "sync dir not rendered" || return 1
    expect_no_text "$plist" "__[A-Z_]*__" || return 1
    RC=0
    /bin/bash "$INSTALL" --print --label 'bad label' >/dev/null 2>&1 || RC=$?
    expect_rc 1
}

# Synthetic transfer with spaces in its payload name and text that must never
# appear in diagnostic output, even with --verbose.
write_transfer() {
    local status="${1:-queued}" id="${2:-11111111-1111-1111-1111-111111111111}"
    TRANSFER="$T/sync/transfers/$id"
    RECEIPT="$TRANSFER/receipt.json"
    mkdir -p "$TRANSFER"
    printf 'PRIVATE-TRANSFER-BODY' >"$TRANSFER/body text.txt"
    jq -n --arg id "$id" --arg status "$status" \
        '{schema_version: 1, id: $id, status: $status, created_at: "2026-11-13T00:00:00Z",
          title: "PRIVATE-TRANSFER-TITLE", note: "PRIVATE-TRANSFER-NOTE",
          attachments: [{name: "body text.txt", uti: "public.utf8-plain-text", bytes: 21, kind: "text"}]}' \
        >"$TRANSFER/manifest.json"
}

transfer_calls() { grep -c '^transfers import ' "$STUB_HEX_STATE/calls.log" 2>/dev/null || true; }

test_transfer_held() {
    write_transfer held
    run --once
    expect_rc 0 || return 1
    [ "$(transfer_calls)" -eq 0 ] || fail "held item imported" || return 1
    [ ! -e "$RECEIPT" ] || fail "held item acknowledged"
}

test_transfer_receipt_and_second_run() {
    write_transfer
    cp "$TRANSFER/manifest.json" "$T/manifest.orig"
    run --once
    expect_rc 0 || return 1
    [ "$(transfer_calls)" -eq 1 ] || fail "queued item not imported once" || return 1
    expect_text "$STUB_HEX_STATE/calls.log" "^transfers import --dir $(cd "$TRANSFER" && pwd -P) --json$" || return 1
    expect_jq "$RECEIPT" '.schema_version == 1 and .id == "11111111-1111-1111-1111-111111111111" and .hex_version == "9.8.7"' || return 1
    expect_jq "$RECEIPT" '.delivered_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' || return 1
    cmp -s "$TRANSFER/manifest.json" "$T/manifest.orig" || fail "manifest changed" || return 1
    expect_text "$TRANSFER/body text.txt" PRIVATE-TRANSFER-BODY || return 1
    [ -z "$(find "$TRANSFER" -name '.receipt.json.*')" ] || fail "receipt temp file left behind" || return 1
    cp "$RECEIPT" "$T/receipt.orig"
    run --once
    expect_rc 0 || return 1
    [ "$(transfer_calls)" -eq 1 ] || fail "item imported again after receipt" || return 1
    cmp -s "$RECEIPT" "$T/receipt.orig" || fail "existing receipt rewritten"
}

test_transfer_failure_then_retry() {
    write_transfer
    export STUB_HEX_TRANSFER_RC=1
    run --once --verbose
    expect_rc 4 || return 1
    [ "$(transfer_calls)" -eq 1 ] || fail "import was not attempted" || return 1
    [ ! -e "$RECEIPT" ] || fail "nonzero importer exit acknowledged" || return 1
    expect_text "$HEX_MOBILE_LOG" "id=11111111-1111-1111-1111-111111111111 status=import-failed" || return 1
    expect_no_text "$HEX_MOBILE_LOG" PRIVATE-TRANSFER || return 1
    expect_no_text "$ERR" PRIVATE-TRANSFER || return 1
    export STUB_HEX_TRANSFER_RC=0
    run --once
    expect_rc 0 || return 1
    [ -f "$RECEIPT" ] || fail "successful retry not acknowledged"
}

test_transfer_dry_run() {
    write_transfer
    cp "$TRANSFER/manifest.json" "$T/manifest.orig"
    run --dry-run
    expect_rc 0 || return 1
    [ "$(transfer_calls)" -eq 0 ] || fail "dry run imported" || return 1
    [ ! -e "$RECEIPT" ] && [ ! -e "$BUNDLE" ] && [ ! -e "$HEX_MOBILE_LOG" ] || fail "dry run wrote files" || return 1
    cmp -s "$TRANSFER/manifest.json" "$T/manifest.orig" || fail "dry run changed manifest" || return 1
    expect_text "$ERR" 'would import transfer id=11111111-1111-1111-1111-111111111111 status=queued'
}

test_transfer_hex_stops() {
    write_transfer queued 22222222-2222-2222-2222-222222222222
    local second_receipt="$RECEIPT"
    write_transfer
    export STUB_HEX_TRANSFER_RC=3
    run --once
    expect_rc 0 || return 1
    [ "$(transfer_calls)" -eq 1 ] || fail "kept calling a stopped Hex" || return 1
    [ ! -e "$RECEIPT" ] && [ ! -e "$second_receipt" ] || fail "stopped Hex acknowledged" || return 1
    expect_jq "$TRANSFER/manifest.json" '.status == "queued"' || return 1
    [ "$(grep -c 'transfers queued: Hex is not running' "$HEX_MOBILE_LOG")" -eq 1 ] || fail "stopped log not once per run"
}

test_transfer_hex_already_stopped() {
    write_transfer
    export STUB_HEX_MODE=stopped
    run --once
    expect_rc 0 || return 1
    [ "$(transfer_calls)" -eq 0 ] || fail "imported while Hex was stopped" || return 1
    [ ! -e "$RECEIPT" ] || fail "stopped item acknowledged"
}

test_transfer_replies() {
    write_transfer
    export STUB_HEX_TRANSFER_REPLY='{"imported":false,"reason":"held"}'
    run --once
    expect_rc 0 || return 1
    [ ! -e "$RECEIPT" ] || fail "held reply acknowledged" || return 1
    export STUB_HEX_TRANSFER_REPLY='{"imported":false,"reason":"other"}'
    run --once
    expect_rc 4 || return 1
    [ ! -e "$RECEIPT" ] || fail "unexpected reply acknowledged" || return 1
    export STUB_HEX_TRANSFER_REPLY='not json'
    run --once
    expect_rc 4 || return 1
    [ ! -e "$RECEIPT" ] || fail "malformed reply acknowledged" || return 1
    export STUB_HEX_TRANSFER_REPLY='{"imported":false,"reason":"already"}'
    export STUB_HEX_VERSION_FAIL=1
    run --once
    expect_rc 0 || return 1
    expect_jq "$RECEIPT" '.hex_version == "unknown"'
}

test_transfer_partial_and_unsupported() {
    write_transfer
    cp "$TRANSFER/manifest.json" "$T/manifest.orig"
    printf 'partial' >"$TRANSFER/body text.txt"
    run --once
    expect_rc 0 || return 1
    [ "$(transfer_calls)" -eq 0 ] || fail "partial attachment imported" || return 1
    rm "$TRANSFER/body text.txt"
    run --once
    expect_rc 0 || return 1
    [ "$(transfer_calls)" -eq 0 ] || fail "missing attachment imported" || return 1
    printf 'PRIVATE-TRANSFER-BODY' >"$TRANSFER/body text.txt"
    chmod 000 "$TRANSFER/body text.txt"
    run --once
    chmod 600 "$TRANSFER/body text.txt"
    expect_rc 0 || return 1
    [ "$(transfer_calls)" -eq 0 ] || fail "unreadable attachment imported" || return 1
    local filter
    for filter in 'del(.schema_version)' '.schema_version = 2'; do
        jq "$filter" "$T/manifest.orig" >"$TRANSFER/manifest.json"
        run --once
        expect_rc 0 || return 1
        [ "$(transfer_calls)" -eq 0 ] || fail "unsupported manifest imported" || return 1
    done
    [ "$(grep -c 'status=unsupported-schema' "$HEX_MOBILE_LOG")" -eq 2 ] || fail "unsupported schema not logged once per item/run" || return 1
    printf '{"schema_version":' >"$TRANSFER/manifest.json"
    run --once
    expect_rc 0 || return 1
    [ "$(transfer_calls)" -eq 0 ] || fail "partial manifest imported" || return 1
    [ ! -e "$RECEIPT" ] || fail "incomplete item acknowledged"
}

test_transfer_dataless() {
    write_transfer
    # A readable iCloud placeholder can report the correct logical byte count.
    # Simulate just its BSD stat flags; all other stat calls use the OS tool.
    mkdir "$T/bin"
    cat >"$T/bin/stat" <<'EOF'
#!/bin/bash
if [ "$1" = "-f" ] && [ "$2" = "%Sf" ] && [ "$3" = "$STUB_DATALESS_FILE" ]; then
    echo dataless
else
    exec /usr/bin/stat "$@"
fi
EOF
    chmod +x "$T/bin/stat"
    local file
    for file in "$TRANSFER/manifest.json" "$TRANSFER/body text.txt"; do
        RC=0
        PATH="$T/bin:$PATH" STUB_DATALESS_FILE="$file" /bin/bash "$SCRIPT" --once >"$T/stdout" 2>"$T/stderr" || RC=$?
        expect_rc 0 || return 1
        [ "$(transfer_calls)" -eq 0 ] || fail "dataless file imported" || return 1
    done
    [ ! -e "$RECEIPT" ] || fail "dataless item acknowledged"
}

# ---------------------------------------------------------------- main

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

t "help and usage errors" test_help_and_usage
t "export via CLI, no post_processing" test_export_via_cli
t "idempotent second run keeps mtime" test_idempotent_second_run
t "fallback to settings.json when Hex is not running" test_fallback_when_hex_not_running
t "fallback with unreadable settings.json exits 3" test_fallback_unreadable_settings
t "fallback with invalid settings.json exits 3" test_fallback_invalid_settings
t "pending vocabulary applied" test_pending_apply
t "pending term already present is dropped" test_pending_all_present
t "pending add failure keeps the entry" test_pending_add_failure_keeps_entry
t "Hex stops during pending apply" test_pending_hex_stops_during_apply
t "entry appended during apply survives" test_pending_appended_during_apply
t "spelling starting with a dash uses --sounds-like=" test_pending_spelling_starting_with_dash
t "Unicode case and case variants in one run" test_pending_unicode_case_and_variants
t "spelling merged during apply survives" test_pending_merged_during_apply_survives
t "invalid pending JSON moved aside, notification deduped" test_pending_invalid_json
t "pending with future schema left untouched" test_pending_future_schema
t "missing CLI exits 1 with deduped notification" test_missing_cli
t "CLI error keeps the previous bundle" test_cli_error_keeps_old_bundle
t "unsupported reply version or shape keeps the bundle" test_unsupported_reply_keeps_old_bundle
t "CLI timeout exits 1 with a notification" test_cli_timeout
t "unwritable state directory exits 1 with a notification" test_state_dir_not_writable
t "dry run writes nothing" test_dry_run_writes_nothing
t "sync folder created once, parent never" test_sync_dir_created_once
t "log rotated at 1 MB" test_log_rotation
t "lock skips a concurrent run" test_lock_skips_concurrent_run
t "install.sh --print renders a valid plist" test_install_print_renders_valid_plist
t "held transfer is not imported" test_transfer_held
t "queued transfer receipt and second-run idempotency" test_transfer_receipt_and_second_run
t "failed transfer has no receipt and retries privately" test_transfer_failure_then_retry
t "dry run does not import or acknowledge transfers" test_transfer_dry_run
t "exit 3 keeps queued transfers and logs once" test_transfer_hex_stops
t "already stopped Hex leaves transfers queued" test_transfer_hex_already_stopped
t "transfer held, invalid and already replies; unknown version" test_transfer_replies
t "partial, unreadable and unsupported transfers skipped" test_transfer_partial_and_unsupported
t "iCloud dataless manifest and attachment skipped" test_transfer_dataless

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
