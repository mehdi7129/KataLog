# Validation de la candidate 0.6.0

Ce document décrit les contrôles de la candidate locale. Il distingue les tests
réussis des contrôles encore ouverts. Il ne constitue pas une qualification de
500 drones physiques ou de toutes les versions de macOS.

L’app déjà installée est conservée. La candidate utilise une bibliothèque de
test isolée et des données inventées. Les nouvelles pages restent derrière le
flag de preview jusqu’à leur validation visuelle.

## Arrêt des opérations et accès à la bibliothèque

**Gate ciblé réalisé sur macOS 27 ARM64 : 13 tests réussis, aucun échec et aucun
skip, en 5,724 secondes.** Les preuves détaillées restent locales et ignorées par
Git. La suite Swift globale du gel final a aussi réussi : **208 tests, aucun
échec et aucun skip**, avec un Python de test indépendant du build du moteur.

| Contrôle | Résultat observé |
|---|---|
| Arrêt d’un helper qui ignore SIGTERM | SIGKILL après le délai prévu ; PID terminé |
| Annulation pendant le runtime handshake | L’appel retourne une annulation et termine son helper |
| Annulation d’un reader dont stdout reste ouvert | Le polling revient et le helper est arrêté |
| Registry des processus | Aucun processus non enregistré n’est arrêté ; les entrées restent présentes jusqu’à la fin |
| Launch gate après Quit | Aucun nouveau helper ne peut être lancé dans cette instance |
| Échec de lancement / cleanup exceptionnel | Aucune entrée de registry retenue |
| Writer lease | Dup parent CLOEXEC ; stdin du helper conserve le lock exact de la bibliothèque |
| Décès du parent sans cleanup | L’enfant peut finir son écriture ; un second writer reste bloqué jusqu’à sa sortie |
| Forwarding GCS | Le helper reçoit la lease via stdin ; aucun argument de bibliothèque n’est envoyé au drone ou au collecteur |
| Restore GCS invalide | Ancienne queue retirée, collecte pausée, mutation et reconnexion bloquées, fichiers restaurés conservés |

`EngineOperations.beginTermination()` ferme définitivement la launch gate de
l’instance et arrête uniquement les helpers qu’elle possède. Les opérations
font un cleanup sur tous les chemins d’erreur. La lease ne fait pas de
`LOCK_UN` explicite : fermer la dernière copie du descriptor libère le lock,
ce qui protège aussi une écriture terminée par un enfant devenu orphelin.

Les inventaires et transferts GCS bornés héritent de cette lease. Discovery
continu ne la reçoit pas, pour qu’un processus de découverte orphelin ne réserve
pas indéfiniment la bibliothèque. En fonctionnement normal, Quit annule aussi
la découverte et attend la fin des opérations possédées.

Le choix natif « Continuer l’opération / Arrêter et quitter » est implémenté.
Son interaction dans la candidate installable reste à vérifier. L’arrêt local
ne promet pas d’annuler une action distante déjà reçue par le drone.

## Récupération après interruption et migration

**Cinq tests autonomes réussis, aucun skip, en 2,761 secondes.** Ils provoquent
neuf véritables SIGKILL dans des subprocess appartenant au test : avant et après
publication d’un backup, d’un restore, d’un archivage et d’une copie préparée à
l’import. Le restore complet est aussi interrompu après publication de son
journal final. La récupération retrouve un état ancien ou nouveau intégral,
reste idempotente et préserve les SHA et mtime des ULog originaux. Une copie
préparée conserve sa provenance sans fabriquer une analyse absente.

La migration utilise une fixture SQLite et des JSON produits par le véritable
parser legacy 1.2.0, sur des données inventées. Le commit source correspond à
0.5.1 ; les deux SHA du parser sont aussi identiques à ceux de l’app locale
0.5.2. IDs, messages, analyses et annotations sont conservés ; deux révisions
historiques deviennent lisibles sans retrouver le fichier ULog. Cette recette
ne requiert ni Git ni app installée à l’exécution. Aucune source 0.5.3 n’est
disponible dans cette qualification : sa migration n’est pas revendiquée.

## Infrastructure de mise à jour

La candidate embarque **Sparkle 2.10.0**, sa licence et ses cinq exécutables
nécessaires. Le framework est recherché dans le bundle installé, avec signature
des composants avant celle du bundle principal.

Les tests de signature réalisés avec les outils du SDK officiel vérifient le
ZIP et l’appcast : une modification du ZIP ou du feed est rejetée. La clé de
test est éphémère et n’est conservée ni dans les sources ni dans le Keychain.

La configuration exige HTTPS, un feed signé et une signature vérifiée avant
extraction. Le profiling, JavaScript et les installations automatiques sont
désactivés. Le code expose des états distincts pour une infrastructure inactive,
une recherche, une mise à jour disponible, une version déjà à jour, un report
et un échec.

