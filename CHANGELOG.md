# Changelog

## À venir — préparation publique

- Fixtures et exemples anonymisés ; GCS configurée par l'utilisateur.
- Documentation opérationnelle et anciennes maquettes privées retirées du contenu publiable.
- Corpus réel optionnel via `KATALOG_PRIVATE_FIXTURES`, avec tests publics autonomes.
- Chemins de compilation neutralisés et contrôle avant packaging.
- Contrôle de publication et plan 0.6.0 : DMG standard, moteur embarqué et updater public.

Le dépôt historique et la release 0.5.1 sont isolés dans une archive privée distincte.
Ce dépôt démarre avec les sources nettoyées et ne contient aucun ancien asset.

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
