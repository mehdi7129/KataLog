# KataLog — bibliothèque locale de logs PX4

Version installée de référence **0.5.2 (build 7)**, native macOS / SwiftUI : interface bento monochrome,
thèmes clair et sombre, carte Apple Maps, fiche de log, collecte GCS,
import réel avec `pyulog` et cache SQLite. Les données
affichées proviennent des imports ; aucun exemple figé n’alimente l’interface.

Les sources **0.6.0 en préparation** implémentent l’index paginé, les sauvegardes,
la restauration, la file GCS durable, les événements PX4 et les courbes à la demande.
Les nouveaux écrans ont été approuvés et sont activés par défaut dans les builds
stables à partir de **0.6.0**. **KataLog Preview** conserve sa bibliothèque
distincte ; `KATALOG_UI_PREVIEW=1` reste disponible en développement. Sparkle 2.10.0 est
embarqué mais son feed reste désactivé. L’app installée 0.5.2 n’est pas remplacée.
Voir le [suivi d’implémentation et ses limites](docs/IMPLEMENTATION-0.6.0.md),
les [contrats](docs/CONTRACTS-0.6.md), la [matrice de validation](docs/VALIDATION-0.6.0.md) et le [plan de développement](docs/PLAN-0.6.0.md).

Le package de review corrigé **0.6.0 (9)** contient **KataLog Preview.app** : il peut
coexister avec KataLog et utilise `~/Library/Application Support/KataLogPreview-0.6/`.
Il ouvre directement les nouveaux écrans, sans Terminal. Les données de l’app
installée sont conservées ; la bibliothèque de la Preview commence vide.
Importer en mode **Référencer** analyse les fichiers existants sans les copier.
Ce package local est signé Developer ID et passe les sept contrôles de
distribution, mais n’est pas notarisé. Il n’est pas une release et son updater
reste désactivé. Le build 8 est une candidate historique remplacée par ce correctif.

L'[audit du 30 septembre](docs/AUDIT-2026-09-30.md) et le
[backlog exécutable](docs/BACKLOG-0.6.0.md) détaillent les corrections préalables,
les données restant à exploiter et les critères de sortie de chaque lot.

## Essayer la Preview 0.6.0

1. Ouvrir son DMG, glisser **KataLog Preview.app** dans Applications, éjecter,
   puis lancer la Preview. Elle dispose de sa propre bibliothèque vide.
2. Importer un dossier en choisissant **Référencer les fichiers** ou **Copier
   vers mes archives**. Le second mode vérifie taille et SHA-256 avant l’analyse ;
   son dossier est conservé au redémarrage. Attendre le bilan avant de retirer la carte SD.
3. Dans **Historique**, choisir le périmètre : drones, période, recherche,
   familles et niveaux. Les agrégats portent sur tout ce périmètre ; les listes
   sont paginées à 200 entrées. Les vues enregistrées conservent les filtres.
4. Dans **Alertes**, personnaliser les familles, les axes du profil et les
   masquages réversibles. **Événements PX4** conserve les événements bruts et
   annonce les dictionnaires manquants ; la traduction exige celui du firmware exact.
5. Ouvrir une fiche pour consulter **Courbes et chronologie**, **Événements PX4**
   et **Révisions**. Les quatre courbes partagent 2 048 points ; leurs lacunes et
   réductions sont annoncées. Une ancienne analyse reste consultable sans sa source.
6. **Stockage** propose sauvegarde analyses/réglages ou complète, restauration
   vérifiée, réassociation des sources par SHA et récupération des caches nettoyés.
7. **Rapports** permet de vérifier le périmètre et les exclusions avant export.
   Les données intégrales sont conservées même si un HTML de plus de 10 Mio
   doit être remplacé par une synthèse et un manifeste.

La collecte utilise une file SQLite durable et importe exactement les fichiers
reçus, sans créer automatiquement une seconde archive. Les drones autorisés
restent dans le registre, même sans log. La comparaison des paramètres conserve
les valeurs et types ; elle n’attribue pas une cause de panne.
Le parseur courant est **1.4.0**, avec projection SQLite **6**. Les anciennes
analyses sont conservées et leur recalcul est explicite.

## Utilisation de la version installée 0.5.2

### Installer une release

**Le dépôt reste privé tant que la publication publique n’est pas décidée.**
Le package local **0.5.2** est un **DMG** avec **KataLog.app** et un lien
**Applications** : ouvrir le DMG, glisser KataLog dans Applications, éjecter,
puis lancer l’app. Le moteur ARM64 est embarqué ; aucun App Store, Terminal,
Homebrew ni Python séparé n’est requis pour utiliser l’app.

**Compatibilité : Mac Apple Silicon, macOS 15 minimum, recette locale sur macOS 27.**
Les minima des composants natifs sont contrôlés au packaging. L’exécution sur
macOS 15 demande une recette sur cette version ; le test macOS 27 ne la remplace pas.
La [recette 0.5.2](docs/DISTRIBUTION-VALIDATION.md) consigne les tests réalisés et
les limites de qualification.

