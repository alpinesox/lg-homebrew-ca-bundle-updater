#!/bin/sh
set -u
umask 077

APP_ID=com.alpinesox.cabundlemanager
if [ "${CA_MANAGER_TESTING:-0}" = 1 ]; then
    TEST_ROOT=${CA_MANAGER_TEST_ROOT:?}
    APP_ROOT=$TEST_ROOT/app
    TARGET=$TEST_ROOT/etc/ssl/certs/ca-certificates.crt
    HOOK=$TEST_ROOT/var/lib/webosbrew/init.d/55-ca-bundle-manager
else
    APP_ROOT=/media/developer/apps/usr/palm/applications/$APP_ID
    TARGET=/etc/ssl/certs/ca-certificates.crt
    HOOK=/var/lib/webosbrew/init.d/55-ca-bundle-manager
fi

STATE=$APP_ROOT/state
SOURCES=$STATE/sources
CONFIG=$STATE/config
STOCK=$STATE/stock-ca.pem
ACTIVE=$STATE/active-ca.pem
ACTIVE_FLAG=$STATE/active.enabled
STAGED=$STATE/staged-ca.pem
LIB=$APP_ROOT/scripts/lib/bundle.sh
LOG=$STATE/last-check.log
HOOK_HASH=$STATE/boot-hook.sha256
FETCH_CA=

. "$LIB" || exit 1

fail() {
    echo "ERROR: $*" >&2
    return 1
}

require_root() {
    [ "${CA_MANAGER_TESTING:-0}" = 1 ] && return 0
    [ "$(id -u)" = 0 ] || fail 'Root access is required through Homebrew Channel.'
}

ensure_state() {
    mkdir -p "$SOURCES" "$(dirname "$TARGET")" || return 1
    chmod 700 "$STATE" 2>/dev/null || true
}

set_last_check() {
    case "$1" in staged|staged-stale|unchanged|stale|source-error|invalid|disabled|not-run) ;; *) return 1 ;; esac
    printf '%s\n' "$1" > "$STATE/last-check.tmp.$$" && mv -f "$STATE/last-check.tmp.$$" "$STATE/last-check"
}

load_config() {
    mozilla=1
    chrome=0
    boot_checks=0
    active=0
    custom_path_b64=
    [ -f "$CONFIG" ] || return 0
    seen_mozilla=0
    seen_chrome=0
    seen_boot=0
    seen_custom=0
    while IFS='=' read -r key value || [ -n "${key:-}" ]; do
        case "$key" in
            mozilla)
                [ "$seen_mozilla" = 0 ] && case "$value" in 0|1) mozilla=$value ;; *) return 1 ;; esac || return 1
                seen_mozilla=1
                ;;
            chrome)
                [ "$seen_chrome" = 0 ] && case "$value" in 0|1) chrome=$value ;; *) return 1 ;; esac || return 1
                seen_chrome=1
                ;;
            boot_checks)
                [ "$seen_boot" = 0 ] && case "$value" in 0|1) boot_checks=$value ;; *) return 1 ;; esac || return 1
                seen_boot=1
                ;;
            custom_path_b64)
                [ "$seen_custom" = 0 ] || return 1
                case "$value" in *[!A-Za-z0-9+/=]*) return 1 ;; esac
                custom_path_b64=$value
                seen_custom=1
                ;;
            *) return 1 ;;
        esac
    done < "$CONFIG"
    [ "$seen_mozilla$seen_chrome$seen_boot$seen_custom" = 1111 ] || return 1
    if [ -f "$ACTIVE_FLAG" ]; then
        active=$(cat "$ACTIVE_FLAG")
        [ "$active" = 1 ] || return 1
    fi
}

save_config() {
    if [ "${CA_MANAGER_TESTING:-0}" = 1 ] && [ "${CA_MANAGER_TEST_FAIL_SAVE:-0}" = 1 ]; then return 1; fi
    temp_config=$STATE/config.tmp.$$
    {
        printf 'mozilla=%s\n' "$mozilla"
        printf 'chrome=%s\n' "$chrome"
        printf 'boot_checks=%s\n' "$boot_checks"
        printf 'custom_path_b64=%s\n' "$custom_path_b64"
    } > "$temp_config" || return 1
    chmod 600 "$temp_config" || return 1
    mv -f "$temp_config" "$CONFIG"
}

