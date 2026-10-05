# Diagnostic local — KataLog 0.8.1

## Utilisation

1. Ouvrir **Réglages → Aide et diagnostic → Préparer un diagnostic…**.
   Le mode avancé donne aussi accès au panneau **Diagnostic local**.
2. Vérifier les compteurs, les événements récents et la liste des pièces du ZIP.
3. Si utile, cliquer **Récupérer les logs GCS**. L’adresse vient de Collecte GCS.
   Une GCS hors ligne ou un firmware sans cet endpoint n’empêche pas le diagnostic local.
4. Les journaux GCS sont joints sous forme de synthèse filtrée. Activer **Inclure
   les journaux GCS bruts** uniquement pour un diagnostic interne : leurs textes
   peuvent contenir des identités, adresses réseau, positions et informations d’infrastructure.
5. Pour examiner un drone, activer l’ajout de ULogs et choisir précisément les
   fichiers. Cette option ne démasque pas les journaux GCS.
6. Exporter le ZIP local. Il n’est jamais envoyé automatiquement.

**Effacer le journal** retire uniquement les événements techniques de KataLog
après confirmation. Les ULogs, analyses et sources restent conservés. Cette
action est désactivée pendant une opération et dans une instance en lecture seule.

## Trois sources complémentaires

| Source | Ce qu’elle permet d’observer | Limites |
| --- | --- | --- |
| ULog PX4 | Vol, capteurs, modes, événements et alertes enregistrés par le drone | Contenu dépendant du firmware et de la configuration de logging |
| Journal KataLog | Connexion, inventaire, cache, transfert, reprise, annulation, analyse et export | Seulement les événements des versions équipées du journal ; aucune reconstitution rétroactive |
| Services GCS | MQTT, liaison radio, backend et serveur web | Endpoint `/servicelogs` dépendant du firmware ; export du démarrage actuel |

Les heures du journal KataLog sont enregistrées en UTC, avec une durée monotone
depuis le lancement. La GCS peut utiliser une autre horloge ; les timestamps ULog
peuvent être relatifs au démarrage du drone. Les trois sources ne sont pas
alignées automatiquement. Une proximité temporelle ne démontre pas une cause.

## Journal et confidentialité

- Fichiers locaux `Diagnostics/events.jsonl` et jusqu’à trois rotations.
- Limite par défaut : 512 Kio par fichier, quatre fichiers au total, rétention de
  14 jours, nettoyée lors des écritures et des lectures.
- Événements et codes d’erreur typés, compteurs bornés, phases de transfert
  explicites. Les progrès sont échantillonnés au plus toutes les cinq secondes,
  avec un événement aux changements de phase.
- Aucun texte d’erreur libre, chemin, endpoint, numéro de stock ou UUID de drone
  n’est enregistré. Les identifiants de corrélation sont pseudonymisés avec un
  secret différent à chaque lancement, conservé uniquement en mémoire.
- Une seconde instance en lecture seule utilise un journal en mémoire ; elle ne
  modifie pas le journal de l’instance qui détient la bibliothèque.
- Les lignes illisibles et les écritures perdues sont comptées dans le diagnostic.
  Un problème de journal ne bloque ni la collecte ni l’analyse.
- Les captures GCS brutes sont conservées en mémoire pendant la prévisualisation,
  puis retirées à sa fermeture. Leur inclusion dans le ZIP exige l’option dédiée.
- La synthèse filtrée conserve uniquement des catégories techniques reconnues,
  niveaux, horodatages et statuts HTTP ; les messages libres sont retirés. Ce
  filtrage réduit le détail disponible. Les ULogs restent des fichiers bruts privés.

## Archive exportée

- `snapshot.json` : versions, système, états et compteurs avec leurs périmètres.
- `events.jsonl` : chronologie locale structurée conservée au moment de la capture.
- `LISEZ-MOI.txt` : explications et événements récents lisibles sans l’app.
- `manifest.json` : liste des pièces, tailles, SHA-256 et limites de couverture.
- `gcs/` : synthèses filtrées ou textes bruts sur choix explicite.
- `ulog/` : ULogs sélectionnés explicitement, avec noms générés sans leur chemin source.

L’export est préparé dans un dossier temporaire privé près de sa destination,
puis publié atomiquement. Annuler conserve un export précédent et nettoie les
fichiers temporaires. Limites : archive GCS reçue 20 Mio ; 2 Mio par journal GCS,
8 Mio de textes au total ; ULogs 256 Mio par fichier et 1 Gio au total.
Le client refuse les redirections, entrées ZIP inattendues, chemins, liens et
doublons. Il lit uniquement les cinq noms de services reconnus, sans extraire
les chemins de l’archive. Aucun SSH, MQTT, FTP ou ordre de vol n’est envoyé par
la récupération des journaux de services.

## Recette de collecte

À effectuer au banc avec les moteurs désarmés. Fermer les autres clients de
transfert FTP et garder les preuves hors du dépôt.

| Cas | Résultat attendu |
| --- | --- |
| Dossier A vide | Progression initiale à zéro, phases drone→GCS puis GCS→Mac visibles |
| Nouvelle collecte vers A | Copies déjà vérifiées réutilisées ; statistiques non multipliées |
| A→B vide→A | Progression et inventaire recalculés pour le dossier choisi ; A réutilisé |
| Pause puis reprise | Fichiers actifs terminés, suivants suspendus, reprise cohérente |
| Arrêt pendant chaque phase | Arrêt des clients locaux ; fichiers complets conservés, aucun faux succès |
| Drone ou GCS indisponible | Erreur de connexion/transfert claire, reprise bornée, journal exploitable |
| Redémarrage KataLog | Destination conservée, file durable cohérente, nouvelle session de journal |
| Diagnostic GCS avant reboot | ZIP de services disponible, messages privés retirés par défaut |
| Deux drones | Travaux concurrents sur deux drones, un seul transfert FTP par drone |

Pour valider les statistiques de vol, utiliser aussi plusieurs ULogs de vols
réels variés. Un drone allumé et désarmé ne crée pas nécessairement un nouveau
ULog ; télécharger plusieurs fois le même fichier vérifie surtout le cache.
Les tests simulés ne remplacent pas cette recette matérielle.

## Validation historique — 30 septembre 2026

- 301 tests Swift : zéro échec, zéro test ignoré, sur macOS 27.
- 17 tests ciblés de bibliothèque, maintenance et rapports repassés après la
  dernière correction du code d’annulation des exports.
- 38 tests Python du collecteur : zéro échec.
- Captures natives du diagnostic en clair/sombre à 820×620 : cartes alignées,
  contenu défilant et actions de fermeture/export accessibles.
- Appel natif réel de `/servicelogs` : cinq fichiers récupérés, puis export ZIP
  filtré. CRC, tailles et SHA-256 vérifiés ; aucune valeur privée recherchée
  retrouvée dans l’export par défaut.
- Contrôle de publication : 220 fichiers, zéro signalement. Gitleaks : aucune
  fuite détectée. Les archives réelles et preuves restent hors du dépôt.

Ces résultats décrivent la recette du 30 septembre, pas la qualification complète
de la version actuelle. Voir la [release 0.8.1](RELEASE-0.8.1.md) pour les tests
du package publié. Les essais simulés ne constituent pas une validation de vol.
