#!/bin/bash
# Creates a local, self-signed code-signing identity in its own keychain so that macOS permissions
# (Accessibility, Camera) and Keychain access survive rebuilds. The private key never leaves this Mac.
set -euo pipefail
KC="$HOME/Library/Keychains/notchid-signing.keychain-db"
NAME="NotchID Local Signing"
if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then exit 0; fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
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
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:notchid
security create-keychain -p notchid "$KC" 2>/dev/null || true
security set-keychain-settings "$KC"
security unlock-keychain -p notchid "$KC"
security import "$TMP/id.p12" -k "$KC" -P notchid -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k notchid "$KC" >/dev/null
echo "Created signing identity \"$NAME\""