set_active() {
    if [ "${CA_MANAGER_TESTING:-0}" = 1 ] && [ "${CA_MANAGER_TEST_FAIL_ACTIVE_FLAG:-0}" = 1 ]; then return 1; fi
    if [ "$1" = 1 ]; then
        active_temp=$STATE/active.enabled.tmp.$$
        printf '1\n' > "$active_temp" && chmod 600 "$active_temp" && mv -f "$active_temp" "$ACTIVE_FLAG"
    else
        rm -f "$ACTIVE_FLAG"
    fi
}

remove_hook_if_unused() {
    if [ "$active" = 0 ] && [ "$boot_checks" = 0 ]; then remove_hook; fi
}

parse_selection() {
    input_file=$1
    mozilla=
    chrome=
    custom_path_b64=
    seen_mozilla=0
    seen_chrome=0
    seen_custom=0
    while IFS='=' read -r key value || [ -n "${key:-}" ]; do
        case "$key" in
            mozilla)
                [ "$seen_mozilla" = 0 ] || return 1
                case "$value" in 0|1) mozilla=$value ;; *) return 1 ;; esac
                seen_mozilla=1
                ;;
            chrome)
                [ "$seen_chrome" = 0 ] || return 1
                case "$value" in 0|1) chrome=$value ;; *) return 1 ;; esac
                seen_chrome=1
                ;;
            custom_path_b64)
                [ "$seen_custom" = 0 ] || return 1
                case "$value" in *[!A-Za-z0-9+/=]*) return 1 ;; esac
                custom_path_b64=$value
                seen_custom=1
                ;;
            *) return 1 ;;
        esac
    done < "$input_file"
    [ "$seen_mozilla$seen_chrome$seen_custom" = 111 ]
}

target_is_mounted() {
    if [ "${CA_MANAGER_TESTING:-0}" = 1 ]; then
        [ -f "$STATE/test-mounted" ]
        return $?
    fi
    awk -v target="$TARGET" '$2 == target { found = 1 } END { exit !found }' /proc/mounts
}

manager_mount() {
    source_file=$1
    if [ "${CA_MANAGER_TESTING:-0}" = 1 ]; then
        [ "${CA_MANAGER_TEST_FAIL_MOUNT:-0}" != 1 ] || return 1
        cp "$source_file" "$TARGET" && : > "$STATE/test-mounted"
    else
        mount --bind "$source_file" "$TARGET"
    fi
}

manager_unmount() {
    if [ "${CA_MANAGER_TESTING:-0}" = 1 ]; then
        [ "${CA_MANAGER_TEST_FAIL_UNMOUNT:-0}" != 1 ] || return 1
        cp "$STOCK" "$TARGET" && rm -f "$STATE/test-mounted"
    else
        umount "$TARGET"
    fi
}

ensure_stock() {
    [ -s "$STOCK" ] && ca_bundle_validate "$STOCK" && return 0
    target_is_mounted && return 1
    [ -r "$TARGET" ] || return 1
    stock_temp=$STATE/stock-ca.tmp.$$
    cp -p "$TARGET" "$stock_temp" || return 1
    ca_bundle_validate "$stock_temp" || { rm -f "$stock_temp"; return 1; }
    mv -f "$stock_temp" "$STOCK"
}

valid_sha256() {
    case "$1" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#1}" -eq 64 ]
}

curl_to() {
    url=$1
    output=$2
    curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 20 \
        --cacert "${FETCH_CA:-$STOCK}" -o "$output" "$url"
}

