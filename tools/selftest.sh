#!/bin/zsh
# Runs the in-app self-test against a fresh store in /tmp. Exit code 0 when every check passed.
# Set SM_ROM_PATH to your own ROM (.sfc, .smc or .zip) to check it too; it is read in place.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.mathieu.smlauncherplus.savedState
store=/tmp/SMLauncherPlus-self.store
rm -f $store $store-shm $store-wal ${store:r}.log
APP_STORE=$store ~/Applications/SMLauncherPlus.app/Contents/MacOS/SMLauncherPlus --selftest
