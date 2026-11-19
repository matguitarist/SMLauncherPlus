# SM Launcher Plus

A native Apple silicon Mac launcher that installs, updates and plays
[SuperMetroidRecomp](https://github.com/mstan/SuperMetroidRecomp) (a native port of Super Metroid)
from your own ROM, with its mods, and later graphics packs. Built for one player who wants Super
Metroid to just work on a modern Mac, the way AM2R Launcher Plus does for AM2R.

App name in the UI: **SM Launcher Plus**, the sibling of AM2R Launcher Plus. Bundle id:
`com.mathieu.smlauncherplus`. Folder and package: `SMLauncherPlus` (`~/Developer/SMLauncherPlus`).
Owner's choice, 2026-11-19.

## Replaces
Downloading each SuperMetroidRecomp zip by hand, unzipping it, moving saves and settings across
versions, and using the game's built-in Dear ImGui launcher for ROM, settings and mods.

## Main jobs
1. **Set up once:** pick my ROM, check it's the supported one, download the latest macOS build,
   verify it, and make a playable profile.
2. **Play:** one big Play button; show the game's log and crash report if it stops.
3. **Tune and mod:** display, sound and controller settings, and turn mod features on or off with
   their options (widescreen, HUD, map, QoL), and install `.snesmod` packages.
4. **Stay current:** see a newer release and update in one click, keeping saves and settings.

## Data
- **RomSource:** path (security-scoped bookmark), SHA-256, validated date. Never copied anywhere else.
- **Profile:** name, game version, install folder, saves folder, installed date, last played, play time.
- **GameRelease:** version, tag, zip URL, SHA-256, published date (cache of GitHub releases).
- **ModPackage:** id, version, name, features (on/off, options), source (preloaded / installed).
- Later, **GraphicsPack:** id, name, author, version, target game version, preview.
- Settings (not a model): data folder, update channel (latest release only in v1).

## Platforms
Mac first (Swift 6, SwiftUI, SwiftPM, `new-mac-app`). Windows and Linux maybe later (C# Avalonia).

## Shape
One window with a sidebar (Play, Settings for the game, Mods, Profiles; Graphics arrives in M5),
macOS 26 or later, Liquid Glass. Data in `~/Library/Application Support/SMLauncherPlus`. Needs the internet
only to check for and download releases. No accounts.

## System hooks
None in version one. Later: Game Mode, a CLI for agents.

## Reference
AM2R Launcher Plus (`~/Developer/AM2RLauncherPlus`): same flow, same look family. The game's own
recomp-ui launcher for the list of settings and mod features (behavior only).
Research: `docs/research/recomp.md`.

## Look
Native Mac app with its own accent: Super Metroid orange-amber (Samus's Power Suit, ~#F2A33A),
dark first. Play page has a large header with our own art (no Nintendo art). English and French.
_Decided by the agent._

## Not in version one
- Graphics and UI packs (M5; needs a graphics-pack plugin in our own fork of the game, kept to
  ourselves until it's solid)
- Netplay lobby, replays viewer, run-ahead and rewind controls (the game handles these)
- Windows and Linux launcher; building the game from source

## Constraints
- Never ship or download the ROM or any Nintendo graphics; the player's ROM is the only source.
- The game is PolyForm Noncommercial: SM Launcher Plus stays free; credit mstan and link the license.
- Unofficial and independent, not affiliated with Nintendo or the SuperMetroidRecomp authors.
