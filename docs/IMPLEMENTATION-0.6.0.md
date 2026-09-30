# KataLog 0.6.0 — code, preuves et portes restantes

Suivi du 30 septembre 2026. **Branche de développement, sans release 0.6.0 ni publication publique.**
L’installation utilisateur reste la référence 0.5.2 (7). Les nouveaux écrans ont
été approuvés le 30 septembre et s’activent par défaut dans les builds stables
à partir de 0.6.0. Ils restent accessibles par `KATALOG_UI_PREVIEW=1` ou le package de revue avec le flag
Info.plist `KataLogUIReviewPreview`. Ce package possède son nom, son bundle ID
et sa bibliothèque par défaut dédiés. L’activation développeur par environnement
conserve le choix explicite d’une bibliothèque. Recette visuelle et approbation
restent distinctes des tests du moteur. La bibliothèque de la stable conserve
son emplacement habituel et les destinations explicites sont préservées.

## Sources, indicateurs et badges — lot de clarté

- **Sources d’import :** liste globale paginée, retrait/restauration persistants,
  annulation et réactivation par import explicite ou réassociation réussie.
  Les ULogs, analyses, annotations et chemins de provenance restent conservés.
  Les actions respectent le verrou écrivain, la lecture seule et les opérations
  actives. La nouvelle projection **7** se reconstruit sans relire les ULogs ;
  le parseur reste **1.4.0**.
- **Indicateurs :** drones scannés avec identités provisoires séparées, durée
  enregistrée incluant le sol, temps de vol cumulé avec couverture N / M logs.
  Une durée absente reste indisponible ; zéro mesuré reste zéro. Les agrégats
  portent sur toute la sélection, indépendamment de la page affichée.
- **Badges :** Signal critique, Erreur à vérifier, Avertissement, Aucune alerte
  détectée et Niveau indéterminé. Le motif observé et la qualité de lecture sont
  distincts. Les événements non traduits conservent leur gravité connue ; un
  failsafe sans niveau n’invente pas un niveau CRITICAL. Filtres et masques sont
  appliqués au badge. Le compteur d’alertes conserve son périmètre historique
  messages textuels/failsafe, explicité dans l’aide.
- **Aides et rapports :** définitions communes au survol, au clic et au clavier ;
  rapports HTML/JSON, mode sans JavaScript, filtres dynamiques, anonymisation et
  impression cohérents. La provenance exportée est distinguée des sources
  d’import actives dans l’app.

### Preuves du lot

| Contrôle | Résultat | Périmètre |
|---|---|---|
| Python autonome | **335 réussis / 336 cas**, 0 échec/erreur/skip inattendu | Le corpus privé de neuf ULogs est absent et annoncé séparément |
| Swift complet | **230 réussis**, 0 échec/skip | Stores, moteur, export, DOM WebKit et vues natives |
| Node | **18 réussis**, 0 échec/skip | Recalcul des indicateurs et badges avec les filtres |
| Conservation et rendu | Retrait/restauration/annulation réels sur fixture, SHA ULog inchangé ; captures natives clair/sombre et rapports JS/sans JS inspectés | Données synthétiques ; fenêtres minimales sources 650×460, workspace/fiche 900×620 |
| Historique synthétique | 50 000 logs, 5 millions de messages, 500 drones : tous les p95 sous 500 ms ; maximum **350,1 ms**, RSS **169 Mio** | Index préparé en 432,57 s ; cache OS non contrôlé |
| Liste des sources | 50 000 chemins, 500 dossiers, page 200 : p95 **8,33 ms** | Avant index/range : 1 990 ms ; chemins Unicode, racine, voisins et copies multiples vérifiés |
| Secrets | Gitleaks 8.30.1 : **0 finding** sur les 206 fichiers du gel publiable | Contrôle complémentaire de contenu ; ne publie pas le dépôt |

Les sous-suites ne sont pas additionnées aux **583 tests réussis** ci-dessus.
Cette recette ne constitue pas un test matériel simultané de 500 drones et ne
ferme pas les portes de distribution sur les autres versions de macOS.

### Package de revue 0.6.0 (10)

App et DMG signés Developer ID et acceptés par Apple ; tickets attachés au helper,
à l’app et au DMG. Les **neuf gates de distribution passent sur macOS 27.0.1**,
y compris retrait/restauration avec le helper embarqué dans des processus
distincts, préservation des ULogs et validation des tickets de l’app et du
helper montés. Le moteur contient les **11 modules** actuels et correspond
exactement aux SHA de leurs sources. Le contrôle de confidentialité du bundle
inspecte **178 fichiers / 474 payloads embarqués : 0 finding** ; les 22 binaires
ARM64 inspectés n’ont aucune dépendance externe à la machine de développement.

| Package notarisé 0.6.0 (10) | Octets | SHA256 |
|---|---:|---|
| DMG | 19 051 960 | `2755a628143e6379f30098b3201a09d7deebe75719f354ed5fe5fac33ef8bbf7` |
| ZIP avec tickets helper/app | 19 407 355 | `1014e4b13ef8b92eee726f930fbca54b88c2fc2cdf1ba1b151addc9a3e7fc182` |

Package local de revue, updater désactivé, aucune release 0.6.0 ni passage public.

## Suite autorisée et recette physique

- **Décisions enregistrées :** interfaces approuvées, licence **GPL-3.0-only**,
  runners GitHub standard uniquement après passage public. Aucun runner n’est
  alloué par ce workflow pendant que le dépôt est privé.
- **Défaut observé :** le store GCS de la première Preview choisissait la
  bibliothèque installée au lieu de la bibliothèque Preview. Il a chargé et
  migré des réglages/queue installés. Aucune collecte n’a été lancée pendant
  cette observation. Le résolveur de bibliothèque est maintenant partagé par
  les stores Library et GCS, avant toute lecture ou migration.
- **Reconnexion au démarrage :** l’attachement GCS pendant `ensure-index`
  reportait une erreur de maintenance et ne relançait pas sa première
  connexion. La découverte et l’initialisation de la file sont maintenant
  différées jusqu’à la fin de cette maintenance ; une collecte arrêtée reste
  arrêtée.
- **Recette logicielle actuelle :** 38 tests ciblés puis **214 tests Swift
  complets réussis, aucun skip ni échec**, sur les mêmes sources. Le premier
  gate de ces corrections avait échoué dans le cas simulé de retry GCS ; des
  répétitions ciblées et le gate instrumenté passent avec les assertions et
  délais inchangés. La cause exacte de ce premier échec reste inconnue. Le
  minimum d’espace libre mesuré pendant le gate réussi est 24,58 Gio ; cela
  ne prouve pas la cause du premier échec.
