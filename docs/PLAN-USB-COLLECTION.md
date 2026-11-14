# Collecte USB et sélection multi-drones

## Demande et constat — 14 novembre 2026

Télécharger les ULog directement par USB serial, et ajouter des sélections de
plusieurs drones à la file pendant les transferts. Le checkout courant est
`feat/katalog-0.6.0` (f6dc26e), avec des changements locaux préexistants conservés.
La file GCS SQLite accepte déjà plusieurs UUID ; le verrou UI `isBusy` interdit
inutilement la navigation pendant les téléchargements.

## Plan

1. Séparer l'activité d'inventaire/préparation du téléchargement GCS. Autoriser
   navigation et ajouts pendant les transferts ; conserver la sérialisation par
   UUID, la pause explicite, la déduplication et la persistance existantes.
2. Ajouter un collecteur USB Python MAVLink (pymavlink / pyserial), lecture seule :
   ports disponibles, heartbeat autopilot, AUTOPILOT_VERSION uid2/uid, inventaire
   LOG_REQUEST_LIST, téléchargement LOG_REQUEST_DATA, LOG_REQUEST_END en sortie.
   Refuser un appareil armé ou sans identité matérielle stable. Le port et sysid
   ne constituent jamais une identité persistante.
3. Vérifier avant chaque téléchargement identité et entrée (id, date, taille).
   Recevoir par blocs avec retries bornés, contrôler offsets, doublons et trous,
   puis taille et signature ULog. Publier atomiquement avec SHA256 et provenance.
   Un débranchement garde un job interrompu, repris explicitement depuis zéro.
4. Ajouter une section USB à Collecte, avec sélection du port, inventaire,
   ajout à la file, progression, pause/arrêt/reprise. Conserver les jobs de
   plusieurs appareils ; exécuter seulement ceux du matériel actuellement
   sélectionné et revalidé. Un changement de port ne retargete jamais un job.
   La file USB est persistée séparément pour éviter toute migration ambiguë des
   identités GCS. Les deux files restent visibles dans Collecte.
5. Réutiliser l'import individuel existant, le dossier de collecte et les verrous
   de bibliothèque. Prévoir le collecteur dans le moteur embarqué et épingler ses
   dépendances ; aucune commande d'armement, d'effacement ou de paramètres.

## Double vérification avant exécution

- Revue indépendante du plan et des risques de concurrence/identité/protocole.
- Pas de conversion implicite UID MAVLink vers UUID Drotek.
- Un seul propriétaire du port serial ; QGroundControl doit libérer ce port.
- Les inventaires LOG_* peuvent suspendre l'écriture des logs sur certains
  firmwares : appareil désarmé et LOG_REQUEST_END même sur erreur/annulation.
- Un cache local ou un pourcentage ne remplace pas une copie complète vérifiée.
- Pas de promesse de débit avant essai physique ; MAVFTP pourra améliorer le
  débit ensuite si nécessaire, mais LOG_* correspond au chemin QGC compatible.

## Validation prévue

Tests Swift du scénario A en transfert → inventaire B → ajout B, exclusion du
même UUID, pause, arrêt et relance. Tests du collecteur avec paquets MAVLink
synthétiques et serial simulé : pertes, doublons, désordre, identité différente,
entrée modifiée, timeout, débranchement, fichier invalide et collisions locales.
Compilation de l'app et vérification du dispatch/packaging du moteur.
Recette physique USB et mesure de débit séparées, avec un AquaDrone connecté.

## État

Plan relu avant implémentation par deux analyses indépendantes. Points ajoutés
après revue : composer les verrous de maintenance des deux files, attendre la
fermeture effective du helper serial après annulation, corréler heartbeat/UID
au même système et composant. Implémentation effectuée.

### Résultats logiciels

- 69 tests Swift distincts GCS/USB/modèles/process/repository/restore/preview
  réussis (77 exécutions sur trois lots), sans échec ni skip.
- Suite Python : 320 réussis sur 321 ; seul le test nécessitant un corpus privé
  est ignoré. Dont 18 tests USB avec vrais paquets MAVLink et pseudo-terminal.
- Ces 18 tests réussissent aussi avec le CRC Python utilisé dans le bundle.
- Helper autonome construit : Python 3.13.15, pymavlink 2.4.50, pyserial 3.5.
  Signature ad hoc, 14 638 objets de code et 15 binaires natifs contrôlés.
  `fastcrc`, optionnel, est exclu du bundle car son binaire upstream contient
  un chemin absolu de build ; le fallback CRC officiel est utilisé.
- App Preview construite avec moteur embarqué ; écran USB contrôlé et bouton
  d'énumération testé dans l'app. Aucun port USB présent au moment de la recette.
- La variante `KATALOG_PREVIEW_VARIANT=usb` reçoit un bundle ID et une bibliothèque
  distincts de l'ancienne Preview 0.6 ; les versions distribuées restent séparées.
  Son lancement natif sans variable d'environnement a confirmé la bibliothèque
  `KataLogPreview-0.6-usb` et l'énumération des ports depuis le helper embarqué.

Livrable local :
`dist/usb-review/0.6-staging/KataLog-Preview-usb-0.6.0-macOS-arm64.zip`.
Ce build de test est issu du checkout courant 0.6, pas d'une nouvelle release
de la branche publiée. Aucun remplacement de l'app installée n'a été effectué.

Preuves locales : `reports/usb-gcs-swift-tests.{json,log}`,
`reports/usb-gcs-core-tests.{json,log}`, `.build/usb-python-summary.json`,
`reports/usb-preview-isolation-tests.{json,log}`,
`.build/usb-python-tests.log`, `.build/usb-engine-build.log`,
`.build/usb-app-build.log`.

### Recette physique restante

Brancher un AquaDrone désarmé, fermer sa connexion QGC, lire les logs dans
**USB direct**, télécharger un ULog, comparer au fichier reçu avec QGC (taille
et SHA256) et mesurer la durée. Tester débranchement/rebranchement, puis remplacer
l'appareil sur le même port et vérifier que l'ancienne demande n'est pas exécutée
sur le nouvel appareil. Le gain de débit et la compatibilité du firmware réel
restent non mesurés. Aucun firmware, paramètre ou log distant n'a été modifié.
