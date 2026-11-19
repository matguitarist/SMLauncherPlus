# SM Launcher Plus

*[Read in English](README.md)*

Un lanceur natif pour Mac à puce Apple qui installe, met à jour et lance
[SuperMetroidRecomp](https://github.com/mstan/SuperMetroidRecomp), un portage natif de Super Metroid,
à partir de votre propre ROM, avec ses mods, en gardant vos sauvegardes et réglages d’une version à l’autre.

**[Télécharger SM Launcher Plus](https://github.com/matguitarist/SMLauncherPlus/releases/latest/download/SMLauncherPlus.dmg)** (macOS 26 ou plus récent)

Il vous faut votre propre copie de Super Metroid (Japan, USA). SM Launcher Plus ne télécharge, ne copie
et ne distribue jamais la ROM ni aucune image de Nintendo, et n’inclut aucun fichier du jeu : il
télécharge SuperMetroidRecomp depuis les versions publiées par ce projet, et lit votre ROM là où elle se trouve.

## Compiler

```zsh
./build.sh --open     # compile, signe et installe ~/Applications/SMLauncherPlus.app
swift test            # tests unitaires
```

## Remerciements et licence

SM Launcher Plus est sous licence MIT (voir `LICENSE`).

[SuperMetroidRecomp](https://github.com/mstan/SuperMetroidRecomp) est l’œuvre de mstan, bâti sur le
cadriciel [snesrecomp](https://github.com/mstan/snesrecomp), et est sous
[licence PolyForm Noncommercial 1.0.0](https://github.com/mstan/SuperMetroidRecomp/blob/main/LICENSE)
avec des [permissions supplémentaires](https://github.com/mstan/SuperMetroidRecomp/blob/main/PERMISSIONS.md).
SM Launcher Plus le télécharge depuis ses propres versions publiées et reste gratuit.

Non officiel et indépendant : sans lien avec Nintendo ni avec les auteurs de SuperMetroidRecomp.