- **Licence dans le bundle :** texte GNU exact, notice originale publique,
  attribution SPDX et manifeste SHA/version/build. **17 tests distribution
  réussis**, dont six nouveaux tests d’intégrité. Le contrôle est obligatoire
  à partir de 0.6.0 ; les notices tierces sont conservées.
- **Gate public avant le correctif de démontage :** Python exécute 308 cas en 37,932 s :
  **307 réussis**, un seul corpus privé absent et annoncé, aucun échec ni skip
  inattendu. Swift : **214 réussis**, zéro skip/échec ; Node : **13 réussis**,
  zéro skip/échec. Cela représente **534 tests publics réussis** et une absence
  privée distincte. Les 17 tests distribution et 38 tests Swift ciblés sont
  compris dans ces suites ; ils ne sont pas ajoutés au total. Les 94 SHA des
  inputs Swift restent identiques au gate natif et au clone consolidé.
- **Matériel :** un drone disponible, découverte passive et inventaire réel
  de deux ULogs. Un premier transfert via le helper signé réussit :
  **4 272 039 octets en 53,824 s**, signature ULog et SHA vérifiés. L’analyse
  lit 48 messages avec un statut `ok`. Le second appel retourne le cache en
  0,185 s, sans nouveau transfert et avec inode/mtime/taille inchangés ; le
  réimport retrouve une analyse sans doublon ni erreur. Le second log est
  arrêté localement en 0,838 s : aucun nouveau ULog n’est publié. La GCS finit
  sa copie distante après 53,477 s, observée par abonnement passif ; la relance
  réussit en 54,421 s. Les deux fichiers totalisent **8 598 637 octets**, sont
  vérifiés et analysés (34 et 48 messages), puis retrouvés dans le cache sans
  nouveau transfert. Le dernier réimport annonce deux inchangés, zéro import
  ni erreur. Les UUID `metadata.gcsUUID` enregistrés sont vérifiés et égaux à
  l’identité MQTT du drone ; le `sys_uuid` ULog distinct reste conservé. Le lancement
  du package corrigé ouvre l’Historique vide et les réglages GCS démarrent sans
  UUID installé. Les appels Computer Use suivants expirent ; le titulaire
  confirme que la page Collecte GCS répond manuellement. Le helper signé et
  son analyse CLI sont qualifiés par cette recette ; cela ne qualifie pas
  les boutons et transitions de l’interface GCS. Un seul drone
  ne ferme pas GCS-10 et ne qualifie ni deux transferts physiques concurrents
  ni une flotte de 500 appareils.
- **Distribution avant notarisation :** Preview corrigée **0.6.0 (9)** construite et signée
  Developer ID, **sept gates réussis**. Le scan inspecte 174 fichiers et 472
  payloads embarqués sans finding ; 22 composants natifs ARM64 sans dépendance
  externe. Import, cache, backup/restore, archivage, événements, courbes,
  rapport et collecte loopback sont exécutés avec le helper signé sous HOME
  isolé et environnement Python hostile. Le DMG est vérifié et son app montée
  correspond au bundle. Le parcours Finder et les transferts réels restent
  distincts de ces contrôles. Les
  empreintes et sept gates du build 8 ci-dessous sont des preuves historiques,
  pas une validation du nouveau code. Aucun profil de notarisation n’est
  disponible selon le titulaire ; sa création interactive est décrite dans
  [RELEASING](RELEASING.md). Aucun credential ni soumission Apple n’est créé
  par cette passe. Le feed Sparkle reste désactivé.

| Package corrigé 0.6.0 (9), avant notarisation | Octets | SHA256 |
|---|---:|---|
| DMG preview | 18 857 910 | `8cb8547e1e243ff3f1a0a5adbe7f76f3f27b725aee6ae463cbe119a616c769be` |
| ZIP preview | 19 020 291 | `afabe2ad6acf8703ba0474d0ff942394d0d17d1eba2e89ae32f2ac27b18393fe` |

### Notarisation de la Preview 0.6.0 (9)

Le profil local est maintenant validé. Apple accepte le ZIP soumis et le
nouveau DMG ; le journal de l'app contient zéro issue. Les tickets du helper
et de l'app sont agrafés et validés avant de recréer le ZIP et le DMG.
Les **174 fichiers originaux du bundle restent identiques** au package signé
ci-dessus. Les anciens packages sont conservés séparément.

La recette avec `--require-notarized` passe **neuf gates sur macOS 27.0.1** :
metadata/licence, confidentialité, runtime ARM64 autonome, infrastructure
Sparkle, signature stricte, import et collecte loopback, ticket/Gatekeeper de
l'app, intégrité et installation du DMG, ticket/Gatekeeper du DMG. Le contrôle
du volume monté valide explicitement les tickets de l'app **et du helper**.
Le scan inspecte 176 fichiers et 472 payloads sans finding ; 22 composants
natifs ARM64 n'ont aucune dépendance externe.

Le démontage des volumes temporaires dispose de réessais bornés et réserve
le dernier essai forcé au montage en lecture seule créé par le contexte.
Un échec conserve le chemin et l'erreur ; aucune suppression récursive du
répertoire potentiellement monté n'est tentée.

Les **28 tests distribution réussissent**, dont neuf nouveaux cas sur le cycle
de montage/démontage, le build après exécution du helper et les deux tickets
dans le DMG. Le gate Python complet final exécute **317 cas : 316 réussis**,
zéro échec/erreur/skip inattendu et le même corpus privé absent annoncé.
Les 214 tests Swift et 13 Node précédents portent sur des sources inchangées ;
ils ne sont pas rejoués pour ce correctif d'outillage. Le total consolidé est
**543 tests publics réussis**, avec leurs dates et périmètres distincts.

| Package notarisé 0.6.0 (9) | Octets | SHA256 |
|---|---:|---|
| DMG preview | 18 853 744 | `965640bf2627384410103cc0f49a22c14aa22256c5fb508f8addc37956284771` |
| ZIP preview | 19 023 924 | `7531cb287a0f74ba22ac0c1fd7d88720a5e11b8253b2348f9b6915acf219d8b2` |

Cette recette qualifie les fichiers locaux de Preview, pas une release stable,
un téléchargement GitHub quarantiné, une installation sur Mac vierge/macOS 15
ni le parcours GUI de mise à jour. Le feed reste désactivé ; aucune publication
publique n'est effectuée.

