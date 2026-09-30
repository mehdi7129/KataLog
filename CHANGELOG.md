# Changelog

## 0.6.0 — en préparation, non publiée

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

## À venir — préparation publique

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
  Voir [les instructions de mise à jour](README.md#mettre-à-jour-une-app-déjà-installée).

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
