#!/bin/zsh
# Creates a stable self-signed code-signing identity in the login keychain so
# AskMax keeps the SAME code signature across rebuilds. That makes macOS
# permissions (Full Disk Access, Automation, Screen Recording) persist instead
# of resetting every build the way ad-hoc signing does.
set -euo pipefail

CN="AskMax Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# find-identity hides self-signed/untrusted certs, so check by certificate name.
if security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ signing identity '$CN' already exists"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Use the SYSTEM OpenSSL (LibreSSL). Homebrew's OpenSSL 3 writes a PKCS#12 that
# macOS's `security import` rejects with "MAC verification failed".
SSL=/usr/bin/openssl

cat > "$WORK/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CN
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

"$SSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cfg" 2>/dev/null

"$SSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout pass:askmax -name "$CN" 2>/dev/null

# -A allows any app (incl. codesign) to use the key without a per-use prompt.
security import "$WORK/id.p12" -k "$KEYCHAIN" -P askmax -A -T /usr/bin/codesign

echo "✓ created signing identity '$CN'"