Les sources de cette recette sont figées dans une copie locale hors iCloud à
partir du HEAD distant vérifié. Le dossier Desktop reste indisponible lors des
lectures ; son identité avec la copie locale n’est pas revendiquée et ses
modifications éventuelles doivent être préservées à la consolidation.

Le [backlog](BACKLOG-0.6.0.md) conserve les **117 IDs, dépendances et critères**.
Son état signifie code testé, preview, critère partiel, qualification externe ou
décision requise. Aucun état « Validé ciblé » n’annonce une recette matérielle,
un fonctionnement universel sans bug ou une release.

### État des 117 tickets après approbation UI et choix de licence

| État du backlog | Tickets |
|---|---:|
| Critères ciblés validés | 67 |
| Protocole/collecte simulés validés | 10 |
| Corpus privé validé | 1 |
| Migration legacy validée | 1 |
| SDK update exercé, avec limites de phase | 2 |
| Backend validé, UI en preview | 6 |
| Implémenté, gates UI/distribution/CI distincts | 16 |
| Preview avec recette visuelle restante | 3 |
| Qualification externe | 9 |
| Décision explicite requise | 2 |
| Intégration finale en cours | 0 |
| **Total d’IDs uniques** | **117** |

Les anciens états « helper final attendu », preview export, diagnostic et diff
paramètres ont leurs preuves ciblées. L’ENOSPC de téléchargement de l’updater
est validé sur un volume de test borné ; une attestation postquit distincte
vérifie la conservation des données et l’app ancienne utilisable. Aucun callback
ni diagnostic de cause de l’installer n’est revendiqué pour cette seconde phase.
Les portes externes et la consolidation finale demeurent ouvertes et ne sont
pas présentées comme des tests réussis.

## Versions et compatibilité

| Couche | Version de développement | Règle |
|---|---|---|
| Parseur | 1.4.0 | Les analyses anciennes restent consultables ; un recalcul est explicite |
| SQLite canonique / JSON | 1 / 1 | Extension additive ; versions futures refusées |
| Projection SQLite | 6 | Index dérivés reconstructibles, backup vérifié avant migration |
| Query / SelectionScope | 1 / 1 | Révision et scope dans les réponses/curseurs |
| Révisions d’analyse | 1 | Résumé et détail séparés, identité et SHA exacts |
| Backup / archive / rapport | 1 | Manifestes, empreintes et publication atomique |
| Cible macOS | 15 minimum, Apple Silicon ; 27 inclus | Machine macOS15 et installation finale restent à qualifier |

Les [contrats](CONTRACTS-0.6.md) décrivent les DTO et limites. Aucun format ancien
ne devient courant simplement parce que le numéro du parseur a changé.

## Preuves historiques du gel précédant la recette GCS

| Gate | Résultat disponible | Limite |
|---|---|---|
| Backend ciblé Python privé | **185/185 réussis, 0 échec/skip**, en 14,57 s, sur les 9 modules gelés | Sous-suite incluse dans le gate Python global ; ne pas l’ajouter au total |
| Backend ciblé Python public | **184 réussis + 1 absence explicite du corpus privé**, 0 échec/skip inattendu, en 8,08 s | Le corpus privé complète la non-régression, sans conditionner un gate autonome |
| ALL Python privé final | **302/302 réussis, 0 échec/erreur/skip** | Corpus privé en local ; aucun original publié |
| ALL Python public final | **301 réussis + 1 absence explicite du corpus privé sur 302**, 0 échec/erreur/skip inattendu | Gate autonome ; absence privée annoncée séparément |
| ALL Swift final | **208/208 réussis, 0 échec/skip** | Copie de sources figée ; ne remplace pas une recette GUI, VoiceOver ou matérielle |
| ALL Node final | **13/13 réussis** | Interactions DOM sur fixtures ; navigateur et print restent distincts |
| CI distante, tentative sur `377d8af` | CI hébergée indisponible : 4 jobs refusés avant allocation de runner ; **0 étape exécutée**, aucun test ni compilation démarré | Aucune qualification distante de macOS15/27 |
| Captures synthétiques de revue | 30 captures, dont historique sombre, stockage et rapport clair | La conformité observée reste une revue locale ; approbation utilisateur des nouveaux écrans distincte |
| Corpus source privé | 9 originaux : SHA256, taille et mtime inchangés | Copies locales stables utilisées pour les tests ; aucun original publié |
| Tests autonomes | Fixtures ULog, dictionnaires, topics, paramètres, queues et rapports inventés | Le test privé annonce son absence quand son dossier n’est pas fourni ; aucun gate critique dépend de ce dossier |
| Repository | 46 tests de parité, pages, filtres, migrations, noms/stock et coverage globale | Les fixtures qualifient les critères logiciels exercés |
| Révisions | 9 tests : deux versions, source retirée, backup/restore, limite, nettoyage, CLI read-only, format futur refusé avant toute mutation | La date est celle de capture ; les analyses déjà remplacées avant cette fonction ne peuvent être recréées |
| Archives | 21 tests : publication avant parser, retrait de la carte, origine, refus copie, recovery et réassociation | Une interruption physique de volume reste distincte des fixtures |
| Crash et migration legacy | 5 tests, 9 injections SIGKILL avant/après publication ; recovery idempotente et SHA/mtime préservés | DDL/JSON réellement produits par les sources legacy 0.5.1, hashes identiques au moteur 0.5.2 ; aucune source 0.5.3 disponible |
| Rapports backend | 11 tests : stream, cohérence, annulation, SHA, enrichissement et canaries de partage | Une recette navigateur/print complète reste distincte |
| Collecte native ciblée | 25 tests GCSStore, dont 500×100 jobs synthétiques | Pas une collecte réelle de 500 appareils |
| Banc natif avec helper final embarqué | 3 nouveaux processus de navigation : pages 1,121 / 0,617 / 0,608 s ; 20 répétitions par scénario, store p95 global 452,4 ms / drone 450,0 ms | Premier drone 656,5 ms conservé ; rendu bitmap séparé, cache OS non contrôlé |
| Courbes et annulation natives | 4 courbes, 2048 points au total ; première extraction synthétique 2,343 s / privée 0,242 s ; feedback d’annulation ≤ 46 µs, retour du helper ≤ 6,16 ms | Les lectures de nouvelles fenêtres restent non cached ; cache du store et extraction sont mesurés séparément |
| HTML réel final | 200 logs / 10 000 messages, HTML 7,43 Mo ; génération 0,805 s, WebKit + JS initial 0,558 s ; 20 changements de filtre, p95 12,3 ms | Oracle des comptes exact ; WebContent 143,1 MiB, impression GUI et navigateurs externes restent distincts |
| Helper final reconstruit | 9 SHA sources/PYZ + requirements/entry/spec exacts ; 14 workflows réels réussis après le dernier précontrôle de format futur | Version 1.4.0 / projection 6 ; HOME/cwd isolés et environnement Python hostile |
| Bootstrap du helper | Cache de 1 655 fichiers validé ; SHA, inode et mtime des Mach-O inchangés | Validation du cache séparée des nouveaux processus et de la distribution finale |
| SDK Sparkle réel | 6 recettes avec callbacks + 1 attestation postquit réussies : install/relaunch 1→2, ZIP/feed altérés, asset 404, download tronqué, ENOSPC de téléchargement, conservation après fermeture | La phase postquit n’expose ni callback ni cause installer ; GUI et feed HTTPS utilisateur non qualifiés |
| Candidate de revue | App preview 0.6.0 (8), Developer ID ; package **7/7 gates réussis**, 58 SHA sources Swift identiques et 14 workflows du bundle réussis | Notarisation absente ; téléchargement quarantiné/Gatekeeper et CI distante non qualifiés |
| Installation utilisateur | Info.plist et Mach-O de l’app 0.5.2 (7) inchangés | La candidate de revue est isolée ; aucun remplacement de l’app installée |
| Audit final précommit | 194 fichiers ; guard à 11 marqueurs et Gitleaks 8.30.1 : 0 finding sur sources/historique de base ; 124 liens locaux valides et 13 images aux métadonnées vérifiées | Aucun drift SHA/mode/sélection ; audit local préalable, sans publication ni verdict de CI distante |