fetch_mozilla() {
    cache=$SOURCES/mozilla.pem
    sum_temp=$SOURCES/mozilla.sha256.tmp.$$
    pem_temp=$SOURCES/mozilla.pem.tmp.$$
    if [ "${CA_MANAGER_TESTING:-0}" = 1 ]; then
        [ -s "$cache" ] && ca_bundle_validate "$cache"
        return $?
    fi
    if curl_to https://curl.se/ca/cacert.pem.sha256 "$sum_temp" && curl_to https://curl.se/ca/cacert.pem "$pem_temp"; then
        expected=$(awk 'NR == 1 { print $1; exit }' "$sum_temp")
        actual=$(sha256sum "$pem_temp" | awk '{print $1}')
        if valid_sha256 "$expected" && [ "$actual" = "$expected" ] && ca_bundle_validate "$pem_temp"; then
            mv -f "$pem_temp" "$cache" || return 1
            printf '%s\n' "$expected" > "$SOURCES/mozilla.sha256"
            rm -f "$sum_temp"
            return 0
        fi
    fi
    rm -f "$sum_temp" "$pem_temp"
    if [ -s "$cache" ] && ca_bundle_validate "$cache"; then
        source_stale=1
        return 0
    fi
    return 1
}

use_cached_chrome() {
    cached_id=$(cat "$SOURCES/chrome.current" 2>/dev/null)
    case "$cached_id" in *[!0-9a-f-]*|'') return 1 ;; esac
    cached_dir=$SOURCES/chrome-$cached_id
    [ -s "$cached_dir/root_store.certs" ] && [ -s "$cached_dir/root_store.md" ] || return 1
    cached_seen=$SOURCES/chrome-cached-seen.$$
    : > "$cached_seen"
    if ca_bundle_add_chrome "$cached_dir/root_store.certs" "$cached_dir/root_store.md" /dev/null "$cached_seen"; then
        rm -f "$cached_seen"
        source_stale=1
        return 0
    fi
    rm -f "$cached_seen"
    return 1
}

fetch_chrome() {
    if [ "${CA_MANAGER_TESTING:-0}" = 1 ]; then
        [ -s "$SOURCES/chrome.certs" ] && [ -s "$SOURCES/chrome.md" ]
        return $?
    fi
    temporary=$SOURCES/chrome.tmp.$$
    mkdir -p "$temporary" || return 1
    base_url=https://chromium.googlesource.com/chromium/src/+/main/net/data/ssl/chrome_root_store
    if ! curl_to "$base_url/root_store.certs?format=TEXT" "$temporary/root_store.certs.b64" ||
        ! curl_to "$base_url/root_store.md?format=TEXT" "$temporary/root_store.md.b64" ||
        ! base64 -d < "$temporary/root_store.certs.b64" > "$temporary/root_store.certs" ||
        ! base64 -d < "$temporary/root_store.md.b64" > "$temporary/root_store.md" ||
        ! ca_bundle_validate "$temporary/root_store.certs"; then
        rm -rf "$temporary"
        use_cached_chrome
        return $?
    fi
    version=$(sed -n 's/^Version:[[:space:]]*//p' "$temporary/root_store.md" | sed -n '1p')
    case "$version" in *[!0-9]*|'') rm -rf "$temporary"; use_cached_chrome; return $? ;; esac
    validation_seen=$temporary/seen.txt
    : > "$validation_seen"
    if ! ca_bundle_add_chrome "$temporary/root_store.certs" "$temporary/root_store.md" /dev/null "$validation_seen"; then
        rm -rf "$temporary"
        use_cached_chrome
        return $?
    fi
    rm -f "$validation_seen" "$temporary/root_store.certs.b64" "$temporary/root_store.md.b64"
    digest=$(cat "$temporary/root_store.certs" "$temporary/root_store.md" | sha256sum | awk '{print $1}')
    source_id=$version-$digest
    destination=$SOURCES/chrome-$source_id
    if [ -d "$destination" ]; then
        rm -rf "$temporary"
    else
        mv "$temporary" "$destination" || { rm -rf "$temporary"; use_cached_chrome; return $?; }
    fi
    printf '%s\n' "$source_id" > "$SOURCES/chrome.current.tmp.$$"
    mv -f "$SOURCES/chrome.current.tmp.$$" "$SOURCES/chrome.current" || { rm -f "$SOURCES/chrome.current.tmp.$$"; use_cached_chrome; return $?; }
}

