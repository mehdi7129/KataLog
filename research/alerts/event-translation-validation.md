# Validation réelle de la traduction des événements — 15 octobre 2026

Le parseur libevents utilisé par le moteur corrigé a traduit **17 événements réels sur 17**, avec **zéro erreur**. Les 17 textes rendus sont non vides ; 5 définitions fournissent aussi une description et les 50 valeurs d’arguments déclarées ont été décodées sans erreur. Les 25 octets d’arguments de chaque événement proviennent exclusivement du cache existant, sans padding ajouté ni valeur fabriquée.

Le dictionnaire utilisé est celui embarqué dans l’unique source locale vérifiée, lié par SHA-256 à ses métadonnées et au cache existant. Le loader applicatif corrigé renvoie `ready` et transmet cet artefact exact au parseur en profil `dev`. Les empreintes de firmware et de dictionnaire restent dans les preuves privées.

La vérification ouvre SQLite en URI `mode=ro`, active `query_only`, conserve une transaction de lecture cohérente, puis l’annule. Elle lit uniquement le cache déjà identifié et sa source vérifiée, sans reimport, réanalyse de vol ni mutation de l’application, de la bibliothèque ou des préférences. Aucun texte d’événement, argument, identifiant privé, chemin source ni dictionnaire brut n’est exporté. La synthèse publique ne conserve que les compteurs et les propriétés de validation.

Cette preuve vérifie la traduction technique avec les définitions du firmware exact. Elle ne prétend pas établir un diagnostic physique et ne signifie pas que la bibliothèque existante a déjà été réanalysée par l’application corrigée.

Résultat machine agrégé : [event-translation-validation.json](event-translation-validation.json). Les scripts ciblés et la copie intégrale des preuves initiales restent localement dans le dossier ignoré `private-data/alerts-research-20261015/`. La CI publique teste la régression avec un dictionnaire synthétique ; elle ne lit pas les événements réels.
