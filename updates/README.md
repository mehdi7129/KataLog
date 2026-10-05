# Mises à jour de KataLog

Le flux stable public propose **KataLog 0.8.1 (build 20)**, publié le
**5 octobre 2026**, pour **macOS 15+ sur Apple Silicon**.

Depuis KataLog **0.7.0 ou ultérieur**, utiliser
**Réglages → Mises à jour → Rechercher une mise à jour**. Les versions antérieures
s’installent directement depuis le [DMG de la stable](https://github.com/mehdi7129/KataLog/releases/download/v0.8.1/KataLog-0.8.1-macOS-arm64.dmg).
La Preview possède une bibliothèque indépendante et son updater est désactivé.
Voir [installation et migrations](../docs/UPDATING.md).

## Flux stable

- [Appcast public signé](https://raw.githubusercontent.com/mehdi7129/KataLog/main/updates/stable/appcast.xml)
- [Copie versionnée de l’appcast](stable/appcast.xml)
- [Clé publique Ed25519](stable/public-key.txt)
- [Release 0.8.1 et archives](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.1)
- [Résultats de qualification et de publication](../docs/RELEASE-0.8.1.md)

Le flux utilise l’archive ZIP de la release ; le DMG sert à l’installation
manuelle. Aucune clé privée n’est stockée dans le dépôt.

## Préparer une prochaine mise à jour

Suivre la [procédure de release](../docs/RELEASING.md) et les
[contrôles de l’updater](../docs/UPDATING.md#vérifications-avant-publication).
Publier les archives finales avant le nouveau flux. Les assets d’une release
publiée restent immuables. Un feed signé ne doit jamais être reformaté ou modifié
sans être signé à nouveau avec les outils Sparkle.