Une recette autonome a aussi réalisé une **véritable installation Sparkle et
un relaunch du build 1 au build 2** sur deux apps synthétiques temporaires. Le
bundle remplacé est identique à celui du ZIP signé et sa signature stricte est
valide. Les SHA de six fichiers de données inventées sont conservés : SQLite,
annotations, vues sauvegardées, queue GCS, préférence du dossier et log ULog.
Les fichiers de l’app KataLog déjà installée sont inchangés. La recette n’ouvre
aucune fenêtre et n’écrit aucune clé dans le Keychain. Elle est reproductible
avec `tools/test-update-install.py --sdk SDK --summary RESULTAT.json`. Deux
recettes supplémentaires ont modifié le ZIP et le feed après leur signature :
le SDK en fonctionnement a rejeté chaque payload, a conservé le build 1 et
n’a pas atteint l’étape « prêt à installer ». Elles sont reproductibles avec
`--tamper archive` et `--tamper feed`. Le cleanup vérifie qu’aucun helper du
test ne reste actif.

Deux autres recettes du SDK réel simulent un asset absent (HTTP 404) et une
réponse tronquée pendant le téléchargement. Chaque échec conserve le bundle
ancien à l’identique et les six fichiers de données ; le build 2 n’est jamais
installé ni lancé. Elles sont reproductibles avec `--failure missing-asset` et
`--failure interrupted-download`.

Une sixième recette provoque un véritable **ENOSPC pendant le téléchargement**
sur une image HFS+ de 128 MiB appartenant au test, avec seulement 1 MiB libre.
Le payload synthétique ajoute 8 MiB. Le SDK retourne Sparkle 2001, Cocoa 640 et
POSIX 28 avant extraction : bundle 1 et six fichiers conservés par SHA, aucun
build 2 installé ou relancé, aucun helper restant et volume détaché. Elle est
reproductible avec `--failure insufficient-space`. Le volume système n’est
jamais rempli. Les six recettes ne touchent pas l’app KataLog installée.

Une sonde distincte place seulement la destination d’installation sur ce petit
volume (`--failure insufficient-space --space-phase install`). Elle a atteint
la fermeture du build 1 puis un timeout du driver, donc son verdict reste
**FAIL**. Après 50 secondes : ancien bundle présent et SHA identique, six
fichiers conservés, aucun relaunch du build 2 et aucun helper avant ou après
cleanup. Cette preuve établit la préservation observée, pas une erreur visible
à l’utilisateur après Quit ; le callback du driver fermé n’est pas qualifié.

Le rejeu doté d’une attestation transactionnelle explicite a ensuite réussi :
hôte sorti normalement avec le code 0, bundle et six fichiers identiques,
signature stricte valide et véritable lancement de l’ancien Mach-O chargeant
Sparkle. Aucun helper n’est actif avant ou après cleanup ; le volume est
détaché. **Cette attestation PASS porte sur la préservation et l’utilisabilité
de l’app précédente après Quit.** Elle ne revendique ni callback reçu, ni cause
d’erreur de l’installer observée. Les verdicts FAIL initiaux sont conservés.

Cette recette utilise un **feed signé en HTTP loopback réservé au test du SDK**.
Elle ne qualifie ni l’HTTPS du futur endpoint public, ni une mise à jour de
l’app KataLog de production. La politique de l’app continue d’exiger HTTPS.

**Le feed de la candidate reste désactivé.** Aucun endpoint public ni clé de
publication n’est activé. Le passage de l’app KataLog installée à la candidate
via son endpoint HTTPS doit encore être qualifié avant d’annoncer des mises à
jour automatiques aux utilisateurs.
L’app 0.5.2 déjà installée utilise encore la procédure manuelle par DMG.

## Packaging de la candidate

Le package visé est `0.6.0 (8)`, ARM64, avec minimum macOS 15 déclaré. Il est
préparé sous `dist/0.6-staging/`, qui reste ignoré par Git. Aucun tag, release ou
changement de visibilité du dépôt n’est nécessaire à ces contrôles locaux.

La candidate de revue se nomme **KataLog Preview.app** et possède son propre
bundle ID. Son dossier par défaut est `KataLogPreview-0.6`, distinct de la
bibliothèque de production. Le DMG et le ZIP utilisent le préfixe
`KataLog-Preview`, pour permettre une installation à côté de KataLog. Le flag
de build n’est accepté que pour la 0.6.0 locale dans `0.6-staging`, avec feed
désactivé. Les builds ordinaires et le smoke CI ne l’activent pas.

Le build copie uniquement les inputs publics dans un snapshot isolé. Le moteur
compile un ensemble neuf de modules à chaque build : un module supprimé ou
renommé ne doit pas rester dans un ancien dossier `inputs/modules`.

Le cache CPython est vérifié contre les 1 655 entrées de son archive pinnée et
sa version. Un cache valide est réutilisé sans remplacer le Mach-O, son inode
ou son mtime ; une réparation est préparée et vérifiée dans un staging avant
publication. Deux tests autonomes et une réutilisation du vrai runtime ont
réussi. Cette correction évite un remplacement partiel de Python pendant les
tests qui l’utilisent.

Le moteur du gel courant **1.4.0 / projection 6** a été reconstruit : ses neuf
modules compilés correspondent exactement aux neuf SHA des sources. Un ancien
module synthétique planté dans les inputs a disparu du nouveau PYZ. Le build
de l’app refuse également un manifest qui contient un module supplémentaire,
des pins de dépendances périmés ou une entrée/spec différente. Ces refus
interviennent avant la compilation et la création d’archives.

