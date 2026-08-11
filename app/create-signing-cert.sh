#!/bin/bash
# Creates a stable, self-signed code-signing identity in your login keychain so
# macOS remembers Screen Recording / Microphone grants across rebuilds.
#
# Why: ad-hoc signing (`codesign --sign -`) produces a new signature every
# build, so TCC treats each rebuild as "a new app" and drops the permission.
# A self-signed cert gives a stable designated requirement that TCC remembers.
#
# Safe to re-run: it no-ops if the identity already exists. Requires no Apple
# Developer account. You will be asked for your macOS login password once (so
# codesign can use the key non-interactively) and may get one Keychain trust
# prompt.
set -euo pipefail

CERT_NAME="${MEETGPT_SIGN_ID:-MeetGPT Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo ">> code-signing identity \"$CERT_NAME\" already exists — nothing to do"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo ">> generating self-signed code-signing certificate \"$CERT_NAME\""
cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints   = critical, CA:false
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.conf" >/dev/null 2>&1

# `-legacy` writes a PKCS12 MAC that Apple's Security framework can import;
# OpenSSL 3.x defaults to a newer algorithm `security import` rejects.
openssl pkcs12 -export -legacy -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$CERT_NAME" -passout pass:meetgpt >/dev/null 2>&1

# `-T /usr/bin/codesign` puts codesign in the key's ACL so it can sign without
# a prompt. The cert is left UNtrusted on purpose: codesign signs fine with an
# untrusted self-signed cert, and macOS TCC keys on the cert's stable identity
# regardless of keychain trust — which is exactly what makes grants persist.
echo ">> importing into login keychain"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P meetgpt \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Sierra+ ignores -T alone for codesign; partition list is what stops the
# "codesign wants to access key … in your keychain" dialog on every build.
# Empty -k works when the login keychain is already unlocked in this session.
if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1; then
    echo ">> key partition list updated — codesign should not re-prompt"
else
    echo ">> note: could not update key partition list non-interactively."
    echo "   On the first build, click \"Always Allow\" once for \"$CERT_NAME\"."
fi

echo ""
echo ">> done — identity \"$CERT_NAME\" created. Now build with it:"
echo "     ./build.sh"
echo "   build.sh auto-detects \"$CERT_NAME\" (even untrusted)."
