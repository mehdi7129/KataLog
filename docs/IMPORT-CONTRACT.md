# Contrat d’import et des fiches — app 0.5 / parseur 1.2.0

## Entrées et stockage

CLI Python :

```sh
analyzer.py scan --folder PATH --database PATH --output PATH --progress PATH
analyzer.py snapshot --database PATH --output PATH
analyzer.py detail --log-id SHA256 --database PATH --output PATH
```

Python 3 avec pyulog + numpy, lecture seule des sources. SQLite stocke le résumé
et tous les messages texte, déduplication SHA256, reprise des fichiers inchangés,
erreurs par fichier sans arrêter le lot. **SQLite est l’autorité de lecture** :
les commits par log sont conservés après annulation et le rechargement de l’app
reconstruit son snapshot depuis la base. `library.json` reste un export/cache.
Le résultat JSON est écrit atomiquement à `--output`. Progression JSON atomique
facultative : `{completed,total,current}`.

Le schéma public demeure **`schemaVersion: 1`**. La version de calcul est distincte :
`metadata.parserVersion: "1.2.0"`. Les anciennes analyses restent lisibles ; le
bouton **Actualiser les analyses** relit les sources locales avec la version
courante, en conservant les identifiants SHA256 et l’historique. Des fichiers
inchangés mais issus d’un autre parseur sont réanalysés.

Les résumés utilisent la table `logs`; la table séparée `flight_details` contient
les fiches calculées à la demande, indexées par SHA256 avec leur version de parseur.
`detail` renvoie un **seul `FlightLog`**, sans enveloppe `FleetSnapshot`. En l’absence
de cache courant, la source est vérifiée par SHA256 et signature de fichier avant
publication. Une source absente ou modifiée ne remplace pas l’analyse de l’original.
Une fiche déjà calculée reste lisible depuis le cache courant si la source disparaît.

Les imports SD ne copient pas automatiquement les ULog dans une archive gérée.
Les copies produites par le collecteur GCS ont leur propre dossier local et
manifeste vérifié. Conserver les sources pour les analyses futures.

## Snapshot de bibliothèque

Structure de base (les champs ajoutés ensuite sont facultatifs pour les anciens
imports ; `flightSeconds` est nullable) :

```
{
 "schemaVersion":1,
 "generatedAt":"ISO8601",
 "sourceFolders":["path"],
 "importStats":{"discovered":9,"imported":9,"unchanged":0,"duplicates":0,"failed":0},
 "logs":[{
   "id":"sha256", "droneID":"uuid/fallback", "droneName":"name",
   "date":"2025-09-09T19:22:52", "dateSource":"path / gps / unknown",
   "sourcePaths":["absolute path"], "fileName":"19_22_52.ulg", "sizeBytes":123,
   "durationSeconds":450.7, "flightSeconds":null,
   "status":"ok / partial / error", "issues":["..."],
   "metadata":{"firmware":"...","parserVersion":"1.2.0"}, "topics":["sensor_gps"],
   "messages":[{
     "id":"hash-index", "timestampSeconds":12.34,
     "level":"INFO / WARNING / ERROR / DEBUG / CRITICAL / ALERT / EMERGENCY / NOTICE / UNKNOWN",
     "text":"raw message", "family":"Batterie / Communication / GNSS / Capteurs / Propulsion / Navigation / Système / Éclairage / Température / Autres",
     "groupKey":"family|level|normalized text", "title":"readable title", "isAlert":true
   }],
   "metrics":[{"key":"gps.rtk_fixed","label":"RTK fixé","value":99.4,"unit":"%","detail":"instance 0, pondéré par timestamps"}],
   "coverage":["Topic ESC absent", "événements binaires non décodés: 4"],
   "failsafeObserved":false,
   "track":null
 }]
}
```

`track` est nullable/absent. Lorsqu’une trajectoire est disponible, le snapshot
conserve un aperçu de **256 points au plus** par log. La vue flotte n’affiche que
les **80 logs géolocalisés récents** de son périmètre ; cette limite de rendu ne
supprime aucun enregistrement de la bibliothèque.

## Trajectoires et détails à la demande

La fiche ajoute les champs suivants au `FlightLog` de base :

```json
{
  "track": {
    "source": "sensor_gps[0] · WGS84 · lat/lon · altitude MSL",
    "originalPointCount": 2263,
    "rejectedPointCount": 0,
    "points": [
      {"timeSeconds": 12.5, "latitude": 45.0, "longitude": 4.0,
       "altitudeMeters": 100.0, "segment": 0}
    ]
  },
  "topicDetails": [
    {"name": "sensor_gps", "instance": 0, "sampleCount": 2263,
     "fields": ["timestamp", "lat", "lon", "fix_type"]}
  ],
  "parameters": {"EXAMPLE_PARAMETER": "1"},
  "parameterChanges": [
    {"timeSeconds": 12.5, "name": "EXAMPLE_PARAMETER", "value": "2"}
  ]
}
```

Ces valeurs illustrent le format. Les données de l’app proviennent exclusivement
des ULog importés.