Le gate privé compte **523 tests uniques : 302 Python + 208 Swift + 13 Node**.
Les 185 tests backend, 25 tests GCSStore et autres sous-suites sont déjà compris
dans ces nombres. Les workflows du helper, recettes SDK, benchmarks et captures
sont des preuves distinctes, pas des tests supplémentaires à additionner.

Les fichiers du package de revue ont leurs empreintes finales :

| Asset | Taille en octets | SHA256 |
|---|---:|---|
| DMG preview | 18 837 733 | `8abed7acdce087bb19162959542e10fc6e38c01f3e17314b08a5ecd33cb40e60` |
| ZIP preview | 19 004 275 | `7d93ecaaf975ed57e678a7c881340ab625b513cbee2a26274b741bd49d018ccb` |

Les sept gates qualifient le package local de revue et ses signatures. Aucun
identifiant de soumission notariale n’existe pour cette candidate. Ces résultats
n’annoncent ni une release publique, ni un feed utilisateur, ni une installation
après téléchargement réel avec quarantine.

Les preuves brutes et informations du corpus privé restent dans les rapports
locaux ignorés par Git. Ce document expose les mesures utiles sans chemins
personnels, identités, positions ni adresses réseau réelles.

## Performance du repository

Banc reproductible [benchmark_library_repository.py](../Tests/benchmark_library_repository.py) :
50 000 résumés, 5 000 000 occurrences textuelles, 500 identités synthétiques,
plusieurs années, dates inconnues, homonymes, numéros partagés et deux drones sans log.
Ce banc ne parse pas 50 000 fichiers ULog et ne qualifie pas 500 drones physiques.

Six répétitions par scénario, première requête incluse dans le gate conservé à
500ms. Avec six valeurs, le p95 utilisé est la plus élevée. Les requêtes
suivantes sont aussi enregistrées ; aucune requête lente n’a été retirée pour
faire réussir le résultat. Index préparé ; le cache de pages de l’OS n’est pas
contrôlé et cette mesure ne remplace pas un véritable cold-start.

| Requête | p95 final |
|---|---:|
| Dashboard | 425 ms |
| Un drone | 223 ms |
| Groupes | 63 ms |
| Famille + alertes | 294 ms |
| Recherche textuelle | 160 ms |
| Occurrences | 21 ms |
| Carte | 24 ms |
| Registre | 445 ms |

**8/8 PASS sur la source finale**, RSS maximale du helper **173,1 MiB**, base
**3 126 554 624 octets**, réponses sous 4 MiB. Les IDs/date et occurrences de premières pages correspondent
à l’oracle ; les pages suivantes d’occurrences ne répètent aucun ID. La limite
de 80 trajectoires sur la carte est annoncée et indépendante des agrégats globaux.

Les mesures négatives sont conservées : projection 5 puis première projection 6
avaient des p95 famille/recherche entre 671 et 798 ms. Après ajout des révisions
et observations du registre, les premiers appels ont révélé d’autres dépassements
entre 564 et 764 ms, y compris sur une fenêtre calme. Aucun n’a été exclu.
Les correctifs utilisent les index existants : un probe de nom par contrôleur,
index du contrôleur pour un scope ULog, sélection temporaire id/ordinal seulement,
agrégats sur index couvrant et joins de stock après agrégation du registre.
Le seuil est resté 500 ms ; aucune DDL supplémentaire n’a été nécessaire.

La génération initiale a duré 41,43 s et la préparation de l’index 235,89 s.
La passe finale est un nouveau processus sur cette même fixture préparée,
sans préchauffage de requête ; la première de chacune des six répétitions est
incluse. La fixture précédente de 3,78 Go a été retirée après conservation des
preuves. La fixture finale a ensuite été retirée après la dernière mesure native
et la conservation de ses preuves. Seul le dossier temporaire généré pour ce banc
a été supprimé ; le clone APFS du banc natif reste sous son propriétaire.

Le banc natif final utilise le helper embarqué et les vrais stores/vues SwiftUI
dans une fenêtre hors écran, sans lancer l’installation utilisateur. Trois
nouveaux processus donnent une première page exploitable en 1,121 / 0,617 /
0,608 s. Le premier bitmap prend 1,734 s depuis l’entrée native, ou 2,117 s
depuis le spawn échantillonné : ces deux points de départ ne sont pas fusionnés.

| Scénario natif warm | Répétitions | p95 store | Maximum store | p95 bitmap séparé |
|---|---:|---:|---:|---:|
| Toute la bibliothèque | 20 | 452,4 ms | 455,5 ms | 193,0 ms |
| Un drone | 20 | 450,0 ms | 656,5 ms | 226,8 ms |

Le premier cas drone à 656,5 ms reste dans les 20 valeurs ; le p95 ne constitue
pas une promesse que chaque requête ou le bitmap complet restera sous 500 ms.
Les deux scénarios possèdent leur propre distribution. La RSS kernel maximale
native est de 137,3 MiB sur les recettes de navigation/courbes ; le plus grand
helper échantillonné est de 63,7 MiB. La recette HTML attribue séparément
143,1 MiB à WebContent, 32,1 MiB au GPU WebKit et 15,3 MiB au réseau WebKit.
Ces pics par processus ne sont pas additionnés comme un total simultané.

