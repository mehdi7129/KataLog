# KataLog — bibliothèque locale de logs PX4

**0.8.6 (build 25)** · macOS 15+ · Apple Silicon · GPL-3.0-only

KataLog rassemble les logs ULog de votre flotte sur votre Mac : historique,
alertes filtrables, trajectoires Apple Maps, courbes et rapports partageables.
L’app native SwiftUI propose des thèmes clair, sombre et système.

La version **0.8.6 est publique**, signée et notarisée. Elle ajoute les filtres
favoris, la comparaison de deux logs, les notes personnelles et le suivi de
sauvegarde. Ses quatre assets ont été téléchargés et vérifiés sans authentification.
[Résultats et limites de qualification](docs/RELEASE-0.8.6.md).

**[Télécharger KataLog 0.8.6 pour Mac Apple Silicon](https://github.com/mehdi7129/KataLog/releases/download/v0.8.6/KataLog-0.8.6-macOS-arm64.dmg)**

[Release et fichiers](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.6) ·
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

**Compatibilité : Mac Apple Silicon, macOS 15 minimum.** Les contrôles du
package 0.8.6 et sa recette native sur macOS 27.0.1 sont consignés dans les
[notes de release](docs/RELEASE-0.8.6.md). La collecte loopback et la migration
manuelle depuis 0.8.5 sont validées ; un nouveau transfert Aqua réel et un cycle
Sparkle en production ne sont pas qualifiés. Le package Intel n’est pas fourni.

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
| Bibliothèque | Import récursif `.ulg` / `.ULG`, déduplication SHA-256, historique, clients locaux et filtres favoris |
| Analyse | Messages texte, familles d’alertes personnalisables, mesures GNSS/RTK, batterie, durées, failsafe et couverture des données |
| Carte | Tous les logs géolocalisés du périmètre, repères regroupés, trajectoires segmentées, recherche par ville, adresse ou coordonnées et rayon |
| Fiches | Fenêtre indépendante par log, synthèse, notes personnelles par log ou drone, messages et courbes Batterie/GNSS/EKF ; mesures détaillées, paramètres et topics dans le menu **Plus** du mode avancé |
| Comparaison | Deux logs du même contrôleur : métadonnées firmware et différences entre les valeurs finales des paramètres typés |
| Collecte GCS | Collecte Drotek, téléchargement d’un log précis, file persistante, 1 à 4 drones en parallèle (2 par défaut), progression et débit par trajet, pause/arrêt/reprise, contrôle d’espace disque et analyse des fichiers vérifiés |
| Rapports | HTML autonome avec filtres, graphiques et impression/PDF ; exports JSON, périmètre explicite et indication cohérente des détails disponibles ou absents |
| Conservation | Archivage vérifié à l’import, sauvegarde/restauration, suivi de la dernière sauvegarde vérifiée, réassociation des sources par SHA-256 et diagnostic local prévisualisé |

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

## Version 0.8.7 en préparation

Le catalogue d’explications passe de quatre à **321 fiches**, avec sens du
message, vérifications, limites et sources. Chaque fiche distingue une
**définition documentée** d’une **interprétation du texte**. Le contexte d’un
module reste disponible lorsqu’une définition précise manque. Les messages,
leurs niveaux et leur classement restent conservés.

La lecture des dictionnaires d’événements compressés est corrigée. Les
explications des messages existants ne nécessitent aucun réimport ; les
anciens détails sont renouvelés à l’ouverture depuis une source locale vérifiée.
[Recherche et méthode](research/alerts/README.md) ·
[Qualification 0.8.7](docs/RELEASE-0.8.7.md).

## Nouveautés de 0.8.6

- **Filtres favoris** : enregistrer une sélection de client, drones, dates et
  messages pour la retrouver depuis le menu **Favoris**.
- **Comparer deux logs** : cocher deux logs du même contrôleur dans
  **Historique**, puis comparer firmware et paramètres avec recherche et inversion A/B.
- **Notes personnelles** : conserver le contexte d’un log ou d’un drone.
  Elles sont sauvegardées et incluses dans les exports privés ; le partage les retire.
- **Collecte** : contrôler l’espace du volume de destination avant le transfert,
  en tenant compte des copies partielles valides et des autres transferts actifs.
- **Sauvegardes** : afficher la date, la couverture et les nouveaux logs depuis
  la dernière sauvegarde vérifiée.
- **Exports** : décrire les mêmes détails disponibles ou absents dans le HTML,
  le JSON et le manifeste, y compris pour une fiche individuelle. Une génération
  immédiate après un changement d’options attend un aperçu à jour.

Les [parcours et limites](docs/WORKFLOW-IMPROVEMENTS.md) précisent ces ajouts.
La CI finale réussit ses quatre jobs : **502 tests Swift, 553 Python et
18 JavaScript** sur chacun de macOS 15 et 26 ; un seul test Python nécessite
le corpus privé absent. Le package passe neuf contrôles de distribution et
sa recette native. Les preuves et limites sont dans la
[recette 0.8.6](docs/RELEASE-0.8.6.md).

## Nouveautés de 0.8.5

- Un clic sur **Connecter** pendant la fermeture de l’ancienne découverte GCS
  est conservé ; les clics répétés ne créent qu’une nouvelle connexion.
- **Annuler**, **Arrêter**, le changement d’hôte et la fermeture invalident la
  demande différée. Une nouvelle connexion explicite reste possible.
- La fermeture, la restauration et la réinitialisation attendent l’arrêt de
  l’ancienne découverte avant de poursuivre.

Cette version reprend les améliorations introduites en 0.8.4 : accès à un log
précis, priorité des demandes manuelles, progression et débit par trajet,
parallélisme de 1 à 4 drones, réessais réseau sans limite par défaut ou limités à
3/10 tentatives, reprise HTTP quand le serveur la permet et maintien éveillé
pendant la collecte. Un seul fichier est transféré à la fois par drone.

Les tests locaux de reconnexion et d’annulation passent. La distribution signée
et notarisée réussit ses neuf contrôles ; la recette native est validée avec
l’observation d’export décrite dans la [recette dédiée](docs/RELEASE-0.8.5.md).
Les quatre jobs CI réussissent, avec 476 tests Swift, 532 tests Python et
18 tests Node réussis sur chacun de macOS 15 et 26 ; seul le corpus Python
privé absent est exclu. Les quatre assets publics correspondent aux fichiers
qualifiés et le DMG téléchargé sous quarantaine passe les contrôles de sécurité.
Les résultats des packages 0.8.3 et 0.8.4 ne qualifient pas le package 0.8.5.

## Nouveautés de 0.8.3

Cette version regroupe les 26 corrections de l’[audit de qualité](docs/AUDIT-QUALITE-2026-10-08.md).
Les fonctions et les parcours restent les mêmes : imports et restaurations plus
fiables, navigation indépendante entre fenêtres, collecte plus réactive et
responsabilités internes mieux séparées.

Le package 0.8.3 est signé Developer ID et notarisé ; neuf contrôles de
distribution réussissent sur le bundle final. La recette native et les limites sont
détaillées dans les notes de qualification.
La release et ses quatre fichiers ont été téléchargés sans authentification ;
leurs octets et SHA-256 concordent avec les archives qualifiées.
Le banc final de 50 000 logs respecte le budget interne de 500 ms pour les
huit requêtes et leurs répétitions. Des essais précédents dépassaient ce budget
sur les premières lectures ; leur variabilité reste suivie. Les mesures et les limites sont détaillées dans les
[notes de qualification](docs/RELEASE-0.8.3.md#performance-et-limites).

## Nouveautés de 0.8.2

- Historique consultable dans les bibliothèques comportant de nombreux dossiers :
  les informations sur les sources sont comptées avant de remplir chaque page.
- Liste des clients chargée indépendamment de l’historique, conservée si une
  lecture échoue, avec une action pour réessayer.
- Lectures clients arrêtées avant une maintenance ou une restauration, puis
  rechargées lorsque la bibliothèque est disponible.

Le correctif **0.8.2 (build 21)** conservait les analyses et les attributions clients,
sans réimport ni nouvelle migration depuis 0.8.1. Les tests locaux, la CI et la
recette de l’app installée sont consignés dans les
[notes de qualification](docs/RELEASE-0.8.2.md). Cette version a été publiée le
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

Les rapports privés peuvent contenir identités, coordonnées, chemins et notes
personnelles. Les rapports partagés retirent ces notes. Vérifier
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
  Les contrôles de reprise et de parallélisme à 3/4 drones utilisent des fixtures ;
  les essais réels propres à 0.8.6 sont détaillés dans sa recette.
  Les benchmarks de 500 identités sont synthétiques. Un arrêt agit sur le Mac ;
  une copie déjà demandée à la GCS peut continuer.
- La reprise par octets GCS → Mac dépend du serveur. Le protocole Drone → GCS
  utilisé ne propose pas d’offset ; ce trajet peut devoir repartir du début.
- Le maintien éveillé n’empêche ni la fermeture du capot ni la mise en veille
  explicite. Après fermeture de l’app, relancer les inventaires incomplets avec
  **Tout collecter** ; les copies HTTP partielles valides restent récupérables.
- La comparaison porte sur les paramètres typés et le firmware de deux logs
  du même contrôleur ; elle ne superpose pas les courbes.
- Le contrôle d’espace n’empêche pas une autre application de remplir le disque.
  Le suivi de sauvegarde ne vérifie pas que l’archive est encore présente et ne
  compte pas les modifications de notes ou de réglages.
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
