# Contrat d’import et de lecture — KataLog 0.8.1

Référence actuelle : app **0.8.1**, parseur **1.4.0**, enveloppe JSON
**`schemaVersion: 1`**, projection SQLite **8**. Les propriétés optionnelles
permettent de conserver les anciens résumés ; une version de parseur ne se
confond pas avec une version d’app ou de base.

## Entrées et stockage

L’import parcourt un dossier de fichiers `.ulg`. Il propose de **référencer** les
sources ou de **copier vers des archives** avant analyse. Une copie non vérifiée
n’est pas analysée ; l’original et les analyses précédentes sont préservés.
La collecte GCS analyse les fichiers de sa destination sans créer une seconde
archive automatique. Voir [le contrat de collecte](GCS-COLLECTION.md).

SQLite est l’autorité de lecture. Chaque log validé est conservé après annulation
d’un lot ; `library.json` est un export/cache, pas une seconde base à synchroniser.
Les fichiers JSON de sortie sont écrits atomiquement. Les erreurs sont annoncées
par fichier et ne font pas disparaître les autres résultats.

Un fichier inchangé est reconnu par sa signature de fichier et la version du
parseur. Le SHA-256 identifie le contenu et déduplique les copies identiques.
Les sources multiples sont conservées comme références d’un même contenu.
Changer le contenu d’un chemin ne remplace pas le résumé historique précédent.

Un nouveau contenu reçoit le client choisi pour l’import ou le travail de collecte.
Un doublon ou une réanalyse conserve son attribution ; une réattribution est
explicite. Les numéros de stock et les clients ne sont jamais utilisés comme
identifiants uniques de contenu. Voir [clients et conservation](CLIENTS-BENTO.md)
et [identité des drones](STOCK-IDENTITY.md).

## Version, migration et réanalyse

La projection SQLite 8 prépare les lectures paginées et les agrégats sans
supprimer les résumés canoniques. La migration crée une sauvegarde. Une ancienne
analyse reste consultable ; la réanalyse est une action explicite et nécessite
une source locale exploitable. Aucun téléchargement GCS n’est requis pour
migrer les projections.

Les résultats distinguent `ok`, `partial` et `error`. Une lecture partielle peut
fournir des mesures utiles ; un champ absent reste inconnu. La durée enregistrée
inclut le temps au sol et ne remplace pas le temps de vol mesuré. Les dates GPS
sont en UTC ; aucun fuseau horaire n’est inventé pour une date issue d’un chemin.
Une alerte enregistrée ne constitue pas une panne matérielle confirmée.

## Requêtes et carte

L’app utilise les requêtes paginées, les agrégats de sélection et les détails à
la demande. La page de résultats ordinaire est bornée à 200 éléments ; le contrat
applique aussi une limite de taille de réponse. Les clients, dates, textes,
familles, sévérités et messages masqués sont pris en compte dans le périmètre
avant les comptes et la pagination.

La vue générale de la carte utilise `map-overview` : toutes les pages de repères
sont chargées pour le périmètre demandé, avec des réponses bornées à **5 000
éléments / 4 Mio**. Il n’existe plus de limite globale aux 80 logs les plus récents.
MapKit regroupe les repères proches ; ouvrir un log charge sa trajectoire détaillée.

La recherche de proximité porte sur les trajectoires complètes disponibles et
leurs segments valides. Un segment traversant la zone suffit ; aucune liaison
n’est ajoutée à travers une lacune GPS. Une trajectoire complète impossible à
vérifier est signalée. Le repère affiché reste un échantillon enregistré, même
si celui-ci se trouve hors du rayon traversé par son segment.

Le cache natif de navigation conserve au plus huit résultats. Sa clé inclut la
requête et l’état des fichiers de la bibliothèque ; les mutations et
l’actualisation explicite invalident les résultats concernés. Voir
[les mesures et leurs limites](PERFORMANCE-MAP-NAVIGATION.md).

## Détails, mesures et événements

`detail` renvoie un seul log, pas un snapshot de flotte. Le cache SQLite
`flight_details` et les révisions historiques conservent les détails déjà
calculés. La source n’est relue qu’après vérification de son SHA-256. Si elle est
absente ou modifiée, les résultats historiques disponibles restent consultables,
avec leur provenance et leurs limites ; ils ne sont pas présentés comme recalculés.

La fenêtre du log propose messages, mesures, courbes et couverture. Les séries
sont demandées à la source vérifiée, bornées pour l’affichage et accompagnées de
leurs unités disponibles. Une unité ou une mesure manquante n’est pas déduite
arbitrairement du nom d’un champ. Paramètres, topics, champs personnalisés et
événements PX4 spécialisés sont accessibles en mode avancé.

Les événements PX4 peuvent être décodés lorsqu’un dictionnaire compatible avec
le firmware est disponible et vérifié. Sans correspondance exacte, les données
brutes sont conservées et l’absence de traduction est explicite. Un texte
ressemblant n’est pas une preuve de correspondance.

## Rapports et confidentialité

L’export distingue la **sélection courante** du **rapport complet**. Le rapport
complet retire les autres filtres, inclut les éléments masqués et conserve le
client sélectionné. Choisir **Tous les clients** pour couvrir toute la bibliothèque.
La fiche d’un log possède son export propre.

Le rapport HTML est autonome : graphiques et filtres s’exécutent localement,
sans CDN ni serveur. Le contenu reste lisible sans JavaScript. Les filtres du
rapport et l’impression limitent l’affichage ; ils ne retirent pas les données
du fichier exporté. Les liens documentaires externes nécessitent une action du lecteur.

Les exports privés peuvent contenir identités, noms de clients, chemins et GPS.
Le mode partage applique ses règles de masquage avant génération du document.
Le JSON détaillé ne prétend pas contenir toutes les séries brutes de l’ULog.
Relire tout fichier avant de le publier ; les diagnostics contenant ULogs ou
journaux GCS bruts restent privés. Voir [publication](PUBLICATION.md).

## Interface du moteur pour le développement

Après préparation de l’environnement décrit dans [CONTRIBUTING.md](../CONTRIBUTING.md) :

```sh
.venv/bin/python3 Sources/KataLog/Resources/analyzer.py scan \
  --folder /chemin/vers/logs --database reports/library.sqlite \
  --output reports/snapshot.json --progress reports/progress.json

.venv/bin/python3 Sources/KataLog/Resources/analyzer.py snapshot \
  --database reports/library.sqlite --output reports/snapshot.json --read-only

.venv/bin/python3 Sources/KataLog/Resources/analyzer.py detail \
  --log-id SHA256 --database reports/library.sqlite --output reports/detail.json
```

`scan` accepte aussi `--archive-destination`, `--client-id` et `--skip-snapshot`.
`detail` accepte `--revision` et `--read-only`. Les commandes `query`,
`ensure-index` et `series` exposent les autres opérations du moteur. Les arguments
exacts sont documentés par `--help` dans
[analyzer.py](../Sources/KataLog/Resources/analyzer.py) ; les bornes et projections
sont définies dans [library_repository.py](../Sources/KataLog/Resources/library_repository.py).