Les archives publiées seront proposées sur la
[page Releases](https://github.com/mehdi7129/KataLog/releases).
Les ZIP de l’ancienne 0.5.1 restent dans une archive privée distincte et ne sont
pas réutilisés dans cette distribution. Pour compiler depuis les sources, voir
[Construire et tester](#construire-et-tester).

### Mettre à jour une app déjà installée

Les versions 0.5.1 et 0.5.2 n’ont pas d’updater. Son premier passage à une version avec Sparkle
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
- L’inspecteur d’un groupe et la fiche proposent quatre explications ciblées :
  lecture SMBus, perte Wi-Fi, température LED et incohérence des accéléromètres.
  Wi-Fi/LED incluent des interprétations sans définition constructeur vérifiée.
  La provenance et l'applicabilité des explications doivent encore être affinées ;
  les messages inconnus restent affichés sans diagnostic inventé.
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
Les réglages et UUID autorisés sont enregistrés dans `gcs-settings.json`, la
file durable dans `gcs-queue.sqlite` et les observations dans `fleet.json`.
L’ancien `gcs-collection.json` est migré lors du chargement. Les erreurs transitoires déclenchent au
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

## Fonctions de la version installée 0.5.2

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

L’audit de référence 0.5.2 avait exécuté **175 tests** et l’installation utilisateur
fonctionne sur macOS 27. Les corrections et nouvelles suites 0.6 sont consignées
dans le [suivi d’implémentation](docs/IMPLEMENTATION-0.6.0.md), avec la version
testée et les limites de chaque preuve. Le benchmark synthétique porte sur
50 000 logs, 5 millions de messages et 500 identités ; ce n’est pas le parsing
de 50 000 ULogs ni une qualification de 500 drones physiques.
Les fixtures publiques sont synthétiques. Le test des neuf logs du corpus réel
annonce explicitement son absence dans le gate public ; ses résultats privés
restent hors Git. Le gate natif
refuse tout test ignoré. Voir [UI-VALIDATION.md](docs/UI-VALIDATION.md).

### GitHub Actions et runners gratuits

La CI utilise les runners GitHub **standard ARM64** `macos-15`, `macos-26` et
`xcode-27` ; ce dernier est actuellement en public preview. GitHub les fournit
gratuitement pour les dépôts publics. Les jobs sont ignorés tant que le dépôt
est privé, y compris lors d’un lancement manuel `workflow_dispatch`. Les tests
locaux restent disponibles avec les commandes ci-dessous.

Une fois le dépôt public, les push sur `main`, les pull requests et les
lancements manuels peuvent exécuter les tests et le packaging ad hoc. La CI ne
publie aucune release et n’utilise ni runner plus grand ni runner auto-hébergé.
Un job ignoré n’est pas une preuve de validation. Voir les
[conditions des runners GitHub](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

## Licence

Copyright (C) 2026 **mehdi7129**.

Le code propre de KataLog, ses tests, scripts, documentation et ressources
originales sont distribués sous la **GNU GPL version 3 uniquement**
(`GPL-3.0-only`), sans garantie. Le texte complet figure dans [LICENSE](LICENSE).
Ce choix n’accorde pas l’utilisation d’une version ultérieure de la GPL.
Les composants tiers conservent leurs licences et notices respectives ; voir
[Dépendances et licences](docs/DEPENDENCIES-LICENSES.md).

Toute distribution d’un binaire doit rendre disponible son code source
correspondant, avec les scripts nécessaires à sa construction et les notices
applicables. Pour les releases KataLog, fournir le tag exact et l’archive de
sources correspondante avec les instructions de build. Les logs et bibliothèques
des utilisateurs ne font pas partie des sources du logiciel.

## Confidentialité et distribution publique

Le projet prépare un dépôt public. Les logs, CSV de stock, identifiants réels,
coordonnées, bibliothèques, réglages locaux et preuves opérationnelles n'en font
pas partie. Les anciens commits et assets restent dans une archive privée distincte ; voir [la préparation publique](docs/PUBLICATION.md).

La distribution autonome **0.5.2** utilise un **DMG signé et notarisé**, à ouvrir pour glisser
**KataLog dans Applications**, sans App Store ni installation séparée de Python.
Le moteur de la base 0.5.1 reste externe ; son ancien ZIP est conservé séparément en privé.

## Limites de la version installée 0.5.2

Les corrections et fonctions 0.6 ci-dessus sont disponibles dans la Preview ;
ce bilan décrit l’installation 0.5.2 existante.

- Sans `sys_uuid`, l'identité de remplacement peut différer entre résumé et fiche
  (C01 dans l'audit) : le numéro manuel peut ne plus apparaître dans la fiche et
  ses exports. L'export flotte conserve l'identité du résumé. Corrigé dans la Preview 0.6.
- Les événements binaires PX4 (`event`) sont comptés mais restent non décodés sans
  dictionnaire du firmware. Tous les messages texte disponibles sont conservés ;
  absence de texte ne signifie pas absence d’alerte.
- Les familles suivent des règles textuelles. Un groupe de textes identiques
  n’est pas un nombre d’incidents, et une alerte n’est pas une panne confirmée.
- Le temps en vol repose sur `landed=false`, dans la portion enregistrée, sans
  extrapoler les extrémités. La qualification des lacunes/couvertures insuffisantes
  reste à améliorer, notamment pour les logs courts (C11 dans l'audit).
  La Preview 0.6 qualifie cette couverture et conserve les durées inconnues.
- Les dates GPS sont UTC ; les dates issues des chemins restent sans fuseau.
- L’inspecteur affiche les 100 premières occurrences ; les exports les contiennent
  toutes. Les filtres de l’interface ne réduisent pas l’export.
- Les imports de cartes SD conservent des références aux fichiers, sans archivage
  automatique des ULog. Les fichiers reçus par la collecte GCS sont copiés localement.
  Garder les originaux pour les analyses approfondies et les versions futures du parseur.
- Le cache de fiche conserve GPS, paramètres et topics, mais pas toutes les séries
  de télémétrie ni les événements binaires bruts. Les graphiques temporels de
  télémétrie, vues enregistrées, filtres de période dans l’app et choix d’un
  sous-ensemble de la flotte avant export sont désormais disponibles dans la Preview 0.6. Le rapport HTML
  permet déjà de filtrer localement les données exportées et leur impression.
- Tous les résumés, messages et aperçus du snapshot sont encore chargés en mémoire ;
  seuls les détails sont demandés par log. Pagination et benchmark d’un historique
  représentatif restent nécessaires avant de qualifier 500 drones.
- Le moteur distribué est embarqué dans l’app ; la compilation des sources nécessite toujours les outils de développement.
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

## Moteur Python pour le développement

Pour exécuter les sources avec SwiftPM ou Xcode, créer un environnement de
développement avec Python 3.13, depuis la racine du dépôt. Ces commandes ne sont pas utiles pour l’app
installée depuis le DMG :

```sh
python3 -m venv "$HOME/Library/Application Support/KataLog/python"
"$HOME/Library/Application Support/KataLog/python/bin/python3" -m pip install --only-binary=:all: --require-hashes -r requirements-runtime.txt
```

Cet environnement est détecté en développement. `KATALOG_PYTHON` peut désigner
un autre exécutable pour les tests/CLI exécutés depuis les sources. Dans le bundle
distribué, le moteur embarqué est prioritaire et son absence bloque le lancement
des analyses avec une erreur de réinstallation ; aucun fallback externe n’a lieu. `KATALOG_LIBRARY_DIR` isole la bibliothèque pour un
lancement configuré depuis Xcode.

## Construire et tester

Cette section concerne la compilation depuis le code source. Pour utiliser ou
mettre à jour l’app distribuée, suivre les instructions de release ci-dessus.
Les dossiers de build, de données privées et `reports/` sont locaux et non versionnés :
le dépôt fournit le code, les tests et la documentation ; ajouter ses propres logs
pour utiliser l’app.

Prérequis : macOS 15+, Xcode / Swift 6. Node.js est utilisé uniquement pour les
tests des interactions du rapport HTML. Python et l’accès réseau servent au build,
pour télécharger les entrées épinglées du moteur et les vérifier par SHA-256.
`bash tools/build-app.sh` construit en Release dans `/private/tmp`, embarque le
helper et crée le ZIP versionné ainsi que `dist/KataLog.zip`.
`bash tools/build-dmg.sh` produit ensuite le DMG depuis la copie locale vérifiée.
Le moteur est CPython 3.13.15, NumPy 2.5.3 et pyulog 1.2.4 ; les licences
sont dans son bundle. Voir [la procédure de distribution](docs/RELEASING.md).
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
python3 tools/run-swift-tests.py -- --disable-sandbox --scratch-path /private/tmp/katalog-validation-build

node --test Tests/test_report_interaction.cjs

python3 tools/run-python-tests.py

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
[Contrat d’import](docs/IMPORT-CONTRACT.md) · [Audit actuel](docs/AUDIT-2026-09-30.md) ·
[Plan 0.6.0](docs/PLAN-0.6.0.md) · [Backlog](docs/BACKLOG-0.6.0.md) ·
[Audit historique 0.4](docs/AUDIT-2026-09-29.md).
Les anciennes maquettes basées sur des logs privés sont conservées localement.
Les exemples visuels publics doivent utiliser exclusivement des données synthétiques.

Moteur : [pyulog](https://github.com/PX4/pyulog),
[format ULog](https://docs.px4.io/main/en/dev_log/ulog_file_format),
[SensorGps](https://docs.px4.io/main/en/msg_docs/SensorGps),
[BatteryStatus](https://docs.px4.io/main/en/msg_docs/BatteryStatus).
