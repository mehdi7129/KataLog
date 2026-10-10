# Mises à jour de KataLog

Le flux stable versionné propose **KataLog 0.8.5 (build 24)**, publiée le
**10 octobre 2026**, pour **macOS 15+ sur Apple Silicon**.

La release 0.8.4 (build 23) est publique et immuable. Ce build n’a jamais été
activé dans le flux. La transition préparée est donc **22 → 24**.
Les résultats de qualification et de publication figurent dans la
[recette 0.8.5](../docs/RELEASE-0.8.5.md).

Depuis KataLog **0.7.0 ou ultérieur**, utiliser
**Réglages → Mises à jour → Rechercher une mise à jour**. Les versions antérieures
s’installent directement depuis le [DMG 0.8.5](https://github.com/mehdi7129/KataLog/releases/download/v0.8.5/KataLog-0.8.5-macOS-arm64.dmg).
La Preview possède une bibliothèque indépendante et son updater est désactivé.
Voir [installation et migrations](../docs/UPDATING.md).

## Flux stable

- [Appcast public signé](https://raw.githubusercontent.com/mehdi7129/KataLog/main/updates/stable/appcast.xml)
- [Copie versionnée de l’appcast](stable/appcast.xml)
- [Clé publique Ed25519](stable/public-key.txt)
- [Release 0.8.5 et archives](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.5)
- [Qualification et publication 0.8.5](../docs/RELEASE-0.8.5.md)

Le flux utilise l’archive ZIP de la release ; le DMG sert à l’installation
manuelle. Aucune clé privée n’est stockée dans le dépôt.

## Préparer une prochaine mise à jour

Suivre la [procédure de release](../docs/RELEASING.md) et les
[contrôles de l’updater](../docs/UPDATING.md#vérifications-avant-publication).
Publier les archives finales avant le nouveau flux. Les assets d’une release
publiée restent immuables. Un feed signé ne doit jamais être reformaté ou modifié
sans être signé à nouveau avec les outils Sparkle.

Le feed 0.8.5 a été préparé avec le build **24** et `--previous-build 22`, après
contrôle du dernier build effectivement servi. Les signatures du feed local
et du ZIP téléchargé publiquement sont vérifiées avec l’outil officiel Sparkle.
L’activation du feed passe par la fusion de sa PR de publication : après fusion,
contrôler sans authentification les octets et signatures du flux effectivement
servi. Cette vérification reste distincte des signatures locales et de celle du ZIP.
