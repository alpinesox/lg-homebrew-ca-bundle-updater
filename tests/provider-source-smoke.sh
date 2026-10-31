#!/bin/sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../scripts/lib/bundle.sh
. "$ROOT/scripts/lib/bundle.sh"

curl -fLsS --proto '=https' --tlsv1.2 -o "$TMP/mozilla.sha256" https://curl.se/ca/cacert.pem.sha256
curl -fLsS --proto '=https' --tlsv1.2 -o "$TMP/mozilla.pem" https://curl.se/ca/cacert.pem
expected=$(awk 'NR == 1 { print $1; exit }' "$TMP/mozilla.sha256")
actual=$(sha256sum "$TMP/mozilla.pem" | awk '{print $1}')
[ "$actual" = "$expected" ]
ca_bundle_validate "$TMP/mozilla.pem"

base=https://chromium.googlesource.com/chromium/src/+/main/net/data/ssl/chrome_root_store
curl -fLsS --proto '=https' --tlsv1.2 --cacert "$TMP/mozilla.pem" "$base/root_store.certs?format=TEXT" | base64 -d > "$TMP/chrome.certs"
curl -fLsS --proto '=https' --tlsv1.2 --cacert "$TMP/mozilla.pem" "$base/root_store.md?format=TEXT" | base64 -d > "$TMP/chrome.md"
: > "$TMP/chrome.pem"
: > "$TMP/seen.txt"
ca_bundle_add_chrome "$TMP/chrome.certs" "$TMP/chrome.md" "$TMP/chrome.pem" "$TMP/seen.txt"
ca_bundle_validate "$TMP/chrome.pem"

version=$(sed -n 's/^Version:[[:space:]]*//p' "$TMP/chrome.md" | sed -n '1p')
printf 'Mozilla SHA-256 verified; Chrome Root Store version %s: %s unconstrained roots\n' "$version" "$(wc -l < "$TMP/seen.txt" | tr -d ' ')"
