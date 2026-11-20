#!/bin/bash
# Signs an app bundle with "NotchID Local Signing", a self-signed identity kept in its own keychain,
# so Accessibility, Camera and Keychain approvals survive rebuilds. The private key never leaves this Mac.
#
# Anyone holding that identity can sign a program that passes for NotchID and reads the saved login
# password, so the signing keychain is guarded:
#   - Its password is random, per Mac, and kept in the login keychain with no trusted apps, so reading
#     it always shows a macOS prompt (once per build).
#   - That login-keychain item is recreated after every build, so an "Always Allow" clicked by mistake
#     lasts only until the next build.
#   - The signing keychain is locked again right after signing, and auto-locks after 5 minutes or on sleep.
#   - Passwords go to `security` on stdin, never on a command line where `ps` could see them.
#
# Usage: scripts/sign.sh path/to/NotchID.app   (exit 3: the password prompt was denied)
set -euo pipefail

APP="$1"
# The NOTCHID_SIGN_* overrides exist only for testing this script against a throwaway keychain.
KC="${NOTCHID_SIGN_KEYCHAIN:-$HOME/Library/Keychains/notchid-signing.keychain-db}"
NAME="${NOTCHID_SIGN_NAME:-NotchID Local Signing}"
SVC="${NOTCHID_SIGN_SERVICE:-app.notchid.signing-keychain}"
ACCT="$USER"
PENDING="$USER.pending"   # holds a new password until the keychain really accepts it
LEGACY_PASSWORD="notchid" # the fixed password older versions used

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; security lock-keychain "$KC" 2>/dev/null || true; }
trap cleanup EXIT

sec() { security -i >/dev/null 2>&1; } # runs the commands piped in; non-zero exit if one fails
random_password() { openssl rand -hex 24; }
has_item() { security find-generic-password -s "$SVC" -a "$1" >/dev/null 2>&1; }       # no prompt
read_item() { security find-generic-password -s "$SVC" -a "$1" -w; }                   # prompts
delete_item() { security delete-generic-password -s "$SVC" -a "$1" >/dev/null 2>&1 || true; }
add_item() { # account password — -T "": no app may read it without asking, not even `security`
    printf 'add-generic-password -s %s -a %s -l "NotchID signing keychain" -T "" -w %s\n' "$SVC" "$1" "$2" | sec
}
unlocks() { printf 'unlock-keychain -p %s %s\n' "$1" "$KC" | sec; }
fail() { echo "$*" >&2; exit 1; }

create_identity() {
    local pw p12pw
    pw=$(random_password); p12pw=$(random_password)
    cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
        -config "$TMP/cert.cnf" 2>/dev/null
    P12PW="$p12pw" openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
        -passout env:P12PW
    delete_item "$ACCT"; delete_item "$PENDING"
    add_item "$ACCT" "$pw" || fail "Couldn't save the signing keychain's password in the login keychain."
    security delete-keychain "$KC" 2>/dev/null || rm -f "$KC"
    printf 'create-keychain -p %s %s\n' "$pw" "$KC" | sec || fail "Couldn't create $KC."
    unlocks "$pw" || fail "The new signing keychain doesn't unlock."
    printf 'import %s -k %s -P %s -T /usr/bin/codesign\n' "$TMP/id.p12" "$KC" "$p12pw" | sec
    printf 'set-key-partition-list -S apple-tool:,apple: -s -k %s %s\n' "$pw" "$KC" | sec
    echo "Created signing identity \"$NAME\"" >&2
    PASSWORD="$pw"
}

# Set up by an older build.sh with the fixed password: give it a random one, keeping the identity
# (and with it every approval macOS already gave NotchID). The new password is saved first and
# only promoted once the keychain has been seen to accept it, so it can never be lost.
migrate_legacy() {
    local new
    unlocks "$LEGACY_PASSWORD" || return 1
    new=$(random_password)
    delete_item "$PENDING"
    add_item "$PENDING" "$new" || fail "Couldn't save the signing keychain's password in the login keychain."
    printf 'set-keychain-password -o %s -p %s %s\n' "$LEGACY_PASSWORD" "$new" "$KC" | sec || {
        delete_item "$PENDING"; fail "Couldn't change the signing keychain's password."; }
    security lock-keychain "$KC"
    unlocks "$new" || fail "The signing keychain didn't take its new password. It is saved as \"$SVC\" / \"$PENDING\" in your login keychain."
    delete_item "$ACCT"
    add_item "$ACCT" "$new" || fail "Couldn't save the signing keychain's password. It is still saved as \"$SVC\" / \"$PENDING\"."
    delete_item "$PENDING"
    echo "Moved the signing keychain to a random password." >&2
    PASSWORD="$new"
}

PASSWORD=""
if ! security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
    create_identity
elif ! has_item "$ACCT" && ! has_item "$PENDING"; then
    migrate_legacy || fail "The signing keychain's password is unknown. Delete $KC and build again to make a new identity (macOS will then ask again for Accessibility and Keychain access)."
else
    acct="$ACCT"; has_item "$ACCT" || acct="$PENDING" # finish an interrupted migration
    echo "macOS will ask to let \"security\" use \"NotchID signing keychain\". Click Allow." >&2
    PASSWORD=$(read_item "$acct") || { echo "Access was denied; nothing was signed." >&2; exit 3; }
    unlocks "$PASSWORD" || fail "The saved password doesn't unlock $KC. Delete it and build again to make a new identity."
    if [[ "$acct" == "$PENDING" ]]; then delete_item "$ACCT"; add_item "$ACCT" "$PASSWORD" && delete_item "$PENDING"; fi
fi

unlocks "$PASSWORD" || fail "Couldn't unlock $KC."
security set-keychain-settings -lut 300 "$KC" # auto-lock after 5 minutes and on sleep
codesign --force --deep --sign "$NAME" --keychain "$KC" "$APP"
security lock-keychain "$KC"

# Recreate the login-keychain item with an empty access list (drops any "Always Allow").
delete_item "$PENDING"
add_item "$PENDING" "$PASSWORD" && delete_item "$ACCT" && add_item "$ACCT" "$PASSWORD" && delete_item "$PENDING" ||
    echo "⚠️  Couldn't refresh the saved signing password's access list; it stays as it was." >&2
