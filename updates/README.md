# Mises à jour de KataLog

KataLog **0.9.0 (build 28)** est publié le **14 novembre 2026** pour
**macOS 15+**, avec deux distributions natives signées et notarisées :
**arm64** pour Apple Silicon et **x86_64** pour Intel. Le moteur Python est
embarqué ; aucun Python, Homebrew ni Rosetta n’est nécessaire chez l’utilisateur.

Depuis KataLog **0.7.0 ou ultérieur** sur Apple Silicon, utiliser
**Réglages → Mises à jour → Rechercher une mise à jour** après activation du flux.
Une première installation Intel, ou une version antérieure à 0.7.0, passe par le
DMG correspondant au Mac :

- [DMG Apple Silicon](https://github.com/mehdi7129/KataLog/releases/download/v0.9.0/KataLog-0.9.0-macOS-arm64.dmg)
- [DMG Intel](https://github.com/mehdi7129/KataLog/releases/download/v0.9.0/KataLog-0.9.0-macOS-x86_64.dmg)

La Preview possède une bibliothèque indépendante et son updater est désactivé.
Voir [installation et migrations](../docs/UPDATING.md).

## Deux flux stables

| Architecture | Flux canonique | Copie versionnée |
| --- | --- | --- |
| Apple Silicon (`arm64`) | [Appcast ARM](https://raw.githubusercontent.com/mehdi7129/KataLog/main/updates/stable/appcast.xml) | [stable/appcast.xml](stable/appcast.xml) |
| Intel (`x86_64`) | [Appcast Intel](https://raw.githubusercontent.com/mehdi7129/KataLog/main/updates/stable-intel/appcast.xml) | [stable-intel/appcast.xml](stable-intel/appcast.xml) |

Les deux flux utilisent la même [clé publique Ed25519](stable/public-key.txt),
embarquée dans les apps finales. Le flux ARM historique conserve son URL. Le
flux Intel a sa propre URL ; chaque app interroge celui de son architecture.
Le flux ARM comporte `hardwareRequirements=arm64`. Le flux Intel dédié ne
comporte pas ce sélecteur : la séparation repose sur l’URL du flux et les
métadonnées d’architecture de l’app et de l’archive.

Sparkle télécharge le **ZIP** de l’architecture concernée ; le **DMG** sert à
l’installation manuelle. Les deux ZIP, les deux DMG, l’archive source et
[SHA256SUMS.txt](https://github.com/mehdi7129/KataLog/releases/download/v0.9.0/SHA256SUMS.txt)
sont les six assets de la [release 0.9.0](https://github.com/mehdi7129/KataLog/releases/tag/v0.9.0).
Le tag et les sources de ces packages désignent le commit
`f2a86e2649f39cde9972a4bbf3ebeb903056ddf5`. Les assets publiés restent immuables.

La [recette 0.9.0](../docs/RELEASE-0.9.0.md) distingue les contrôles des packages,
les recettes natives ARM/Intel sur macOS 15 et 26, les essais USB synthétiques
et les limites connues. Un contrôle de signature ou un lancement natif ne
constitue pas un cycle complet d’installation Sparkle ni un essai sur drone.

## Préparer et activer un flux

Suivre la [procédure de release](../docs/RELEASING.md) et les
[contrôles de l’updater](../docs/UPDATING.md#vérifications-avant-publication).
Aucune clé privée n’est stockée dans le dépôt. La préparation signée utilise
les outils officiels de **Sparkle 2.10.0** et le compte du Trousseau
`katalog-sparkle-stable`, commun aux deux flux.

Pour la transition **0.9.0 / build 28**, le dernier build servi sur ARM est
**27** ; Intel n’avait pas de flux précédent et utilise donc la valeur initiale
**0**. Les préparations utilisent respectivement `--architecture arm64 --previous-build 27`
et `--architecture x86_64 --previous-build 0`. Pour une release suivante,
relire chaque flux effectivement servi au lieu de réutiliser ces valeurs.

1. Publier et télécharger sans authentification les six assets finaux. Comparer
   leurs tailles et SHA-256 aux fichiers qualifiés et au manifeste public.
2. Préparer chaque flux depuis le ZIP public exact de son architecture avec
   `tools/update-feed.py prepare`. Contrôler version, build, minimum macOS,
   URL du ZIP, taille, architecture, clé embarquée et route canonique.
3. Vérifier avec `sign_update --account katalog-sparkle-stable --verify`
   la signature de chaque XML, puis celle de son ZIP en fournissant
   l’`edSignature` de son enclosure. Conserver les empreintes des deux XML vérifiés.
4. Fusionner les XML signés dans leurs deux chemins canoniques sans les reformater.
   Après fusion, télécharger chaque flux sans authentification, comparer ses
   octets et vérifier à nouveau sa signature ainsi que celle du ZIP public désigné.

La publication des archives et l’activation des flux sont deux étapes distinctes.
Un XML régénéré, même depuis un ZIP inchangé, peut avoir une nouvelle `pubDate`
et de nouveaux octets : il exige une nouvelle signature et une nouvelle preuve
de vérification locale, puis du flux canonique servi. Les contrôles des anciens
XML restent historiques et ne qualifient pas leurs remplaçants. La régénération
d’un flux ne doit jamais reconstruire ou remplacer un asset déjà publié.
