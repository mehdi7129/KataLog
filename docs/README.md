# Documentation de KataLog

La version stable actuelle est **0.8.1 (build 20)**, publiée le **5 octobre 2026**.
Pour installer l’app, commencer par le [README du projet](../README.md#installation).
Le correctif **0.8.2 (build 21)** est en préparation :
[résultats et qualification restante](RELEASE-0.8.2.md).

## Trouver le bon document

| Besoin | Documentation |
| --- | --- |
| Importer, explorer, exporter ou collecter des logs | [Guide utilisateur](#guide-utilisateur) |
| Installer une mise à jour et comprendre les migrations | [Mises à jour](UPDATING.md) |
| Comprendre la version stable et ses contrôles | [Release 0.8.1](RELEASE-0.8.1.md), [changelog](../CHANGELOG.md) |
| Classer les logs par client et gérer le nettoyage | [Clients et interface](CLIENTS-BENTO.md) |
| Identifier les drones | [Numérotation et identité](STOCK-IDENTITY.md) |
| Comprendre la collecte et ses limites | [Collecte GCS](GCS-COLLECTION.md) |
| Produire un diagnostic local | [Diagnostic](DIAGNOSTICS.md) |
| Comprendre les données importées, les détails et les rapports | [Contrat d’import](IMPORT-CONTRACT.md) |
| Construire, tester et proposer une contribution | [Contribution](../CONTRIBUTING.md) |
| Préparer un package et une release | [Distribution](RELEASING.md), [publication et confidentialité](PUBLICATION.md) |
| Comprendre les licences | [Licence du projet](../LICENSE), [dépendances](DEPENDENCIES-LICENSES.md) |
| Voir les évolutions envisagées | [Roadmap](ROADMAP.md) |

## Guide utilisateur

### Prise en main

1. Ouvrir le DMG, glisser **KataLog.app** dans Applications, éjecter, puis lancer.
   Une installation existante retrouve sa bibliothèque ; une nouvelle commence vide.
2. Dans **Tous les clients → Créer ou gérer les clients…**, créer votre
   organisation ou vos clients. Ce classement est facultatif : les anciens logs
   restent dans **Sans client** jusqu’à une attribution explicite.
3. **Importer** un dossier, choisir son client destinataire, puis **Référencer
   les fichiers** ou **Copier vers mes archives**. Le second mode vérifie taille
   et SHA-256 avant l’analyse ; son dossier est conservé au redémarrage. Attendre
   le bilan avant de retirer la carte SD. Un doublon conserve son client initial.
4. Dans **Historique**, filtrer les logs du client choisi : drones, période,
   recherche, familles et niveaux. Les agrégats portent sur tout ce périmètre,
   indépendamment des pages de 200 entrées au maximum. L’attribution à un client peut être
   modifiée en lot. Dans **Alertes**, personnaliser familles et masquages réversibles.
5. Ouvrir un log dans sa fenêtre macOS pour consulter sa synthèse, ses messages,
   sa carte et ses courbes. Jusqu’à quatre courbes partagent un budget total de
   2 048 points au maximum ; les champs absents, lacunes et réductions sont annoncés.
   Activer le **mode avancé** dans les réglages pour accéder au menu **Plus** :
   événements, mesures détaillées, paramètres, topics, couverture et révisions.
6. **Stockage** propose sauvegarde analyses/réglages ou complète, restauration
   vérifiée, réassociation des sources par SHA et retrait groupé des sources.
   Dans **Réglages**, **Vider la bibliothèque** et **Réinitialiser KataLog** sont
   deux actions distinctes pour tous les clients, avec confirmation. Les fichiers
   `.ulg` restent sur disque ; [les éléments effacés sont explicités](CLIENTS-BENTO.md#nettoyage).
7. **Rapports** permet de vérifier le périmètre et les exclusions avant export.
   Les données intégrales sont conservées même si un HTML de plus de 10 Mio
   doit être remplacé par une synthèse et un manifeste.

La collecte utilise une file SQLite durable et importe exactement les fichiers
reçus, sans créer automatiquement une seconde archive. Les drones ajoutés lors de la collecte
restent dans le registre, même sans log ni numéro de stock. La comparaison des paramètres conserve
les valeurs et types ; elle n’attribue pas une cause de panne.
Le parseur courant est **1.4.0**, avec projection SQLite **8** depuis 0.8.1
(**7** en 0.8.0). Les anciennes analyses sont conservées et leur recalcul est explicite.

Le correctif 0.8.2 adapte le nombre de logs d’une page au budget de réponse,
y compris les informations sur les dossiers sources. Les totaux restent ceux
du périmètre complet. La liste des clients se charge indépendamment des logs :
une erreur de lecture ne supprime aucun client et propose un nouvel essai.

### Diagnostic local

Dans **Réglages → Aide et diagnostic → Préparer un diagnostic…**, KataLog propose
une prévisualisation avant export ZIP : état de l’app, chronologie locale et, à votre
demande, journaux de la GCS. Les données restent sur le Mac. Les messages GCS
libres sont retirés par défaut ; les journaux bruts et les ULogs choisis sont deux
options privées distinctes. Cette fonctionnalité est disponible à partir de la release 0.7.0.

[Contenu, limites et recette du diagnostic](DIAGNOSTICS.md).

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
- Le profil natif compte les logs concernés et affiche jusqu’à huit axes
  personnalisables ; les axes automatiques retiennent les huit premières familles
  par ordre alphabétique. **Voir toutes les familles** donne accès à la liste
  complète, classée par nombre de logs concernés. Une absence d’alerte texte ne prouve pas l’absence
  de problème : les événements binaires non décodés restent signalés en couverture.

### Carte et fiche d’un log

1. Ouvrir **Carte**, sélectionner un client si nécessaire, puis saisir une ville,
   une adresse ou des coordonnées et choisir un rayon. Un log correspond dès
   qu’une portion valide de sa trajectoire traverse cette zone. La recherche
   porte sur tout le périmètre client, avant la pagination des résultats.
2. La recherche utilise les trajectoires complètes disponibles ; celles d’une
   ancienne bibliothèque sont mises en cache à partir des sources accessibles.
   Les logs qui n’ont pas pu être vérifiés sont annoncés. En 0.8.1, la carte
   représente **tous les logs géolocalisés** du périmètre
   par des marqueurs regroupés. Cliquer sur un groupe zoome ; ouvrir un log
   affiche sa trajectoire détaillée. Les coupures GPS ne sont jamais reliées.
   La limite de 80 logs des versions précédentes est levée.
3. Ouvrir un log depuis la carte ou l’historique. Sa fenêtre macOS peut être
   déplacée, agrandie et fermée indépendamment ; rouvrir le même log ramène sa
   fenêtre au premier plan. Elle charge ses détails à la demande : carte jusqu’à
   **4 096 points**, chronologie des alertes et messages texte filtrables.
   Les mesures détaillées, paramètres et topics sont accessibles via **Plus**
   lorsque le **mode avancé** est activé dans les réglages.
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
Voir le [contrat d’import et des détails](IMPORT-CONTRACT.md).

### Rapport HTML interactif

Depuis **Rapports**, exporter la sélection ou tous les logs du client choisi en
HTML, puis ouvrir le fichier dans un navigateur. Choisir **Tous les clients**
avant l’export pour couvrir la bibliothèque entière. **Exporter ce log** utilise la même présentation pour une seule
fiche. Le rapport est autonome : styles, données et interactions sont embarqués,
sans connexion à KataLog, à la GCS ou à un service de graphiques.

- Synthèse bento claire/sombre : identités, fichiers, durée enregistrée,
  temps de vol cumulé avec couverture et logs avec alertes. Les compteurs
  suivent le périmètre affiché ; la durée enregistrée inclut les périodes au sol.
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
2. Choisir le **Client destinataire** des nouveaux logs dans les options de
   collecte, puis **Tout collecter**. Les drones éligibles visibles sur cette GCS
   sont acceptés automatiquement ; aucun ajout un par un ni numéro de stock
   préalable n’est nécessaire. Leur identité reste dans le registre, même sans log.
3. Les appareils explicitement armés, hors ligne ou sans UUID valide sont exclus.
   Pour choisir les fichiers d’un drone, ouvrir directement **Voir les logs**,
   puis **Collecter la sélection**. Les contrôles d’identité restent appliqués.
4. **Analyser après collecte**, activé par défaut, ajoute les fichiers vérifiés à
   la bibliothèque existante. Chaque travail garde le client destinataire choisi
   à sa création, même si la sélection change ensuite. Les doublons déjà analysés
   conservent leur attribution. Le cache et l’import évitent les copies inutiles.

La barre **Progression globale** suit le lot courant : octets, fichiers vérifiés,
attentes et erreurs. Jusqu’à **2 drones distincts** transfèrent leurs logs en
parallèle, avec **1 fichier à la fois par UUID**. Les fichiers déjà vérifiés sont
reconnus lors de l’inventaire et exclus des nouveaux téléchargements.
En 0.8.1, l’analyse utilise un worker séparé ; un transfert
vérifié libère son slot réseau immédiatement. Au plus quatre fichiers sont en
transfert, en analyse ou en attente d’analyse. Les résultats et limites mesurés figurent dans
[la validation des performances](PERFORMANCE-MAP-NAVIGATION.md).

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
copie indépendante de KataLog. Voir le [diagnostic](GCS-COLLECTION.md#copies-supplémentaires-dans-téléchargements-gcs-web-372).
Chaque log reçoit un manifeste de provenance `.ulg.katalog.json` avec son SHA256.
La reconnaissance d’un fichier déjà collecté vérifie UUID, chemin distant, taille
et empreinte locale, même si la file a été perdue ou si l’adresse de la GCS change.
Un fichier existant sans preuve valide est conservé et signalé pour examen.
Si iCloud a retiré une copie ou son manifeste du Mac, KataLog explique comment
télécharger le dossier dans Finder avant de relancer. Il conserve les fichiers
existants et ne programme pas un doublon depuis le drone pour ce seul motif.

Protocole validé : **GCS Drotek 3.7.2**, MQTT 1999 et HTTP 8080, deux IOSTAR3
firmware 4.1.5. Voir le [contrat et la recette](GCS-COLLECTION.md).

### Stockage local et conservation

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

## Développement et références

La [contribution](../CONTRIBUTING.md) décrit l’environnement, les tests et les
builds locaux. La [direction visuelle](../DESIGN.md) décrit les conventions de l’interface.

Les [mesures carte/navigation et collecte](PERFORMANCE-MAP-NAVIGATION.md)
précisent le périmètre des benchmarks 0.8.1. Le [banc 500 identités](BENCHMARK-500.md)
utilise des données synthétiques et ne qualifie pas une flotte physique.

Références du moteur : [pyulog](https://github.com/PX4/pyulog),
[format ULog](https://docs.px4.io/main/en/dev_log/ulog_file_format),
[SensorGps](https://docs.px4.io/main/en/msg_docs/SensorGps),
[BatteryStatus](https://docs.px4.io/main/en/msg_docs/BatteryStatus).

## Historique des releases et des travaux

Ces documents conservent la version et le contexte de leur rédaction. Leurs
états « à faire », « privé » ou « feed désactivé » décrivent cette étape et ne
remplacent pas l’état actuel de la [release 0.8.1](RELEASE-0.8.1.md).

| Étape | Documents |
| --- | --- |
| Preview 0.8.1 | [Recette beta 1](RELEASE-0.8.1-BETA.md), [audit UX](UX-AUDIT-0.8.1.md) |
| 0.8.0 | [Release](RELEASE-0.8.0.md), [validation de la Preview clients](VALIDATION-CLIENTS-BENTO.md) |
| 0.7.0 | [Release](RELEASE-0.7.0.md) |
| 0.6.0 | [Release](RELEASE-0.6.0.md), [contrats](CONTRACTS-0.6.md), [plan](PLAN-0.6.0.md), [backlog](BACKLOG-0.6.0.md), [implémentation](IMPLEMENTATION-0.6.0.md), [validation](VALIDATION-0.6.0.md) |
| Distribution initiale | [Qualification 0.5.2](DISTRIBUTION-VALIDATION.md), [validation UI 0.5.1 et compléments 0.6](UI-VALIDATION.md) |
| Audits initiaux | [29 septembre 2026](AUDIT-2026-09-29.md), [30 septembre 2026](AUDIT-2026-09-30.md) |

Les fixtures du dépôt sont synthétiques. Les captures, bibliothèques et preuves
opérationnelles contenant des données réelles restent hors du dépôt public.
