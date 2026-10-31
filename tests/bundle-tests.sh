#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/bundle.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -f "$LIB" ]]; then
    echo "Missing bundle library: $LIB" >&2
    exit 1
fi

# shellcheck source=../scripts/lib/bundle.sh
source "$LIB"

make_ca() {
    local name="$1" path="$2"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$TMP/$name.key" -out "$path" -days 2 \
        -subj "/CN=$name" -addext 'basicConstraints=critical,CA:TRUE' \
        >/dev/null 2>&1
}

make_leaf() {
    local name="$1" path="$2"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$TMP/$name.key" -out "$path" -days 2 \
        -subj "/CN=$name" -addext 'basicConstraints=critical,CA:FALSE' \
        >/dev/null 2>&1
}

cert_sha256() {
    openssl x509 -in "$1" -outform DER | sha256sum | awk '{print $1}'
}

make_ca MozillaFixture "$TMP/mozilla.pem"
make_ca ChromeTrustedFixture "$TMP/chrome-trusted.pem"
make_ca ChromeConstrainedFixture "$TMP/chrome-constrained.pem"
make_leaf NotACAFixture "$TMP/not-a-ca.pem"

: > "$TMP/out.pem"
: > "$TMP/seen.txt"
ca_bundle_add_pem "$TMP/mozilla.pem" "$TMP/out.pem" "$TMP/seen.txt" no
ca_bundle_add_pem "$TMP/mozilla.pem" "$TMP/out.pem" "$TMP/seen.txt" no
[[ "$(grep -c 'BEGIN CERTIFICATE' "$TMP/out.pem")" -eq 1 ]]
ca_bundle_validate "$TMP/out.pem"

cat "$TMP/chrome-trusted.pem" "$TMP/chrome-constrained.pem" > "$TMP/chrome.certs"
trusted_hash="$(cert_sha256 "$TMP/chrome-trusted.pem")"
constrained_hash="$(cert_sha256 "$TMP/chrome-constrained.pem")"
cat > "$TMP/chrome.md" <<EOF
## Trusted Roots
SHA 256 Hash | Subject
---|---
$trusted_hash | CN=ChromeTrustedFixture
## Constrained Roots
SHA 256 Hash | Subject
---|---
$constrained_hash | CN=ChromeConstrainedFixture
EOF

: > "$TMP/chrome-out.pem"
: > "$TMP/chrome-seen.txt"
ca_bundle_add_chrome "$TMP/chrome.certs" "$TMP/chrome.md" "$TMP/chrome-out.pem" "$TMP/chrome-seen.txt"
[[ "$(grep -c 'BEGIN CERTIFICATE' "$TMP/chrome-out.pem")" -eq 1 ]]
grep -q 'ChromeTrustedFixture' <(openssl x509 -in "$TMP/chrome-out.pem" -noout -subject)
! grep -q "$constrained_hash" "$TMP/chrome-seen.txt"

cat > "$TMP/chrome-incomplete.md" <<EOF
## Trusted Roots
SHA 256 Hash | Subject
---|---
$trusted_hash | CN=ChromeTrustedFixture
$(printf '0%.0s' {1..64}) | CN=MissingFixture
## Constrained Roots
EOF
: > "$TMP/incomplete-out.pem"
: > "$TMP/incomplete-seen.txt"
if ca_bundle_add_chrome "$TMP/chrome.certs" "$TMP/chrome-incomplete.md" "$TMP/incomplete-out.pem" "$TMP/incomplete-seen.txt"; then
    echo 'Incomplete Chrome store snapshot unexpectedly accepted' >&2
    exit 1
fi

printf 'not a PEM certificate\n' > "$TMP/invalid.pem"
if ca_bundle_add_pem "$TMP/invalid.pem" "$TMP/out.pem" "$TMP/seen.txt" no; then
    echo 'Invalid PEM unexpectedly accepted' >&2
    exit 1
fi

if ca_bundle_add_pem "$TMP/not-a-ca.pem" "$TMP/out.pem" "$TMP/seen.txt" yes; then
    echo 'Custom non-CA certificate unexpectedly accepted' >&2
    exit 1
fi

echo 'bundle tests passed'
