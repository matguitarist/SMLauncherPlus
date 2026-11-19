# SM Launcher Plus

A native Apple silicon Mac launcher that installs, updates and plays
[SuperMetroidRecomp](https://github.com/mstan/SuperMetroidRecomp), a native port of Super Metroid,
from your own ROM, with its mods, keeping saves and settings across versions.

**[Download SM Launcher Plus](https://github.com/matguitarist/SMLauncherPlus/releases/latest/download/SMLauncherPlus.dmg)** (macOS 26 or later)

You need your own copy of Super Metroid (Japan, USA). SM Launcher Plus never downloads or ships the ROM
or any Nintendo art.

## Build

```zsh
./build.sh --open     # builds, signs and installs ~/Applications/SMLauncherPlus.app
swift test            # unit tests
```

## License

SM Launcher Plus is MIT licensed (see `LICENSE`). SuperMetroidRecomp is by mstan and is under the
PolyForm Noncommercial license ([its repository](https://github.com/mstan/SuperMetroidRecomp));
SM Launcher Plus downloads it from its own releases and stays free.

Unofficial and independent: not affiliated with Nintendo or the SuperMetroidRecomp authors.