decode_custom_path() {
    [ -n "$custom_path_b64" ] || return 1
    case "$custom_path_b64" in *[!A-Za-z0-9+/=]*) return 1 ;; esac
    path_temp=$STATE/custom-path.tmp.$$
    printf '%s' "$custom_path_b64" | base64 -d > "$path_temp" 2>/dev/null || { rm -f "$path_temp"; return 1; }
    if LC_ALL=C grep -q '[[:cntrl:]]' "$path_temp"; then rm -f "$path_temp"; return 1; fi
    custom_path=$(cat "$path_temp")
    rm -f "$path_temp"
    case "$custom_path" in /*) ;; *) return 1 ;; esac
    [ -f "$custom_path" ] && [ -r "$custom_path" ]
}

refresh_sources() {
    source_error=0
    source_stale=0
    if [ -n "$custom_path_b64" ]; then
        if decode_custom_path; then
            custom_temp=$SOURCES/custom.pem.tmp.$$
            custom_seen=$SOURCES/custom-seen.tmp.$$
            : > "$custom_temp"
            : > "$custom_seen"
            if ca_bundle_add_pem "$custom_path" "$custom_temp" "$custom_seen" yes && ca_bundle_validate "$custom_temp"; then
                mv -f "$custom_temp" "$SOURCES/custom.pem" || source_error=1
            else
                rm -f "$custom_temp" "$custom_seen"
                source_error=1
            fi
            rm -f "$custom_seen"
        else
            source_error=1
        fi
    fi
    if [ "$source_error" = 0 ] && [ -n "$custom_path_b64" ]; then
        fetch_ca_temp=$SOURCES/fetch-ca.tmp.$$
        if cp "$STOCK" "$fetch_ca_temp" && cat "$SOURCES/custom.pem" >> "$fetch_ca_temp" && ca_bundle_validate "$fetch_ca_temp"; then
            FETCH_CA=$fetch_ca_temp
        else
            rm -f "$fetch_ca_temp"
            source_error=1
        fi
    fi
    if [ "$source_error" = 0 ]; then
        if [ "$mozilla" = 1 ]; then fetch_mozilla || source_error=1; fi
        if [ "$chrome" = 1 ]; then fetch_chrome || source_error=1; fi
    fi
    if [ -n "${fetch_ca_temp:-}" ]; then rm -f "$fetch_ca_temp"; fi
    FETCH_CA=
    [ "$source_error" = 0 ] || return 1
    [ "$mozilla" = 1 ] || [ "$chrome" = 1 ] || [ -n "$custom_path_b64" ]
}

build_candidate() {
    candidate_output=$1
    candidate_temp=$STATE/candidate.tmp.$$
    seen_temp=$STATE/seen.tmp.$$
    : > "$candidate_temp"
    : > "$seen_temp"
    if [ "$mozilla" = 1 ]; then
        ca_bundle_add_pem "$SOURCES/mozilla.pem" "$candidate_temp" "$seen_temp" no || { rm -f "$candidate_temp" "$seen_temp"; return 1; }
    fi
    if [ "$chrome" = 1 ]; then
        if [ "${CA_MANAGER_TESTING:-0}" = 1 ]; then
            chrome_certs=$SOURCES/chrome.certs
            chrome_markdown=$SOURCES/chrome.md
        else
            chrome_source_id=$(cat "$SOURCES/chrome.current" 2>/dev/null)
            case "$chrome_source_id" in *[!0-9a-f-]*|'') rm -f "$candidate_temp" "$seen_temp"; return 1 ;; esac
            chrome_certs=$SOURCES/chrome-$chrome_source_id/root_store.certs
            chrome_markdown=$SOURCES/chrome-$chrome_source_id/root_store.md
        fi
        ca_bundle_add_chrome "$chrome_certs" "$chrome_markdown" "$candidate_temp" "$seen_temp" || { rm -f "$candidate_temp" "$seen_temp"; return 1; }
    fi
    if [ -n "$custom_path_b64" ]; then
        ca_bundle_add_pem "$SOURCES/custom.pem" "$candidate_temp" "$seen_temp" yes || { rm -f "$candidate_temp" "$seen_temp"; return 1; }
    fi
    rm -f "$seen_temp"
    if ! ca_bundle_validate "$candidate_temp"; then rm -f "$candidate_temp"; return 1; fi
    mv -f "$candidate_temp" "$candidate_output"
}

install_hook() {
    mkdir -p "$(dirname "$HOOK")" || return 1
    hook_directory_is_safe || { fail 'Startup hook directory is not root-owned and protected.'; return 1; }
    if [ "${CA_MANAGER_TESTING:-0}" = 1 ] && [ "${CA_MANAGER_TEST_FAIL_HOOK:-0}" = 1 ]; then return 1; fi
    if [ -f "$HOOK" ]; then
        hook_is_owned || { fail 'A different or modified startup hook already uses the CA manager hook path.'; return 1; }
        if cmp -s "$APP_ROOT/scripts/boot-hook.sh" "$HOOK"; then return 0; fi
    fi
    if [ -e "$HOOK" ] && [ ! -f "$HOOK" ]; then fail 'A non-regular file uses the CA manager hook path.'; return 1; fi
    hook_temp=$HOOK.tmp.$$
    cp "$APP_ROOT/scripts/boot-hook.sh" "$hook_temp" || return 1
    chmod 755 "$hook_temp" || { rm -f "$hook_temp"; return 1; }
    mv -f "$hook_temp" "$HOOK" || { rm -f "$hook_temp"; return 1; }
    hook_hash=$(sha256sum "$HOOK" | awk '{print $1}')
    printf '%s\n' "$hook_hash" > "$HOOK_HASH.tmp.$$" && mv -f "$HOOK_HASH.tmp.$$" "$HOOK_HASH"
}

hook_is_owned() {
    [ -f "$HOOK" ] && [ ! -L "$HOOK" ] || return 1
    grep -q '^# CA-BUNDLE-MANAGER-BOOT-HOOK$' "$HOOK" || return 1
    if [ "${CA_MANAGER_TESTING:-0}" != 1 ]; then
        hook_uid=$(stat -c '%u' "$HOOK" 2>/dev/null) || return 1
        [ "$hook_uid" = 0 ] || return 1
        hook_mode=$(stat -c '%a' "$HOOK" 2>/dev/null) || return 1
        hook_mode_num=$((0$hook_mode))
        [ $((hook_mode_num & 022)) -eq 0 ] || return 1
    fi
    hook_actual=$(sha256sum "$HOOK" | awk '{print $1}')
    hook_expected=$(sha256sum "$APP_ROOT/scripts/boot-hook.sh" | awk '{print $1}')
    if [ -r "$HOOK_HASH" ] && [ "$(cat "$HOOK_HASH")" = "$hook_actual" ]; then return 0; fi
    [ "$hook_actual" = "$hook_expected" ]
}

hook_directory_is_safe() {
    [ "${CA_MANAGER_TESTING:-0}" = 1 ] && return 0
    hook_dir=$(dirname "$HOOK")
    hook_dir_uid=$(stat -c '%u' "$hook_dir" 2>/dev/null) || return 1
    [ "$hook_dir_uid" = 0 ] || return 1
    hook_dir_mode=$(stat -c '%a' "$hook_dir" 2>/dev/null) || return 1
    hook_dir_mode_num=$((0$hook_dir_mode))
    [ $((hook_dir_mode_num & 022)) -eq 0 ]
}

remove_hook() {
    [ -e "$HOOK" ] || return 0
    hook_directory_is_safe || { fail 'Startup hook directory is not root-owned and protected.'; return 1; }
    hook_is_owned || { fail 'Refusing to remove an unknown or modified startup hook.'; return 1; }
    rm -f "$HOOK" && rm -f "$HOOK_HASH"
}

run_apply() {
    ensure_state && ensure_stock || return 1
    load_config || return 1
    refresh_sources || { fail 'Could not refresh selected sources; active trust was not changed.'; return 1; }
    apply_candidate=$STATE/apply-candidate.$$
    build_candidate "$apply_candidate" || { fail 'The selected sources did not produce a valid CA bundle.'; return 1; }
    if target_is_mounted && [ "${CA_MANAGER_TESTING:-0}" != 1 ] && ! findmnt -T "$TARGET" -n -o SOURCE 2>/dev/null | grep -q 'active-ca.pem'; then
        rm -f "$apply_candidate"
        fail 'The CA path is mounted by another source; refusing to replace it.'
        return 1
    fi
    previous_active=$active
    if [ "$previous_active" = 1 ] && { [ ! -s "$ACTIVE" ] || ! ca_bundle_validate "$ACTIVE"; }; then
        previous_active=0
        set_active 0 || { rm -f "$apply_candidate"; return 1; }
    fi
    if [ -s "$ACTIVE" ]; then
        if ! cp -p "$ACTIVE" "$STATE/previous-ca.pem"; then rm -f "$apply_candidate"; return 1; fi
    fi
    cp "$apply_candidate" "$STATE/active-ca.tmp.$$" || { rm -f "$apply_candidate"; return 1; }
    rm -f "$apply_candidate"
    mv -f "$STATE/active-ca.tmp.$$" "$ACTIVE" || { rm -f "$STATE/active-ca.tmp.$$"; return 1; }
    if target_is_mounted; then
        if ! manager_unmount; then
            if [ "$previous_active" = 1 ] && [ -s "$STATE/previous-ca.pem" ]; then cp -f "$STATE/previous-ca.pem" "$ACTIVE"; fi
            fail 'Could not replace the existing CA mount; previous trust is still active.'
            return 1
        fi
    fi
    if ! install_hook; then
        rollback_ok=1
        if [ "$previous_active" = 1 ] && [ -s "$STATE/previous-ca.pem" ]; then
            cp -f "$STATE/previous-ca.pem" "$ACTIVE"
            manager_mount "$ACTIVE" || rollback_ok=0
        fi
        remove_hook_if_unused
        if [ "$rollback_ok" = 1 ] && [ "$previous_active" = 1 ]; then
            fail 'Could not update the boot hook; the previous approved bundle was restored.'
        elif [ "$rollback_ok" = 1 ]; then
            fail 'Could not install the boot hook; stock trust remains active.'
        else
            fail 'Could not install the boot hook or remount the previous bundle; stock trust is visible and the approved bundle will be retried at boot.'
        fi
        return 1
    fi
    if ! manager_mount "$ACTIVE"; then
        rollback_ok=1
        if [ "$previous_active" = 1 ] && [ -s "$STATE/previous-ca.pem" ]; then
            cp -f "$STATE/previous-ca.pem" "$ACTIVE"
            manager_mount "$ACTIVE" || rollback_ok=0
        fi
        if [ "$previous_active" = 0 ]; then remove_hook_if_unused; fi
        if [ "$rollback_ok" = 1 ] && [ "$previous_active" = 1 ]; then
            fail 'Apply failed; the previous approved bundle was restored.'
        elif [ "$rollback_ok" = 1 ]; then
            fail 'Apply failed; stock trust remains active.'
        else
            fail 'Apply failed and the previous bundle could not be remounted; stock trust is visible and the approved bundle will be retried at boot.'
        fi
        return 1
    fi
    if ! set_active 1; then
        rollback_ok=1
        manager_unmount || rollback_ok=0
        if [ "$previous_active" = 1 ] && [ -s "$STATE/previous-ca.pem" ]; then
            cp -f "$STATE/previous-ca.pem" "$ACTIVE"
            manager_mount "$ACTIVE" || rollback_ok=0
        fi
        if [ "$previous_active" = 0 ]; then remove_hook_if_unused; fi
        if [ "$rollback_ok" = 1 ] && [ "$previous_active" = 1 ]; then
            fail 'Could not persist the approved-bundle flag; previous trust was restored.'
        elif [ "$rollback_ok" = 1 ] && [ "$previous_active" = 0 ]; then
            fail 'Could not persist the approved-bundle flag; stock trust was restored.'
        elif [ "$previous_active" = 1 ]; then
            fail 'Could not persist the approved-bundle flag or remount previous trust; previous approved trust will be retried at boot.'
        elif [ "$rollback_ok" = 1 ]; then
            fail 'Could not persist the approved-bundle flag; stock trust remains visible and boot application is disabled.'
        else
            fail 'Could not persist the approved-bundle flag or complete rollback; reboot to expose stock trust.'
        fi
        return 1
    fi
    rm -f "$STAGED"
    if [ "$source_stale" = 1 ]; then
        echo "Applied $(grep -c 'BEGIN CERTIFICATE' "$ACTIVE") selected CA certificates using cached source data; an upstream check failed."
    else
        echo "Applied $(grep -c 'BEGIN CERTIFICATE' "$ACTIVE") selected CA certificates."
    fi
}

run_check() {
    ensure_state && ensure_stock || return 1
    load_config || return 1
    if ! refresh_sources; then
        set_last_check source-error || true
        echo 'Source check failed; active trust was not changed.'
        return 1
    fi
    if ! build_candidate "$STAGED"; then
        set_last_check invalid || true
        fail 'Selected sources did not produce a valid candidate.'
        return 1
    fi
    candidate_hash=$(sha256sum "$STAGED" | awk '{print $1}')
    active_hash=
    [ -s "$ACTIVE" ] && active_hash=$(sha256sum "$ACTIVE" | awk '{print $1}')
    if [ "$candidate_hash" = "$active_hash" ]; then
        rm -f "$STAGED"
        if [ "$source_stale" = 1 ]; then
            set_last_check stale || true
            echo 'No source updates were fetched; cached provider data is unchanged.'
        else
            set_last_check unchanged || true
            echo 'Selected trust sources are unchanged.'
        fi
    else
        if [ "$source_stale" = 1 ]; then
            set_last_check staged-stale || true
            echo "A candidate from cached source data was staged ($candidate_hash); an upstream check failed."
        else
            set_last_check staged || true
            echo "Candidate staged: $candidate_hash. Press Apply to change active trust."
        fi
    fi
}

run_status() {
    ensure_state || return 1
    load_config || return 1
    mounted=0
    if target_is_mounted; then
        if [ "${CA_MANAGER_TESTING:-0}" = 1 ] || findmnt -T "$TARGET" -n -o SOURCE 2>/dev/null | grep -q 'active-ca.pem'; then mounted=1; fi
    fi
    current_hash=
    cert_count=0
    if [ "$mounted" = 1 ] && [ -s "$ACTIVE" ] && ca_bundle_validate "$ACTIVE"; then
        current_hash=$(sha256sum "$ACTIVE" | awk '{print $1}')
        cert_count=$(grep -c 'BEGIN CERTIFICATE' "$ACTIVE")
    fi
    staged=0
    [ -s "$STAGED" ] && staged=1
    last_check=not-run
    [ -r "$STATE/last-check" ] && last_check=$(cat "$STATE/last-check")
    case "$last_check" in staged|staged-stale|unchanged|stale|source-error|invalid|disabled|not-run) ;; *) last_check=invalid ;; esac
    printf 'active=%s\nmounted=%s\nboot_checks=%s\nmozilla=%s\nchrome=%s\ncustom_path_b64=%s\nactive_sha256=%s\ncertificate_count=%s\nstaged=%s\n' \
        "$active" "$mounted" "$boot_checks" "$mozilla" "$chrome" "$custom_path_b64" "$current_hash" "$cert_count" "$staged"
    printf 'last_check=%s\n' "$last_check"
}

run_restore() {
    ensure_state || return 1
    load_config || return 1
    if target_is_mounted; then
        if [ "${CA_MANAGER_TESTING:-0}" != 1 ] && ! findmnt -T "$TARGET" -n -o SOURCE 2>/dev/null | grep -q 'active-ca.pem'; then
            fail 'The CA path is mounted by another source; refusing to unmount it.'
            return 1
        fi
    fi
    previous_boot_checks=$boot_checks
    boot_checks=0
    if ! save_config; then
        boot_checks=$previous_boot_checks
        fail 'Could not disable boot behavior; active trust was not changed.'
        return 1
    fi
    if ! set_active 0; then
        boot_checks=$previous_boot_checks
        save_config || true
        fail 'Could not disable boot application; current trust was not changed.'
        return 1
    fi
    set_last_check disabled || true
    hook_removed=1
    remove_hook || hook_removed=0
    if target_is_mounted && ! manager_unmount; then
        fail 'Boot application is disabled, but the live bind mount could not be removed. Reboot to expose stock trust.'
        return 1
    fi
    rm -f "$STAGED"
    if [ "$hook_removed" = 0 ]; then
        fail 'Stock trust is restored, but an unknown startup hook remains at the CA manager path; inspect it manually.'
        return 1
    fi
    echo 'Restored stock trust. The original system bundle was not modified.'
}

run_boot_checks() {
    ensure_state || return 1
    load_config || return 1
    previous_boot_checks=$boot_checks
    case "${1:-}" in on) boot_checks=1 ;; off) boot_checks=0 ;; *) fail 'Use boot-checks on|off.'; return 1 ;; esac
    save_config || return 1
    if [ "$active" = 1 ] || [ "$boot_checks" = 1 ]; then
        if ! install_hook; then
            boot_checks=$previous_boot_checks
            save_config || true
            fail 'Could not install the startup hook; boot-check setting was not changed.'
            return 1
        fi
    elif ! remove_hook; then
        fail 'Boot checks are disabled, but the startup hook could not be removed.'
        return 1
    fi
    [ "$boot_checks" = 1 ] || set_last_check disabled || true
    echo "Boot-time checks $([ "$boot_checks" = 1 ] && echo enabled || echo disabled)."
}

run_startup() {
    ensure_state || return 1
    load_config || return 1
    if [ "$active" = 0 ] && [ "$boot_checks" = 0 ]; then
        remove_hook
        return $?
    fi
    if [ "$active" = 1 ] && [ -s "$ACTIVE" ] && ca_bundle_validate "$ACTIVE"; then
        if ! target_is_mounted; then manager_mount "$ACTIVE" || echo 'Could not mount approved CA bundle; stock trust remains active.' >&2; fi
    fi
    if [ "$boot_checks" = 1 ]; then
        nohup "$APP_ROOT/scripts/ca-manager.sh" check > "$LOG" 2>&1 </dev/null &
    fi
}

run_configure() {
    ensure_state || return 1
    [ "$#" -eq 1 ] || { fail 'Invalid configuration payload.'; return 1; }
    case "$1" in *[!A-Za-z0-9+/=]*) fail 'Invalid configuration encoding.'; return 1 ;; esac
    payload=$STATE/config-payload.tmp.$$
    printf '%s' "$1" | base64 -d > "$payload" 2>/dev/null || { rm -f "$payload"; fail 'Invalid configuration encoding.'; return 1; }
    parse_selection "$payload" || { rm -f "$payload"; fail 'Invalid source selection.'; return 1; }
    selected_mozilla=$mozilla
    selected_chrome=$chrome
    selected_custom_path_b64=$custom_path_b64
    rm -f "$payload"
    load_config || return 1
    mozilla=$selected_mozilla
    chrome=$selected_chrome
    custom_path_b64=$selected_custom_path_b64
    save_config
    echo 'Selection saved. Press Apply to activate it.'
}

main() {
    require_root || return 1
    ensure_state || return 1
    action=${1:-startup}
    shift || true
    case "$action" in
        status) run_status ;;
        configure) run_configure "$@" ;;
        apply) if [ "$#" -ne 0 ]; then fail 'Invalid apply arguments.'; else run_apply; fi ;;
        restore) if [ "$#" -ne 0 ]; then fail 'Invalid restore arguments.'; else run_restore; fi ;;
        boot-checks) run_boot_checks "$@" ;;
        check) if [ "$#" -ne 0 ]; then fail 'Invalid check arguments.'; else run_check; fi ;;
        startup) if [ "$#" -ne 0 ]; then fail 'Invalid startup arguments.'; else run_startup; fi ;;
        *) fail 'Unsupported action.' ;;
    esac
}

main "$@"
