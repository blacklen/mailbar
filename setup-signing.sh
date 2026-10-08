#!/bin/bash
# One-time setup: creates a private code-signing certificate in your login Keychain, so every
# build of MailBar has the same identity and macOS stops asking for Keychain access after rebuilds.
set -euo pipefail

NAME="MailBar Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl # macOS's LibreSSL writes .p12 files that `security import` can read

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists. Nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/cert.conf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

PASSWORD="$(uuidgen)" # only protects the temporary .p12 file
"$OPENSSL" pkcs12 -export -name "$NAME" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/identity.p12" -passout "pass:$PASSWORD"

# -T lets codesign use the key without asking each time.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign

echo "Created \"$NAME\" in your login Keychain."
