# Audit de qualité et de maintenabilité — 8 octobre 2026

## Objectif et périmètre

Rendre KataLog plus fiable, lisible et efficace **en conservant ses fonctions,
ses parcours et ses résultats métier**. Cette PR contient uniquement cet audit :
aucun correctif applicatif, changement de format, migration, release ou réglage
GitHub n'est appliqué.

Référence : `main`, commit `6aa9007bcc893e8f213f85c2cba9fd770330be72`,
version source **0.8.2, build 21**. L'audit utilise un worktree isolé. Le checkout
de développement ancien et ses modifications locales sont hors de cette
baseline et ont été conservés.

Quatre agents ont travaillé en parallèle : interface/stores SwiftUI,
moteur/persistance Python, services Core/collecte/CLI, puis coordination,
outillage/CI et vérification des constats. Les constats concernent le code de
cette référence, pas une panne observée sur une flotte réelle.

## Conclusion

La base **SwiftUI + services Swift + moteur Python + SQLite** reste adaptée.
Le projet possède déjà des protections utiles : writer lease, annulation des
processus, réponses bornées, copies vérifiées, captures d'export, tests de
reprise, dépendances épinglées et contrôles de distribution. Une réécriture
générale ou un nouveau framework d'architecture ne se justifient pas.

**20 points retenus : 2 P1, 12 P2 et 6 P3.** Les deux P1 sont reproduits sur
données synthétiques ; les autres points distinguent bugs, risques et dette.
Les trois auditeurs ont relu la synthèse consolidée ; les deux reproductions P1
publiées en fin de document ont été rejouées avec succès par un second agent.

La priorité est de corriger les écarts de cohérence démontrés, puis de sortir
les accès disque du rendu de l'interface et de découper les responsabilités
les plus concentrées. Un fichier long est un signal de lecture, pas à lui seul
la preuve d'un défaut.

## Mesures et couverture

Mesures sur les seuls fichiers suivis, hors builds, dépendances et données privées :

| Zone | Fichiers de code | Lignes physiques |
| --- | ---: | ---: |
| Interface et stores Swift | 41 | 11 945 |
| Core Swift | 34 | 5 202 |
| CLI Swift | 1 | 54 |
| Moteur Python | 14 | 6 694 |
| Tests et benchmarks | 75 | 14 709 |
| Outils Swift/Python/shell | 19 | 4 029 |

Le dépôt contient **254 fichiers suivis**, dont **23 895 lignes applicatives**.
La taille des tests ne constitue pas un taux de couverture.

| Concentration | Mesure | Responsabilités à séparer progressivement |
| --- | ---: | --- |
| `Workspace06View.swift` | 1 725 lignes | Navigation, pages, rapports, réglages, maintenance |
| `analyzer.py` | 1 666 lignes | Parsing, import, transactions, révisions, dispatch CLI |
| `library_repository.py` | 1 191 lignes | Projections, filtres, pagination, plusieurs types de requêtes |
| `GCSStore.swift` | 1 151 lignes | Connexion, inventaire, scheduling, transfert, analyse, persistance |
| `main.swift` | 1 144 lignes | Point d'entrée et ancien workspace encore accessible en développement |
| `FleetMapView.swift` | 1 004 lignes | Chargement, carte, recherche, sélection et présentations |

L'analyse AST trouve notamment `query()` à 346 lignes, `analyzer.main()` à 260,
`initialize()` à 224 et `scan()` à 192. Ces mesures servent à choisir des
frontières de responsabilité, pas à imposer une limite arbitraire de lignes.

Couverture : sources applicatives, contrats entre Swift et Python, stockage,
archives/restauration, GCS/processus, rapports, tests, build/distribution et CI.
Lecture ciblée par responsabilité, suites automatisées et reproductions
synthétiques ; aucune revendication de preuve exhaustive d'absence de bugs.

## Résultats de validation

Exécution locale sur macOS 27.0.1 ARM64, Swift 6.4, Python 3.13.15,
NumPy 2.5.3, pyulog 1.2.4 et Node 22.16.0 :