Le banc natif échantillonne la RSS toutes les 40 ms : une pointe plus courte
peut manquer. Les processus WebKit déjà présents ou partagés sont exclus du
total attribuable à la recette. Le disque mesuré est APFS interne ; les vitesses
de cartes/volumes externes et un cache OS réellement froid ne sont pas qualifiés.

## Stabilisation S

**IDs suivis : S01–S12.** Identité canonique conservée résumé/fiche/exports,
sources absentes qualifiées, phases GCS séparées, profil basé sur logs uniques,
failsafe observé sans texte inventé, couverture GNSS par récepteur et durée de
vol courte qualifiée. Un inventaire en erreur empêche le verdict complet.
Double export, réponse périmée et cache ancien ont des gardes explicites.

Preuves : [test_analyzer.py](../Tests/test_analyzer.py),
[test_flight_data.py](../Tests/test_flight_data.py),
[FleetTests](../Tests/KataLogCoreTests/FleetTests.swift),
[GCSModelsTests](../Tests/KataLogCoreTests/GCSModelsTests.swift),
[GCSStoreTests](../Tests/KataLogAppTests/GCSStoreTests.swift),
[LibraryStoreTests](../Tests/KataLogAppTests/LibraryStoreTests.swift),
[ReportDOMTests](../Tests/KataLogCoreTests/ReportDOMTests.swift).
Les retouches de layout et filtres ont été approuvées ; la recette des
interactions dans le package corrigé reste distincte.

## L0 — contrats et oracles

**IDs suivis : L0-01–L0-10.** Formats distincts, scope commun, identité de
contrôleur distincte d’un numéro de stock, métriques/couverture, fixtures publiques,
révisions de lecture et writer lease sont codés et testés. Le catalogue global
des filtres conserve INFO et les familles/niveaux inconnus observés ; un
ancien parseur hors page200 et hors scope courant est signalé par
`totals.libraryStaleAnalysisLogs`. Les erreurs non analysables ne provoquent pas
un prompt permanent de refresh.

Preuves : [LibraryContractsTests](../Tests/KataLogCoreTests/LibraryContractsTests.swift),
[test_library_repository.py](../Tests/test_library_repository.py),
[fixture_ulog.py](../Tests/fixture_ulog.py),
[LibraryWriterLeaseTests](../Tests/KataLogCoreTests/LibraryWriterLeaseTests.swift),
[ProcessLifetimeTests](../Tests/KataLogCoreTests/ProcessLifetimeTests.swift).
L0-08 garde la matrice cold/RSS distincte ; L0-10 garde l’approbation visuelle.

## L1 — distribution

**IDs suivis : L1-01–L1-06.** Moteur embarqué, manifeste, hashes, refus de helper
endommagé/incompatible et validation des packages existent. Les outils contrôlent
les versions, dépendances, liens, signatures et mêmes bits entre packages.

Preuves : [EngineRuntimeTests](../Tests/KataLogCoreTests/EngineRuntimeTests.swift),
[test_engine_entry.py](../Tests/test_engine_entry.py),
[test_distribution_validation.py](../Tests/test_distribution_validation.py).
Le package final de cette source, son téléchargement réellement quarantiné,
son remplacement sans perte et macOS15 sur machine réelle sont des gates
séparés. Le succès d’installation0.5.2 sur macOS27 est une preuve historique.

## L2 — conservation

**IDs suivis : L2-01–L2-12.** Backup SQLite via l’API dédiée, configurations,
manifestes/SHA, restauration en staging et rollback conservent le dossier racine
et son inode de lease. Les fichiers ULog utilisateur sont lus, pas supprimés.
La réassociation exige le même SHA ; une source modifiée n’est pas reconnue
comme un original valable.

L2-08 propose à l’import **référencer ou archiver dans un dossier choisi**.
`scan --archive-destination` est optionnel ; le mode standard et la collecteGCS
n’ajoutent pas une seconde copie. Les imports déjà en cache peuvent être
archivés ; une copie existante valide est réutilisée. L’ordre est
**temporaire → taille/stat/SHA → publication atomique → parsing de la copie**.
Nom de fichier, contexte de carte, identité provisoire et provenance de date
restent ceux de l’origine. Retirer la carte après publication n’interrompt pas
l’analyse. Progression et compteurs d’archive sont distincts de l’analyse.
Le disque plein refuse cet import, conserve toute analyse antérieure et ne
publie aucun fichier final partiel ni fausse analyse en erreur.
`import-options.json` fait partie du backup. Un crash avant le premier parsing
laisse une copie vérifiable et son contexte dans le journal/manifest ; la
récupération ne fabrique pas de résultat d’analyse.

### Révisions d’analyse (L2-10)

`analysis_revisions` retient les résumés et détails réussis comme objets
distincts. ID stable, logSHA, type, version de parseur, SHA du JSON UTF8 exact,
taille et dateUTC de capture accompagnent le payload compressé. Aucune date
historique de calcul n’est inventée lors de la migration. Ancien et nouveau
calcul sont conservés ; une lecture répétée ou un import inchangé ne dupliquent
pas la même révision.

Les limites sont64MiB décompressés par analyse et512MiB compressés pour l’histoire.
Le budget plein refuse le remplacement, conserve résumé/cache/projection et
demande export puis nettoyage. Aucune suppression automatique n’est effectuée.
Le nettoyage choisi retire les caches de détail et les anciennes révisions
après leur copie dans un recovery SQLite vérifié. Dernier résumé et dernier
détail restent conservés par log ; sources ULog et fiches canoniques restent
présentes. La preview annonce cette règle et le nombre de logs sélectionnés.
Les nombres exacts de caches/révisions retirés et de révisions conservées sont
affichés après l’opération ; aucun chiffre d’impact non calculé n’est annoncé
avant. La restauration retrouve les payloads, dates et SHA exacts.
La consultation paginée ne charge pas tous les payloads ; la lecture d’une
révision vérifie la taille, la compression, le SHA et l’appartenance au log.

[test_library_crash_recovery.py](../Tests/test_library_crash_recovery.py) tue
réellement les subprocess autour des publications backup/restore/archive.
Les récupérations répétées gardent un état ancien ou nouveau complet et
préservent l’origine. La fixture de migration utilise les véritables sorties
du parseur legacy 1.2.0 sur un ULog inventé, sans Git au runtime et sans lire la
bibliothèque utilisateur. Les sources legacy correspondent à 0.5.1/0.5.2 ;
aucune qualification de source 0.5.3 inexistante dans ce corpus n’est annoncée.

