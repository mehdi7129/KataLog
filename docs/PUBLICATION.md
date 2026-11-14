# Publication publique et confidentialité

## État

Le dépôt est **public**. La [release **0.9.0 (build 28)**](https://github.com/mehdi7129/KataLog/releases/tag/v0.9.0)
est publiée le **14 novembre 2026**, depuis
**`f2a86e2649f39cde9972a4bbf3ebeb903056ddf5`**, avec collecte USB direct,
files de téléchargement et distributions natives Apple Silicon/Intel, à partir
de la base **0.8.8 (build 27)**.

La [recette 0.9.0](RELEASE-0.9.0.md) distingue les suites de tests, les packages
CI, les bundles finaux signés, les téléchargements publics et les feeds. Elle
conserve les limites connues acceptées pour cette livraison : **527,74 ms** pour
la première requête dashboard à 50 000 logs et **514,54 ms** pour le planificateur
GCS sur Intel 15, contre des budgets de 500 ms. Les rapports restent en échec.
Le crash Metal du runner Intel 15 est reproduit indépendamment ; le rendu sur
cet hôte n’est pas entièrement qualifié. Aucun matériel USB réel n’a été testé.

La [recette 0.8.8](RELEASE-0.8.8.md) conserve les preuves de la base historique.
Les six assets de 0.9.0 ont été vérifiés après téléchargement public anonyme.
L’activation des feeds signés et leur contrôle canonique après fusion sont suivis
séparément dans les [notes de 0.9.0](https://github.com/mehdi7129/KataLog/releases/tag/v0.9.0).

Les contrôles de confidentialité couvrent le contenu publié et son historique,
pas seulement les fichiers de la branche principale. Les rapports détaillés,
marqueurs privés et preuves opérationnelles restent hors du dépôt.

### Clôture de 0.9.0 au 14 novembre 2026

| Périmètre | Résultat documenté | Limite |
| --- | --- | --- |
| Sources courantes et suites natives | Sur `f2a86e2`, ARM macOS 15/26 et Intel 26 : 527 Swift, 629 Python et 18 JavaScript réussis par hôte | Un test Python dépend d’un corpus privé absent ; ces suites ne qualifient pas à elles seules les archives finales. |
| Intel macOS 15 | Diagnostic exhaustif : 525 PASS, 1 crash Metal reproduit sans code KataLog, 1 assertion de latence à 514,54 ms | Le job et le résultat brut restent en échec ; le rendu de ce runner n’est pas entièrement qualifié. |
| Capacité 50 000 logs / 5 millions de messages | Sept cas SQL sur huit sous 500 ms, identités et RSS 473,984 MiB conformes ; 7 Swift ciblés réussis | Dashboard à 527,74 ms : limite connue, résultat SQL FAIL conservé. |
| Packages CI du candidat courant | Quatre jobs ARM/Intel, macOS 15/26, réussis | Packages CI distincts des distributions Developer ID finales et des téléchargements publics. |
| Apps et DMG finaux issus de `f2a86e2` | Signatures/notarisation vérifiées ; quatre hôtes natifs, 40 contrôles de distribution et 8 cycles USB réussis | Trois fermetures gracieuses ; Intel 15 utilise SIGTERM, sans qualification d’arrêt gracieux. Aucun matériel USB réel testé. |
| Sources et surfaces publiques | Tag annoté exact, 381 fichiers source comparés à Git ; revue bornée des commits, PR, documents et preuves listés ci-dessous | Aucun secret ou contenu opérationnel non classé observé dans ce périmètre ; ce n’est pas une garantie universelle. |
| Publication des six assets | **34 contrôles publics réussis**, après 44 contrôles avant publication | Octets, digests API, manifeste, signatures et tickets contrôlés ; archives antérieures inchangées. |
| Feeds ARM/Intel | XML et ZIP vérifiés avec Sparkle officiel, clé commune et routes propres à chaque architecture | Activation par cette mise à jour ; les observations des URLs canoniques après fusion sont consignées dans les notes de release. |

Les mesures courantes proviennent de la [CI f2](https://github.com/mehdi7129/KataLog/actions/runs/43628563135),
du [diagnostic Intel 15](https://github.com/mehdi7129/KataLog/actions/runs/43628542042)
et du [benchmark complet](https://github.com/mehdi7129/KataLog/actions/runs/43628544742).
Les limites de performance sont détaillées dans la [note de capacité](CAPACITY-2026-11-14.md)
et la recette. Le succès des checks protégés ne remplace pas les autres résultats
échoués : la campagne CI conserve sa conclusion globale `failure`.
La [recette des binaires signés finaux](https://github.com/mehdi7129/KataLog/actions/runs/43636719034)
utilise le harnais `4023555` contre les sources produit `f2a86e2`, sans reconstruire
ni remplacer les quatre archives. Les limites de fermeture et de matériel sont
conservées dans ses reçus.

### Revue bornée des surfaces de `f2a86e2`

La revue couvre les huit commits depuis la base 0.8.8, leurs auteurs et messages,
81 blobs introduits, la PR #50 et les notes de release actualisées, les documents
préparés, dix logs complets et dix archives de preuves des campagnes
`43628563135`, `43628542042` et `43628544742`. Les sept images inspectées montrent
des fixtures de démonstration ou le probe graphique. L’archive source publique
contient uniquement les 381 fichiers attendus ; les auteurs utilisent leurs
identités GitHub noreply.

Aucun secret usuel ni donnée opérationnelle non classée n’a été observé dans ce
périmètre. Les signalements de chemins ont été attribués aux runners hébergés.
Les contrôles de confidentialité des deux apps finales couvrent chacun 200
fichiers et 503 payloads embarqués, sans signalement. Aucun Gitleaks ni blocklist
privée n’a été utilisé dans cette revue ; les dépendances et binaires réutilisent
les reçus de distribution, sans nouveau scan indépendant de chaque octet.

Les correctifs ultérieurs du harnais ont reçu une contre-relecture distincte,
avec garde de publication et auteurs noreply contrôlés. Leurs nouvelles campagnes
de runtime ne sont pas incluses rétroactivement dans la revue des journaux
ci-dessus. Les reçus de notarisation, de runtime et de téléchargement public
établissent leurs contrôles précis, pas une nouvelle revue de toute la surface GitHub.

### Preuves historiques du précédent candidat 0.9.0

Les signatures, notarisation et recettes natives du
[run 43623188624](https://github.com/mehdi7129/KataLog/actions/runs/43623188624)
concernent les quatre archives ZIP/DMG construites depuis **`8287cee`**. Le
harnais était au commit `a209944` et la tête ultérieure d’outillage à `6adb3bd` ;
leurs entrées produit étaient identiques. **Ces preuves ne qualifient pas les
nouveaux binaires issus de `f2a86e2`.**

Sur les quatre hôtes ARM/Intel macOS 15/26, ces anciens bundles avaient passé
la copie depuis le DMG puis son éjection, le lancement natif sans Rosetta,
l’initialisation d’une bibliothèque isolée et son contrôle SQLite, puis la
fermeture gracieuse avec exit 0. Le helper embarqué avait passé les scénarios
USB synthétiques MAVLink 1 et 2, dont pertes, mauvais UID, annulation et libération
du port. Le parcours graphique ARM historique avait vérifié trois demandes
sur deux identités synthétiques, reprise après redémarrage, analyse, déduplication
et sauvegarde. Ces reçus ne revendiquent aucune connexion USB physique.

La revue bornée des surfaces de `8287cee` à `6adb3bd` utilisait le garde existant
et une lecture des changements, métadonnées et rapports disponibles. Elle ne
constituait pas un nouveau scan Gitleaks : aucun binaire disponible ni blocklist
privée n’a été utilisé pour cette revue. La revue courante de `f2a86e2` est
décrite séparément ci-dessus ; aucune couverture historique n’est étendue implicitement.

Les rapports sont conservés hors Git ; seuls leurs résultats bornés et les
références publiques appropriées entrent dans la recette de release. Un succès
de signature, de notarisation ou de tests ne clôt pas à lui seul la revue de
confidentialité.

Les contrôleurs, ULogs et positions utilisés dans les fixtures USB sont
synthétiques. Ni un port simulé ni un runner Intel ne prouvent le fonctionnement
avec le firmware Aqua installé, un câble physique ou un débit matériel.

Les revues datées ci-dessous conservent leur périmètre historique. Leurs comptes,
versions et états de publication ne décrivent pas automatiquement la release 0.9.0.

### Revue de la release du 15 octobre 2026

Le candidat `1f544cd722d98c67ccf92a75193356e81035b6af` fournit le package
0.8.7 signé et notarisé, ses neuf contrôles de distribution et sa recette native.
Le catalogue public contient les fiches et leurs références ; les fixtures
publiques sont artificielles. Le corpus réel, ses comptages et les captures
opérationnelles restent hors du dépôt et des archives sources.

La CI du candidat et la vérification publique des quatre assets sont suivies
dans la [recette 0.8.7](RELEASE-0.8.7.md). Le flux signé build 26 est préparé ;
sa fusion est conditionnée à la publication et à la vérification des archives. Les octets et
signatures du flux canonique seront contrôlés après fusion.

### Revue de la release du 14 octobre 2026

Les **326 fichiers** de l’archive source correspondent au tag, dont l’arbre
est identique au candidat qualifié et au merge testé par la CI. Les scans
Gitleaks des sources exportées et des nouveaux commits ne signalent aucun
secret. Les quatre jobs CI réussissent ; le package Developer ID final passe
ses neuf contrôles et sa recette native sur macOS 27.0.1.
Les quatre assets téléchargés sans authentification sont identiques aux
fichiers qualifiés ; manifeste SHA-256, digests GitHub et tag concordent. Le
DMG public sous quarantaine passe signature, ticket et Gatekeeper. Les preuves
sont consignées dans [RELEASE-0.8.6.md](RELEASE-0.8.6.md). La vérification du
flux canonique après activation reste distincte de sa préparation signée.

Les notes personnelles sont des données locales de bibliothèque. Les sauvegardes
et les exports privés peuvent les contenir ; toutes les pièces des rapports en
mode partage les excluent. Les tests utilisent des notes et identifiants fictifs.
Les bibliothèques, captures et preuves opérationnelles restent hors du dépôt.

### Revue de la release du 10 octobre 2026

La qualification 0.8.5 couvre ses sources, ses quatre assets publiés et ses
signatures. Les archives téléchargées sans authentification correspondent aux
fichiers qualifiés. Le détail et les limites, dont la vérification distincte du
flux réellement servi, restent dans [sa recette](RELEASE-0.8.5.md).

### Revue de la release du 9 octobre 2026

Les sources qualifiées `caff7eb` comprennent 303 fichiers. La revue de
157 commits et 845 blobs des refs disponibles ne confirme aucun secret réel
ni aucune donnée privée non classée. Les auteurs et committers utilisent
leurs identités GitHub noreply.

Le bundle passe ses **9/9 contrôles de distribution** : 186 fichiers et
482 payloads inspectés sans signalement, 19 modules Python source vérifiés
et 22 fichiers natifs ARM64 sans dépendance externe. La signature Developer ID,
la notarisation, le runtime autonome, Sparkle, l’import synthétique et le
layout DMG sont contrôlés. Le périmètre source se limite aux refs disponibles
dans le clone ; ces contrôles ne couvrent pas les refs inaccessibles.

Les logs et annotations CI, 43 fichiers d’artifacts, métadonnées des
PR #35/#34/#6, notes de release, tag et archive source sont examinés sans
signalement non classé. Les digests des artifacts concordent avec l’API GitHub.
Les quatre fichiers publics — DMG, ZIP de mise à jour, archive source et
SHA256SUMS.txt — sont identiques aux fichiers qualifiés ; empreintes du
manifeste et digests GitHub concordent.

Les preuves détaillées restent privées ; aucun log de flotte ni capture de
recette n’est ajouté aux archives publiques.

### Revue de la release du 7 octobre 2026

Le correctif 0.8.2, sa documentation, la PR et la CI ont été contrôlés sans nouveau
signalement non classé. L’archive des sources publiée contient **254 fichiers**,
identiques au tag `v0.8.2`. Les quatre assets et le flux ont été téléchargés sans
authentification ; leurs octets, empreintes et signatures ont été rapprochés
des éléments qualifiés localement. Les preuves détaillées restent privées.

### Revue du 5 octobre 2026

La revue de maintenance documentaire couvre les refs Git annoncées, y compris
celles des pull requests, les commits, blobs, auteurs, messages et tags ; les
descriptions et échanges GitHub ; toutes les releases et leurs assets ; les
runs Actions, annotations, journaux disponibles et inventaires d’artifacts.
Les archives sources ont été comparées fichier par fichier à leurs tags.
Les distributions ont été rapprochées des empreintes de qualification, avec
rehachage des copies disponibles et réutilisation des preuves exactes pour
les anciens packages. Les contrôles combinent marqueurs privés, scanner de
secrets et classification des résultats.

Aucun secret réel ni donnée privée non classée n’a été confirmé dans ce périmètre.
Issues, Discussions, wiki, Pages et Projects du dépôt sont désactivés à cette
date. Les espaces de compte externes au dépôt, notamment les ProjectsV2 à
visibilité indépendante, ne sont pas qualifiés par cette revue.

La documentation courante distingue maintenant la version publiée des anciens
plans et recettes. Cette mise à jour documentaire ne remplace aucun installateur,
tag, archive source ni signature de mise à jour.

### Historique de l’isolation et des premières revues

L'ancien historique, ses tags et sa release sont isolés dans une archive GitHub
**privée distincte**. Ce dépôt repart de sources nettoyées avec un historique
neuf et une identité d'auteur `noreply`, sans ancien tag ni asset.

La publication publique utilise cette base nettoyée et des distributions
reconstruites, signées, notarisées et auditées. Les fichiers utilisateur et les
originaux restent conservés localement ; les rapports détaillés restent privés.

La revue du 30 septembre couvre aussi les surfaces GitHub : historique,
auteurs noreply, branches, PR, runs et annotations. Deux anciennes entrées de
runs ont été sauvegardées en privé puis supprimées avec autorisation explicite ;
leurs check-runs ne sont plus accessibles. Les runs antérieurs à la publication
sont skipped sans runner ni étape. Il faut refaire cette revue avant chaque publication et après
tout nouveau contenu GitHub. L’absence de données dans l’arbre source ne suffit
pas à qualifier les métadonnées, pièces jointes, assets ou logs de CI.

La revue du 1er octobre reprend tous les commits et blobs des refs annoncées,
y compris les refs de pull requests ; auteurs, messages et tags, images et
métadonnées, archives sources et distributions existantes. Elle couvre aussi les
PR/comments/reviews, releases, runs/annotations/artifacts Actions, paramètres
publics et social preview GitHub. Aucun secret réel ni donnée opérationnelle
privée n’a été confirmé dans ce périmètre. Les faux positifs du scanner sont
classés en privé ; les derniers assets et le commit de release sont revérifiés.
Les ProjectsV2 ont une visibilité indépendante ; leur contenu n’est pas qualifié
par cet audit avec les permissions API disponibles.

## Périmètre de la distribution actuelle

Les preuves de **0.9.0** sont consignées dans
[RELEASE-0.9.0.md](RELEASE-0.9.0.md). Elles identifient le commit et les
fichiers exacts, distinguent ARM64 et Intel, et séparent exécution native,
inspection statique croisée, distribution signée/notarisée et téléchargements
publics. Le contrôle des feeds servis après leur activation reste distinct de
leur signature locale et est consigné dans les notes de release.

La vérification des ZIP et DMG publics précède l’activation des feeds signés.
Le flux ARM conserve `updates/stable/appcast.xml` ; Intel utilise
`updates/stable-intel/appcast.xml`. Après activation, contrôler séparément les
hashes, signatures, build et enclosure réellement servis par chaque URL canonique.
Les preuves de [0.8.8](RELEASE-0.8.8.md) et des versions antérieures restent
historiques ; leurs tags et assets ne sont pas remplacés.

Les fonctionnalités clients, favoris et notes n’introduisent aucun compte
distant : noms, attributions et bibliothèques restent locaux. Les fixtures
utilisent des noms et identifiants fictifs. Les rapports en mode partage
excluent noms et identifiants de clients ainsi que les notes personnelles ;
les exports privés peuvent les contenir et restent hors Git.
Les captures d’acceptation et les preuves détaillées ne sont pas ajoutées aux
archives publiques.

## Ce qui entre dans le dépôt public

- Code source, contrats, documentation technique et scripts reproductibles.
- Fixtures entièrement synthétiques, avec identifiants et scénarios fictifs.
- Icônes abstraites et futurs aperçus issus uniquement de données synthétiques.
- Clé **publique** de vérification des mises à jour, versions et appcast public.

Les archives de distribution reconstruites, auditées, signées et notarisées sont
publiées comme **assets de release**, sans ajouter les builds au suivi Git.

## Ce qui reste local ou privé

- ULog, cartes SD, télémétrie, positions et réponses réseau réelles.
- CSV/catalogues de stock, UUID réels, séries et associations de numéros.
- Bibliothèques SQLite, annotations, flotte, jobs et réglages de collecte.
- Rapports, captures, anciennes maquettes et preuves opérationnelles.
- Configurations personnelles, secrets, clés privées et certificats exportés.
- Ancien historique Git et anciennes archives contenant des métadonnées privées.

Le bundle identifier et l'identité publique du certificat Developer ID sont des
métadonnées normales de l'application distribuée. Ils ne sont pas des clés privées
et restent stables pour la continuité des mises à jour. Aucun e-mail personnel
n'est nécessaire dans les commits publics : utiliser l'adresse GitHub `noreply`.

## Contrôle du contenu courant

```sh
python3 tools/check-publication.py --include-untracked
python3 tools/check-publication.py --path /chemin/vers/export-public
```

Le contrôle signale uniquement les chemins relatifs et catégories. Une liste de
marqueurs privés peut être fournie avec `--blocklist /chemin/local/marqueurs.json` ;
ce fichier ne doit jamais être ajouté au dépôt. Le contrôle complète `.gitignore`.
Il ne remplace pas la revue d'historique, des images et des assets GitHub.

Compléter avec un scanner de secrets tel que Gitleaks sur l'export et l'historique.
Vérifier les nouvelles images visuellement ; inspecter les métadonnées PNG/EXIF,
plists et octets des exécutables, pas seulement leur sortie `strings`.
Les chaînes qui suivent un NUL peuvent échapper à certains outils textuels.

La signature, la notarisation et une absence de détection de secrets ne prouvent
pas l'absence universelle de données personnelles. Les rapports détaillés du
contrôle restent dans un stockage local ignoré.

## Stratégie pour l'historique

**Approche réalisée :** conserver l'ancien dépôt en privé et utiliser une base
neuve issue des seuls fichiers approuvés, sans fork, mirror ou ancienne ascendance.
Le remote du checkout historique pointe vers l'archive privée ; celui du projet
courant pointe vers cette nouvelle base. Aucun ancien asset n'est transféré.
Les scripts de contrôle ne changent jamais la visibilité.

Une réécriture de l'existant est une autre option, mais elle exige tous les refs,
tags, anciennes releases et références cachées. Un force push seul peut laisser
des commits accessibles par SHA ou par d'autres références.
[GitHub décrit les limites du nettoyage d'historique](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).

Lors de la création d’une nouvelle base publique, la procédure appliquée est :

1. Vérifier la sauvegarde privée de l'historique et des assets originaux.
2. Exporter seulement la liste de fichiers approuvés, sans `.git` ni données locales.
3. Auditer cet export, les images et les métadonnées d'un futur commit initial.
4. Construire depuis les sources nettoyées avec chemins de compilation neutralisés.
5. Auditer app, DMG et archive d'update ; signer et notariser les nouveaux assets.
6. Préparer la base publique avec auteur public/noreply et seulement les nouveaux assets.
7. Contrôler branches, tags, issues, PR, Actions/artifacts, Pages et releases.
8. Rendre publique cette base validée, puis vérifier en accès anonyme son contenu.

La visibilité rend disponibles davantage de surfaces que le dernier arbre de
fichiers ; voir [GitHub — visibilité](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility).

## Installation utilisateur

La distribution autonome se fait **hors App Store** : télécharger le DMG, l'ouvrir,
glisser KataLog dans Applications, éjecter puis lancer. Le moteur est embarqué.
Un appcast public signé permet les updates Sparkle sans compte GitHub utilisateur
à partir de la release 0.7.0. Les versions 0.6.x nécessitent une première installation
par DMG ; leur flux était désactivé.
Choisir le DMG `arm64` pour Apple Silicon ou `x86_64` pour Intel.
Le minimum de la génération 0.9.0 est macOS 15. Voir la
[recette 0.9.0](RELEASE-0.9.0.md), la [base historique 0.8.8](RELEASE-0.8.8.md)
et la [procédure de release](RELEASING.md).
