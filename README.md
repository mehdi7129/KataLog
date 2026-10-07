# KataLog — bibliothèque locale de logs PX4

**0.8.2 (build 21)** · macOS 15+ · Apple Silicon · GPL-3.0-only

KataLog rassemble les logs ULog de votre flotte sur votre Mac : historique,
alertes filtrables, trajectoires Apple Maps, courbes et rapports partageables.
L’app native SwiftUI propose des thèmes clair, sombre et système.

**[Télécharger KataLog 0.8.2 pour Mac Apple Silicon](https://github.com/mehdi7129/KataLog/releases/download/v0.8.2/KataLog-0.8.2-macOS-arm64.dmg)**

[Release et fichiers](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.2) ·
[Guide utilisateur](docs/README.md) · [Changelog](CHANGELOG.md) ·
[Contribuer](CONTRIBUTING.md)

## Installation

1. Télécharger le DMG, puis l’ouvrir.
2. Glisser **KataLog.app** dans **Applications**.
3. Éjecter le DMG, puis lancer KataLog depuis Applications.

Le package est signé Developer ID et notarisé par Apple. Le moteur Python
ARM64 est embarqué : aucun Python séparé, Homebrew ni Terminal n’est nécessaire.
Une nouvelle installation démarre avec une bibliothèque vide ; une installation
existante retrouve ses données.

**Compatibilité : Mac Apple Silicon, macOS 15 minimum.** La recette locale a été
exécutée sur macOS 27 ; ses résultats et les limites de qualification figurent
dans les [notes de release](docs/RELEASE-0.8.2.md). Le package Intel n’est pas fourni.

## Mises à jour

Depuis **0.7.0**, ouvrir **Réglages → Mises à jour → Rechercher une mise à jour**,
puis choisir **Installer et redémarrer**. La recherche automatique est facultative.
Terminer ou arrêter les imports, collectes et exports avant l’installation.

Depuis **0.5.x ou 0.6.x**, quitter KataLog et remplacer l’app par celle du nouveau
DMG. La bibliothèque, les identités, les clients, les réglages et les dossiers
choisis sont conservés. **KataLog Preview** garde une bibliothèque indépendante
et se met à jour manuellement.

[Procédure et migrations](docs/UPDATING.md)

## Fonctions disponibles

| Fonction | Ce que fait KataLog |
| --- | --- |
| Bibliothèque | Import récursif `.ulg` / `.ULG`, déduplication SHA-256, historique et classement par clients locaux |
| Analyse | Messages texte, familles d’alertes personnalisables, mesures GNSS/RTK, batterie, durées, failsafe et couverture des données |
| Carte | Tous les logs géolocalisés du périmètre, repères regroupés, trajectoires segmentées, recherche par ville, adresse ou coordonnées et rayon |
| Fiches | Fenêtre indépendante par log, synthèse, messages et courbes Batterie/GNSS/EKF ; mesures détaillées, paramètres et topics dans le menu **Plus** du mode avancé |
| Collecte GCS | Collecte Drotek, file persistante, deux drones en parallèle, pause/arrêt/reprise et analyse automatique des fichiers vérifiés |
| Rapports | HTML autonome avec filtres, graphiques et impression/PDF ; exports JSON et choix explicite du périmètre |
| Conservation | Archivage vérifié à l’import, sauvegarde/restauration, réassociation des sources par SHA-256 et diagnostic local prévisualisé |

Les outils PX4 spécialisés sont accessibles via le **mode avancé** des réglages.

## Prise en main

1. Créer si besoin des clients dans **Tous les clients → Créer ou gérer les
   clients…**. Ce classement est facultatif.
2. Cliquer **Importer**, choisir un dossier de logs et son client destinataire,
   puis **Référencer les fichiers** ou **Copier vers mes archives**. Attendre
   le bilan avant de retirer une carte SD.
3. Explorer **Vue d’ensemble**, **Historique**, **Carte**, **Drones** et **Alertes**.
   Ouvrir un log pour ses messages, sa trajectoire et ses mesures.
4. Dans **Rapports**, choisir la sélection ou tous les logs du client courant.
   Choisir **Tous les clients** pour couvrir la bibliothèque entière.

Pour collecter directement sur une GCS, ouvrir **Collecte GCS**, renseigner son
adresse, se connecter et choisir **Tout collecter**. Le client destinataire et
le dossier de copie sont explicites. Voir le [guide de collecte](docs/README.md#collecter-depuis-une-gcs).

## Nouveautés de 0.8.2

- Historique consultable dans les bibliothèques comportant de nombreux dossiers :
  les informations sur les sources sont comptées avant de remplir chaque page.
- Liste des clients chargée indépendamment de l’historique, conservée si une
  lecture échoue, avec une action pour réessayer.
- Lectures clients arrêtées avant une maintenance ou une restauration, puis
  rechargées lorsque la bibliothèque est disponible.

Le correctif **0.8.2 (build 21)** conserve les analyses et les attributions clients,
sans réimport ni nouvelle migration depuis 0.8.1. Les tests locaux, la CI et la
recette de l’app installée sont consignés dans les
[notes de qualification](docs/RELEASE-0.8.2.md). La stable est publiée depuis le
**7 octobre 2026** ; le DMG et le flux de mise à jour signés ont été vérifiés
après publication.

## Nouveautés de 0.8.1

- Carte couvrant tous les logs géolocalisés, au-delà de l’ancienne limite de 80.
- Cadrage et mode satellite conservés ; résultats valides réutilisés pendant la navigation.
- Filtres compacts, accès au log depuis une alerte et actions indisponibles expliquées.
- Analyse d’un fichier pendant le transfert du suivant, avec file d’attente bornée.

Ces améliorations introduites en **0.8.1** restent incluses dans la version
actuelle. Le gain de collecte est mesuré sur un banc simulé. Les
[mesures](docs/PERFORMANCE-MAP-NAVIGATION.md) et la
[qualification 0.8.1](docs/RELEASE-0.8.1.md) précisent la portée des résultats.

## Données et confidentialité

La bibliothèque est locale, sous `~/Library/Application Support/KataLog/`.
Les clients sont des regroupements locaux, sans compte ni cloud. Les ULogs
sources sont lus sans modification. Le cache conserve les analyses déjà calculées ;
garder les originaux ou choisir l’archivage vérifié pour pouvoir recalculer.

Le fond Apple Maps et la recherche d’adresses utilisent le réseau ; KataLog
ne demande pas la localisation du Mac. La collecte contacte la GCS configurée
sur le réseau local, et les mises à jour utilisent le flux GitHub signé.

Les rapports privés peuvent contenir identités, coordonnées et chemins. Vérifier
le mode et le contenu avant partage. Le [diagnostic local](docs/DIAGNOSTICS.md)
permet une prévisualisation ; journaux bruts et ULogs sont des options privées
distinctes. Le dépôt distribue des fixtures synthétiques.

## Limites connues

- Une alerte décrit une observation ; elle ne confirme pas une cause de panne.
  Les événements binaires exigent le dictionnaire exact du firmware pour être traduits.
- Les mesures dépendent des topics et de leur couverture. Une durée inconnue
  n’est pas assimilée à zéro ; les lacunes GPS ne sont pas reliées.
- Le cache et le JSON d’une fiche ne contiennent pas toutes les séries brutes du ULog.
- La collecte réelle a été testée avec une GCS Drotek 3.7.2 et deux drones.
  Les benchmarks de 500 identités sont synthétiques. Un arrêt agit sur le Mac ;
  une copie déjà demandée à la GCS peut continuer.
- La recette locale sur macOS 27 ne remplace pas une recette physique sur macOS 15.

[Contrat de collecte](docs/GCS-COLLECTION.md) · [Contrat d’import](docs/IMPORT-CONTRACT.md) ·
[Roadmap](docs/ROADMAP.md)

## Construire et contribuer

Prérequis de développement : **macOS 15+, Xcode / Swift 6, Python 3.13** ;
**Node.js** sert aux tests du rapport HTML. Le guide de
[contribution](CONTRIBUTING.md) détaille l’environnement, les commandes de build
et les suites Swift, Python et JavaScript. La
[procédure de distribution](docs/RELEASING.md) couvre le moteur embarqué, le DMG,
les signatures et la notarisation.

La [CI](.github/workflows/ci.yml) teste macOS 15 et 26 et construit des packages
ARM64 ad hoc sur macOS 15 et 27. Elle ne publie pas de release.
Les tests publics utilisent des données synthétiques ; le corpus réel externe
reste optionnel et son absence est signalée.

## Licence

Copyright (C) 2026 **mehdi7129**. Le code propre de KataLog, ses tests, scripts,
documentation et ressources originales sont sous **GPL-3.0-only**, sans garantie.
Voir [LICENSE](LICENSE) et les [licences des dépendances](docs/DEPENDENCIES-LICENSES.md).
Les releases proposent le code source correspondant à leur tag. Les logs et
bibliothèques des utilisateurs ne font pas partie des sources du logiciel.