`analysis-revisions --read-only` et `detail --revision ID --read-only` fonctionnent
sans source et sans écrire. `analysisRevision` est un objet top-level ;
`metadata` conserve uniquement des strings. Le flag `current` exige version
et SHA identiques au résumé/cache actif. Les résumés historiques sont qualifiés
comme résumés et n’annoncent pas une fiche détaillée.

Le nettoyage est réversible, archive les révisions retirées et conserve la
dernière analyse exploitable de chaque type. La dernière fiche retenue reste
lisible après retrait de source. Backup/restauration préservent toutes les
révisions, SHA et dates, avec validation avant remplacement.

Preuves : [test_library_storage.py](../Tests/test_library_storage.py),
[test_library_archives.py](../Tests/test_library_archives.py),
[test_analysis_revisions.py](../Tests/test_analysis_revisions.py),
[LibraryMaintenanceTests](../Tests/KataLogAppTests/LibraryMaintenanceTests.swift),
[LibraryIntegrationTests](../Tests/KataLogAppTests/LibraryIntegrationTests.swift).
L2-04 vérifie avant staging un budget conservateur sur le volume destination : DB+WAL+configs+dictionnaires, tailles stat des sources et absences, capture+ZIP+marge/réserve. Le SHA est vérifié lors de la copie ; un ENOSPC tardif garde le ZIP précédent et retire le staging. Le résultat expose bytes, couverture et durée du préflight. L2-12 indique les
points d’injection effectivement exercés, sans annoncer tous les arrêts possibles.

## L3 — grand historique

**IDs suivis : L3-01–L3-12.** Projections incrémentales, pages et curseurs,
agrégats SQL/présences compactes, recherche Unicode/accents et intégration des
annotations évitent de charger toutes les occurrences dans SwiftUI. La carte
charge au maximum 80 logs du scope ; les exports et agrégats ne sont pas limités
à cette page. Le registre conserve contrôleurs homonymes et drones sans log.

Preuves : [test_library_repository.py](../Tests/test_library_repository.py),
[benchmark_library_repository.py](../Tests/benchmark_library_repository.py),
[WorkspacePreviewTests](../Tests/KataLogAppTests/WorkspacePreviewTests.swift),
[DroneAnnotationsTests](../Tests/KataLogCoreTests/DroneAnnotationsTests.swift),
[FlightMapTests](../Tests/KataLogAppTests/FlightMapTests.swift).
Les migrations synthétiques1–6 ne remplacent pas chaque ancien binaire/bibliothèque
réel. Le registre capture une seule révision de fleet.json par requête, conserve la dernière observationGCS datée/provenancée et inclut les drones autorisés sans log ni numéro. Un changement de capture invalide le curseur. Les états sources proviennent de vérifications writer stockées en SQL : état daté au contrôle, jamais affirmation de disponibilité actuelle. Sans preuve, date=nil/statut=inconnu. Le banc moteur ne mesure pas la RSS UI.

## GCS — collecte

**IDs suivis : GCS-01–GCS-10.** Queue SQLite durable, historique séparé,
inventaires paginés/bornés, autorisation par identité, contexts host/destination,
stop/retry/offline et absence de fallback Téléchargements sont testés. Une queue
hors ligne n’empêche pas d’ajouter un drone autorisé nouvellement visible.
Les helpers ignorant SIGTERM sont arrêtés avec escalade et reap bornés.

Le banc500×100jobs mesure l’enqueue sans réécriture globale : p95 transaction5ms,
heartbeat MainActor23ms sur la passe ciblée. La limite reste deux UUID et une
opérationFTP par UUID. L’arrêt local ne promet pas un arrêtFTP distant ; la
reprise octet et le hash distant ne sont pas inventés.

Preuves : [test_gcs_collect.py](../Tests/test_gcs_collect.py),
[GCSQueueRepositoryTests](../Tests/KataLogCoreTests/GCSQueueRepositoryTests.swift),
[GCSQueuePolicyTests](../Tests/KataLogCoreTests/GCSQueuePolicyTests.swift),
[GCSProcessTests](../Tests/KataLogCoreTests/GCSProcessTests.swift),
[GCSStoreTests](../Tests/KataLogAppTests/GCSStoreTests.swift).
GCS-10 reste une recette physique à deux drones, puis une qualification progressive.

## L4 — UI, scope et rapports

**IDs suivis : L4-01–L4-15.** Scope partagé, Historique paginé, registre global,
familles/occurrences, vues nommées, masquages réversibles et profil sans diagnostic
automatique sont intégrés en preview. Capture SQLite+scope+annotations cohérente,
stream de toutes les pages, progression, annulation et publication atomique
forment le chemin d’export. Un HTML au-delà du budget propose une synthèse et
les données complètes jointes avec manifeste/SHA, sans troncature silencieuse.

Le détail d’export est explicite : paramètres/changes, topics/instances,
événements/dictionnaire, metadata, batterie/GNSS et relevés de courbes disponibles.
Les sections absentes restent absentes. Les options de partage retirent aussi
les champs inconnus, provenance libre, séries sensibles et fingerprints de
révisions ; chaque option possède un test canary portant sur tous les fichiers.
Un rapport interne garde la traçabilité et le SHA exact de l’analyse en cache.

Preuves : [test_library_reports.py](../Tests/test_library_reports.py),
[ReportExportTests](../Tests/KataLogCoreTests/ReportExportTests.swift),
[ReportRendererTests](../Tests/KataLogCoreTests/ReportRendererTests.swift),
[ReportDOMTests](../Tests/KataLogCoreTests/ReportDOMTests.swift),
[test_report_interaction.cjs](../Tests/test_report_interaction.cjs),
[WorkspacePreviewTests](../Tests/KataLogAppTests/WorkspacePreviewTests.swift).
La recette HTML ciblée finale compte 27 tests Swift et 13 Node réussis.
Le rendu lazy a réduit de 77 % le pic WebContent observé : 155,5 MiB après
correctif, contre environ 680 MiB auparavant. Les autres processus et les
mesures de navigation finale restent comptés séparément.
La preview d’export et son diagnostic sont en consolidation. Les captures
offscreen thèmes/petit écran et le DOM WKWebKit ne remplacent pas Safari/Chrome
avec impression, navigation complète clavier ou VoiceOver.

## L5 — provenance et explications

