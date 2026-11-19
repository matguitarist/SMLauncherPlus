# SuperMetroidRecomp as a launch target

Research for SM Launcher Plus. Done 2026-11-19.
[V] verified in a source, [K] from knowledge, [U] unverified, test first.

Question: what must a native Mac launcher do around mstan/SuperMetroidRecomp, and can it carry
sprite and UI replacement later?

## Findings

### The game
- A static recompilation of the SNES CPU code into C on the `snesrecomp` framework; PPU, APU, DMA
  stay emulated. SDL3 + OpenGL. [V](https://github.com/mstan/SuperMetroidRecomp)
- Each GitHub release ships `supermetroid-<ver>-macos-arm64.zip`, `-macos-x64.zip`, Windows, Linux,
  and `SHA256SUMS`. Latest: v0.4.6 (2026-11-13); releases come every few days. [V](https://github.com/mstan/SuperMetroidRecomp/releases)
- The zip is a folder, not an .app: the executable `SuperMetroidSNESRecomp`, `assets/` (shaders),
  `mods/preloaded/`, `config.ini`, docs. [V] `scripts/package_release.sh`
- Accepted ROM: Super Metroid (Japan, USA) (En,Ja), 3,145,728 bytes, SHA-256
  `12b77c4bc9c1832cee8881244659065ee1d84c70c3d29e6eaf92e6798cc2ca72`, CRC32 `d63ed5f8`.
  Patched ROMs are refused. [V] `rom_identity.txt`
- The ROM path can be given as the first argument (`./SuperMetroidSNESRecomp "<rom>.sfc"`). [V] README.
  Whether that skips the built-in Dear ImGui launcher is [U]: test first.
- User data lives beside the executable: `saves/save.srm` (battery save), `config.ini`,
  `mods/preloaded/state.toml` (enabled features), `logs/`, replay captures. [V] `src/main.c`, README
- `config.ini` sections: General, Graphics (renderer, shader, window, fullscreen, widescreen via
  mods), Sound, KeyMap, GamepadMap. [V] `config.ini`
- macOS minimum is 11.0 (deployment target in CI). Builds are unsigned/ad-hoc. [V] release.yml, [U] signature
- A file downloaded by URLSession in a non-sandboxed app gets no quarantine flag, so Gatekeeper
  won't block the game binary. [K], test with `xattr`.
- License: PolyForm Noncommercial + extra permissions: free distribution allowed, no paid access. [V] `PERMISSIONS.md`

### Mods
- `.snesmod` = ZIP with a root `manifest.toml`, data only, max 4096 files / 256 MiB. Packages install to
  `mods/preloaded/packages/<id>/<version>/`; player choices in `mods/preloaded/state.toml`. [V] snesrecomp `docs/MOD_PACKAGES.md`
- Behavior comes from "trusted plugins" compiled into the game (about 30 in `src/mods/`: HUD, map,
  X-ray, controls, balance, bug fixes, widescreen). Packages switch them on with options. [V]
- A package can declare a `[[resource]]` file picker (e.g. PNG) for a plugin to read. [V] `MOD_AUTHORING.md`
- **"There is no generic rule that an `assets/` folder overrides ROM graphics."** Sprite replacement
  needs a new trusted plugin in the game. [V] `MOD_AUTHORING.md`
- Precedent: the Zero Mission map-art feature draws tiles read from the player's own GBA ROM in place
  of the pause map. [V] `docs/ZERO_MISSION_MAP_ART.md`
- snesrecomp has asset-dump tools that export composed tiles, sprites and palettes as PNG and name the
  routine that drew them. [V] snesrecomp `docs/ASSET_TOOLS_PLAN.md`

### strager/supermetroid
- A disassembly (WLA-DX) that rebuilds the byte-identical ROM; `graphics/` and `data/` show where
  sprites, HUD, fonts and palettes live and how they're compressed. Last change 2021. [V](https://github.com/strager/supermetroid)
- Useful as a map for a graphics-pack plugin, not as something to ship or run.

### ShadowOne333/Super-Metroid-Redux
- A ROM hack (Project Base + Control Freak + many smaller hacks) with full asar source in `code/`,
  optional IPS patches in `patches/optional/`, GPLv3. Last change 2025-12. [V](https://github.com/ShadowOne333/Super-Metroid-Redux)
- SuperMetroidRecomp already re-implements a lot of it as plugins (97 mentions): heavy physics,
  bug fixes, intro and Ceres skip, faster elevators, charge combos, pause map, ship-save fix. [V]
  `SUPER_METROID_ENHANCEMENTS.md`, `src/mods/`
- What isn't ported yet and is graphics: `code/Graphics/` (pause screen, equipment screen, minimap
  tiles, title, room select) and `patches/optional/Redesigned Samus/` (Redesigned Samus and Dual Suit
  sprites). These are the natural first test cases for the graphics-pack plugin (S-040). [V]
- Its asm shows exactly which ROM addresses each change touches, which turns into plugin hooks and
  pack slots. [V]
- Redux's own code and art can be reused under GPLv3 with credit; sprite edits derived from Nintendo
  art are a grey zone, so ship them only as a pack the player installs, with the authors' OK. [K]

## Decisions
- Download mstan's precompiled macOS zip; never build the game. [V]
- Verify the zip against `SHA256SUMS` and the ROM against `rom_identity.txt`'s SHA-256. [V]
- Keep user data (saves, config, mod state, logs) per profile and carry it across updates. [V]
- Pass the ROM as an argument; fall back to placing it in the game folder if needed. [U]
- Sprite and UI replacement needs a graphics-pack plugin contributed to the game (or a fork): plan it,
  and keep the launcher side ready (install and pick packs). [V]
- Never ship Nintendo graphics: packs carry only original art; templates are made on the player's Mac
  from their own ROM. [K]
