# KataLog 0.8.3 — recette de release

Version **0.8.3**, build **22**. État au **9 octobre 2026** : **candidat en
qualification, non publié**. La stable téléchargeable reste 0.8.2 build 21.

## Corrections

Cette version regroupe les 26 corrections de l’[audit de qualité](AUDIT-QUALITE-2026-10-08.md)
et de la [PR d’intégration #34](https://github.com/mehdi7129/KataLog/pull/34).
Elle conserve les fonctions, les parcours et les résultats métier existants.

- **Imports et données** : rollback transactionnel, protection des sorties,
  conservation de la provenance, contrôle des sources avant lecture et prise
  en charge des grandes sélections sans dépasser les limites SQLite.
- **Restauration et maintenance** : reprise après interruption, traitement des
  bibliothèques endommagées, clients et collecte réconciliés avant reprise,
  erreurs de réinitialisation explicites.
- **Navigation** : chaque fenêtre garde son état de lecture ; les alertes suivent
  les filtres actifs et la recherche de proximité réutilise sa sélection exacte
  entre les pages.
- **Collecte** : accès disque sérialisés hors du thread d’interface, progression
  et compteurs cohérents, délais HTTP appliqués jusqu’à la fin du corps,
  inventaires MQTT et flux d’événements bornés.
- **Exports et maintenance du code** : résultat de diagnostic fiable, états
  partagés entre Swift et SQL, capacités des commandes explicites, fichiers
  Swift/Python découpés par responsabilité, builds isolés et métadonnées vérifiées.

## Installation et conservation des données

Mac Apple Silicon, macOS 15 minimum. L’identité stable **KataLog.app**, le moteur
Python embarqué, le parseur **1.4.0** et la projection SQLite **8** sont conservés.
Depuis 0.8.2, aucun réimport, nouveau téléchargement GCS ou nouvelle migration
n’est nécessaire. Les analyses, clients, attributions, identités, dossiers et
réglages restent conservés ; KataLog Preview garde sa bibliothèque séparée.

Les modalités de mise à jour restent décrites dans [UPDATING.md](UPDATING.md).
Le flux stable et ses archives ne sont pas modifiés par la préparation de ce
candidat. Leur publication et vérification viennent après la recette finale.

## Preuves logicielles obtenues

Les résultats ci-dessous portent sur le code applicatif `91a392a`, avant le
changement de version du package. Ils ne qualifient pas à eux seuls la signature
et la distribution finales 0.8.3.

| Contrôle | Résultat vérifié |
| --- | --- |
| [CI du code corrigé](https://github.com/mehdi7129/KataLog/actions/runs/37908235149) | Quatre checks requis réussis : tests macOS 15 et 26, packages ARM64 macOS 15 et Xcode 27 |
| Suites sur chacun des deux runners | 431 tests Swift ; 508/509 tests Python, seul le corpus privé externe absent ; 18 tests JavaScript |
| Packages CI ad hoc | 6/6 contrôles par package ; 19 modules Python sources vérifiés, imports/restauration/collecte loopback isolés |
| Revue native préliminaire, macOS 27 | Vue d’ensemble : 180 logs, 1 512,9 min, 4 drones en clair et sombre ; carte Apple chargée, 12 groupes de 15 repères ; clic d’un groupe : 15 logs, retour au périmètre complet : 180 |
| Helper embarqué, bibliothèque synthétique préparée | 50 000 logs, 5 millions de messages, 500 drones ; cinq lectures conformes à l’oracle après contrôle et normalisation des seuls timestamps courants ; fichier SQLite inchangé |

La revue native utilise une copie du bundle ad hoc avec identité isolée, puis
re-signature ad hoc. Les sections Mach-O de code et de données restent identiques.
Elle qualifie le rendu réel de la fenêtre : la limite des bitmaps MapKit des
tests automatisés n’est donc pas un défaut d’affichage observé dans cette
recette. Elle ne remplace pas le lancement du package final copié depuis le DMG.
Les captures et rapports détaillés restent hors du dépôt public.

## Performance et limites

Le [banc de capacité final](https://github.com/mehdi7129/KataLog/actions/runs/37908235241)
reste **en échec** : les premières requêtes dashboard et registre prennent
**631,1 ms et 542,1 ms** pour un budget inchangé de **500 ms**. Les six autres
requêtes respectent ce budget ; les répétitions suivantes sont à 51–60 ms et
95–122 ms. Le RSS reste à 504,94 Mio sur 512 Mio. Les oracles de données et les
sept tests Swift du banc passent. Les quatre checks requis verts n’effacent
pas cette limite de performance.

Un essai local du helper réellement embarqué en lecture seule mesure
**1,044 s** pour les contrôles runtime et les deux lectures initiales de
l’historique, puis **0,489 s** pour leur répétition ; la lecture du registre
prend **0,555 s**, contrôle runtime inclus. Cette bibliothèque synthétique est
déjà préparée ; le cache du système n’est pas contrôlé, et le temps Swift de
décodage et de rendu n’est pas inclus. Ces résultats montrent une attente
initiale possible sur un grand historique, sans écart de données détecté dans
ces essais. Ils ne constituent pas une garantie de latence pour toute bibliothèque.

Le profilage de la variabilité des premières lectures reste suivi dans la
[roadmap](ROADMAP.md#qualification-et-limites-encore-ouvertes), sans relever le
budget ni masquer les échecs. Cette version ne revendique pas de nouvelle
qualification de flotte physique, de corpus privé absent, de parcours physique
complet sur macOS 15 ou de cycle Sparkle réel de 0.8.2 vers 0.8.3.

## Contrôles restant avant publication

| Contrôle | État du candidat 0.8.3 |
| --- | --- |
| Métadonnées version/build | 8/8 tests de contrat réussis après génération Xcode : defaults, smoke, Debug/Release et plist final cohérents sur 0.8.3 build 22 |
| Signature Developer ID et notarisation app/helper/DMG | À exécuter sur le package final |
| Distribution finale | Neuf contrôles à exécuter avec notarisation requise |
| Copie depuis le DMG, éjection et lancement natif | À exécuter avec bibliothèque isolée ; import, export, redémarrage et conservation à vérifier |
| Confidentialité du commit final, de ses sources et des assets | Garde des fichiers courants : 303 fichiers, zéro signalement ; historique, métadonnées et distributions finales à contrôler séparément |
| Tag, sources correspondantes, ZIP, DMG et SHA-256 | À produire après qualification |
| Téléchargements publics et quarantaine | À vérifier après publication |
| Flux stable signé build 22 | À publier après les assets puis à vérifier avec les outils Sparkle |

La [procédure de distribution](RELEASING.md) décrit les contrôles. Les preuves
seront ajoutées lorsqu’elles existent ; celles des anciennes releases restent
attribuées à leurs archives immuables.
