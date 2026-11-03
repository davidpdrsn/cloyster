#!/bin/sh
# Creates the self-signed certificate Cloyster is signed with, unless it already exists. macOS ties
# the Accessibility permission to the signing identity, so a stable one keeps it across rebuilds.
set -eu

name="Cloyster Self-Signed"
security find-certificate -c "$name" > /dev/null 2>&1 && exit 0

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
password=$(openssl rand -hex 16)

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" -subj "/CN=$name" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"
/usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -out "$dir/identity.p12" -passout "pass:$password"
security import "$dir/identity.p12" -P "$password" -T /usr/bin/codesign
