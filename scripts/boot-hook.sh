#!/bin/sh
# CA-BUNDLE-MANAGER-BOOT-HOOK

if [ "${CA_MANAGER_TESTING:-0}" = 1 ]; then
    TEST_ROOT=${CA_MANAGER_TEST_ROOT:?}
    APP_ROOT=$TEST_ROOT/app
    STATE=$TEST_ROOT/state
else
    APP_ROOT=/media/developer/apps/usr/palm/applications/com.alpinesox.cabundlemanager
    STATE=/var/lib/webosbrew/ca-bundle-manager
fi
release_id=$(cat "$STATE/current.version" 2>/dev/null)
case "$release_id" in
    *[!0-9a-f]*|'')
        if [ ! -r "$APP_ROOT/scripts/ca-manager.sh" ]; then rm -f "$0"; fi
        exit 0
        ;;
esac
[ "${#release_id}" -eq 64 ] || exit 0
HELPER=$STATE/releases/$release_id/ca-manager.sh

if [ ! -r "$APP_ROOT/scripts/ca-manager.sh" ]; then
    if [ -x "$HELPER" ]; then "$HELPER" restore || exit 0; fi
    rm -f "$0"
    exit 0
fi

[ -x "$HELPER" ] || exit 0

exec "$HELPER" startup