| Contrôle | Résultat | Portée |
| --- | --- | --- |
| Gate Swift du dépôt | **356 réussis**, 0 échec, 0 ignoré | Core, stores, fenêtres de test natives et WebKit |
| Gate Python du dépôt | **383 réussis sur 384 découverts**, 0 échec/erreur | 1 test du corpus privé externe absent, skip attendu |
| Interactions HTML / Node | **18 réussis**, 0 échec/ignoré | Calculs et interactions du rapport |
| Syntaxe | 56 fichiers Python parsés, 6 scripts shell valides | Analyse syntaxique uniquement |
| Garde de publication initiale | **254 fichiers, 0 signalement** | Fichiers courants, couverture limitée du scanner |
| Garde de publication avec cet audit | **255 fichiers, 0 signalement** | Rapport compris ; 50 liens locaux vers les sources vérifiés |
| CI de `main` relue sur GitHub | [Succès du 7 octobre](https://github.com/mehdi7129/KataLog/actions/runs/37680435238) | Commit applicatif `a7e6f9f` ; les commits suivants de la baseline concernent docs/feed |

Les 38 tests du collecteur rejoués par un auditeur sont déjà inclus dans les
383 tests Python : ils ne sont pas additionnés une deuxième fois. Les premiers
essais avec le Python système 3.9, hors prérequis du projet, ne sont pas des
régressions du produit. Le bilan ci-dessus vient de la relance conforme.

Commandes de référence, depuis la racine du worktree, avec le Python conforme
sélectionné dans l'environnement de test :

```sh
python tools/run-python-tests.py --summary /tmp/katalog-audit-python.json
python tools/run-swift-tests.py --summary /tmp/katalog-audit-swift.json \
  --log /tmp/katalog-audit-swift.log \
  -- --disable-sandbox --scratch-path /tmp/katalog-audit-swift-build
node --test Tests/test_report_interaction.cjs
python3 tools/check-publication.py --include-untracked
git diff --check
```

Les régressions ci-dessous ne sont pas détectées par cette baseline verte.
Les preuves synthétiques sont décrites avec leur niveau d'isolation ; elles ne
constituent pas des incidents observés dans l'app installée.

## Corrections proposées

**P1** : cohérence ou conservation des données à traiter avant les refactors.
**P2** : fiabilité, réactivité ou dette structurelle à traiter ensuite.
**P3** : hygiène de développement et prévention des régressions.

**Reproduit** signifie obtenu sur fixture synthétique ; **risque étayé** signifie
chaîne de code identifiée sans incident réel démontré ; **dette** signifie coût
de maintenance constaté. Les tests de sortie ci-dessous sont à ajouter avec les
correctifs, et ne sont pas présentés comme déjà existants.

### Q01 — P1 — Rendre l'import d'un fichier réellement transactionnel

**Reproduit.** Le `SAVEPOINT` de `remember_log()` peut être le premier niveau
de transaction ; son `RELEASE` publie alors l'analyse avant que `scan()` vérifie
que la source n'a pas changé. Le `rollback()` de l'erreur arrive trop tard.
Preuves : [publication](../Sources/KataLog/Resources/analyzer.py#L838-L851),
[ordre du scan et rollback](../Sources/KataLog/Resources/analyzer.py#L1002-L1065).

Une fixture remplacée entre hash et parsing laisse une analyse `status=ok`
sous l'ancien SHA, avec les données du contenu remplacé et sa révision
archivée, alors que le bilan annonce `failed=1`.

- **Correction minimale :** transaction explicite par fichier couvrant analyse,
  contrôle de stabilité, révisions, sources et cache spatial ; commit après les
  contrôles, puis reconstruction des projections dérivées. Conserver les commits
  courts et les analyses précédentes, sans rebuild de tout l'index par fichier.
- **Test de sortie :** remplacer une source synthétique pendant l'analyse ;
  vérifier qu'aucune analyse/révision valide du mauvais contenu n'est publiée,
  que l'erreur de lecture reste visible et que les anciens enregistrements sont
  inchangés. Tester aussi un échec tardif d'écriture et un doublon.

### Q02 — P1 — Refuser les collisions entre sorties CLI et données de la bibliothèque

**Reproduit au niveau moteur utilisé par la CLI.** `--output` est transmis sans
contrôle de collision, puis écrit par remplacement atomique.
Preuves : [CLI](../Sources/KataLogCLI/main.swift#L17-L40),
[sortie du scan](../Sources/KataLog/Resources/analyzer.py#L1089-L1090),
[écriture atomique](../Sources/KataLog/Resources/analyzer.py#L76-L85).

Avec `output=database` sur une base temporaire, le scan retourne un succès mais
l'en-tête SQLite est remplacé par du JSON ; une lecture SQL échoue ensuite.
Le writer lease n'empêche pas une collision à l'intérieur de la même commande.
Ce constat vise la CLI/entrée moteur ; aucun parcours normal GUI écrasant sa
base n'a été reproduit.

- **Correction minimale :** prévalider destinations JSON/HTML/progression contre
  base, sidecars, fichiers de contrôle et sources, avant toute mutation ; traiter
  chemins relatifs et aliases. Défense dans la CLI et à la frontière moteur.
  Conserver les destinations légitimes `library.json` et `progress.json` :
  interdire tout le dossier bibliothèque serait une régression.
- **Test de sortie :** collisions directes et par alias refusées avant écriture,
  hash de la base et des sources conservé ; sorties distinctes inchangées.

### Q03 — P2 — Préserver les métadonnées historiques lors d'une réanalyse

**Reproduit.** `refresh_analysis()` reparse le chemin réassocié et conserve
explicitement l'identité, mais reprend d'autres métadonnées du nouveau chemin.
Preuve : [réanalyse](../Sources/KataLog/Resources/analyzer.py#L1245-L1280).
Pour un ULog sans date GPS exploitable, le même SHA peut ainsi passer d'une date
historique à celle du dossier de copie ; le nom de fichier change aussi.

- **Correction minimale :** réutiliser la provenance canonique enregistrée pour
  les champs dérivés du chemin, et garder séparé le chemin actuel de lecture.
  Conserver les règles actuelles de priorité des dates réellement enregistrées.
- **Test de sortie :** importer un ULog, le réassocier sous un autre dossier daté
  et un autre nom, forcer une nouvelle version de parseur, actualiser ; identité,
  date d'origine et provenance doivent rester cohérentes.

### Q04 — P2 — Réconcilier l'état après une suppression de client partiellement réussie

**Reproduit sur le store isolé avec faux services.** Le client est supprimé
dans la bibliothèque avant le nettoyage de ses attributions GCS. Si ce callback
échoue, profils et scope UI ne sont pas réconciliés.
Preuves : [ClientStore](../Sources/KataLog/ClientStore.swift#L87-L94),
[enchaînement des mutations](../Sources/KataLog/ClientStore.swift#L117-L127),
[nettoyage GCS](../Sources/KataLog/GCSStore.swift#L294-L303).
La probe obtient une suppression backend réussie et un client encore présent
dans `profiles` et dans le scope actif, avec une erreur globale.

- **Correction minimale :** distinguer commit et réconciliation, recharger l'état
  réel même après l'échec secondaire, rendre le nettoyage idempotent et relançable.
  Un simple `do/catch` ne rend pas deux bases atomiques.
- **Test de sortie :** échec du callback après suppression réussie, puis relance ;
  profils, scope et file convergent sans perdre ni réattribuer les logs.

### Q05 — P2 — Lier les événements affichés au filtre qui les a produits

**Reproduit sur le store isolé.** Une requête B échouée laisse `page` issue de A,
alors que les filtres et le numéro de page affichés ont déjà changé.
Preuves : [chargement](../Sources/KataLog/EventBrowserView.swift#L12-L30),
[affichage et pagination](../Sources/KataLog/EventBrowserView.swift#L94-L131).
La fixture charge les événements de A puis fait échouer B : les données A
restent accessibles sous le nouveau contexte, à côté du message d'erreur.

- **Correction minimale :** associer résultat et clé de requête validée ; garder
  le cache sans le présenter comme réponse au nouveau filtre. Commettre le
  curseur après succès et remettre `isLoading` à zéro si le moteur manque.
- **Test de sortie :** A réussi, B lent/échoué/annulé, réponse A tardive et
  pagination échouée ; jamais de données A attribuées à B.

### Q06 — P2 — Sortir les I/O GCS du rendu et du MainActor

**Risque étayé, gel utilisateur non mesuré.** `batchProgress` et `retryableCount`
effectuent des requêtes SQLite synchrones dans le store `@MainActor` ;
`saveState()` y écrit également la file et le JSON.
Preuves : [compteurs](../Sources/KataLog/GCSStore.swift#L87-L100),
[persistance](../Sources/KataLog/GCSStore.swift#L1080-L1104),
[repository](../Sources/KataLogCore/GCSQueueRepository.swift#L18-L30).
Le timeout SQLite de cinq secondes peut donc aussi retarder les commandes UI.
Le rendu recalcule certains agrégats déjà capturés ; le benchmark existant de
préparation de file déporte sa grosse écriture et ne mesure pas tout ce chemin.

- **Correction minimale :** réutiliser les compteurs capturés, publier un snapshot
  après changement et sérialiser les I/O hors du MainActor. Conserver un seul
  propriétaire des écritures, leur ordre et leur durabilité.
- **Test de sortie :** vraie persistance + progression sur gros lot synthétique,
  heartbeat du MainActor, arrêt et reprise. Mesurer avant/après ; pas de tâches
  d'écriture détachées concurrentes ajoutées pour masquer le problème.

### Q07 — P2 — Ne pas remplacer silencieusement un total GCS par une page partielle

**Risque étayé sur erreur de lecture.** Les `try?` des compteurs retombent sur
`queue` si SQLite échoue, alors que cette liste ne conserve normalement que les
travaux actifs et 200 terminaux récents.
Preuves : [fallbacks](../Sources/KataLog/GCSStore.swift#L87-L98),
[rétention](../Sources/KataLogCore/GCSQueueRepository.swift#L111-L117).
Avec un historique plus grand, compte de relances et progression ne décrivent
plus le même ensemble, sans signal d'indisponibilité du total.

- **Correction minimale :** conserver le dernier snapshot valide avec son état
  de lecture ; ne pas inférer un total historique ou une complétion depuis le
  sous-ensemble en mémoire.
- **Test de sortie :** 500 échecs historiques, 200 retenus, puis erreur repository ;
  aucun passage silencieux du compteur complet au compteur partiel.

### Q08 — P2 — Respecter le délai global d'un téléchargement HTTP lent

**Reproduit sur loopback avec horloge de deadline accélérée.** La deadline est
vérifiée avant `HTTPResponse.read(n)`, qui peut attendre le remplissage du bloc.
Un flux régulier lent évite le timeout socket d'inactivité.
Preuve : [boucle de copie](../Sources/KataLog/Resources/gcs_collect.py#L659-L678).

Fixture de 32 Kio livrant 1 Kio toutes les 80 ms ; horloge du collecteur ×100 :
budget effectif 0,6 s, retour après **2,618 s**, premier progrès après **2,617 s**.
Ce n'est pas une mesure réelle de 60 s. L'annulation explicite du helper reste
protégée ; le constat concerne le délai automatique et la progression.

- **Correction minimale :** lectures disponibles bornées par le temps restant,
  contrôle de deadline à chaque lecture ; garder hash, taille et publication.
- **Test de sortie :** flux continu lent, serveur bloqué, absence de Content-Length,
  dépassement de taille, annulation ; durée bornée et `.part` nettoyé.

### Q09 — P2 — Borner le backlog d'événements entre le helper GCS et l'app

**Risque structurel, pas d'OOM de l'app reproduit.** La frame JSONL est bornée,
mais `AsyncThrowingStream` est créé avec son buffer non borné et `yield` n'attend
pas le consommateur.
Preuve : [stream et yield](../Sources/KataLogCore/GCSProcessService.swift#L11-L55).
Une probe du même constructeur accepte 100 000 événements sans consommateur.
Un consommateur ralenti peut donc accumuler mémoire et événements périmés.

- **Correction minimale :** backpressure pour les pages et événements obligatoires,
  coalescence uniquement des progressions/snapshots périssables. Un simple buffer
  qui jette les derniers ou premiers événements perdrait erreurs ou fins de transfert.
- **Test de sortie :** burst + consommateur lent ; backlog plafonné, ordre et
  complétude des pages/terminaux conservés, annulation rapide.

### Q10 — P2 — Appliquer la même garde cloud à tous les chemins de stockage

**Divergence reproduite avec `UF_DATALESS` simulé ; iCloud réel non testé.**
`analyzer.digest_file()` refuse une source évincée, mais les copies/hashes de
stockage utilisent d'autres helpers sans ce contrôle.
Preuves : [garde existante](../Sources/KataLog/Resources/analyzer.py#L62-L68),
[copie](../Sources/KataLog/Resources/library_archives.py#L50-L64),
[réassociation](../Sources/KataLog/Resources/library_archives.py#L294-L302),
[backup](../Sources/KataLog/Resources/library_storage.py#L154-L157).
La fixture marquée dataless est refusée par le premier chemin mais copiée par
le second. Une hydratation lente pendant la maintenance reste un risque,
pas un blocage cloud effectivement observé.

- **Correction minimale :** petit helper partagé de lecture locale/signature,
  appelé avant hash/copie ; conserver le traitement partiel ou l'erreur prévu
  par chaque opération, et privilégier une copie déjà locale lorsqu'elle existe.
- **Test de sortie :** flag dataless simulé avec interdiction d'appeler `open` ou
  `copyfile`, backup/réassociation/archives, plusieurs copies dont une locale.

### Q11 — P2 — Qualifier la cohérence des fenêtres principales simultanées

**Risque étayé, scénario GUI non reproduit.** Le `WindowGroup` partage un seul
`LibraryStore`, tandis que chaque workspace conserve sa page et ses curseurs.
Les résultats, le tri de requête et la tâche annulable restent partagés.
Preuves : [ownership App](../Sources/KataLog/main.swift#L6-L16),
[workspace](../Sources/KataLog/Workspace06View.swift#L7-L30),
[chargement](../Sources/KataLog/LibraryStore.swift#L570-L580).
Une fenêtre peut donc remplacer ou annuler la lecture utilisée par l'autre.

- **Avant correction :** reproduire avec deux fenêtres et préciser le contrat
  existant attendu. S'il est partagé, synchroniser les contrôles et résultats ;
  s'il est indépendant, isoler seulement l'état de navigation par fenêtre.
  Aucun changement de ce contrat n'est décidé par cet audit.
- **Test de sortie :** deux fenêtres, pages/curseurs différents, lecture lente
  et annulation dans l'une ; chaque résultat correspond à ses contrôles visibles.

### Q12 — P2 — Découper les responsabilités et nommer les capacités de l'app

**Dette constatée.** `LibraryStore`, `GCSStore` et `Workspace06View` concentrent
plusieurs cycles de vie. Les gardes `busy`, `hasActiveWork`, `canMutate` et
`installationAllowed` répètent des combinaisons différentes de flags.
Preuves : [activité bibliothèque](../Sources/KataLog/LibraryStore.swift#L271-L318),
[maintenance](../Sources/KataLog/LibraryStore.swift#L710-L720),
[commandes dans la vue](../Sources/KataLog/Workspace06View.swift#L1503-L1589).
Le coût principal est de devoir modifier plusieurs endroits éloignés quand une
opération apparaît, pas seulement la longueur des fichiers.

- **Correction minimale :** capacités nommées par commande, avec différences
  intentionnelles explicites ; garder les façades actuelles. Extraire navigation,
  import, maintenance, rapports et sous-vues par responsabilité. Une extension
  ou un petit type suffit lorsqu'il apporte une frontière claire.
- **Test de sortie :** matrice commandes × import/lecture/fiche/GCS/maintenance/
  export/lecture seule/annulation ; mêmes autorisations et ordre des opérations.
  Captures des pages concernées pour confirmer présentation inchangée.

### Q13 — P3 — Séparer les responsabilités Python et unifier les helpers divergents

**Dette constatée, reliée à Q01/Q03/Q10.** Le même module porte parsing, schéma,
révisions, import et dispatch CLI ; `query()` regroupe plusieurs familles de
requêtes. Les hashes, écritures atomiques et réapplication de provenance sont
réimplémentés avec des protections différentes.
Preuves : [dispatch](../Sources/KataLog/Resources/analyzer.py#L1403),
[query](../Sources/KataLog/Resources/library_repository.py#L827),
[helpers stockage](../Sources/KataLog/Resources/library_storage.py#L40-L57).

- **Correction minimale après les bugs :** extraire I/O locale et signatures,
  transactions/révisions puis dispatch ; fonctions privées par type de requête,
  même connexion et même contrat. Aucun ORM ni couche générique supplémentaire.
- **Test de sortie :** mêmes JSON canoniques, révisions immuables, migrations,
  pagination, budgets et reprise après interruption. Chaque extraction reste
  petite et indépendante d'une évolution des calculs d'analyse.

### Q14 — P3 — Typer les états GCS et vérifier leur parité avec SQL

**Dette constatée, divergence actuelle non affirmée.** États/phases sont des
chaînes libres et leurs catégories/progressions sont répétées en Swift et SQL.
Preuves : [modèles](../Sources/KataLogCore/GCSModels.swift#L78-L136),
[requêtes](../Sources/KataLogCore/GCSQueueRepository.swift#L125-L207).

- **Correction minimale :** types internes aux valeurs sérialisées inchangées,
  tolérance explicite du legacy, catégories centralisées. Conserver les agrégations
  SQL ; ne pas tout décoder en mémoire pour éliminer une duplication.
- **Test de sortie :** table de tous les états/phases et cas limites, mêmes
  résultats Swift/SQL, mêmes fichiers persistés ; compléter les tests de parité.

### Q15 — P3 — Isoler le shell legacy encore accessible en développement

**Dette constatée ; ce code n'est pas mort dans tous les lancements.** La stable
0.8.2 utilise `Workspace06View`, mais un exécutable SwiftPM sans version de bundle
ni flag peut atteindre `WorkspaceView` et son ancien chemin de fiche.
Preuves : [branche de lancement](../Sources/KataLog/main.swift#L6-L16),
[configuration](../Sources/KataLog/AppPreviewConfiguration.swift#L19-L31),
[ancien chargement](../Sources/KataLog/LibraryStore.swift#L247-L268).

- **Correction minimale :** sortir ce shell de `main.swift`, documenter les
  conditions d'activation et éviter que les corrections de services divergent.
  Sa suppression nécessite une décision distincte ; elle ne fait pas partie
  d'un refactor annoncé à fonctionnement constant.
- **Test de sortie :** lancement bundle stable et lancement SwiftPM, mêmes
  bibliothèques, thèmes et comportements pour chaque mode existant.

### Q16 — P2 — Isoler ou verrouiller un build local de bout en bout

**Risque étayé pour deux builds simultanés, package mélangé non reproduit.** Les
scripts utilisent des répertoires de travail globaux par défaut ; le moteur
déplace/réécrit ses inputs et ses sorties sans verrou global. Le build Swift et
la copie des deux exécutables sont des étapes distinctes.
Preuves : [defaults et copie](../tools/build-app.sh#L5-L17),
[compilation/copie](../tools/build-app.sh#L120-L138),
[mutation des inputs](../tools/build-engine.sh#L16-L24),
[compilation moteur](../tools/build-engine.sh#L66-L83).
Deux worktrees peuvent se gêner ; les contrôles de hash du moteur limitent le
risque mais ne sérialisent pas toute la chaîne. Le smoke CI utilise déjà un
[root unique](../tools/package-smoke.sh#L15-L27), à préserver.

- **Correction minimale :** root par invocation ou verrou couvrant build jusqu'à
  la capture de l'artefact, avec caches réutilisables séparés des sorties mutables.
- **Test de sortie :** deux builds synthétiques/stubbés avec marqueurs distincts ;
  chaque paquet correspond à sa source, aucun déplacement des inputs du voisin.

### Q17 — P3 — Conserver les preuves CI et surveiller les budgets utiles

**Manque de garde-fous automatisés.** La CI exécute bien les suites, mais les
JSON de tests restent dans `/tmp` et les benchmarks de capacité complets ne sont
pas rejoués par ce workflow. Les tests GCS de performance existants ne couvrent
pas toutes les I/O UI de Q06.
Preuves : [workflow](../.github/workflows/ci.yml#L33-L45),
[budgets du benchmark](../Tests/benchmark_library_repository.py#L117-L135).

- **Correction minimale :** conserver les résumés/logs synthétiques, y compris
  sur échec ; un banc périodique ou manuel reproductible pour requêtes, mémoire,
  rendu et file GCS. Utiliser les budgets existants, publier les conditions de
  mesure, ne pas ajouter un seuil de temps fragile à toutes les PR.
- **Test de sortie :** artefacts relisibles par commit et jeu de données ;
  reproduction des régressions Q01–Q10 ajoutée aux suites au fil des correctifs.
  Le taux de couverture éventuel ne remplace pas ces scénarios.

### Q18 — P3 — Rendre les contrôles requis avant intégration sur `main`

**Configuration constatée en lecture via l'API GitHub le 8 octobre :**
`branches/main` indique `protected=false`, l'endpoint de protection renvoie
« Branch not protected », et la liste des rulesets du dépôt est vide.
La CI existe, mais ces protections ne rendent pas son succès obligatoire pour
une intégration. Aucun réglage distant n'a été modifié pendant l'audit.

- **Proposition :** protection minimale de `main` avec les checks utiles requis
  et discussion explicite des exceptions administrateur ; conserver un workflow
  praticable pour un mainteneur unique.
- **Vérification de sortie :** constater qu'un changement applicatif en échec ne
  peut plus être intégré par le chemin normal. Cette action concerne le dépôt,
  pas le fonctionnement de l'app.

### Q19 — P3 — Vérifier la cohérence des métadonnées de build dupliquées

**Dette constatée ; les valeurs effectives de la baseline sont cohérentes.**
Version/build et réglages d'update se retrouvent dans le projet généré, son YAML,
le script de build et le smoke. Le template plist contient même d'anciennes
valeurs, correctement remplacées plus bas aujourd'hui.
Preuves : [projet](../project.yml#L35-L55),
[defaults](../tools/build-app.sh#L10-L14),
[template et remplacement](../tools/build-app.sh#L158-L180),
[smoke](../tools/package-smoke.sh#L22-L26).

- **Correction minimale :** contrôle automatique de cohérence des entrées et du
  plist final ; supprimer les valeurs intermédiaires trompeuses. Une source
  commune ne se justifie que si elle simplifie réellement les scripts existants.
- **Test de sortie :** stable, preview et override explicite conservent bundle ID,
  bibliothèque, version/build et politique d'update attendus.

### Q20 — P2 — Exécuter les grandes sélections dans le budget de variables SQLite

**Reproduit sur le runtime exact ; sélection GUI de cette taille non observée.**
Le contrat accepte jusqu'à 100 000 chaînes par liste, puis construit un paramètre
SQL par élément, parfois répété.
Preuves : [validation](../Sources/KataLog/Resources/library_repository.py#L443-L448),
[construction SQL](../Sources/KataLog/Resources/library_repository.py#L583-L610),
[budget requête](../Sources/KataLog/Resources/analyzer.py#L1623-L1626).
Sur SQLite 3.53.1, une requête de **32 767 SHA**, **2 228 226 octets**, est acceptée
puis échoue avec `too many SQL variables` ; limite runtime **32 766**, requête
pourtant inférieure aux 16 Mio autorisés. Les combinaisons de filtres peuvent
consommer le budget plus tôt.

- **Correction minimale :** listes volumineuses dans une table temporaire, sans
  changer la sélection ni son ordre. À défaut transitoire, erreur de contrat
  explicite calculée sur le budget total réel, avant préparation SQL.
- **Test de sortie :** valeurs autour de la limite runtime, filtres combinés,
  paramètres réutilisés, rapports et attribution client ; même ensemble de
  résultats qu'un oracle de petite sélection.

## Ordre de correction sans changement fonctionnel

Les cases sont volontairement ouvertes : fusionner cette PR ne corrige aucun
de ces points. L'ordre ci-dessous est une proposition d'exécution.

| Lot | Corrections | Livrable et condition de sortie |
| --- | --- | --- |
| 1. Conservation | Q01, Q02 | Deux petites PR séparées, reproductions intégrées, données précédentes inchangées après échec |
| 2. Cohérence | Q03, Q04, Q05, Q07, Q20 | Provenance conservée, résultats rattachés à leur requête, erreurs partielles réconciliées, grandes sélections testées |
| 3. Réactivité et I/O | Q06, Q08, Q09, Q10 | Latences et backlog mesurés, deadline tenue, arrêt/reprise et durabilité inchangés |
| 4. Clarification | Q11, Q12, Q13, Q14, Q15 | Contrat multi-fenêtre qualifié ; extractions ciblées, mêmes façades/JSON/écrans, aucun retrait implicite du legacy |
| 5. Prévention | Q16, Q17, Q18, Q19 | Builds isolés, preuves reproductibles, cohérence des métadonnées et contrôles d'intégration |

Suivi proposé :

- [ ] Q01 — transaction d'import
- [ ] Q02 — collisions CLI/moteur
- [ ] Q03 — provenance après réanalyse
- [ ] Q04 — suppression client partielle
- [ ] Q05 — événements et filtre courant
- [ ] Q06 — I/O GCS hors du rendu
- [ ] Q07 — compteurs complets en erreur
- [ ] Q08 — deadline HTTP
- [ ] Q09 — backlog d'événements
- [ ] Q10 — sources cloud
- [ ] Q11 — qualification multi-fenêtre
- [ ] Q12 — responsabilités et capacités Swift
- [ ] Q13 — responsabilités et helpers Python
- [ ] Q14 — états GCS typés
- [ ] Q15 — isolation du shell legacy
- [ ] Q16 — isolation des builds locaux
- [ ] Q17 — preuves CI et budgets
- [ ] Q18 — contrôles requis sur main
- [ ] Q19 — métadonnées de build
- [ ] Q20 — grandes sélections SQLite

Les extractions ne doivent pas être mélangées avec les correctifs de cohérence :
chaque diff doit montrer ce qui répare un bug et ce qui déplace du code à
résultat identique. Garder le design bento, les seuils, les formats et les noms
exposés aux utilisateurs. Mesurer les agrégats de carte avant d'ajouter des caches.

## Reproductions minimales des deux P1

Depuis la racine du commit audité, avec Python 3.13 et les dépendances runtime
épinglées. Ce script ne manipule que ses propres dossiers temporaires ; ses
assertions décrivent **les défauts présents**, et devront être inversées dans
les futurs tests de correction.

```sh
PYTHONPATH=Sources/KataLog/Resources:Tests python - <<'PY'
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
import json
import sqlite3
import analyzer
from fixture_ulog import synthetic_ulog

with TemporaryDirectory(prefix='katalog-audit-import-') as tmp:
    root = Path(tmp)
    source = root / 'source.ulg'
    source.write_bytes(synthetic_ulog(drone_name='Before', samples=2))
    initial_sha = analyzer.digest_file(source)
    database = root / 'library' / 'library.sqlite'
    original_analyze = analyzer.analyze_file

    def replaced_source(path, *args, **kwargs):
        Path(path).write_bytes(synthetic_ulog(drone_name='After', samples=2))
        return original_analyze(path, *args, **kwargs)

    with patch.object(analyzer, 'analyze_file', replaced_source):
        result = analyzer.scan(source, database)
    db = analyzer.open_database(database, read_only=True)
    try:
        saved = json.loads(db.execute(
            'SELECT summary FROM logs WHERE id=?', (initial_sha,)).fetchone()[0])
        revisions = db.execute('SELECT COUNT(*) FROM analysis_revisions WHERE log_id=?',
                               (initial_sha,)).fetchone()[0]
        assert result['importStats']['failed'] == 1
        assert analyzer.digest_file(source) != initial_sha
        assert saved['status'] == 'ok' and saved['droneName'] == 'After'
        assert revisions > 0
        print('Q01: analyse et revision publiees sous le SHA rejete')
    finally:
        db.close()

with TemporaryDirectory(prefix='katalog-audit-collision-') as tmp:
    root = Path(tmp)
    source = root / 'empty'
    source.mkdir()
    database = root / 'library.sqlite'
    analyzer.scan(source, database)
    db = sqlite3.connect(database)
    try:
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    finally:
        db.close()
    assert database.read_bytes().startswith(b'SQLite format 3')
    analyzer.scan(source, database, output=database)
    assert not database.read_bytes().startswith(b'SQLite format 3')
    print('Q02: base remplacee par la sortie JSON')
PY
```

Les autres reproductions de l'audit utilisent les mêmes fixtures synthétiques,
des faux services pour les stores, un flag dataless simulé ou un serveur loopback.
Leurs scénarios, limites et assertions à pérenniser sont précisés dans chaque
constat ; aucun de ces tests supplémentaires n'est ajouté au produit par cette PR.

## Limites et critères communs

- Aucun accès à une bibliothèque utilisateur, aucun contact GCS réel, aucun
  remplacement d'app installée et aucune nouvelle distribution pendant l'audit.
- Les reproductions Swift avec faux services qualifient la logique des stores,
  pas un parcours utilisateur complet dans le bundle distribué.
- Le contrôle de publication couvre les fichiers actuels et les motifs du
  scanner du dépôt. Il ne prouve pas l'absence de secrets dans tout l'historique,
  les assets distants, ni l'absence de vulnérabilités des dépendances.
- Pas de nouvelle recette manuelle VoiceOver, clavier, impression, macOS 15
  physique, iCloud réel, disque défaillant ou flotte radio. La CI et les recettes
  historiques ne remplacent pas ces validations.
- Aucune modification proposée des seuils d'alerte, identités, comptes,
  filtres, rétention, parallélisme de collecte, formats publics ou présentation
  bento. Toute différence métier découverte pendant un refactor doit être
  isolée et expliquée avant intégration.
- Chaque lot doit conserver les anciennes données et les erreurs utiles,
  fournir son test de non-régression, passer les suites concernées, puis la
  baseline complète avant release. Le packaging et la recette de l'app installée
  restent des étapes distinctes.
