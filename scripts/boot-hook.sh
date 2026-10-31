#!/bin/sh
# CA-BUNDLE-MANAGER-BOOT-HOOK

if [ "${CA_MANAGER_TESTING:-0}" = 1 ]; then
    APP_ROOT=${CA_MANAGER_TEST_ROOT:?}/app
else
    APP_ROOT=/media/developer/apps/usr/palm/applications/com.alpinesox.cabundlemanager
fi
HELPER=$APP_ROOT/scripts/ca-manager.sh

if [ ! -x "$HELPER" ]; then
    rm -f "$0"
    exit 0
fi

exec "$HELPER" startup
