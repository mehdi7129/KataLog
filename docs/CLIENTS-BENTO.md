# Clients et interface Bento

Cette évolution est destinée à **0.8.0 (build 18)**. La Preview est validée ;
le statut du package stable et de sa publication figure dans la
[recette de release](RELEASE-0.8.0.md).

## Contrat produit

- Les clients sont des regroupements locaux nommés librement, sans compte ni cloud.
- Le sélecteur propose tous les clients, un client nommé ou les logs sans client.
- L'attribution est portée par chaque log ; l'identité du contrôleur reste unique.
- Un nouveau log est attribué au client choisi à l'import ou au démarrage de sa collecte.
- Un doublon ou une réanalyse conserve son attribution. Le changement se fait explicitement, en lot si nécessaire.
- Les logs déjà présents restent dans « Sans client » à la migration. Supprimer un client y replace ses logs et retire sa référence des travaux de collecte, sans supprimer fichiers ou analyses.
- « Tous les clients » est un périmètre de consultation. L'import et la collecte affichent un destinataire concret.
- Statistiques, registre, carte et rapports respectent le client sélectionné. Stockage et réinitialisation sont globaux et l'indiquent.

## Interface

Boutons discrets sans contour ni fond permanent, survol et focus visibles. Thème clair/sombre en un clic, système dans les réglages. Cartes Bento monochromes, accents réservés aux états et graphiques. Activité récente dans une carte alignée sur les alertes, avec défilement interne et accès à l'historique complet.

Les drones éligibles connectés à la GCS sont directement collectables. L'attribution à un client et le numéro de stock sont indépendants. Chaque travail en file conserve son client destinataire ; changer le sélecteur après son démarrage ne réattribue pas ses logs. Les protections existantes contre les transferts simultanés incompatibles et les appareils signalés armés sont conservées.

La carte recherche une ville, une adresse ou des coordonnées avec un rayon. Les noms de lieux dépendent du service Apple. Les anciennes trajectoires complètes sont mises en cache lorsque leurs sources sont accessibles, puis restent recherchables hors ligne. Un log correspond dès qu'une portion de sa trajectoire traverse la zone. La recherche s'applique avant la limite d'affichage et annonce les logs dont la trajectoire complète n'a pas pu être vérifiée. Aucune liaison n'est inventée dans une lacune GPS.

Chaque fiche de log possède sa fenêtre macOS et son état de lecture indépendants. Les données PX4 spécialisées sont accessibles via le mode avancé, désactivé par défaut.

## Nettoyage

| Action | Effet | Conservation |
| --- | --- | --- |
| Retirer les sources | Masque les références de dossiers de la liste | Analyses et fichiers |
| Vider la bibliothèque | Efface analyses, sources et historique d'import de tous les clients | Clients, identifications, réglages et fichiers `.ulg` |
| Réinitialiser KataLog | Efface également clients, identifications, réglages et état de collecte | Tous les fichiers `.ulg`, y compris sous le dossier interne de collecte |

Les commandes destructives nécessitent une confirmation explicite et concernent tous les clients. Le répertoire de bibliothèque n'est jamais supprimé récursivement. Ces opérations ne sont jamais déclenchées par une mise à jour de l'app.

Le rapport complet couvre tous les logs du client sélectionné. Pour couvrir toute
la bibliothèque, sélectionner « Tous les clients ». Les rapports en mode partage
retirent aussi les noms et identifiants de clients ; les exports privés peuvent
les inclure.

## Vérifications

Migration sans attribution implicite ; isolation des résultats et rapports ; déduplication entre clients ; attribution en lot ; destination de collecte capturée au démarrage ; proximité sur segments et lacunes ; sessions de fenêtres indépendantes ; nettoyage préservant les originaux internes et externes ; contrôle visuel en clair/sombre aux dimensions de fenêtre prises en charge.
