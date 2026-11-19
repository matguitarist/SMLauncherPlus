#!/bin/zsh
# Runs the in-app self-test against a fresh store in /tmp. Exit code 0 when every check passed.
# Set SM_ROM_PATH to your own ROM (.sfc, .smc or .zip) to check it too; it is read in place.
# With APP_SELFTEST_INSTALL=1, SM_GBA_ZIP=<your zipped Metroid: Zero Mission (USA)> also plays with its map art.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.mathieu.smlauncherplus.savedState
store=/tmp/SMLauncherPlus-self.store
rm -f $store $store-shm $store-wal ${store:r}.log
rm -rf ${store:r}-data
APP_STORE=$store ~/Applications/SMLauncherPlus.app/Contents/MacOS/SMLauncherPlus --selftest