- **Choix du récepteur :** retenir le candidat GNSS qui possède le plus de points
  valides ; à égalité, préférer `sensor_gps`, puis l’instance de plus petit numéro.
  Les récepteurs ne sont pas fusionnés.
- **Unités :** `lat`/`lon` sont convertis depuis 10⁻⁷ degré et `alt` depuis les
  millimètres ; `latitude_deg`/`longitude_deg` et `altitude_msl_m` sont déjà en
  degrés et mètres. La conversion dépend des noms enregistrés, jamais d’une
  estimation fondée sur leur ordre de grandeur. Altitude MSL nullable.
- **Validité :** temps fini dans la durée enregistrée, latitude strictement entre
  −90 et 90°, longitude entre −180 et 180°, fix **3, 4, 5 ou 6** et temps croissant.
  Les fix extrapolés, dont 8, sont exclus. Un zéro sur l’équateur ou le méridien
  n’est pas rejeté automatiquement.
- **Segments :** échantillons invalides, retours de temps et lacunes supérieures à
  **10 secondes** séparent les portions valides. Les segments ne sont pas reliés
  graphiquement. Un segment d’un seul point reste une position isolée.
- **Budget :** au plus **4 096 points** dans une fiche ; les identifiants de segment
  sont conservés pendant l’échantillonnage. Les bornes des segments sont retenues
  dans la limite du budget. Ce relevé d’affichage n’est pas une trajectoire de commande.
- **Position d’un message :** champ facultatif `messages[].position`, de même forme
  qu’un point GPS, ajouté aux résumés et aux détails si un échantillon réel se
  trouve à **deux secondes au plus** du message, dans le même segment temporel
  valide. Aucun point n’est interpolé et aucune position n’est attribuée dans une
  lacune. Le repère peut correspondre à un point absent de l'aperçu échantillonné :
  il provient du relevé valide original.
- **Paramètres :** valeurs initiales et changements horodatés séparés ; les valeurs
  sont des chaînes qui conservent la représentation du parseur.
- **Topics :** une entrée par nom/instance avec nombre d’échantillons et champs.
  `fieldUnits` est facultatif ; les unités non renseignées ne sont pas inventées.

Les paramètres et inventaires détaillés ne sont pas ajoutés au snapshot global.
Les champs de modèle `telemetry` et `events` préparent des lots ultérieurs ; le
parseur 1.2.0 ne fournit pas encore de séries temporelles ni d’événements binaires
bruts/décodés dans les fiches.

## Qualité, erreurs et historique

Les fichiers invalides sont des logs `status:error`, avec tableau messages vide,
identifiant contenu, droneID fallback carte/fichier, durée 0 et issues explicites.
Une erreur de permissions sans contenu lisible utilise un identifiant synthétique ;
elle disparaît après une nouvelle lecture réussie. Un dossier inaccessible est
signalé séparément et n'empêche pas les autres imports. Les
alertes binaires `event` non décodables restent signalées en couverture, jamais
considérées comme absentes. Les métriques non finies sont omises ; flightSeconds
est nullable si le temps déclaré en vol ne peut pas être calculé.
Ne pas appeler get_version_info_str() (firmware Drotek a des métadonnées string).
Un nom de drone découvert ultérieurement pour le même UUID remplit les anciens noms.
sourcePaths peut être vide si tous les chemins associés ont été remplacés par un
contenu différent : le résumé est conservé et cette limite apparaît en couverture.
Les timestamps de messages sont relatifs au début du log et peuvent être négatifs
pour des messages mis en tampon. Les dates GPS se terminent par Z (UTC), les dates
de chemin ne reçoivent pas de fuseau inventé.

## Interface et exports

L’app regroupe tous les messages par `groupKey` et calcule les filtres, comptes
de logs affectés et messages sans supprimer les sources. La fiche conserve les
messages individuels, avec recherche/famille/niveau. Les filtres de période dans
l’app, vues persistantes et masquage réversible restent à réaliser.

Le rapport HTML contient résumés, mesures, couverture et messages horodatés.
L’export **Données de la fiche (JSON)** inclut les données détaillées consultées
(GPS borné, paramètres, topics, messages), sans prétendre exporter tout l’ULog.
Les exports de bibliothèque couvrent toute la bibliothèque et ne sont pas réduits
par les filtres d’affichage. Aucun diagnostic matériel automatique n’est fondé
uniquement sur un WARN/ERROR.

### Rapport HTML autonome — 0.5.1

Le même renderer produit le rapport de bibliothèque et celui d’une fiche. HTML,
CSS, JavaScript et données utiles aux filtres sont inclus dans un seul fichier,
consultable depuis `file://` sans GCS, serveur local, CDN ou police distante. Les
explications peuvent contenir des liens documentaires externes, ouverts seulement
par action du lecteur. Sans JavaScript, le contenu rendu reste lisible.

- Le rapport de bibliothèque contient tous les logs du snapshot annoté. Le
  rapport de fiche contient uniquement le log sélectionné. Les filtres de l’app
  ne réduisent pas le snapshot exporté.
