# KataLog — bibliothèque locale de logs PX4

Base de développement **0.5.1 (build 6)**, native macOS / SwiftUI : interface bento monochrome,
thèmes clair et sombre, carte Apple Maps, fiche de log, collecte GCS,
import réel avec `pyulog` et cache SQLite. Les données
affichées proviennent des imports ; aucun exemple figé n’alimente l’interface.

La prochaine grande mise à jour est préparée dans le
[plan de développement 0.6.0](docs/PLAN-0.6.0.md) : historique de flotte,
analyses avec courbes, sauvegardes et installation autonome. Ce périmètre est
planifié ; la première distribution publique sera reconstruite depuis ces sources.

## Utilisation

### Installer une release

**La première distribution publique est en préparation.** Ce dépôt contient les
sources nettoyées ; aucune archive de l'ancienne release privée n'y est transférée.
La cible **0.6.0** se téléchargera en **DMG signé et notarisé** : ouvrir le DMG,
glisser **KataLog dans Applications**, éjecter puis lancer. Aucun App Store,
Terminal, Homebrew ou Python séparé ne sera nécessaire.

Les futures archives seront proposées sur la
[page Releases](https://github.com/mehdi7129/KataLog/releases).
Pour construire la base actuelle depuis les sources, voir
[Construire et tester](#construire-et-tester) ; son moteur Python est encore externe.

### Mettre à jour une app déjà installée

La base 0.5.1 n'a pas d'updater. Son premier passage à une version avec Sparkle
sera manuel : terminer/arrêter les imports et la collecte, quitter KataLog,
remplacer l'app depuis le nouveau DMG, puis la rouvrir.

Le remplacement du bundle conserve la bibliothèque, les numéros de drones,
les classements et réglages dans `~/Library/Application Support/KataLog/`.
Le dossier personnalisé et les logs collectés restent en place. Les migrations
seront détaillées dans les notes de release. Les anciennes archives privées
restent dans une archive distincte et ne sont pas distribuées ici.

### Premiers imports

1. Ouvrir **KataLog** depuis son dossier d’installation.
2. Cliquer **Importer un dossier** et choisir une carte SD de logs,
   ou le dossier parent contenant plusieurs drones.
3. Explorer **Vue d’ensemble**, **Carte**, **Drones**, **Alertes** et **Rapports**.
4. Ajouter d’autres dossiers avec le même bouton. Un réimport conserve l’historique
   et ignore les contenus déjà connus.

### Identifier les drones et comprendre les alertes

- **Identifier ce drone** permet de saisir un numéro depuis la flotte GCS, même
  sans log, ou depuis une fiche de log. Les UUID enregistrés restent accessibles
  hors ligne. Le numéro est local, éditable et conservé au redémarrage.
- L’association suit l’UUID GCS observé dans `dance_status` et vérifié, lorsqu’il
  est disponible ; sinon elle reste attachée à l’identité ULog. Aucun numéro n’est
  déduit d’un CSV et deux UUID portant le même numéro ne sont jamais fusionnés.
- Les noms apparaissent dans l’historique, les filtres, la carte, la collecte et les
  exports. Le nom source et l’identité d’origine restent consultables.
- L’inspecteur d’un groupe et la fiche expliquent les quatre messages documentés
  du corpus : lecture SMBus, perte Wi-Fi, température LED et incohérence des
  accéléromètres. Les sources PX4 et les interprétations constructeur sont
  distinguées ; les messages inconnus restent affichés sans diagnostic inventé.
- **Classer…** permet d’attribuer une famille existante ou nouvelle à un texte et
  un niveau, dans les logs présents et futurs. **Rétablir la détection** retire
  l’annotation. Le texte original est conservé.
- Le profil compte les logs concernés, avec un ordre alphabétique stable. Au-delà
  de huit familles, le radar regroupe les suivantes sur un axe et donne accès à
  toutes les valeurs détaillées. Une absence d’alerte texte ne prouve pas l’absence
  de problème : les événements binaires non décodés restent signalés en couverture.

### Carte et fiche d’un log

1. Ouvrir **Carte**. Si les fichiers ont été importés avec une ancienne version,
   cliquer **Actualiser les analyses** : KataLog relit les copies locales avec le
   parseur **1.2.0**, sans les télécharger à nouveau ni dupliquer l’historique.
2. Choisir le drone et rechercher un fichier ou une date. La carte affiche les
   **80 logs géolocalisés les plus récents** du périmètre, avec un aperçu de
   **256 points maximum par log** ; la limite est affichée et la liste conserve
   les autres enregistrements. Les coupures de données séparent les trajectoires.
3. Ouvrir un log depuis la carte ou l’historique. La fiche charge ses détails à
   la demande : carte jusqu’à **4 096 points**, chronologie des alertes, tous les
   messages texte filtrables, mesures, paramètres et inventaire des topics.
4. Une alerte positionnable peut être sélectionnée sur la carte ; le repère
   utilise un échantillon GPS réel situé à deux secondes au plus du message,
   dans le même segment valide. Aucune position n’est interpolée dans une lacune.
5. **Exporter ce log** propose un rapport HTML des messages et mesures, ou les
   **Données de la fiche (JSON)**. Ce JSON inclut les paramètres, topics et GPS
   de la fiche ; il ne représente pas toutes les séries brutes du fichier ULog.

Les détails calculés sont conservés séparément dans SQLite et restent consultables
si le fichier source devient indisponible. Les positions proviennent des ULog :
l’app ne demande pas la localisation du Mac. Le fond Apple Maps utilise le réseau.
Sans trajectoire exploitable, les messages et les mesures restent accessibles.
Voir le [contrat d’import et des détails](docs/IMPORT-CONTRACT.md).

### Rapport HTML interactif — 0.5.1

Depuis **Rapports**, exporter la bibliothèque en HTML, puis ouvrir le fichier dans
un navigateur. **Exporter ce log** utilise la même présentation pour une seule
fiche. Le rapport est autonome : styles, données et interactions sont embarqués,
sans connexion à KataLog, à la GCS ou à un service de graphiques.

- Synthèse bento claire/sombre : identités, fichiers, durée enregistrée et logs
  avec alertes. Les compteurs suivent le périmètre affiché.
- Profil des familles en **radar entre 3 et 8 familles**, en **barres sinon**.
  Cliquer une famille ou un point du radar filtre le rapport. Les valeurs comptent
  des logs uniques concernés, sans additionner les répétitions d’un message.
- Graphique d’activité : fichiers par jour, mois ou année selon l’étendue des
  données ; cliquer une colonne sélectionne cette période. Les dates inconnues
  restent séparées et les dates source ne changent pas de fuseau horaire.
- Filtres combinables par drone, famille, niveau et recherche ; **Réinitialiser**
  retrouve tout le contenu. Les messages INFO/DEBUG et les répétitions sont
  conservés dans le fichier, même lorsqu’un filtre les masque.
- Groupes dépliables avec explications et liens vers les logs ; historique avec
  messages horodatés, mesures, couverture, identité source, chemins et SHA256.
- **Imprimer / PDF** imprime le périmètre filtré, rappelé en tête, et déplie ses
  détails. Réinitialiser les filtres avant d’imprimer pour inclure toute la
  bibliothèque exportée.

Ces filtres modifient seulement la lecture du document et sont réinitialisés au
rechargement. Sans JavaScript, les résumés et les détails source restent lisibles.
Les liens de documentation PX4 ouvrent leurs pages externes lorsqu’on les choisit.
L’export JSON conserve son format et ses données ; il n’est pas réduit par les
filtres du rapport HTML.

### Collecter depuis une GCS

1. Ouvrir **Collecte GCS**, saisir son adresse IP ou hostname, puis **Connecter**.
2. Ajouter explicitement les drones souhaités à **Ma flotte**. Leur UUID complet
   est conservé ; les appareils non enregistrés ne sont pas collectés.
3. Cliquer **Tout collecter** pour inventorier les drones autorisés actuellement
   connectés et récupérer leurs nouveaux logs. Les drones explicitement armés sont
   exclus. Pour choisir les fichiers d’un drone : **Voir les logs**, puis
   **Collecter la sélection**.
4. **Analyser après collecte**, activé par défaut, ajoute les fichiers vérifiés à
   la bibliothèque existante. Le cache et l’import évitent les copies inutiles.

La barre **Progression globale** suit le lot courant : octets, fichiers vérifiés,
attentes et erreurs. Jusqu’à **2 drones distincts** transfèrent leurs logs en
parallèle, avec **1 fichier à la fois par UUID**. Les fichiers déjà vérifiés sont
reconnus lors de l’inventaire et exclus des nouveaux téléchargements.

La connexion surveille les nouveaux appareils et se rétablit automatiquement.
La file et la flotte sont enregistrées dans `gcs-collection.json` ; les files des
versions précédentes restent lisibles. Les erreurs transitoires déclenchent au
maximum **3 tentatives au total**, avec attentes de **5 puis 15 secondes**, prolongées
si une session distante est encore en attente de fin. Les erreurs permanentes ne
sont pas réessayées automatiquement. **Relancer** reprend les fichiers arrêtés,
interrompus ou en échec.

**Mettre en pause** laisse finir les fichiers actifs. **Arrêter** interrompt
immédiatement la collecte sur le Mac et conserve les fichiers déjà vérifiés.
La copie déjà demandée à la GCS peut continuer : aucune commande d’arrêt distant
n’a été confirmée. Une fin de session reçue libère le drone ; à défaut, une reprise
peut être tentée après temporisation. L’expiration du délai client de 300 à
3 600 secondes ne prouve pas que la GCS a arrêté le transfert.
Les originaux restent sur les cartes SD.
Par défaut les copies se trouvent dans `~/Library/Application Support/KataLog/Collected Logs/`,
rangées par UUID et répertoire distant ; le bouton **Changer** permet un autre dossier.
Ce choix est conservé au redémarrage. Un dossier absent ou inaccessible bloque la
collecte avec une erreur explicite ; aucun autre dossier n’est choisi silencieusement.
Les travaux déjà en file gardent leur destination initiale, visible dans la file.
Si l’interface web GCS 3.7.2 reste ouverte dans Edge, elle peut elle-même créer une
copie dans Téléchargements : fermer cet onglet pendant la collecte évite cette
copie indépendante de KataLog. Voir le [diagnostic](docs/GCS-COLLECTION.md#copies-supplémentaires-dans-téléchargements-gcs-web-372).
Chaque log reçoit un manifeste de provenance `.ulg.katalog.json` avec son SHA256.
La reconnaissance d’un fichier déjà collecté vérifie UUID, chemin distant, taille
et empreinte locale, même si la file a été perdue ou si l’adresse de la GCS change.
Un fichier existant sans preuve valide est conservé et signalé pour examen.

Protocole validé : **GCS Drotek 3.7.2**, MQTT 1999 et HTTP 8080, deux IOSTAR3
firmware 4.1.5. Voir le [contrat et la recette](docs/GCS-COLLECTION.md).

## Fonctions disponibles

- Scan récursif `.ulg` / `.ULG`, progression et annulation.
- Identification par `sys_uuid`, noms issus du log ou de `data/name.txt` ;
  identités provisoires explicites si l’UUID manque.
- Déduplication SHA256, cache des fichiers inchangés et historique persistant.
- Conservation des messages texte, y compris les messages taggés et INFO/DEBUG.
- Recherche ; filtres drone, famille et niveau ; mode « Alertes ».
- Radar du **nombre de logs affectés** par famille : les répétitions d’un même
  message dans un log ne gonflent pas ce compteur.
- Regroupement des textes identiques de même niveau, inspecteur, historique et
  accès au fichier source dans le Finder.
- Mesures disponibles GNSS/RTK par récepteur, batterie, durées, failsafe et dropouts.
- Carte Apple Maps avec trajectoires segmentées, points isolés, fond plan/satellite
  et ouverture de la fiche depuis la carte ou l’historique.
- Fiche chargée à la demande : messages filtrables, mesures, GPS, paramètres
  initiaux et changements horodatés, topics/instances/champs, couverture et sources.
- Exports HTML autonomes et JSON : toute la bibliothèque, messages, métadonnées,
  topics, empreintes, sources, méthodes de calcul et limites par fichier.
- Rapport HTML clair/sombre avec graphiques cliquables, filtres locaux et
  impression du périmètre affiché.
- Un fichier invalide ou un sous-dossier inaccessible n’arrête pas les autres imports.
- Collecte GCS avec détection en direct, flotte enregistrée, inventaire, collecte
  de toute la flotte connectée, file persistante, progression globale, 2 drones en
  parallèle, arrêt local, pause et réessais bornés ; import automatique des fichiers reçus.

Bibliothèque de l’app : `~/Library/Application Support/KataLog/` (`library.sqlite`
et `library.json`). Les numéros et classements locaux sont enregistrés atomiquement
dans `annotations.json`. **SQLite est l’autorité de lecture** ; le JSON est un export/cache.
Les logs déjà commis restent visibles après une annulation, même si le JSON n’a
pas été réécrit. La table `flight_details` conserve les détails consultés sans
les ajouter au snapshot global. Les sources sont lues sans modification. La collecte communique
avec la GCS configurée sur le réseau local pour demander et recevoir les logs.
Si un chemin est remplacé par un autre contenu, l’ancien résumé reste conservé
et son lien devenu faux est retiré. Un UUID changé n’est pas automatiquement
reconnu comme le même drone physique.

## Validation

La référence 0.5.1 a exécuté 68 tests Python, 64 Swift et 9 JavaScript. Les
observations détaillées issues des logs privés sont conservées hors Git.
Les fixtures publiques sont synthétiques ; certains tests de recette nécessitent
un corpus privé explicite. Voir [UI-VALIDATION.md](docs/UI-VALIDATION.md).

## Confidentialité et distribution publique

Le projet prépare un dépôt public. Les logs, CSV de stock, identifiants réels,
coordonnées, bibliothèques, réglages locaux et preuves opérationnelles n'en font
pas partie. Les anciens commits et assets restent privés tant que leur nettoyage
n'est pas terminé ; voir [la préparation publique](docs/PUBLICATION.md).

La cible **0.6.0** est un **DMG signé et notarisé**, à ouvrir pour glisser
**KataLog dans Applications**, sans App Store ni installation séparée de Python.
Le moteur de la base 0.5.1 reste externe ; son ancien ZIP est conservé séparément en privé.

## Limites actuelles

- Les événements binaires PX4 (`event`) sont comptés mais restent non décodés sans
  dictionnaire du firmware. Tous les messages texte disponibles sont conservés ;
  absence de texte ne signifie pas absence d’alerte.
- Les familles suivent des règles textuelles. Un groupe de textes identiques
  n’est pas un nombre d’incidents, et une alerte n’est pas une panne confirmée.
- Le temps en vol repose sur `landed=false`, dans la portion enregistrée ; une
  couverture insuffisante ou incohérente donne une durée inconnue.
- Les dates GPS sont UTC ; les dates issues des chemins restent sans fuseau.
- L’inspecteur affiche les 100 premières occurrences ; les exports les contiennent
  toutes. Les filtres de l’interface ne réduisent pas l’export.
- Les imports de cartes SD conservent des références aux fichiers, sans archivage
  automatique des ULog. Les fichiers reçus par la collecte GCS sont copiés localement.
  Garder les originaux pour les analyses approfondies et les versions futures du parseur.
- Le cache de fiche conserve GPS, paramètres et topics, mais pas toutes les séries
  de télémétrie ni les événements binaires bruts. Les graphiques temporels de
  télémétrie, vues enregistrées, filtres de période dans l’app et choix d’un
  sous-ensemble de la flotte avant export restent à réaliser. Le rapport HTML
  permet déjà de filtrer localement les données exportées et leur impression.
- Tous les résumés, messages et aperçus du snapshot sont encore chargés en mémoire ;
  seuls les détails sont demandés par log. Pagination et benchmark d’un historique
  représentatif restent nécessaires avant de qualifier 500 drones.
- Le runtime Python n’est pas encore embarqué dans l’app.
- La collecte est limitée à 2 UUID simultanés et au protocole GCS testé. La recette
  réelle 0.3 confirme ce parallélisme sur deux drones ; une collecte complète de
  500 drones et les réessais après perte réseau réelle restent à qualifier.
- Aucun indicateur universel de fermeture d’un log n’est disponible : sa taille
  doit être stable avant et après transfert. Un état d’armement absent reste inconnu.
- Ne pas lancer un autre client FTP sur le même drone pendant sa collecte : les
  réponses de cette GCS n’ont pas de request ID. Quitter KataLog interrompt la copie
  locale ; une copie déjà demandée à la GCS peut continuer. Le délai client de
  300 à 3 600 secondes ne garantit pas un arrêt distant. La reprise recommence
  le fichier ou vérifie son cache, sans reprise à un offset réseau.

## Moteur Python

Pour une première installation sur un autre Mac disposant de Python 3,
créer l’environnement local ci-dessous. Ces commandes ne nécessitent pas de
cloner le dépôt :

```sh
python3 -m venv "$HOME/Library/Application Support/KataLog/python"
"$HOME/Library/Application Support/KataLog/python/bin/python3" -m pip install 'numpy>=1.26,<3' 'pyulog>=1.2,<2'
```

Cet environnement est détecté par l’app. `KATALOG_PYTHON` peut désigner un autre
exécutable pour les tests/CLI. `KATALOG_LIBRARY_DIR` isole la bibliothèque pour un
lancement configuré depuis Xcode.

## Construire et tester

Cette section concerne la compilation depuis le code source. Pour utiliser ou
mettre à jour l’app distribuée, suivre les instructions de release ci-dessus.
Les dossiers de build, de données privées et `reports/` sont locaux et non versionnés :
le dépôt fournit le code, les tests et la documentation ; ajouter ses propres logs
pour utiliser l’app.

Prérequis : macOS 15+, Xcode / Swift 6. Node.js est utilisé uniquement pour les
tests des interactions du rapport HTML. `bash tools/build-app.sh` construit en Release
dans `/private/tmp`, crée `dist/KataLog.zip` et vérifie la signature après extraction.
La signature locale est ad hoc par défaut. Avec un certificat Developer ID
disponible dans le trousseau, on peut produire un bundle signé avec hardened
runtime et timestamp :

```sh
KATALOG_SIGN_IDENTITY='Developer ID Application: Nom (TEAMID)' \
  bash tools/build-app.sh
```

Remplacer l’identité par celle de son certificat. Ce script ne soumet pas l’app à
la notarisation ; cette étape reste distincte. Les futurs assets publics seront reconstruits, audités et notarisés ;
la signature de l’ancienne archive privée ne la rend pas publiable.

Après ce build, **`Installer KataLog.command`** installe l’app dans
`~/Applications/KataLog.app` et demande son ouverture. Il conserve la précédente
version dans un dossier `.katalog-previous.*` de `~/Applications`, sans modifier
les réglages de sécurité ni demander de droit administrateur. Il refuse de
remplacer le bundle tant que KataLog est ouvert.

Le lanceur **`Ouvrir KataLog.command`** extrait le ZIP dans un dossier temporaire,
vérifie sa signature, puis demande à macOS d’ouvrir l’app depuis le Terminal de
l’utilisateur. Il sert à tester le build local ; l’installation durable passe
par le script d’installation ou la release.

Pour construire une variante Debug de diagnostic :

```sh
KATALOG_BUILD_DIR=/private/tmp/katalog-validation-build \
KATALOG_CONFIGURATION=debug bash tools/build-app.sh
```

Le build hors Desktop évite les attributs Finder du file provider qui peuvent
faire échouer la signature. `KataLog.xcodeproj` se régénère avec `xcodegen generate`.

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/katalog-clang-cache \
XDG_CACHE_HOME=/private/tmp/katalog-xdg-cache \
swift test --disable-sandbox --scratch-path /private/tmp/katalog-validation-build

node --test Tests/test_report_interaction.cjs

"$HOME/Library/Application Support/KataLog/python/bin/python3" \
  -m unittest discover -s Tests -v

swift run --disable-sandbox katalog-cli \
  --folder /chemin/vers/logs --database reports/library.sqlite \
  --output reports/library.json --html reports/KataLog-rapport-flotte.html
```

Les tests privés utilisent `KATALOG_PRIVATE_FIXTURES` pour désigner un corpus
local ; ils sont ignorés lorsqu'il n'est pas fourni. Les fixtures privées ne
sont pas distribuées. Les tests créent leurs variantes dans un dossier temporaire
et ne modifient pas les originaux. Pour la CLI, choisir son propre dossier source.

## Conception et références

[Direction visuelle](DESIGN.md) ·
[Contrat d’import](docs/IMPORT-CONTRACT.md) · [Audit 0.4 et suite](docs/AUDIT-2026-09-29.md).
Les anciennes maquettes basées sur des logs privés sont conservées localement.
Les exemples visuels publics doivent utiliser exclusivement des données synthétiques.

Moteur : [pyulog](https://github.com/PX4/pyulog),
[format ULog](https://docs.px4.io/main/en/dev_log/ulog_file_format),
[SensorGps](https://docs.px4.io/main/en/msg_docs/SensorGps),
[BatteryStatus](https://docs.px4.io/main/en/msg_docs/BatteryStatus).
