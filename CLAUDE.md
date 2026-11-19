# SM Launcher Plus

A native Apple silicon Mac launcher in SwiftUI that installs, updates and plays
SuperMetroidRecomp (a native port of Super Metroid) from your own ROM, with its
mods, keeping saves and settings across versions. The sibling of AM2R Launcher Plus.

Shared rules for my Mac apps (build and check, design rules, skills, git):
@~/.claude/mac-app-conventions.md

Shared rules for how every project is laid out and named:
@~/.claude/project-layout.md

## Layout

- `Sources/SMLauncherPlus/` the app. `App.swift` has the window, menus, and the database location.
- `Sources/SMLauncherPlusKit/` rules and data logic with no SwiftUI. Tests in `Tests/SMLauncherPlusKitTests/`.
- `Package.swift` a Swift package. There is no Xcode project.
- `build.sh` builds, signs, and installs `~/Applications/SMLauncherPlus.app`.
- Release: `tools/release.sh <version>` (settings in `release.conf`, version in `Info.plist.in`). Use the mac-release skill.
- `Icon/AppIcon.icon` the app icon, an Icon Composer file (JSON plus SVG layers). `build.sh` compiles it with `tools/make_icon.sh`; `tools/icon_review.sh` renders every look into one PNG.
- `docs/` the brief, the screen index, and the user stories, when they exist.

## Checks specific to this app

- `APP_SNAPSHOT_MIN=1 tools/snap.sh` shoots the window at its smallest size.
- Never test against the real library in `~/Library/Application Support/SMLauncherPlus/`.
- Never copy, ship or download the ROM or any Nintendo art. The player's ROM is read where it is.
