#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TEST_ROOT="$TMP/root"
APP="$TEST_ROOT/app"
STATE="$TEST_ROOT/state"
TARGET="$TEST_ROOT/etc/ssl/certs/ca-certificates.crt"
HOOK="$TEST_ROOT/var/lib/webosbrew/init.d/55-ca-bundle-manager"
mkdir -p "$APP/scripts/lib" "$STATE/sources" "$(dirname "$TARGET")"
cp "$ROOT/scripts/ca-manager.sh" "$APP/scripts/ca-manager.sh"
cp "$ROOT/scripts/boot-hook.sh" "$APP/scripts/boot-hook.sh"
cp "$ROOT/scripts/lib/bundle.sh" "$APP/scripts/lib/bundle.sh"
chmod 755 "$APP/scripts/ca-manager.sh"

make_ca() {
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$TMP/$1.key" -out "$2" -days 2 \
        -subj "/CN=$1" -addext 'basicConstraints=critical,CA:TRUE' \
        >/dev/null 2>&1
}

cert_hash() {
    openssl x509 -in "$1" -outform DER | sha256sum | awk '{print $1}'
}

run_manager() {
    manager="$APP/scripts/ca-manager.sh"
    if [ -r "$STATE/current.version" ]; then
        release_id=$(cat "$STATE/current.version")
        manager="$STATE/releases/$release_id/ca-manager.sh"
    fi
    CA_MANAGER_TESTING=1 CA_MANAGER_TEST_ROOT="$TEST_ROOT" sh "$manager" "$@"
}

make_ca StockFixture "$TMP/stock.pem"
make_ca MozillaFixture "$STATE/sources/mozilla.pem"
cp "$TMP/stock.pem" "$TARGET"
run_manager bootstrap
release_id=$(cat "$STATE/current.version")
test -x "$STATE/releases/$release_id/ca-manager.sh"
test -r "$STATE/releases/$release_id/lib/bundle.sh"
test -r "$STATE/releases/$release_id/boot-hook.sh"
test "$(stat -c '%a' "$STATE")" = 700
test "$(stat -c '%a' "$STATE/releases/$release_id")" = 700
test "$(stat -c '%a' "$STATE/releases/$release_id/ca-manager.sh")" = 700
test "$(stat -c '%a' "$STATE/releases/$release_id/lib/bundle.sh")" = 600
run_manager bootstrap
test "$(cat "$STATE/current.version")" = "$release_id"
payload=$(printf 'mozilla=1\nchrome=0\ncustom_path_b64=\n' | base64 | tr -d '\r\n')
run_manager configure "$payload"
status=$(run_manager status)
printf '%s\n' "$status"
printf '%s\n' "$status" | grep -qx 'mozilla=1'
printf '%s\n' "$status" | grep -qx 'chrome=0'
run_manager apply

status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'active=1'
printf '%s\n' "$status" | grep -qx 'mounted=1'
printf '%s\n' "$status" | grep -qx 'boot_checks=0'
printf '%s\n' "$status" | grep -qx 'certificate_count=1'
test -x "$HOOK"
cmp "$APP/scripts/boot-hook.sh" "$HOOK"
CA_MANAGER_TESTING=1 CA_MANAGER_TEST_ROOT="$TEST_ROOT" sh "$HOOK"
test "$(sha256sum "$TARGET" | awk '{print $1}')" = "$(sha256sum "$STATE/active-ca.pem" | awk '{print $1}')"
test "$(sha256sum "$TARGET" | awk '{print $1}')" != "$(sha256sum "$STATE/stock-ca.pem" | awk '{print $1}')"
touch "$STATE/test-foreign-mounted"
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'mounted=0'
printf '%s\n' "$status" | grep -qx 'foreign_mount=1'
if run_manager restore; then
    echo 'Restore unexpectedly unmounted a foreign CA mount' >&2
    exit 1
fi
rm -f "$STATE/test-foreign-mounted"

previous_hash=$(sha256sum "$STATE/active-ca.pem" | awk '{print $1}')
target_hash=$(sha256sum "$TARGET" | awk '{print $1}')
if CA_MANAGER_TEST_FAIL_UNMOUNT=1 run_manager apply; then
    echo 'Apply unexpectedly succeeded with unmount failure injection' >&2
    exit 1
fi
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'active=1'
printf '%s\n' "$status" | grep -qx 'mounted=1'
test "$(sha256sum "$STATE/active-ca.pem" | awk '{print $1}')" = "$previous_hash"
test "$(sha256sum "$TARGET" | awk '{print $1}')" = "$target_hash"

make_ca FailedApplyFixture "$STATE/sources/mozilla.pem"
if CA_MANAGER_TEST_FAIL_MOUNT=1 run_manager apply; then
    echo 'Apply unexpectedly succeeded with mount failure injection' >&2
    exit 1
fi
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'active=1'
printf '%s\n' "$status" | grep -qx 'mounted=0'
test "$(sha256sum "$STATE/active-ca.pem" | awk '{print $1}')" = "$previous_hash"
run_manager startup
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'mounted=1'

if CA_MANAGER_TEST_FAIL_ACTIVE_FLAG=1 run_manager restore; then
    echo 'Restore unexpectedly succeeded with active-flag failure injection' >&2
    exit 1
