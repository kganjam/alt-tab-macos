#!/bin/bash
# Manage TCC permissions for the locally-rebuilt AltTab.app.
#
# Subcommands:
#   status — print AltTab's current TCC entries from the user and system DBs.
#   grant  — upsert TCC entries so permissions persist across rebuilds.
#
# Requirements:
#   - The shell invoking this script must have Full Disk Access.
#     macOS treats `claude` and similar non-Terminal binaries as their own
#     TCC clients; FDA on Terminal alone is not inherited by children
#     spawned through a separate Mach-O. If the script reports it cannot
#     read TCC.db, add the actual binary running this shell to System
#     Settings → Privacy & Security → Full Disk Access.
#   - The SYSTEM TCC.db (Accessibility, Screen Recording, Input Monitoring,
#     Post Event) requires SIP at least partially disabled to write. Without
#     that, only the USER TCC.db is writable; macOS will keep prompting for
#     the system-level services.

set -e

APP="/Applications/AltTab.app"
BUNDLE_ID="com.lwouis.alt-tab-macos"
USER_TCC="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
SYS_TCC="/Library/Application Support/com.apple.TCC/TCC.db"

SERVICES=(
    "kTCCServiceAccessibility"
    "kTCCServiceScreenCapture"
    "kTCCServicePostEvent"
    "kTCCServiceListenEvent"
)

usage() {
    echo "Usage: $0 {status|grant}"
    exit 2
}

check_fda() {
    if ! cat "$USER_TCC" >/dev/null 2>&1; then
        echo "ERROR: cannot read TCC.db — Full Disk Access not granted to" >&2
        echo "       the binary running this shell." >&2
        echo "       Process tree:" >&2
        ps -o pid,command -p $$ -p $PPID >&2
        return 1
    fi
}

print_db() {
    local label="$1" db="$2" sudo_prefix="$3"
    echo "=== $label TCC.db: entries for $BUNDLE_ID ==="
    if [[ -n "$sudo_prefix" ]]; then
        $sudo_prefix sqlite3 -header -column "$db" \
            "SELECT service, auth_value, datetime(last_modified,'unixepoch','localtime') AS modified, length(csreq) AS csreq_bytes \
             FROM access WHERE client = '$BUNDLE_ID' ORDER BY service;"
    else
        sqlite3 -header -column "$db" \
            "SELECT service, auth_value, datetime(last_modified,'unixepoch','localtime') AS modified, length(csreq) AS csreq_bytes \
             FROM access WHERE client = '$BUNDLE_ID' ORDER BY service;"
    fi
}

cmd_status() {
    check_fda || return 1
    print_db "USER" "$USER_TCC" ""
    echo
    print_db "SYSTEM" "$SYS_TCC" "sudo"
}

build_csreq_hex() {
    local req
    req=$(codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => //p')
    if [[ -z "$req" ]]; then
        echo "ERROR: cannot read designated requirement from $APP" >&2
        return 1
    fi
    local tmp
    tmp=$(mktemp)
    if ! echo "$req" | csreq -r - -b "$tmp" 2>/dev/null; then
        echo "ERROR: csreq failed to compile: $req" >&2
        rm -f "$tmp"
        return 1
    fi
    xxd -p "$tmp" | tr -d '\n'
    rm -f "$tmp"
}

upsert_one() {
    local db="$1" sudo_prefix="$2" svc="$3" csreq_hex="$4" now="$5"
    # auth_value=2 (Allowed), auth_reason=4 (User Set), client_type=0 (bundle id)
    local sql="INSERT OR REPLACE INTO access \
        (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags, last_modified) \
        VALUES ('$svc', '$BUNDLE_ID', 0, 2, 4, 1, X'$csreq_hex', 0, $now);"
    if [[ -n "$sudo_prefix" ]]; then
        $sudo_prefix sqlite3 -cmd ".timeout 5000" "$db" "$sql" 2>&1
    else
        sqlite3 -cmd ".timeout 5000" "$db" "$sql" 2>&1
    fi
}

cmd_grant() {
    check_fda || return 1
    local csreq_hex now
    csreq_hex=$(build_csreq_hex) || return 1
    now=$(date +%s)
    # Drop any stale entries for our bundle id BEFORE writing fresh ones.
    # Old entries may have a different csreq (from a previous code-sign
    # cert) that shadow our new entry — observed in practice as
    # repeated tccd prompts even after a successful grant. tccutil is
    # the supported API for resetting per-(service, client) state.
    echo "Resetting any stale TCC entries..."
    for svc_short in Accessibility ScreenCapture PostEvent ListenEvent SystemPolicyAppBundles; do
        tccutil reset "$svc_short" "$BUNDLE_ID" >/dev/null 2>&1 || true
    done
    # Brief settle so tccd releases its write lock on TCC.db before our
    # UPSERTs run; otherwise sqlite3 hits SQLITE_BUSY ("database is
    # locked") even with .timeout set, since tccd is mid-flush.
    sleep 1
    echo "Upserting TCC entries (csreq=${#csreq_hex} hex chars, now=$now)"
    for svc in "${SERVICES[@]}"; do
        local err
        err=$(upsert_one "$USER_TCC" "" "$svc" "$csreq_hex" "$now") || true
        if [[ -z "$err" ]]; then
            echo "  user   TCC: $svc OK"
        else
            echo "  user   TCC: $svc FAILED: $err"
        fi
        err=$(upsert_one "$SYS_TCC" "sudo" "$svc" "$csreq_hex" "$now") || true
        if [[ -z "$err" ]]; then
            echo "  system TCC: $svc OK"
        else
            echo "  system TCC: $svc FAILED: $err  (SIP usually blocks system-DB writes)"
        fi
    done
    # Tell tccd to invalidate its in-memory cache so the rows we just
    # wrote take effect for the next AX/SC call. Without this, tccd may
    # serve a stale "no decision" verdict and queue another prompt.
    notifyutil -p com.apple.private.tcc.changed.user 2>/dev/null || true
    notifyutil -p com.apple.private.tcc.changed 2>/dev/null || true
}

case "${1:-}" in
    status) cmd_status ;;
    grant)  cmd_grant ;;
    *)      usage ;;
esac
