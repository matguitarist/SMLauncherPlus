# SM Launcher Plus — Stories

Source: `docs/BRIEF.md`, `docs/research/recomp.md`. No reference screenshots; `Screens:` names the
snapshot pages that show each story. Thimble tasks live in "SM Launcher Plus Roadmap"; their notes start with
`Story: S-xxx`.

Snapshot pages: `welcome`, `welcome-checking`, `welcome-error`, `install-progress`, `play`,
`play-running`, `play-failed`, `log-sheet`, `update-banner`, `settings-display`, `settings-sound`,
`settings-controls`, `mods`, `mods-feature`, `mods-install`, `profiles`, `profiles-delete`,
`saves`, `graphics`, `graphics-pack`, `settings-general`.

## M1 Install and play (0.1.0)

### S-001 Pick my Super Metroid ROM
As the player, on first launch I drop my ROM onto the welcome page, or click Choose…, and SM Launcher Plus
checks that it's the supported one.
Screens: welcome, welcome-checking, welcome-error
Acceptance:
- [unit] A file of 3,145,728 bytes with SHA-256 `12b77c4b…ca72` is accepted; a headered ROM (512 extra
  bytes) is accepted after skipping the header; anything else is rejected with the reason (wrong size,
  different version or region, patched ROM, not a ROM).
- [unit] A `.zip` holding one `.sfc`/`.smc` is read without unpacking to disk.
- [snap] Checking shows a spinner; a wrong file shows the reason inline with Choose Another….
- [self] The ROM is kept as a security-scoped bookmark and survives a restart; it's never copied.
UX:
- Flow: first launch -> welcome page with drop zone -> drop or Choose… (⌘O, open panel filtered to .sfc, .smc, .zip) -> "Checking your ROM…" -> accepted: checkmark, "Super Metroid (Japan, USA) found", Install Game button focused. Way back: Choose Another….
- Surface: the welcome page fills the window until a profile exists; no sheet.
- States: empty "Play Super Metroid natively on this Mac. Drop your ROM here, or choose it."; loading "Checking your ROM…"; error inline: "This ROM isn't the supported version. SM Launcher Plus needs Super Metroid (Japan, USA)." / "This ROM has been patched. Use an unmodified copy; mods are added in SM Launcher Plus."; done: checkmark + file name (middle-truncated, full path in tooltip).
- Words: "Choose…", "Choose Another…", "Install Game"; note under the zone: "Your ROM stays where it is. Nothing is uploaded."
- Access: the drop zone is a button ("Choose your ROM"); status changes are announced; the error has an icon and words, not only red.
Status: done

### S-002 Download the latest game build
As the player, after my ROM is accepted SM Launcher Plus downloads the latest macOS build of SuperMetroidRecomp
and checks it.
Screens: install-progress
Depends: S-001
Acceptance:
- [unit] The latest release is read from the GitHub API for `mstan/SuperMetroidRecomp`; the asset
  matching `supermetroid-*-macos-arm64.zip` is chosen (x64 on Intel).
- [unit] The zip's SHA-256 matches its line in the release's `SHA256SUMS`; a mismatch deletes it and
  says so.
- [unit] A verified zip already in `Downloads/<version>/` is reused.
- [snap] Progress shows step name and megabytes; offline shows "Can't reach GitHub" with Try Again.
UX:
- Flow: Install Game -> install progress page with steps "Downloading SuperMetroidRecomp 0.4.6", "Checking the download", "Setting up the game" -> checkmarks -> S-003 end. Way back: Cancel (stops, removes partial files, returns to the welcome page).
- Surface: the progress page replaces the welcome page (a task the player watches).
- States: determinate bar "Downloading — 18 of 42 MB"; error inline under the failed step: "Unable to reach GitHub. Check your connection, then try again." / "The download is damaged. Try again." with Try Again; cached: "Using the downloaded 0.4.6".
- Words: "Cancel", "Try Again".
- Access: the bar has a label and value; step changes announced; Escape = Cancel.
Status: done

### S-003 Make a playable profile
As the player, the verified build is unpacked into a profile with its own saves, settings and mods.
Screens: install-progress, play
Depends: S-002
Acceptance:
- [unit] The zip unpacks to `Profiles/<id>/game/`; paths that escape the folder are refused.
- [unit] `profile.json` records version, installed date and the ROM's SHA-256.
- [self] The executable runs (`--help` or a headless smoke start) right after unpacking, with no
  quarantine flag (`xattr` shows none) and no Gatekeeper prompt.