**Quatorze workflows ont réussi dans ce véritable moteur autonome**, avec HOME
et cwd isolés, PATH système et variables Python invalides. Ils couvrent les
events exacts, le catalogue global, les séries bornées, les données du rapport,
la copie optionnelle à l’import, le preflight du backup complet, les opérations
de stockage réversibles, le restore conservant la lease et le dictionnaire,
les observations GCS/source datées et une révision historique lue en readonly
après retrait de toutes les copies ULog du fixture. Aucun Python externe n’est
utilisé. Ces workflows ont aussi réussi depuis le bundle final de l’app.

**Le package final 0.6.0 (8) a réussi les sept catégories du validateur**, sur
macOS 27 ARM64, avec signature Developer ID stricte. Le contrôle privacy a
inspecté 171 fichiers et 472 payloads Python décompressés, sans finding ; 22
fichiers natifs sont portables et aucune dépendance externe n’est présente.
La CLI a importé hors du checkout, vérifié l’archive optionnelle et produit le
HTML. Deux sources identiques donnent une seule analyse et un seul ULog
archivé, avec deux copies vérifiées dont une réutilisée. La collecte loopback
ne télécharge pas deux fois son log et conserve une seule destination.

Les contrôles réussis sur le package final vérifient :

- versions de l’app, du helper et du parser cohérentes ;
- correspondance exacte des SHA des modules compilés et des sources embarquées ;
- absence de chemins personnels et de données de flotte, y compris dans les archives Python décompressées ;
- minima macOS et dépendances natives portables ;
- signature stricte du bundle et de ses composants ;
- runtime sans Python externe, avec PATH système et variables Python hostiles ;
- import, déduplication, cache hors ligne et collecte GCS en loopback ;
- events bruts puis traduction par dictionnaire XZ exact, catalogue global et séries bornées ;
- capture du rapport et production des données intégrales ;
- backup avec ULog vérifié, restore, cleanup de cache réversible, archivage et réassociation ;
- DMG monté en lecture seule, lien Applications et égalité des fichiers de l’app.

Les 58 SHA des sources Swift sont inchangés depuis le build. Les SHA du
manifest embarqué correspondent aux neuf modules et aux requirements/entry/
spec courants. Les SHA de l’Info.plist et du Mach-O de KataLog installé
**0.5.2 (7)** sont inchangés ; aucune installation de la preview n’a été faite.

| Artefact local | Taille | SHA256 |
|---|---:|---|
| `KataLog-Preview-0.6.0-macOS-arm64.dmg` | 18 837 733 octets | `8abed7acdce087bb19162959542e10fc6e38c01f3e17314b08a5ecd33cb40e60` |
| `KataLog-Preview-0.6.0-macOS-arm64.zip` | 19 004 275 octets | `7d93ecaaf975ed57e678a7c881340ab625b513cbee2a26274b741bd49d018ccb` |

La composition HTML et les interactions du rapport sont vérifiées séparément
par les tests Swift/WebKit et JavaScript. Le smoke du moteur Python vérifie les
données du rapport ; il ne prétend pas tester cette composition native.

Une signature Developer ID est disponible pour la candidate locale. La
notarisation et Gatekeeper du **nouveau** package ne sont pas encore qualifiés.
Les résultats de la précédente version ne sont pas attribués à la 0.6.0.

Sur macOS 27, le File Provider du dossier de destination refuse la création de
l’image writable par `hdiutil`. Le builder construit désormais le DMG dans un
staging local, puis signe, vérifie et monte cette image avant de publier ses
octets identiques. Deux tests vérifient le cleanup, la conservation d’une
destination existante et le retrait d’une publication interrompue.

## CI et compatibilité

Le YAML CI a été validé localement. Il décrit les suites autonomes et un
packaging ad hoc sur les runners macOS 15 et macOS 27. Ces jobs ne publient pas
d’asset, n’utilisent pas de corpus privé et ne contactent pas une flotte réelle.

**Les jobs réseau de cette candidate n’ont pas encore été exécutés.** Un minimum
macOS déclaré et une inspection Mach-O ne remplacent pas une recette réelle sur
cette version. Le Mac local fournit macOS 27 ; macOS 15 doit encore être testé
sur son runner ou un Mac approprié.

## Contrôles restant ouverts

- Suites globales exécutées sur les mêmes sources que le package final.
- Recette visuelle et interaction Quit dans le bundle final.
- Mise à jour de KataLog via le futur endpoint HTTPS ; installation et relaunch SDK déjà testés sur des bundles synthétiques.
- Notarisation, quarantaine de téléchargement et Gatekeeper de cette version.
- CI macOS 15 et 27 exécutée et relue.
- Collecte avec les drones physiques disponibles ; un simulateur ne la remplace pas.

Les résultats finaux doivent être reportés ici avec leur périmètre exact. Aucune
promesse de « zéro bug » n’est déduite d’un nombre de tests réussis.
