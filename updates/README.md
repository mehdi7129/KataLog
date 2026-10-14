# Mises à jour de KataLog

La version **KataLog 0.8.6 (build 25)** est publique depuis le **14 octobre 2026**,
pour **macOS 15+ sur Apple Silicon**. Ses quatre fichiers publics sont vérifiés.
Le flux signé build **25** est préparé ; son activation passe par la fusion de
la PR de publication, suivie d’un contrôle du flux canonique effectivement servi.

La release 0.8.4 (build 23) est publique et immuable. Ce build n’a jamais été
activé dans le flux. La transition de 0.8.5 était donc **22 → 24** ; celle de
0.8.6 est préparée pour **24 → 25**, après vérification anonyme du build 24 servi.
Les résultats figurent dans les recettes
[0.8.6](../docs/RELEASE-0.8.6.md) et [0.8.5](../docs/RELEASE-0.8.5.md).

Depuis KataLog **0.7.0 ou ultérieur**, utiliser
**Réglages → Mises à jour → Rechercher une mise à jour**. Les versions antérieures
s’installent directement depuis le [DMG 0.8.6](https://github.com/mehdi7129/KataLog/releases/download/v0.8.6/KataLog-0.8.6-macOS-arm64.dmg).
La Preview possède une bibliothèque indépendante et son updater est désactivé.
Voir [installation et migrations](../docs/UPDATING.md).

## Flux stable

- [Appcast public signé](https://raw.githubusercontent.com/mehdi7129/KataLog/main/updates/stable/appcast.xml)
- [Copie versionnée de l’appcast](stable/appcast.xml)
- [Clé publique Ed25519](stable/public-key.txt)
- [Release 0.8.6 et archives](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.6)
- [Qualification et publication 0.8.6](../docs/RELEASE-0.8.6.md)
- [Qualification historique 0.8.5](../docs/RELEASE-0.8.5.md)

Le flux utilise l’archive ZIP de la release ; le DMG sert à l’installation
manuelle. Aucune clé privée n’est stockée dans le dépôt.

## Préparer une prochaine mise à jour

Suivre la [procédure de release](../docs/RELEASING.md) et les
[contrôles de l’updater](../docs/UPDATING.md#vérifications-avant-publication).
Publier les archives finales avant le nouveau flux. Les assets d’une release
publiée restent immuables. Un feed signé ne doit jamais être reformaté ou modifié
sans être signé à nouveau avec les outils Sparkle.

Pour 0.8.6, préparer le build **25** avec `--previous-build 24` seulement après
contrôle du dernier build effectivement servi. Vérifier avec les outils officiels
Sparkle les signatures du feed local et du ZIP téléchargé publiquement.
L’activation passe par la fusion de la publication du flux : après fusion,
contrôler sans authentification les octets et signatures du flux effectivement
servi. Cette vérification reste distincte des signatures locales et de celle du ZIP.