UX:
- Flow: last install step -> the window switches to the Play page with the new profile selected.
- Surface: no extra screen; failure stays on the progress page.
- States: error: "SM Launcher Plus couldn't set up the game. <reason>" with Try Again and Show Log.
- Words: profile default name "Super Metroid".
- Access: focus moves to Play.
Status: done

### S-004 Play
As the player, I press Play and the game starts with my ROM, straight into the game (not the game's
built-in launcher).
Screens: play, play-running
Depends: S-003
Acceptance:
- [unit] The launch command passes the ROM path and the profile's `config.ini`.
- [self] The game boots past its own launcher to the title screen. If the ROM argument doesn't skip
  it, the fallback is documented and tested (see research [U]).
- [snap] While running, Play becomes "Playing…" with a Stop button and a running timer.
- [self] Play time and last played are saved when the game exits.
UX:
- Flow: Play page -> Play (Return) -> SM Launcher Plus stays open beside the game; button shows "Playing…" -> game exits -> back to Play. Way back: Stop asks "Stop the game? Unsaved progress since your last save station is lost." (Stop / Keep Playing).
- Surface: Play page: header art, profile name, version, last played, big Play button.
- States: running; ROM missing: "Your ROM moved. Choose it again." with Choose….
- Words: "Play", "Playing…", "Stop".
- Access: Play is the default button; ⌘R also plays.
Status: done

### S-005 See why the game stopped
As the player, when the game quits with an error SM Launcher Plus tells me and shows the log.
Screens: play-failed, log-sheet
Depends: S-004
Acceptance:
- [unit] An exit code other than 0, or a new `crash_report_*.json`, counts as a failure.
- [snap] The Play page shows "The game stopped unexpectedly" with Show Log and Report a Problem.
- [self] Report a Problem zips the session log, replay files, `last_run_report.json` and crash files
  (never the ROM) and reveals the zip in Finder, matching the game README's bug-report list.
UX:
- Flow: game exits with error -> inline banner on Play -> Show Log opens the log sheet (LogKit viewer) -> Close. Report a Problem -> zip saved to Desktop and revealed.
- Surface: banner inline (not an alert); log in a sheet (short look, then back).
- States: no log: "The game left no log."
- Words: "Show Log", "Report a Problem", "Close".
- Access: banner announced; the log sheet is searchable with ⌘F.
Status: todo

### S-006 Bundle nothing, credit everything
As the player, About and the README credit SuperMetroidRecomp, snesrecomp and their license, and
say SM Launcher Plus ships no game files.
Screens: settings-general
Acceptance:
- [self] About shows the installed game version and links to the project and its license.
- [manual] README and README.fr.md say the ROM and Nintendo art are never included.
Status: todo

## M2 Tune the game (0.1.0)

### S-010 Choose display settings
As the player, I set window scale, fullscreen, VSync, renderer, shader and widescreen (Fit, 16:9,
21:9, 32:9) from the Display tab.
Screens: settings-display
Depends: S-003
Acceptance:
- [unit] Changes are written to the profile's `config.ini` keeping unknown keys, comments and order.
- [unit] The shader list comes from the profile's `assets/shaders/`.
Status: todo

### S-011 Sound
As the player, I set volume and turn audio on or off.
Screens: settings-sound
Acceptance:
- [unit] `[Sound] Volume` and `EnableAudio` are written; values are clamped to 0–100.
Status: todo

### S-012 Controller and keys
As the player, I see which controller is connected and remap buttons and keys.
Screens: settings-controls
Acceptance:
- [unit] `[GamepadMap] Controls` and `[KeyMap]` round-trip without loss.
- [self] A connected controller is named (GameController framework).
Status: todo

### S-013 Move the data folder
As the player, I move SM Launcher Plus's data folder to another drive in Settings › General.
Screens: settings-general
Acceptance:
- [unit] Profiles and downloads are moved; a failed move leaves the old folder intact.
Status: todo

## M3 Mods (0.2.0)

### S-020 See and switch mod features
As the player, the Mods page lists the game's packages and their features (HUD, map, controls,
balance, bug fixes…), and I turn each on or off and set its options.
Screens: mods, mods-feature
Depends: S-003
Acceptance:
- [unit] Packages are read from `mods/preloaded/packages/<id>/<version>/manifest.toml`; boolean,
  choice and integer options are shown with their bounds.
- [unit] Choices are written to `mods/preloaded/state.toml` in the game's format; the game reads them
  on next launch.
- [self] Turning on a feature changes the game (e.g. widescreen 16:9).
Status: done

### S-021 Install a .snesmod package
As the player, I drop a `.snesmod` file on the Mods page to install it.
Screens: mods-install
Acceptance:
- [unit] Same limits as the game: root `manifest.toml`, stored or DEFLATE, no unsafe paths, at most
  4096 files and 256 MiB.
