#!/bin/bash
set -euo pipefail

IDENTITY_NAME="${LLATSER_LISTEN_SIGN_IDENTITY:-Llatser Listen Local Code Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -Fq "$IDENTITY_NAME"; then
    echo "Code signing identity already exists: $IDENTITY_NAME"
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

CONFIG_FILE="$WORK_DIR/codesign.cnf"
KEY_FILE="$WORK_DIR/identity.key"
CERT_FILE="$WORK_DIR/identity.crt"
P12_FILE="$WORK_DIR/identity.p12"

cat > "$CONFIG_FILE" <<EOF
[ req ]
prompt = no
distinguished_name = dn
x509_extensions = codesign_ext

[ dn ]
CN = $IDENTITY_NAME

[ codesign_ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req \
    -new \
    -newkey rsa:2048 \
    -nodes \
    -keyout "$KEY_FILE" \
    -x509 \
    -days 3650 \
    -out "$CERT_FILE" \
    -config "$CONFIG_FILE"

/usr/bin/openssl pkcs12 \
    -export \
    -out "$P12_FILE" \
    -inkey "$KEY_FILE" \
    -in "$CERT_FILE" \
    -passout pass:

security import "$P12_FILE" \
    -k "$KEYCHAIN" \
    -P "" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$CERT_FILE"

if ! security find-identity -v -p codesigning | grep -Fq "$IDENTITY_NAME"; then
    echo "Created certificate, but macOS does not list it as a valid code-signing identity."
    exit 1
fi

echo "Created code signing identity: $IDENTITY_NAME"
