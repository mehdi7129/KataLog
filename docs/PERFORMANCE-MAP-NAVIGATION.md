> **Mesures historiques — développement de 0.8.1, le 3 octobre 2026.**
> La mention « non publiés » ci-dessous décrit l’état avant publication.
> Ces changements ont été livrés dans la Preview du 3 octobre, puis dans la
> [stable 0.8.1 (build 20), publiée le 5 octobre](RELEASE-0.8.1.md).
> Les mesures et leurs limites restent celles des exécutions décrites.

# Carte, navigation et collecte — validation de développement

État : changements postérieurs à 0.8.0, non publiés. Mesures locales du 3 octobre 2026.

## Comportement

- L’indicateur de vol présente la valeur en minutes sur une ligne, puis « Temps de vol cumulé ». Durée enregistrée et couverture restent dans l’aide. La mention « Copies identiques dédupliquées » disparaît des indicateurs ; la déduplication reste active.
- La vue générale de la carte charge tous les marqueurs de la sélection, par pages bornées à 5 000 éléments / 4 Mio. Les coordonnées sont des échantillons enregistrés, jamais inventés. MapKit regroupe les repères proches. La fiche du log charge sa trajectoire à la demande.
- Le client, les dates et les filtres de messages s’appliquent avant le comptage et la pagination. La recherche géographique continue de tester les trajectoires complètes et leurs segments valides. Son repère est l’échantillon enregistré le plus proche du lieu recherché ; il peut être hors du rayon si un segment traverse la zone entre deux échantillons.
- Huit résultats de navigation au maximum sont retenus en mémoire. Leur clé comprend toute la requête : sélection, client, annotations, messages masqués, ordre, curseur, recherche et proximité. Les identités et dates de modification de SQLite et du WAL empêchent la réutilisation après modification externe. L’onglet Drones surveille aussi le registre ; un heartbeat GCS seul ne vide pas le cache de l’historique ou de la carte. L’actualisation explicite et les mutations invalident aussi le cache.
- Un retour sur un onglet déjà chargé restaure son résultat sans lancer de moteur. Une actualisation de la même sélection garde le contenu visible. Une autre sélection ne réutilise pas les résultats de l’ancienne.
- Un helper annulé doit avoir terminé avant que l’app ne libère le verrou d’activité, même si la destination de navigation est en cache.
- Deux transferts restent autorisés, sur des drones distincts. Une file d’analyse séparée utilise un seul worker ; au plus quatre fichiers se trouvent simultanément en transfert ou en analyse/en attente d’analyse. L’état durable `importing` précède la libération du slot réseau. Une erreur d’analyse conserve le fichier vérifié.

## Mesures

| Expérience | Avant | Après | Périmètre mesuré |
| --- | ---: | ---: | --- |
| Carte, copie isolée de 180 logs | 80 trajectoires, 2 929 065 octets | 180 marqueurs, 51 341 octets | Corps JSON ; représentation volontairement plus légère |
| Même requête carte | 115,9 ms | 5,3 ms | Moteur Python déjà chargé, hors lancement de processus et dessin MapKit |
| Navigation répétée | Requêtes à chaque changement | 40 retours en 2,7 ms ; zéro helper | Store natif et moteur synthétique ; hors dessin de fenêtre |
| Collecte de 8 fichiers synthétiques, un drone | 5,200 s | 2,927 s | Une exécution par variante ; transfert simulé 150 ms et analyse 300 ms |
| Carte de volume | Limite de 80 | 50 000 / 50 000 marqueurs en 10 pages, 2,73 s | Backend en processus ; 0,156–0,447 s/page, environ 1,18 Mo/page |

La nouvelle carte retrouve les onze enregistrements anciens exclus de l’ancienne sélection de 80 logs dans la copie de bibliothèque. La préparation de son nouvel index a pris 1,09 s. Les originaux et la bibliothèque de l’application installée n’ont pas été modifiés.

Le gain de 43,7 % du banc de collecte concerne le chevauchement transfert/analyse simulé. Il ne qualifie pas le débit Wi-Fi, FTP, une vraie GCS ou une flotte de 500 drones. L’inventaire des drones reste séquentiel.

## Vérifications

- Pagination exhaustive, curseurs, révision, absence de GPS, anciennes positions, filtres clients/messages/dates et recherche de segments sans liaison à travers une lacune.
- Migration de l’index précédent avec sauvegarde et conservation des résumés canoniques.
- Cache : clés de sélection, borne et éviction, restauration de l’historique, changements de WAL/registre, mutations, reprise après annulation et démarrage directement sur la carte.
- Collecte : analyse lente, concurrence sur deux drones, limite de fichiers en attente, pause/reprise, arrêt/redémarrage, erreurs d’analyse et attribution au client capturé.
- Rendu natif en clair/sombre, notamment un total de 1 512,9 minutes et une carte de 180 marqueurs synthétiques.

Suite complète : 341 tests Swift réussis, zéro échec et zéro test ignoré. Après les derniers ajustements visuels, huit contrôles ciblés réussissent aussi, dont un nouveau test natif vérifiant les 180 annotations MapKit, leur cadrage et l’ouverture du log sélectionné. Suite Python : 379 tests réussis ; un test exigeant un ancien corpus privé de neuf fichiers n’a pas été exécuté. Contrôle des fichiers courants, y compris nouveaux fichiers : 246 fichiers, aucun signalement de données privées usuelles. Ce contrôle ne constitue pas un nouvel audit de tout l’historique Git.

Les artefacts locaux de mesure et les copies privées restent hors du dépôt. Les tests et fixtures ajoutés au dépôt sont synthétiques.