**IDs suivis : L5-01–L5-09.** Événements binaires bruts, ID/args/séquence/instance,
niveaux interne/externe et timestamps restent distincts des messages. Dictionnaire
exact par SHA, compression bornée, refus d’artefact incompatible et état inconnu
préservent le brut. Aucun fallback silencieux vers master n’est utilisé.

Les textes normal/tagged conservent source, tag, timestamp brut, niveau brut et
index d’origine ; deux occurrences identiques ne sont pas fusionnées. Dropouts
et changements de paramètres utilisent le dernier timestamp de data connu par
pyulog, qualification affichée. Un dropout de recording ne prouve pas une panne
radio. Les paramètres gardent valeurs/types décodés/previous ; pyulog ne conserve
pas le type déclaré dans le format ULog, qui n’est donc pas inventé.
Les infos ULog simples/multiples et relevés boot/performance disponibles sont
conservés dans les métadonnées détaillées typées et bornées ; les clés inconnues
gardent leur provenance sans interprétation ajoutée.

Batterie/GNSS conservent champs scalaires, cellules, cycles, serial et instances
réellement présents. Unités/conversions/sentinelles connues sont sourcées ; les
champs constructeur inconnus restent sans unité inventée. Serial batterie,
controllerUUID et numéro de stock sont distincts. Les explications distinguent
source documentée, interprétation et inconnu ; une alerte ne confirme pas un
défaut matériel.

Preuves : [test_px4_events.py](../Tests/test_px4_events.py),
[test_event_dictionary.py](../Tests/test_event_dictionary.py),
[test_event_dictionary_storage.py](../Tests/test_event_dictionary_storage.py),
[test_recorded_details.py](../Tests/test_recorded_details.py),
[EventContractsTests](../Tests/KataLogCoreTests/EventContractsTests.swift),
[AlertKnowledgeTests](../Tests/KataLogCoreTests/AlertKnowledgeTests.swift).
Le diff temporel initial/changes existe. La comparaison entre une révision et la
fiche courante est intégrée côté Core/UI : valeurs UInt64, types, firmware et
présence/absence restent qualifiés ; un vieux cache sans valeurs comparables
n’invente pas de différence. Deux tests de comparaison et deux tests natifs de
révisions exercent ce contrat, y compris source absente. La non-causalité reste
annoncée ; le gate Swift global demeure distinct de ces preuves ciblées.

## L6 — télémétrie et chronologie

**IDs suivis : L6-01–L6-09.** Catalogue selon champs réellement présents,
fenêtre/cache à la demande, extrema/transitions/gaps, recettes batterie/GNSS/EKF
et sélection temporelle commune sont codés. Maximum de 2 048 points **au total par
recette**, pas 2 048 pour chaque courbe. Originaux/valides/rejetés/affichés,
budget et perte sont explicités. Les gaps ne sont pas reliés et les positions
voisines restent qualifiées. Le relevé exporté est une réduction déclarée.

Preuves : [test_telemetry_extractor.py](../Tests/test_telemetry_extractor.py),
[TelemetryReportTests](../Tests/KataLogCoreTests/TelemetryReportTests.swift),
[TimelineSelectionTests](../Tests/KataLogCoreTests/TimelineSelectionTests.swift),
[AppFlightStudyStoreTests](../Tests/KataLogAppTests/AppFlightStudyStoreTests.swift),
[FlightMapTests](../Tests/KataLogAppTests/FlightMapTests.swift).
La présence de champs privés dépend du firmware/topic ; absence n’est pas zéro.
La recette native finale et la matrice RSS/cold/annulation restent séparées des
oracles de réduction et d’unités.

## L7 — mises à jour

**IDs suivis : L7-01–L7-08.** Sparkle, configuration validée, clé publique,
signature EdDSA, ZIP/appcast et coordination avec opérations actives sont intégrés.
Le feed est **désactivé sans configuration HTTPS complète** ; aucun canal public
n’est annoncé. Les clés privées restent hors du dépôt. Les tests refusent
archive/feed altérés et configurations dangereuses.

Preuves : [UpdatePolicyTests](../Tests/KataLogCoreTests/UpdatePolicyTests.swift),
[UpdateStoreTests](../Tests/KataLogAppTests/UpdateStoreTests.swift),
[test_update_feed.py](../Tests/test_update_feed.py),
[test_update_packaging.py](../Tests/test_update_packaging.py),
[test-update-install.py](../tools/test-update-install.py).
Les six recettes exécutent le SDK Sparkle sur deux apps synthétiques jetables :
download/remplacement/relaunch positif, ZIP altéré, feed altéré, asset absent 404
et download tronqué, puis téléchargement sur un volume de test HFS de 128 MiB
plein. Le serveur est local à la recette, en HTTP loopback ; le
canal de production conserve son exigence HTTPS. Bibliothèque,
annotations, vues, destination et jobs inventés restent identiques octet pour
octet. Ces preuves exercent le SDK installé ; elles ne remplacent pas le parcours
GUI entre deux vrais bundles KataLog ni la configuration d’un feed utilisateur.
Les cinq cas d’échec conservent l’ancien bundle ; l’app utilisateur installée
reste inchangée. Aucune écriture Keychain n’est nécessaire à cette recette.
L7-01 attend la décision feed ; L7-06/07 gardent la qualification GUI et la
conservation de la bibliothèque réelle distinctes du banc synthétique. La
recette ENOSPC de téléchargement a produit la chaîne d’erreurs Sparkle 2001 →
Cocoa 640 → POSIX 28. L’ancien bundle et six fichiers de données inventées ont
gardé leurs SHA ; aucune installation ni relance en version 2 n’a été constatée,
et le nettoyage du volume de test a réussi.

Une septième recette est une attestation de transaction après fermeture de
l’hôte : volume HFS+ de 128 MiB avec 1 MiB libre pour un payload de 8 MiB,
hôte sorti avec code 0, ancien bundle version 1 et six fichiers de données
inchangés par SHA. Sa signature stricte et le lancement réel de son Mach-O
chargeant Sparkle ont réussi. Aucun build 2 ni helper résiduel n’a été observé
avant/après nettoyage ; le volume de test a été détaché. Cette preuve qualifie
la conservation et l’app ancienne utilisable, **pas un callback d’erreur ou
une cause ENOSPC observée dans l’installer après fermeture**. La sonde initiale
en timeout reste conservée comme négative. Les six recettes SDK et cette
attestation postquit ne sont pas remplacées par les tests de backup/archivage,
et ne ferment pas la recette GUI de deux vrais bundles KataLog.
L’adoption depuis 0.5.2 commence par une installation manuelle de la première
version intégrant Sparkle.

