# KataLog 0.8.1 — recette de release

Version **0.8.1**, build **20**, préparée le 5 octobre 2026.
État : **promotion stable en préparation** depuis la Preview approuvée
`v0.8.1-beta.1`, commit `61bea6e3ab649ae217d5c64afbbadb1431a2f439`.
La qualification du nouveau package stable et sa publication restent à compléter.

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

Après publication du flux signé, les versions stables à partir de 0.7.0 pourront
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
| Sources finales, version 0.8.1 et build 20 | Entrées de build mises à jour ; compilation stable signée en cours |
| Tests et CI des sources finales | À consigner |
| Banc SDK Sparkle, installation et relancement | Réussi avec app jetable et flux HTTP local ; six fichiers synthétiques conservés |
| Identité stable, bibliothèque stable et configuration Sparkle | À vérifier dans le bundle final |
| Signature Developer ID, notarisation et tickets app, helper et DMG | À effectuer sur les nouveaux artefacts |
| Distribution finale et installation après éjection du DMG | À effectuer |
| Confidentialité des sources et des archives | À vérifier |
| Tag `v0.8.1`, archive source et SHA-256 | À générer après gel des sources |
| Release publique et téléchargements anonymes | À effectuer |
| Flux stable signé, archive et signatures Sparkle publiques | À publier et vérifier après les assets |

Les captures, bibliothèques et rapports détaillés de recette restent hors du dépôt.
La distribution ne contient ni bibliothèque de démonstration ni données utilisateur.

## Limites

- Le gain de collecte a été mesuré sur un banc simulé ; aucun nouveau débit GCS
  réel ni essai sur une flotte physique n’est revendiqué.
- Les mesures de navigation et de carte isolent certains coûts ; elles ne
  représentent pas tous les temps de parcours dans l’interface.
- Le fond Apple Maps et la recherche d’adresses dépendent du réseau. Les lacunes
  GPS ne sont pas reliées et les trajectoires non vérifiables restent signalées.
- La recette locale sur macOS 27 ne remplace pas une recette physique sur macOS 15.
