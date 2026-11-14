# KataLog 0.9.0 — qualification et limites connues

Version **0.9.0**, build **28**, macOS **15 minimum**, apps natives Apple Silicon et Intel.
La livraison utilise le commit **`f2a86e2649f39cde9972a4bbf3ebeb903056ddf5`**.
Deux budgets de latence de 500 ms restent dépassés ; ils sont acceptés comme
**limites connues de cette livraison**, sans modifier les seuils ni les résultats
en échec. Le rendu Intel macOS 15 conserve une limite de qualification liée au
GPU virtuel du runner.

La [release 0.9.0 est publiée](https://github.com/mehdi7129/KataLog/releases/tag/v0.9.0)
le **14 novembre 2026**. Les apps finales sont signées et notarisées ; les six
assets ont été téléchargés sans authentification et vérifiés. Les XML des deux
feeds sont signés et vérifiés localement ; le contrôle de leurs URLs canoniques
après fusion de l’activation est consigné séparément dans les notes de release.

## Fonctionnalités

- Téléchargement direct des ULog PX4 par USB serial, avec identité matérielle,
  état désarmé récent, contrôle des métadonnées et vérification des octets reçus.
- File USB persistante par contrôleur, ajout de fichiers pendant un transfert,
  pause et reprise explicite après reconnexion ; les fichiers incomplets repartent de zéro.
- Consultation et ajout des logs d’un autre appareil pendant les transferts GCS,
  avec conservation du client destinataire et du dossier de chaque demande.
- Distributions natives `arm64` et `x86_64`, Python embarqué, flux Sparkle distincts.
- README revu et setup Paradev partagé. Aucun serveur de développement ou
  service externe n’est nécessaire au workspace.

Le parseur **1.4.1**, la projection SQLite **8** et l’identité stable de l’app
restent inchangés. Aucun réimport global n’est requis. Les sources, notes,
favoris et attributions existants sont conservés.

## Sources et provenance

Le candidat `f2a86e2` ajoute aux fonctionnalités USB/Intel les correctifs de travail
sur le MainActor pour les grandes files GCS et de requêtes SQLite. La pagination
sélectionne les clés de page avant les résumés complets, tout en conservant les
liens d’identité et noms globaux des contrôleurs concernés. Le registre agrège les
groupes sur un index additionnel ; une bibliothèque ancienne ouverte en lecture
seule sans cet index conserve le chemin SQL historique.

Le benchmark, ses volumes et ses budgets restent inchangés. Les tests de
régression vérifient notamment les identités et noms hors page, les dates
inconnues ou égales, les durées fractionnaires, les mises à jour et suppressions,
et la lecture sans modification d’une ancienne bibliothèque.

Les preuves du précédent candidat `8287cee`, dont la tête documentaire et
outillage était `6adb3bd`, restent historiques. Ses quatre archives signées ne
qualifient pas les nouveaux binaires de `f2a86e2`. Le tag annoté `v0.9.0` pointe
sur `f2a86e2` ; les 381 fichiers de l’archive source publique sont identiques à
son arbre Git. La [PR #50](https://github.com/mehdi7129/KataLog/pull/50) est fusionnée ;
les documents de clôture et l’activation des feeds ne modifient pas les archives publiées.

## Suites natives du candidat publié

| Hôte natif | Swift | Python public | JavaScript | Preuve |
| --- | ---: | ---: | ---: | --- |
| Apple Silicon, macOS 15.8.2 | **527 PASS**, aucun skip | **629 PASS** | **18 PASS** | [CI f2](https://github.com/mehdi7129/KataLog/actions/runs/43628563135) |
| Apple Silicon, macOS 26.7.2 | **527 PASS**, aucun skip | **629 PASS** | **18 PASS** | [CI f2](https://github.com/mehdi7129/KataLog/actions/runs/43628563135) |
| Intel, macOS 26.6.1 | **527 PASS**, aucun skip | **629 PASS** | **18 PASS** | [CI f2](https://github.com/mehdi7129/KataLog/actions/runs/43628563135) |
| Intel, macOS 15.7.9 | **525/527 PASS**, 1 crash Metal, 1 assertion de latence échouée | **629 PASS** | Non exécuté après le crash du job CI | [Diagnostic exhaustif f2](https://github.com/mehdi7129/KataLog/actions/runs/43628542042) |

Chaque suite Python comporte 630 tests : le seul test non exécuté dépend d’un
corpus privé absent. Aucun skip inattendu n’est relevé. Les quatre jobs de
packaging natif réussissent sur ARM et Intel, macOS 15 et 26. Ces packages CI
restent distincts des archives Developer ID finales et des téléchargements publics.
La campagne CI conserve sa conclusion globale **failure** à cause du job Intel 15.

Le diagnostic Intel 15 a atteint les **527 identifiants exactement une fois**,
en 76 exécutions : **525 PASS, un crash et une assertion échouée**. Il ne comporte
aucun skip, timeout, interruption, omission ou retry d’un test atteint. Le rapport
conserve `rawFullSuitePassed: false` et le job reste en échec.

### Réactivité GCS à 50 000 jobs sur Intel 15

Les deux assertions qui échouaient sur le candidat précédent réussissent avec
le même seuil de **500 ms** sur `f2a86e2` :

| Parcours | Heartbeat maximal | Résultat |
| --- | ---: | --- |
| Persistance après arrêt de la file | **135,59 ms** | PASS |
| Progression et sauvegardes, 50 000 jobs en attente | **466,46 ms** | PASS |
| Préparation de 50 000 jobs pour 500 identités | **514,54 ms** | **FAIL**, limite connue |

Le troisième résultat dépasse le budget de **14,54 ms**. C’est une mesure de
réactivité de l’interface pendant la préparation de la file synthétique ; ce
n’est ni un débit réseau ni une qualification de 500 appareils physiques. Ce
résultat applicatif n’est pas attribué au défaut Metal et n’est pas reclassé en PASS.

### Rendu Intel 15 : défaut du runner reproduit

Le crash du premier rendu `AppFlightStudyStoreTests` est reproduit sans code
KataLog par les probes **Canvas et Chart**, tous deux interrompus par SIGABRT ;
le probe Text réussit. Le GPU virtuel déclare une architecture `Unknown`. Les
rapports de crash du probe et de XCTest présentent la même stack
Metal/MTLBinaryArchive/RenderBox et l’assertion décrite dans
[actions/runner-images#15251](https://github.com/actions/runner-images/issues/15251).
Cette preuve permet de classifier ce seul crash comme défaut du runner ; elle
ne valide pas entièrement le rendu Intel 15. Le crash et les rapports bruts sont conservés.

## Capacité SQLite du candidat publié

L’[unique campagne complète f2](https://github.com/mehdi7129/KataLog/actions/runs/43628544742)
utilise **50 000 logs, 5 millions de messages, 500 drones et cinq répétitions**.
Sept cas sur huit respectent le budget de 500 ms ; la première requête du tableau
de bord atteint **527,74 ms** et reste **FAIL**. La première lecture du registre
atteint **202,10 ms**, la RSS maximale **473,984 MiB** pour une limite de 512 MiB.
Les contrôles des totaux et identités, ainsi que les **7 tests Swift ciblés**, réussissent.

Ce dépassement de **27,74 ms** est la seconde limite de latence connue de cette
livraison. Les quatre requêtes suivantes plus rapides ne remplacent pas le critère
initial. Aucun seuil, volume ou warmup n’est modifié, aucune relance jusqu’au succès
n’est utilisée. La [note de capacité](CAPACITY-2026-11-14.md) conserve les cinq
mesures de chaque cas et la comparaison avec les deux échecs précédents. Le cache
OS n’est pas contrôlé et aucune cause précise liée aux I/O n’est démontrée.

## Preuves historiques USB et distribution

Les preuves suivantes concernent les apps construites depuis **`8287cee`**,
avant les correctifs de `f2a86e2` ; elles ne remplacent pas les recettes finales
sur les nouveaux binaires.

La [recette signée historique](https://github.com/mehdi7129/KataLog/actions/runs/43623188624)
a réussi sur quatre hôtes natifs ARM et Intel, macOS 15 et 26, sans Rosetta :
copie depuis le DMG puis éjection, hashes et signatures, tickets et Gatekeeper,
moteur autonome, collecte GCS loopback, USB synthétique MAVLink 1 et 2, bibliothèque
SQLite isolée et fermeture gracieuse de l’app avec exit 0. Ce lancement n’est pas
une interaction visuelle exhaustive.

Le parcours graphique ARM historique depuis le DMG éjecté a vérifié trois demandes
USB sur deux identités synthétiques, ajout pendant transfert, pause, redémarrage
et reprise successive A puis B. Les trois demandes ont été analysées et deux
contenus ULog uniques dédupliqués. Les tailles et SHA locaux concordaient avec
le banc ; la sauvegarde contenait le même état de file après décodage JSON.
L’app et le banc ont ensuite été arrêtés.

Les validations locales de ce candidat historique comptaient **609 tests Python
réussis et un corpus absent**, **524 tests Swift avant les derniers correctifs**,
puis **12 tests ciblés USBStore**, **18 tests JavaScript**, **32 tests de protocole
USB**, **5 scénarios de stress** et **2 scénarios de pseudo-terminal**. Ces groupes
ne s’additionnent pas en une suite unique et ne décrivent pas le candidat courant.

Les [20 recettes historiques du SDK Sparkle](https://github.com/mehdi7129/KataLog/actions/runs/43607919965)
portent sur des fixtures loopback, sur quatre hôtes. Elles ne constituent pas un
cycle de mise à jour HTTPS des nouveaux binaires depuis une app utilisateur installée.

## Vérification des installateurs finaux

Le premier [run signé f2](https://github.com/mehdi7129/KataLog/actions/runs/43634759167)
a qualifié le runtime et l’USB sur ARM 15, Intel 15 et Intel 26. Sur ARM 26,
les deux tentatives ont échoué lors de l’éjection du DMG, avant le lancement
de l’app : `hdiutil: detach failed - No such file or directory`. Ces échecs
sont conservés ; ils ne sont pas comptés comme des succès du produit.
Sur Intel 26, le lancement et SQLite ont réussi, sans crash observé, mais
le harnais a utilisé son fallback SIGTERM après le délai de fermeture :
ce reçu ne qualifie pas un arrêt gracieux.

Le [diagnostic du harnais `99a5344`](https://github.com/mehdi7129/KataLog/actions/runs/43635791131)
a montré que l’image restait attachée alors que son mountpoint avait disparu.
Le harnais `4023555` capture donc le device racine de son propre attachement,
sans dépendre de l’ordre du plist. Il vérifie encore son appartenance à l’image
avant chaque commande et exige ensuite l’absence effective de l’image et du
montage. Les états ambigus, illisibles ou encore attachés restent bloquants.
Les 41 tests ciblés mount/build/distribution, les 8 tests du contrat de release,
la contre-relecture et un montage/éjection réel local passent. Le checkout
produit reste `f2a86e2`, propre et séparé du harnais ; aucun binaire n’est
reconstruit ni changé. La [recette finale](https://github.com/mehdi7129/KataLog/actions/runs/43636719034)
consigne séparément les deux commits et les mêmes SHA-256 d’archives.

Cette recette finale réussit sur **quatre hôtes natifs**, avec **40 contrôles
de distribution** et **8 cycles USB MAVLink 1/2**. Les apps copiées depuis le
DMG sont exécutées après éjection ; le moteur embarqué fonctionne avec un
Python externe rendu indisponible, et la bibliothèque isolée passe son contrôle
SQLite. Les quatre digests d’artifacts et les quatre hashes ZIP/DMG concordent.
ARM 15, ARM 26 et Intel 26 ferment l’app avec exit 0. Sur Intel 15, le harnais
utilise son fallback SIGTERM, exit −15, sans crash observé : le démarrage est
qualifié, mais ce reçu ne prouve pas un arrêt gracieux.

## Clôture de distribution et publication

| Étape pour les binaires issus de `f2a86e2` | Résultat |
| --- | --- |
| Apps ARM64 et Intel : Developer ID, notarisation, tickets et Gatekeeper | **PASS**, apps et DMG acceptés par Apple ; audit statique indépendant sur chaque architecture. |
| DMG/ZIP finaux : provenance, hashes, runtime autonome et USB synthétique | **PASS sur quatre hôtes**, avec la limite de fermeture Intel 15 décrite ci-dessus. |
| Tag, archive source comparée à l’arbre Git, manifeste SHA-256 | **PASS**, tag exact `f2a86e2`, 381 fichiers source, cinq archives couvertes. |
| Téléchargement anonyme des six assets et concordance des octets | **PASS**, 34 contrôles publics ; signatures ZIP/DMG/app, tickets et Gatekeeper également vérifiés. |
| Feed ARM et feed Intel : clé, signature XML/ZIP, version/build, longueur et URL | **PASS localement**, outil officiel Sparkle, build 28, routes et archives propres à chaque architecture. |
| Octets servis par les deux URLs canoniques | Contrôle distinct après fusion de l’activation ; résultat consigné dans les [notes de la release](https://github.com/mehdi7129/KataLog/releases/tag/v0.9.0). |

L’audit avant publication a réussi **44 contrôles sur 44**. Après publication,
les six fichiers téléchargés sans credentials correspondent aux octets qualifiés,
aux digests API et au manifeste SHA-256. Les empreintes ci-dessous identifient ces
archives publiques signées et staplées.

Cette mise à jour documentaire accompagne l’activation des deux XML signés dans
`main`. Elle ne constitue pas à elle seule une observation de leurs URLs canoniques :
les octets, signatures, build et enclosures servis sont contrôlés après fusion,
puis consignés dans les notes de release. Les feeds ARM et Intel restent séparés ;
les tags et assets antérieurs ne sont pas remplacés.

| Archive finale | SHA-256 |
| --- | --- |
| `KataLog-0.9.0-macOS-arm64.dmg` | `f39536a20c55425cad7c0cfd3fd50f0b99bc583e1777f75ad9ae0eeb1a03eeda` |
| `KataLog-0.9.0-macOS-arm64.zip` | `9f8184afea9c7dd082aeafc4e6d85a37a985e5ae295a28655ea70502b9ff6944` |
| `KataLog-0.9.0-macOS-x86_64.dmg` | `f651b6c68f5fb71d720d55d6589e578bf64f9a9fe0e7f52d88f010b7bb05abca` |
| `KataLog-0.9.0-macOS-x86_64.zip` | `9dfd1fc125fbcb53b3d53b3e146aaf74e70add7570117fc39caf7c1c4988d737` |
| `KataLog-0.9.0-source.zip` | `7e073f70ef92cfe7e35488a6a1a5e34a874836218b9fa943033245935c27170a` |

## Limites matérielles

Aucun drone ou AquaDrone physique, câble USB réel ou réseau de flotte n’a été
utilisé. Le firmware installé doit exposer le service de logs MAVLink sur son
port USB. Le câble, les pilotes, la carte SD et le débit réel restent à confirmer.
L’USB élimine la dépendance au réseau ; aucun gain de vitesse matériel n’est
annoncé sans mesure. Le SHA-256 est calculé localement : le service MAVLink
utilisé ne fournit pas d’empreinte distante. Les originaux restent sur la carte SD.

[Plan et double vérification](PLAN-USB-INTEL-RELEASE.md) ·
[Guide USB](USB-COLLECTION.md) · [Procédure de release](RELEASING.md).
