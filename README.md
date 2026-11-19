# SM Launcher Plus

A native Apple silicon Mac launcher that installs, updates and plays
[SuperMetroidRecomp](https://github.com/mstan/SuperMetroidRecomp), a native port of Super Metroid,
from your own ROM, with its mods, keeping saves and settings across versions.

**[Download SM Launcher Plus](https://github.com/matguitarist/SMLauncherPlus/releases/latest/download/SMLauncherPlus.dmg)** (macOS 26 or later)

You need your own copy of Super Metroid (Japan, USA). SM Launcher Plus never downloads, copies or ships
the ROM or any Nintendo art, and includes no game files: it downloads SuperMetroidRecomp from that
project's own releases, and reads your ROM where it is.

*[Lire en français](README.fr.md)*

## Build

```zsh
./build.sh --open     # builds, signs and installs ~/Applications/SMLauncherPlus.app
swift test            # unit tests
```

## Credits and license

SM Launcher Plus is MIT licensed (see `LICENSE`).

[SuperMetroidRecomp](https://github.com/mstan/SuperMetroidRecomp) is by mstan, built on the
[snesrecomp](https://github.com/mstan/snesrecomp) framework, and is under the
[PolyForm Noncommercial License 1.0.0](https://github.com/mstan/SuperMetroidRecomp/blob/main/LICENSE)
with [extra permissions](https://github.com/mstan/SuperMetroidRecomp/blob/main/PERMISSIONS.md).
SM Launcher Plus downloads it from its own releases and stays free.

Unofficial and independent: not affiliated with Nintendo or the SuperMetroidRecomp authors.
