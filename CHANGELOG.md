# Changelog

Version stable actuelle : [0.8.5](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.5),
build **24**. [Télécharger le DMG](https://github.com/mehdi7129/KataLog/releases/download/v0.8.5/KataLog-0.8.5-macOS-arm64.dmg)
ou suivre les [instructions de mise à jour](docs/UPDATING.md).
Les sections antérieures conservent l’état de leur version au moment de sa livraison.
Le flux versionné propose le build **24**, préparé depuis le build 22. Les
archives et le tag de 0.8.4 restent immuables ; son build 23 n’a jamais été activé.

## 0.8.5 — 2026-10-10

- Reconnexion GCS demandée pendant la fermeture de l’ancienne connexion conservée,
  sans perdre le clic ni lancer deux sessions de découverte.
- Annulation de cette demande lors d’un arrêt ou d’un changement d’hôte ;
  attente de la fermeture de la découverte avant de terminer les opérations de sortie.
- Restauration et réinitialisation attendent cette fermeture et invalident les
  demandes de reconnexion avant de poursuivre.

Version **0.8.5**, build **24**, publiée sous le tag `v0.8.5` (`0209635`).
CI, distribution signée et notarisée et recette native validées, avec une
observation de métadonnées d’export. Les quatre assets ont été téléchargés et
vérifiés sans authentification. Elle reprend les améliorations 0.8.4 ci-dessous.
Parseur et projection SQLite inchangés. Voir la
[recette 0.8.5](docs/RELEASE-0.8.5.md).

## 0.8.4 — 2026-10-10

- Progression GCS stable pendant le recalcul des totaux, avec débit séparé pour
  Drone → GCS et GCS → Mac.
- Accès rapide à un log précis : inventaire consultable, téléchargement individuel
  et priorité sur les fichiers encore en attente.
- Collecte réglable de 1 à 4 drones simultanés, 2 par défaut, avec un fichier
  à la fois par drone et une file d’analyse bornée.
- Réessais réseau sans limite par défaut, ou 3/10 tentatives par fichier ou
  inventaire de collecte ; reprise des inventaires interrompus, pause et arrêt.
- Maintien éveillé pendant la collecte et l’attente du réseau ; l’écran peut
  dormir. La fermeture du capot et la veille explicite ne sont pas contournées.
- Reprise des copies HTTP partielles quand le serveur fournit un ETag fort et
  une plage valide ; vérification du préfixe, de la source et de l’intégrité.

Version **0.8.4**, build **23**, publiée sous le tag `v0.8.4`. Aucun changement de
parseur ou projection SQLite. La reprise par octets Drone → GCS n’est pas exposée
par le protocole utilisé. Le flux stable était resté sur 0.8.3 pendant la préparation
du correctif 0.8.5 : le build 23 n’a jamais été activé dans ce flux. Le tag et les
assets 0.8.4 restent immuables. Voir la [recette 0.8.4](docs/RELEASE-0.8.4.md).

## 0.8.3 — 2026-10-09

- Imports et réanalyses : rollback cohérent, protection des fichiers de sortie,
  provenance conservée et vérification locale des sources avant leur lecture.
- Restauration et maintenance : reprise après interruption, traitement d’une
  bibliothèque endommagée, clients et collecte réconciliés avant reprise.
- Navigation indépendante entre fenêtres, résultats d’alertes cohérents après
  changement de filtres et réutilisation de la recherche de proximité paginée.
- Collecte : accès disque déplacés hors du thread d’interface, compteurs et
  états cohérents, délai HTTP complet et flux MQTT/JSONL bornés. Après une
  sauvegarde, les index des grandes files en attente sont préparés hors du
  thread d’interface, avec les mêmes gardes et priorités de collecte.
- Resynchroniser un destinataire de collecte déjà sélectionné ne déclenche
  plus de fausse erreur de stockage pendant le rechargement des clients.
  Les changements de destinataire restent bloqués pendant cette opération.
- Exports et grandes sélections sécurisés ; logique Swift/Python séparée par
  responsabilité, métadonnées de build vérifiées et preuves CI conservées.

Version **0.8.3**, build **22**. Les 26 points de l’audit sont intégrés sans
nouvelle fonction ni changement de parseur ou de projection SQLite. La
[recette 0.8.3](docs/RELEASE-0.8.3.md) distingue les tests réussis, les mesures
et la variabilité du banc de capacité, et les contrôles de distribution.
Publiée le **9 octobre 2026** sous le tag **`v0.8.3`** (`97ff13f`), dont
l’arbre correspond exactement au code qualifié. DMG signé/notarisé, ZIP,
sources correspondantes et SHA-256 téléchargés et vérifiés sans authentification.

## 0.8.2 — 2026-10-07

- Pagination de l’historique : la liste des sources et les statistiques d’import
  sont comptées dans la limite de réponse avant de remplir la page de logs.
  Les bibliothèques comportant de nombreux dossiers restent consultables sans
  augmenter la limite de 4 Mio ni retirer des données.
- Chargement des clients indépendant de l’historique : une erreur de lecture des
  logs ne masque plus leur liste. Une lecture clients échouée conserve le dernier
  résultat valide et propose un nouvel essai explicite.
- Les lectures clients sont arrêtées avant une modification ou une restauration
  de bibliothèque, puis rechargées après restauration et préparation de l’index.

Version **0.8.2**, build **21**. La correction conserve les analyses, les clients
et leurs attributions ; aucun réimport ni changement de projection SQLite n’est
requis depuis 0.8.1. Publiée sous le tag **`v0.8.2`** (`1c15e0c`) : DMG signé et
notarisé, ZIP de mise à jour, sources correspondantes et SHA-256 vérifiés en accès
anonyme. Le flux stable signé propose le build 21. Les tests et contrôles sont
consignés dans [RELEASE-0.8.2.md](docs/RELEASE-0.8.2.md).

## 0.8.1 — 2026-10-05

- Carte couvrant tous les logs géolocalisés du périmètre, avec regroupement des
  repères proches et trajectoire détaillée à l’ouverture du log.
- Cadrage et mode satellite conservés entre les onglets ; réutilisation des
  résultats valides pour accélérer la navigation.
- Filtres compacts, actions indisponibles expliquées et ouverture directe d’un
  log depuis une alerte ; outils techniques accessibles en mode avancé.
- Analyse d’un fichier possible pendant le transfert du suivant, avec
  concurrence et file d’attente bornées ; mesure de performance sur banc simulé.
- Projection SQLite 8, avec conservation des résumés et sauvegarde de migration.

Version **0.8.1**, build **20**, issue de la Preview approuvée
`v0.8.1-beta.1`, publiée le **5 octobre 2026** sous le tag **`v0.8.1`**
(`a88c3bc`). DMG signé et notarisé, ZIP de mise à jour, archive des sources
correspondantes et SHA-256 sont publiés ; le flux stable signé propose ce build.
Les résultats de qualification et de publication du package stable figurent
dans [RELEASE-0.8.1.md](docs/RELEASE-0.8.1.md).

## 0.8.0 — 2026-10-01

- Clients locaux personnalisables ; attribution des nouveaux logs à l’import et
  à la collecte, réattribution en lot, périmètre client partagé entre statistiques,
  historique, carte, registre et rapports. Les doublons conservent leur attribution.
- Interface Bento épurée : boutons sans cadre permanent, états de survol/focus,
  bascule clair/sombre directe et activité récente avec défilement interne.
- Recherche géographique par ville, adresse ou coordonnées avec rayon, sur les
  trajectoires complètes disponibles ; traversées de zone et lacunes distinguées.
- Fenêtres macOS indépendantes par log, déplaçables et redimensionnables, avec
  état de lecture indépendant et réouverture de la fenêtre déjà affichée.
- Collecte des drones éligibles connectés sans inscription manuelle ; destination
  client persistante par travail. Numéro de stock facultatif.
- Outils PX4 spécialisés regroupés dans un mode avancé désactivé par défaut.
- Retrait groupé des sources, vidage de bibliothèque et réinitialisation globale
  confirmés ; tous les fichiers `.ulg` restent sur disque, y compris les copies internes.
- Diagnostic GCS guidé et disponibilité des options expliquée.
- Compatibilité des anciennes bibliothèques en lecture seule, cache géographique
  alimenté depuis les sources accessibles, exports partagés sans identité client.

Version **0.8.0**, build **18**. Le package stable est qualifié ; le suivi de
la CI finale et de la publication reste séparé de la Preview. Résultats et limites :
[RELEASE-0.8.0.md](docs/RELEASE-0.8.0.md).

## 0.7.0 — 2026-10-01

- Refonte native des dix onglets en bento monochrome, clair/sombre, boutons et icônes cohérents.
- Navigation des fiches unifiée ; détails techniques accessibles à la demande.
- Flux Sparkle stable signé, recherche depuis l’app et recherche automatique facultative conservée.
- Installation et redémarrage confirmés ; attente pendant les opérations et blocage en lecture seule.
- Diagnostic KataLog/GCS prévisualisé avant export, journaux privés uniquement sur choix explicite.
- Progression globale de collecte et changement de destination actualisés.
- Sources correspondantes, installation par DMG et bibliothèque conservée.

La qualification et ses limites sont consignées dans [RELEASE-0.7.0.md](docs/RELEASE-0.7.0.md).

## 0.6.0 — 2026-09-30

- Identité stable entre résumé et fiche ; ancienne analyse conservée sans source ; durée de vol et GNSS qualifiés par couverture.
- Projections SQLite version 7, requêtes paginées et scope partagé ; annotations, masquages, recherche Unicode et tri intégrés aux agrégats.
- Sources d’import retirables et restaurables sans supprimer les ULogs ni leurs analyses ; liste persistante et globale.
- Drones scannés et identités provisoires séparés ; durée enregistrée et temps de vol cumulé avec couverture explicitée.
- Badges de signaux distincts de la qualité de lecture, y compris les événements PX4 non traduits ; aides au survol et au clic harmonisées dans les rapports.
- Sauvegardes vérifiées, restauration avec recovery, archives et réassociation SHA ; nettoyage de cache réversible sans supprimer les sources.
- File GCS SQLite durable, inventaires en pages, progression par phase, imports exacts et arrêt borné des helpers ; protection du verrou après décès du parent.
- Événements binaires bruts, dictionnaires locaux exact SHA, couverture des caches et niveaux interne/externe distincts.
- Catalogue réel Batterie/GNSS/EKF, quatre courbes partageant 2 048 points, segments et pertes annoncés ; relevé HTML/JSON exportable.
- Rapports de toute la sélection par pages, capture cohérente, publication atomique, progression/annulation et partage conservateur.
- Nouveaux écrans bento clair/sombre/Système approuvés, activés par défaut dans les builds stables 0.6.0 ; Preview isolée de la bibliothèque, des réglages et de la file GCS installés.
- Reconnexion initiale GCS différée jusqu’à la fin de la maintenance de la bibliothèque, sans relancer une collecte arrêtée.
- Sparkle 2.10.0 embarqué et signatures testées ; **feed désactivé** jusqu’au choix et à la recette de staging.
- Licence GPL-3.0-only pour le code propre, notices originales et tierces conservées dans le bundle ; sources correspondantes associées à la release.
- CI autonome Python/Swift/Node et packaging ARM64 sur runners standard uniquement après passage public du dépôt ; diagnostic sans données privées par défaut et contrôles de publication.

La validation finale, les mesures et les gates externes sont suivis dans
[IMPLEMENTATION-0.6.0.md](docs/IMPLEMENTATION-0.6.0.md). Aucune release publique
ni modification de l’app installée ne découle de ce lot.

## Préparation du dépôt public — historique

Ce travail accompagne la préparation de 0.6.0. Le dépôt est désormais public ;
le statut courant est décrit dans [PUBLICATION.md](docs/PUBLICATION.md).

- Fixtures et exemples anonymisés ; GCS configurée par l'utilisateur.
- Documentation opérationnelle et anciennes maquettes privées retirées du contenu publiable.
- Corpus réel optionnel via `KATALOG_PRIVATE_FIXTURES`, avec tests publics autonomes.
- Chemins de compilation neutralisés et contrôle avant packaging.
- Contrôle de publication et plan 0.6.0 : DMG standard, moteur embarqué et updater public.

Le dépôt historique et la release 0.5.1 sont isolés dans une archive privée distincte.
Ce dépôt démarre avec les sources nettoyées et ne contient aucun ancien asset.

## 0.5.2 — distribution autonome

- Helper macOS ARM64 embarqué avec CPython 3.13.15, NumPy 2.5.3 et pyulog 1.2.4 ;
  dépendances épinglées et téléchargements contrôlés par SHA-256, licences incluses.
- Résolveur partagé import/collecte : handshake du moteur, environnement nettoyé,
  aucun fallback Python externe dans une app distribuée ; erreur de réinstallation
  lorsqu’un composant est absent ou incompatible.
- Build nettoyé des chemins personnels et des chemins de recherche Xcode,
  signature des composants natifs et des bundles imbriqués avant l’app.
- Pipeline DMG avec lien Applications et présentation monochrome ; vérification
  du contenu copié, signature et notarisation configurables par Trousseau.
- Recette du package : ULog synthétique, dédoublonnage, détails hors ligne,
  collecte GCS sur simulateur local, inspection des archives Python compressées
  et des dépendances natives. Aucun log ni état de flotte n’est distribué.
- Version ciblée : 0.5.2 (build 7), macOS 15 minimum, Apple Silicon. Cette version
  ne livre pas les autres fonctionnalités du plan 0.6.0 ; le dépôt reste privé.
- Package local signé Developer ID, accepté par Apple et tickets agrafés ;
  lancement après copie/éjection, import, fiche, carte et export HTML testés
  sous macOS 27. Voir la recette et ses limites dans `docs/DISTRIBUTION-VALIDATION.md`.

## 0.5.1 — 29 septembre 2026

Première release distribuée sur GitHub, **build 6**. Elle réunit les évolutions
locales des versions 0.3 à 0.5 et le nouveau rapport interactif 0.5.1.

### Rapport HTML interactif

- Nouvelle présentation bento monochrome avec thèmes clair et sombre.
- Radar des familles d’alertes entre 3 et 8 familles, barres dans les autres cas ;
  un clic filtre les messages et les logs concernés.
- Graphique d’activité cliquable par jour, mois ou année selon les données.
- Filtres combinables : drone, famille, niveau et recherche. Les compteurs et
  l’historique suivent le périmètre sélectionné.
- Groupes dépliables, explications des alertes et accès aux logs sources.
- Impression/PDF du périmètre filtré, avec ses détails dépliés.
- Fichier autonome consultable hors ligne ; styles, données et interactions
  sont intégrés. Les exports JSON conservent leurs données et leur format.

### Bibliothèque, carte et détails

- Import récursif des ULog avec progression, annulation, cache SQLite,
  déduplication SHA256 et réanalyse locale sans nouveau téléchargement.
- Carte Apple Maps avec trajectoires segmentées et alertes géolocalisées lorsque
  les données du log le permettent.
- Fiche par log : messages filtrables, mesures, GPS, paramètres, topics,
  couverture et provenance ; détails calculés conservés localement.
- Numéro de drone saisi manuellement, associé à l’identité source et conservé au
  redémarrage, y compris pour un drone enregistré dans la flotte sans log.
- Familles d’alertes personnalisables et explications sourcées des messages
  documentés, avec distinction entre observation et interprétation.
- Nouvelle icône cohérente avec le logo de l’interface.

### Collecte GCS

- Détection des drones et flotte autorisée enregistrée par UUID.
- Collecte de toute la flotte connectée ; deux drones en parallèle, un fichier
  à la fois par drone, progression globale et file persistante.
- Pause, arrêt local, relance et réessais bornés des erreurs transitoires.
- Reconnaissance des fichiers déjà vérifiés et import automatique après collecte.
- Dossier de destination personnalisé conservé au redémarrage, sans changement
  silencieux de destination en cas d’accès impossible.
- Manifeste de provenance et vérification de taille et SHA256 des fichiers reçus.

### Validation et distribution

- Release 0.5.1 : **68 tests Python, 64 tests Swift et 9 tests JavaScript**, plus
  une recette réelle du rapport dans l’app installée et le navigateur.
  Détails dans [UI-VALIDATION.md](docs/UI-VALIDATION.md).
- Distribution pour **macOS 15+ sur Apple Silicon**, signée avec un certificat
  **Developer ID et notarisée par Apple**. Python 3, `pyulog` et `numpy` restent à installer
  séparément sur un nouveau Mac.
- Build local avec signature ad hoc par défaut ; certificat Developer ID
  configurable via `KATALOG_SIGN_IDENTITY`, notarisation séparée. L’installateur
  local refuse de remplacer une app encore ouverte.
- Mise à jour manuelle en remplaçant le bundle de l’app ; la bibliothèque,
  les annotations, les réglages et les logs locaux sont conservés.
  Voir [les instructions de mise à jour](docs/UPDATING.md).

### Limites connues

- Les événements binaires PX4 restent non décodés sans dictionnaire du firmware.
  Une alerte texte n’est pas une panne confirmée.
- La collecte réelle a été validée avec la GCS Drotek 3.7.2 et deux drones ;
  une flotte complète de 500 drones reste à qualifier.
- L’arrêt de collecte interrompt la copie locale ; une copie déjà demandée à la
  GCS peut continuer. Les réessais après perte réseau sont testés par simulation.
- Si l’interface web GCS 3.7.2 reste ouverte dans Edge, elle peut créer sa propre
  copie dans Téléchargements. Voir le [diagnostic](docs/GCS-COLLECTION.md#copies-supplémentaires-dans-téléchargements-gcs-web-372).
- Aucun mécanisme de mise à jour automatique n’est intégré à cette version.