- Les filtres du document (drone, famille, niveau, texte et période cliquée)
  s’appliquent localement aux graphiques, indicateurs, groupes et messages visibles.
  Ils ne retirent aucune donnée du fichier et ne sont pas persistés. Le reset
  retrouve tous les messages, y compris INFO/DEBUG et les occurrences répétées.
- La recherche porte sur les messages et sur l’identité, le nom, le fichier et
  la date du log. Les contrôleurs sont sélectionnés par `droneID`, jamais par
  leur numéro manuel ; deux identités portant le même numéro restent distinctes.
- Les durées et les comptes de logs avec alertes excluent `status:error`. Les
  fichiers en erreur restent comptés et consultables. Un log partiel peut
  contribuer avec les données disponibles ; `flightSeconds:null` ne devient
  pas un temps de vol nul.
- Le profil compte les SHA de logs uniques par famille pour les messages
  `isAlert`. Il utilise un radar pour 3 à 8 familles et des barres dans les autres
  cas, sans cacher les familles supplémentaires. L’ordre est alphabétique stable
  et les valeurs des familles ne s’additionnent pas en un total d’incidents.
- Le filtre **Alertes repérées** respecte `isAlert`, y compris pour un INFO taggé
  comme alerte. ERROR+ et WARNING+ suivent le niveau. Un failsafe observé sans
  message est compté lorsqu’aucun filtre de messages n’est actif ; il n’invente
  ni texte correspondant à une recherche ni famille d’alerte.
- L’activité représente tous les fichiers et les logs valides avec alertes du
  périmètre. Les jours sont extraits des dates source sans conversion de fuseau.
  Les dates absentes ou invalides sont regroupées comme inconnues. Au-delà de
  24 dates distinctes, l’affichage regroupe par mois, puis par année si nécessaire ; cliquer
  une colonne filtre le jour, le mois ou l’année indiqué.
- L’impression/PDF reprend le périmètre filtré et son rappel. Les détails visibles
  sont dépliés pour l’impression, les éléments filtrés restent masqués, puis les
  états de lecture sont restaurés. Réinitialiser avant impression inclut toutes
  les données du snapshot exporté.

Les messages et les attributs HTML sont échappés. Le JSON du tableau de bord
encode les délimiteurs HTML et les séparateurs Unicode pour qu’un texte source
ne puisse pas fermer son élément `<script>`. Le contenu original est retrouvé
après décodage. Les textes dynamiques utilisent des nœuds texte, pas du HTML
interprété. L’export JSON conserve son schéma, ses données détaillées disponibles
et ses annotations ; les filtres du HTML ne le modifient pas.

Les résumés/messages/aperçus sont encore chargés globalement en mémoire. Le cache
de fiche à la demande évite d’y ajouter tous les détails ; la pagination et un
benchmark représentatif restent nécessaires avant de qualifier 500 drones.
Voir [l’audit et les limites du lot 0.4](AUDIT-2026-09-29.md).

## Annotations locales — 0.5

`annotations.json` (schéma 1) stocke séparément `stockNumbers` et
`familyOverrides`. Les écritures sont atomiques ; un fichier illisible est conservé
et ne peut pas être écrasé implicitement. La bibliothèque brute reste inchangée.

- `metadata.gcsUUID` provient uniquement de douze octets valides et constants de
  `dance_status.uuid`. Une contradiction avec un `sys_uuid` Drotek reconnu empêche
  l’association et est signalée dans la couverture. Aucun UUID GCS n’est déduit du
  seul `sys_uuid`. `gcsIdentityStatus` distingue `verified`, `unavailable` et
  `rejected`. Un log rejeté ne reçoit jamais de lien local dérivé.
- `annotationGCSUUID` est une liaison locale distincte des métadonnées source :
  elle peut relier un ancien log si les autres logs du même `droneID` prouvent
  exactement un UUID GCS. Aucune liaison n’est propagée en présence d’une
  contradiction. Cette projection est recalculée depuis les preuves à chaque lecture.
  Les numéros ULog antérieurs sont migrés atomiquement vers une identité GCS
  prouvée, uniquement sans conflit ; les conflits de numéros sont conservés et signalés.
- Clé d’identité : `gcs:<UUID majuscule>` si cet UUID vérifié ou relié existe ; sinon
  `ulog:<droneID>`. `stockNumber`, facultatif dans les exports, conserve les zéros
  initiaux. Les regroupements restent fondés sur les identités, pas les numéros.
- La clé de classement utilise niveau et texte, espaces normalisés, indépendamment
  de la famille automatique. Une ancienne clé `groupKey` reste lisible et est
  migrée à l’édition. `family` reflète le choix ; `sourceFamily` conserve la famille
  détectée lorsqu’un classement manuel existe. Le texte et le niveau sont intacts.
- Les annotations sont projetées sur les résumés, fiches et exports à la lecture,
  et s’appliquent après de nouveaux imports sans modifier les sources ULog.
- Les explications du catalogue Swift sont dérivées de messages complets connus,
  avec sources et limites dans l’interface et le HTML. Elles ne changent ni la
  sévérité ni les métriques et ne remplacent pas les messages bruts du JSON.