## L8 — intégration et décisions

**IDs suivis : L8-01–L8-14.** Workflow CI, corpus public/privé distinct, diagnostic
local, inventaire des licences et outils d’hygiène/publication existent ou sont
en consolidation finale. Les tests read-only, les erreurs offline et les
canaries ne publient aucune donnée du corpus privé.

Preuves : [test_publication_guard.py](../Tests/test_publication_guard.py),
[test_distribution_validation.py](../Tests/test_distribution_validation.py),
[LibraryIntegrationTests](../Tests/KataLogAppTests/LibraryIntegrationTests.swift)
et les suites liées par lot ci-dessus. Les 523 tests uniques et le moteur
reconstruit sont validés. Le package local de revue possède ses sept gates
réussis et l’audit final précommit est validé. La tentative de CI distante est
consignée ci-dessous sans exécution de tests ; les 175 tests de l’audit 0.5.2 restent
historiques.

### Tentative historique de CI distante et choix des runners

La tentative de CI de la PR privée, sur le commit `377d8af`, s’est terminée en échec **avant toute
allocation de runner**. La CI hébergée était indisponible : chacun des quatre
jobs possède un nom de runner vide et une liste d’étapes vide. **Aucun test distant,
build ou package n’a été exécuté.** Aucun défaut du code ou du workflow n’a donc
été reproduit par cette tentative, et aucun succès macOS15/27 en CI n’est
revendiqué. L8-01 reste une qualification externe : l’exécution distante doit
être rejouée lorsque la CI hébergée est disponible. Les deux anciennes entrées
de runs ont été sauvegardées localement et retirées avec autorisation du
titulaire avant toute publication. Les annotations associées ne sont plus
accessibles ; aucune étape n’avait été exécutée dans ces runs.

Le workflow de la branche corrigée exige maintenant la visibilité `public`
pour chacun de ses jobs, y compris un déclenchement manuel. Le run de
`7e2c9bc` est **skipped**, avec deux jobs sans runner, étape ni annotation.
Il prouve l’absence d’exécution privée de ce workflow, pas une validation
distante du code. Les runners standard seront utilisés après passage public.

### Critères à fermer séparément

| Critère | Tickets | État |
|---|---|---|
| Préflight du backup et observations GCS/sources du registre | L2-04, L3-10 | Backend et ALL Swift validés ; UI datée en preview |
| Diff interrévisions firmware/paramètres | L5-08 | Core/UI validés dans ALL Swift ; absence/type/firmware qualifiés |
| Preview d’export complète et diagnostic selon scope | L4-07, L8-07 | Preuves ciblées scope/privacy et conflits de révision validées ; UI preview |
| Matrice froide/RSS UI/navigateur et helper embarqué | L0-08, L1-05, L3-12, L6-09, L8-06 | Moteur 8/8 et banc natif final validés ; cache OS non contrôlé |
| Migration legacy | L3-02 | Sorties réelles des sources 0.5.1/0.5.2 validées sans source ULog ; aucune source 0.5.3 disponible |
| Nouveaux écrans, minimum d’espace, focus/clavier/VoiceOver, print navigateurs | L0-10, L4-14/15, L8-03/04 | Preview/recette visuelle et accessibilité |
| macOS15 réel, download quarantiné et remplacement final | L1-02/03, L8-10 | Qualification externe |
| Deux drones physiques, perte connexion/stop/cache/retry/destination | GCS-10, L8-11 | Qualification externe, jamais extrapolée à 500 appareils |
| Deux builds updater en GUI, interruption/remplacement/relaunch | L7-06/07 | Qualification externe et configuration de staging |
| Download/remplacement updater sur volume de test plein | L7-07 | Callback ENOSPC download validé ; attestation postquit de conservation/app utilisable validée, erreur GUI non observée |
| Package local de revue | L8-13 | App preview Developer ID, DMG/ZIP et sept gates validés ; aucun acte de publication |
| Hygiène des sources, historique de base et assets | L8-09 | Audit final précommit validé ; aucune publication |
| CI distante | L8-01 | Tentative observée : CI hébergée indisponible, quatre jobs refusés avant runner, zéro étape ; exécution distante restante |
| Documentation et matrice de preuves | L8-12 | Consolidation logicielle terminée ; tentative CI et absence d’exécution consignées |
| Licence, hébergementfeed, release et visibilité | L7-01, L8-08/14 | GPL-3.0-only choisie et notices intégrées ; feed/release/visibilité distincts, aucun changement public effectué |

## Reproduire les gates autonomes

Depuis un checkout propre et l’environnement de test épinglé :

```sh
python tools/run-python-tests.py --summary /tmp/katalog-python-tests.json
python tools/run-swift-tests.py --summary /tmp/katalog-swift-tests.json --log /tmp/katalog-swift-tests.txt
node --test Tests/test_report_interaction.cjs
python Tests/benchmark_library_repository.py --logs 50000 --messages 100 --drones 500 --repeats 6 --output /tmp/katalog-benchmark.json
```

Le corpus privé peut être fourni via `KATALOG_PRIVATE_FIXTURES` sur un poste
autorisé. Vérifier avant/après SHA, taille et mtime des originaux ; en cas de
provider qui change le ctime lors de la lecture, valider les SHA puis employer
une copie stable locale. La garde de stabilité du parseur n’est pas assouplie.
Les commandes ci-dessus produisent des preuves logicielles ; elles n’exécutent
aucune publication, collecte réelle, migration de l’installation utilisateur
ou certification de vol.

## Relecture du périmètre backend

Le diff existant et les nouveaux modules de stockage, archive, repository et
rapport ont été relus avec leurs contrats et tests. Un défaut P2 a été reproduit :
le refus d’un format de révisions futur intervenait après l’ajout de tables et
le passage en WAL. Le précontrôle a été déplacé avant ces mutations. Un test
writer/reader vérifie désormais SHA de la base, schéma, mode de journal et
absence de WAL/SHM inchangés ; les 185 tests ciblés ont été rejoués ensuite.

Aucun autre finding confirmé n’est resté dans ce périmètre. Cela n’est pas une
preuve d’absence universelle de bug. La revue couvre conservation des sources,
copie opt-in avant analyse, versions et budgets, read-only, publication des
projections, curseurs, partage des nouveaux champs et distinction brut/unités/
interprétation. Le dernier précontrôle futur ne change ni les requêtes ni la
DDL courante ; les bancs SQL et natifs conservés précèdent ce changement ciblé.
