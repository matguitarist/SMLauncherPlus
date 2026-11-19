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

## Start from AM2R Launcher Plus

`~/Developer/AM2RLauncherPlus` is the sibling app with the same flow. Before you code a story, read
its version of that story, then port and rename its code rather than writing new code. Keep what
belongs to AM2R out: GameMaker, data.win, VCDiff/xdelta, Rosetta, Butterscotch, randomizer, room log.

| Story here | Start from there |
| --- | --- |
| S-001 ROM check | `Kit/AM2R11Check.swift` (hash rule, `HashCache`, zip reading), `WelcomePage.swift`, the bookmark in `Models.swift` |
| S-002 download | `Kit/PatchData.swift` (GitHub API, download with progress, typed `Failure`), `InstallPage.swift` |
| S-003 profile | `Kit/ProfileBuilder.swift`, `Kit/ProfileName.swift`, the `Profile` model in `Models.swift` (SwiftData) |
| S-004 play | `GameRunner.swift` (start, watch, play time) |
| S-005 why it stopped | `LogSheet.swift`, `DebugLogWindow.swift`, `LauncherLog.swift`, `Kit/DebugLog.swift` |
| S-010 to S-012 settings | `Kit/GameConfig.swift` (`IniFile` edits only the keys asked for), `GameSettingsView.swift` |
| S-013 data folder | `Kit/FolderMove.swift` |
| S-020 to S-022 mods | `Kit/ModPackage.swift`, `Kit/ModCatalog.swift`, `ModsPage.swift` |
| S-030, S-031 updates | `Kit/UpdateCheck.swift` (once a day, cached answer) |
| S-032 profiles | `ContentView.swift` (profile list, delete with kept saves) |
| S-033 saves | `Kit/SaveBackup.swift`, `BackupsSheet.swift` |
| Snapshots, self-test, seed | `Snapshot.swift`, `SelfTest.swift`, `SeedData.swift` |

`Kit/` means `Sources/AM2RLauncherPlusKit/`; the rest is in `Sources/AM2RLauncherPlus/`. Its
`docs/FIXLOG.md` lists bugs already fixed there; don't bring them back.

## Checks specific to this app

- `APP_SNAPSHOT_MIN=1 tools/snap.sh` shoots the window at its smallest size.
- Never test against the real database, `~/Library/Application Support/SMLauncherPlus/SMLauncherPlus.store` (SwiftData, models in `Models.swift`, like AM2R Launcher Plus).
- Never copy, ship or download the ROM or any Nintendo art. The player's ROM is read where it is.
  One exception, the owner's choice (2026-11-19): the game can only read a plain .sfc, so a ROM in a .zip or .7z, or a
  headered one, is unpacked at Play into a private temp folder (mode 700) and deleted when the game
  quits; leftovers are removed at the next launch. A plain .sfc or .smc is always passed in place.
  The same goes for files a mod asks for (S-022), the owner's choice (2026-11-19): a .zip or .7z
  holding one (like the Zero Mission .gba) is accepted, unpacked at Play into that private folder,
  pointed to from state.toml for the run, then deleted and state.toml set back to the archive.