- [unit] A package whose target `game_id` isn't `supermetroid-jpn` is refused with the reason.
- [unit] Removing a package deletes its folder and its entries in `state.toml`.
Status: todo

### S-022 Pick files a mod asks for
As the player, a feature that declares a resource (like the Zero Mission map art) shows a file picker.
Screens: mods-feature
Acceptance:
- [unit] `[[resource]]` entries show a picker with the declared file patterns; required ones block
  the feature until chosen.
Status: todo

## M4 Stay current (0.2.0)

### S-030 See that an update is available
As the player, the Play page shows when a newer release exists, with its notes.
Screens: update-banner
Acceptance:
- [unit] Checks GitHub at most once a day; compares semantic versions.
- [snap] Banner "SuperMetroidRecomp 0.4.7 is available" with What's New and Update.
Status: todo

### S-031 Update a profile in one click
As the player, Update installs the new build into the same profile and keeps my saves, settings,
mod choices and installed packages.
Screens: install-progress
Depends: S-030
Acceptance:
- [unit] `saves/`, `config.ini` (merged with new keys), `mods/preloaded/state.toml`, installed
  packages and `logs/` survive; the old build is kept until the new one starts once.
- [self] Roll Back returns to the previous version.
Status: todo

### S-032 Manage profiles
As the player, I rename, duplicate, show in Finder and delete profiles (optionally keeping saves).
Screens: profiles, profiles-delete
Status: todo

### S-033 Back up and restore saves
As the player, I back up `save.srm` and restore it, and a backup is made before each update.
Screens: saves
Status: todo

## M5 Graphics and UI packs (0.3.0)

Needs a graphics-pack plugin in the game. Decided 2026-11-19: build it in our own fork of
SuperMetroidRecomp, not proposed upstream until it's solid (then offer it to mstan). Use
strager/supermetroid and snesrecomp's asset-dump tools as the map of where graphics live, and
Super-Metroid-Redux's graphics as the first real packs (mstan already ported most of its gameplay).

### S-040 A graphics-pack plugin in the game
As a pack author, the game replaces original tiles and palettes with PNGs from an installed package,
at the original size and color limits.
Acceptance:
- [manual] Our fork of SuperMetroidRecomp builds for macOS arm64 and passes the game's own tests.
- [unit] The launcher installs the fork's build as its own profile beside mstan's; updates track
  mstan's tags merged into the fork.
- [live] A pack replacing Samus's Power Suit palette and one HUD icon shows in game, and turning the
  feature off restores the original.
- [unit] PNGs that break the size or color limits are refused with the reason.
Status: todo

### S-041 Make editing templates from my ROM
As a pack author, SM Launcher Plus exports the original graphics from my own ROM as PNG templates on my Mac.
Screens: graphics
Depends: S-040
Acceptance:
- [unit] Templates match the pack format and are written only to a folder I choose; nothing is uploaded.
- [manual] The README says templates are for personal editing and must not be shared.
Status: todo

### S-042 Choose a graphics pack
As the player, the Graphics page shows installed packs with a preview, and I pick one per profile.
Screens: graphics, graphics-pack
Depends: S-040, S-021
Acceptance:
- [unit] A pack's target game version is checked; a mismatch warns instead of failing.
- [self] Switching packs changes the game on next launch.
Status: todo

### S-043 HUD and menu packs
As the player, packs can also restyle the HUD, pause screen and menus.
Depends: S-040
Acceptance:
- [live] Redux's pause screen, equipment screen and minimap tiles (`code/Graphics/`) load as a pack.
Status: todo

### S-044 Redux Redesigned Samus as the first pack
As the player, I install a pack with Redux's Redesigned Samus (and Dual Suit) and see it in game.
Depends: S-040, S-042
Acceptance:
- [manual] Permission and credit from ShadowOne333 and the sprite authors; GPLv3 kept for their files.
- [unit] SM Launcher Plus converts the IPS's graphics to pack PNGs on the player's Mac from their own ROM + the
  IPS, so no Nintendo-derived art is shipped by the launcher.
- [live] Samus uses the redesigned sprites in every suit; turning the pack off restores the original.
Status: todo

## Later
- High-resolution sprites (needs the custom renderer to draw above native resolution).
- Windows and Linux launcher (C# Avalonia).
- Game Mode, a CLI for agents.
- Sparkle self-update, signing and notarization.

## Dropped
- Building the game from source in the launcher: precompiled releases cover it.
- Netplay lobby and replay viewer: the game's own launcher and tools handle them.
- ROM patches (IPS/BPS): the game refuses patched ROMs; changes come as mods.