fi
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'active=1'
printf '%s\n' "$status" | grep -qx 'mounted=1'

if CA_MANAGER_TEST_FAIL_SAVE=1 run_manager restore; then
    echo 'Restore unexpectedly succeeded with state-save failure injection' >&2
    exit 1
fi
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'active=1'
printf '%s\n' "$status" | grep -qx 'mounted=1'
test -x "$HOOK"

make_ca UpdatedMozillaFixture "$STATE/sources/mozilla.pem"
active_hash=$(sha256sum "$STATE/active-ca.pem" | awk '{print $1}')
run_manager boot-checks on
run_manager startup
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'boot_checks=1'
printf '%s\n' "$status" | grep -qx 'staged=1'
test "$(sha256sum "$STATE/active-ca.pem" | awk '{print $1}')" = "$active_hash"
run_manager boot-checks off

rm -f "$STATE/test-mounted"
cp "$STATE/stock-ca.pem" "$TARGET"
run_manager startup
test "$(sha256sum "$TARGET" | awk '{print $1}')" = "$active_hash"

if CA_MANAGER_TEST_FAIL_UNMOUNT=1 run_manager restore; then
    echo 'Restore unexpectedly succeeded with unmount failure injection' >&2
    exit 1
fi
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'active=0'
printf '%s\n' "$status" | grep -qx 'mounted=1'
run_manager restore
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'active=0'
printf '%s\n' "$status" | grep -qx 'mounted=0'
printf '%s\n' "$status" | grep -qx 'boot_checks=0'
test ! -e "$HOOK"
test "$(sha256sum "$TARGET" | awk '{print $1}')" = "$(sha256sum "$STATE/stock-ca.pem" | awk '{print $1}')"

run_manager configure "$payload"
if CA_MANAGER_TEST_FAIL_HOOK=1 run_manager apply; then
    echo 'Apply unexpectedly succeeded with hook failure injection' >&2
    exit 1
fi
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'active=0'
printf '%s\n' "$status" | grep -qx 'mounted=0'
test ! -e "$HOOK"
test "$(sha256sum "$TARGET" | awk '{print $1}')" = "$(sha256sum "$STATE/stock-ca.pem" | awk '{print $1}')"

run_manager configure "$payload"
run_manager apply
printf 'corrupt config\n' > "$STATE/config"
run_manager restore
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'active=0'
printf '%s\n' "$status" | grep -qx 'mounted=0'
test "$(sha256sum "$TARGET" | awk '{print $1}')" = "$(sha256sum "$STATE/stock-ca.pem" | awk '{print $1}')"

make_ca CustomFixture "$TMP/custom trust.pem"
custom_path_b64=$(printf '%s' "$TMP/custom trust.pem" | base64 | tr -d '\r\n')
custom_payload=$(printf 'mozilla=0\nchrome=0\ncustom_path_b64=%s\n' "$custom_path_b64" | base64 | tr -d '\r\n')
run_manager configure "$custom_payload"
run_manager apply
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'mozilla=0'
printf '%s\n' "$status" | grep -qx 'certificate_count=1'
run_manager restore
test "$(sha256sum "$TARGET" | awk '{print $1}')" = "$(sha256sum "$STATE/stock-ca.pem" | awk '{print $1}')"

make_ca ChromeTrustedFixture "$TMP/chrome-trusted.pem"
make_ca ChromeConstrainedFixture "$TMP/chrome-constrained.pem"
cat "$TMP/chrome-trusted.pem" "$TMP/chrome-constrained.pem" > "$STATE/sources/chrome.certs"
trusted_hash=$(cert_hash "$TMP/chrome-trusted.pem")
constrained_hash=$(cert_hash "$TMP/chrome-constrained.pem")
cat > "$STATE/sources/chrome.md" <<EOF
## Trusted Roots
SHA 256 Hash | Subject
---|---
$trusted_hash | CN=ChromeTrustedFixture
## Constrained Roots
SHA 256 Hash | Subject
---|---
$constrained_hash | CN=ChromeConstrainedFixture
EOF
chrome_payload=$(printf 'mozilla=0\nchrome=1\ncustom_path_b64=\n' | base64 | tr -d '\r\n')
run_manager configure "$chrome_payload"
run_manager apply
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'mozilla=0'
printf '%s\n' "$status" | grep -qx 'certificate_count=1'
openssl x509 -in "$STATE/active-ca.pem" -noout -subject | grep -q ChromeTrustedFixture
run_manager restore

if CA_MANAGER_TEST_FAIL_HOOK=1 run_manager boot-checks on; then
    echo 'Boot checks unexpectedly enabled without a startup hook' >&2
    exit 1
fi
status=$(run_manager status)
printf '%s\n' "$status" | grep -qx 'boot_checks=0'
test ! -e "$HOOK"

run_manager boot-checks on
printf '\n# tampered\n' >> "$HOOK"
if run_manager boot-checks off; then
    echo 'Modified startup hook was unexpectedly removed' >&2
    exit 1
fi
test -f "$HOOK"
rm -f "$HOOK" "$STATE/boot-hook.sha256"
run_manager boot-checks on
rm -rf "$APP"
CA_MANAGER_TESTING=1 CA_MANAGER_TEST_ROOT="$TEST_ROOT" sh "$HOOK"
test ! -e "$HOOK"

echo 'lifecycle tests passed'
