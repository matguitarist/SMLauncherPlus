#!/bin/zsh
# Runs the in-app self-test against a fresh store in /tmp. Exit code 0 when every check passed.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.mathieu.smlauncherplus.savedState
store=/tmp/SMLauncherPlus-self.json
rm -f $store ${store:r}.log
APP_STORE=$store ~/Applications/SMLauncherPlus.app/Contents/MacOS/SMLauncherPlus --selftest
