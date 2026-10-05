# KataLog 0.8.1 — recette de release

Version **0.8.1**, build **20**, publiée le 5 octobre 2026.
État : **release stable publiée ; téléchargements et flux signé vérifiés**.
La version est préparée depuis la Preview approuvée
`v0.8.1-beta.1`, commit `61bea6e3ab649ae217d5c64afbbadb1431a2f439`.

## Nouveautés

- **Carte complète** : tous les logs géolocalisés du périmètre sont représentés,
  avec regroupement des repères proches et trajectoire détaillée à l’ouverture
  d’un log. Le cadrage et le mode satellite sont conservés entre les onglets.
- **Navigation plus rapide** : les résultats encore valides sont réutilisés ;
  une actualisation conserve le contenu du périmètre déjà affiché.
- **Actions plus lisibles** : filtres compacts, accès direct au log depuis une
  alerte et explication des actions indisponibles. Les outils techniques restent
  accessibles en mode avancé.
- **Collecte et analyse en parallèle** : un fichier vérifié peut être analysé
  pendant le transfert du suivant, avec une file d’attente bornée.

Les mesures et leur périmètre figurent dans la
[validation des performances](PERFORMANCE-MAP-NAVIGATION.md).

## Installation et migration

Mac Apple Silicon, macOS 15 minimum. Le package stable porte le nom
**KataLog.app**, avec moteur Python autonome embarqué. Il conserve la bibliothèque
stable, les identités, les clients, les réglages et les dossiers choisis.
La bibliothèque de **KataLog Preview** reste indépendante et n’est pas transférée
automatiquement.

La projection SQLite passe de 7 à 8 ; sa préparation conserve les résumés
canoniques et crée une sauvegarde de migration. Les anciennes analyses restent
disponibles et leur recalcul reste explicite. Aucun nouveau téléchargement GCS
n’est nécessaire pour cette migration.

Le flux signé est publié ; les versions stables à partir de 0.7.0 peuvent
installer 0.8.1 depuis **Réglages → Rechercher une mise à jour**. L’installation
manuelle par DMG reste possible pour toutes les versions. Voir
[les instructions de mise à jour](UPDATING.md).

## Preuves déjà obtenues sur la Preview

La [recette de la beta 1](RELEASE-0.8.1-BETA.md) consigne les résultats suivants
sur le build 19. Ils ne constituent pas une qualification du build stable 20.

| Contrôle de la Preview | Résultat consigné |
| --- | --- |
| Suites Swift, Python et JavaScript | 348 tests Swift, 379 Python et 18 JavaScript réussis ; un test de corpus privé externe non exécuté |
| Recette native synthétique | Carte à 180 repères, conservation du cadrage, identité après redémarrage, export HTML, réimport et sauvegarde complète |
| Package Preview | Neuf contrôles de distribution réussis ; signatures, notarisation et tickets validés |
| Installation Preview | Copie depuis le DMG, éjection et lancement de la copie réussis |

## Qualification du package stable

| Contrôle | État |
| --- | --- |
| Sources finales, version 0.8.1 et build 20 | Package stable construit et métadonnées vérifiées |
| Suite Swift locale | 348 tests réussis, aucun échec ni test ignoré |
| Suite Python locale | 379 tests réussis ; un test de corpus privé externe non exécuté |
| Interactions JavaScript des rapports | 18 tests réussis |
| CI sur `3f24eb1` | [Exécution 37300429488](https://github.com/mehdi7129/KataLog/actions/runs/37300429488) réussie : tests macOS 15 et 26, packages ARM64 macOS 15 et 27 |
| Banc SDK Sparkle, installation et relancement | Réussi avec app jetable et flux HTTP local ; six fichiers synthétiques conservés |
| Identité et configuration Sparkle | Identité stable, build 20, canal stable et clé publique attendue vérifiés dans le bundle final |
| Signature Developer ID, notarisation et tickets | App et DMG acceptés par Gatekeeper comme distributions Developer ID notarisées ; tickets app, helper et DMG validés |
| Distribution finale | Neuf contrôles réussis sur la copie installée depuis le DMG, après éjection |
| Présentation du DMG | Fenêtre contrôlée dans Finder, conforme ; éjection effectuée |
| Confidentialité des sources et des archives | Aucun finding non classé ; ZIP et DMG finaux identiques, payloads embarqués inspectés |
| Tag `v0.8.1`, archive source et SHA-256 | Tag sur `a88c3bc` ; 250 fichiers sources identiques au commit ; empreintes publiées |
| Release publique et téléchargements anonymes | Latest stable 0.8.1 ; quatre fichiers téléchargés sans authentification, empreintes locales et GitHub concordantes |
| Flux stable signé, archive et signatures Sparkle publiques | Publié après les assets ; HTTPS anonyme, version 0.8.1 build 20, octets et signatures du flux et du ZIP vérifiés |

Les captures, bibliothèques et rapports détaillés de recette restent hors du dépôt.
La distribution ne contient ni bibliothèque de démonstration ni données utilisateur.
Le package stable n’a pas fait l’objet d’un nouveau lancement graphique lors de
cette recette. Les tests natifs ont été exécutés ; la recette graphique de la
Preview approuvée reste la preuve disponible pour les parcours d’interface.

## Limites

- Le gain de collecte a été mesuré sur un banc simulé ; aucun nouveau débit GCS
  réel ni essai sur une flotte physique n’est revendiqué.
- Les mesures de navigation et de carte isolent certains coûts ; elles ne
  représentent pas tous les temps de parcours dans l’interface.
- Le fond Apple Maps et la recherche d’adresses dépendent du réseau. Les lacunes
  GPS ne sont pas reliées et les trajectoires non vérifiables restent signalées.
- La recette locale sur macOS 27 ne remplace pas une recette physique sur macOS 15.

## Traçabilité

Le package est construit depuis les entrées du commit `3f24eb1`, dont les quatre
jobs CI ont réussi. Le code applicatif, les tests, les dépendances et les sources
du moteur sont identiques à la Preview approuvée `61bea6e` ; le build stable
passe à 20 et active le canal de mise à jour stable. Les mises à jour de
documentation suivent ces validations sans modifier les entrées du package.

## Publication

La [release stable 0.8.1](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.1)
est publiée après fusion de la PR #4. Le tag cible `a88c3bc` et la documentation
de qualification complète est actualisée ensuite sur `main`.

Le DMG téléchargé avec quarantaine est accepté par Gatekeeper comme distribution
Developer ID notarisée ; son ticket Apple est validé. Le flux stable public
correspond exactement aux octets signés préparés. Son URL de ZIP et sa taille
concordent avec l’archive téléchargée ; les deux signatures Sparkle sont valides.
Le banc SDK reste une recette synthétique : il ne représente pas une installation
Sparkle réelle de KataLog 0.8.0 vers 0.8.1 dans une autre session macOS.

| Archive | SHA-256 |
| --- | --- |
| `KataLog-0.8.1-macOS-arm64.dmg` | `14193fc3d0c3de17ffc6e44e71eb4752c0bc7cc4ee97b07d487744b3b2fbd1fb` |
| `KataLog-0.8.1-macOS-arm64.zip` | `f05da2b6e7daccaf43054adeb19d6149595e56b268c4027304532f65bb072289` |
| `KataLog-0.8.1-source.zip` | `eeefd55cf2ef80b34138be876dd2a0a4e4575c2fad08fab35e5331eb8f0dd4a2` |
