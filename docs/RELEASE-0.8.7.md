# KataLog 0.8.7 — recette de release

Version **0.8.7**, build **26**, livraison du **15 octobre 2026**.
Le package final est signé Developer ID et notarisé. Ses neuf contrôles de
distribution et sa recette native réussissent. La publication des quatre assets,
la CI et l’activation du flux sont suivies séparément ci-dessous.

## Changements

Le catalogue embarqué passe de **4 à 321 fiches**, couvrant messages PX4,
Drotek/show, batterie, éclairage, communications et périphériques marins.
Chaque fiche fournit sens, vérifications, limites, provenance et sources.
Les **209 définitions documentées** et **112 interprétations du texte** sont
identifiées séparément ; un module connu fournit un contexte lorsque la
définition précise manque. Aucun diagnostic causal n’est déduit de la famille
ou du niveau du message. Les rapports HTML affichent aussi ce niveau de preuve.

Les sources upstream sont épinglées et vérifiées ; leur correspondance au
firmware constructeur exact demeure explicitement non attestée. Voir la
[méthode et les références](../research/alerts/README.md). Les extraits de logs
réels, comptages par firmware et preuves opérationnelles restent locaux ;
les tests publics utilisent des messages synthétiques.

Le décodeur XZ autorise **65 Mio** de mémoire pour un dictionnaire LZMA2 de
64 Mio et sa mémoire de gestion. Les plafonds **4 Mio compressés / 16 Mio
extraits**, la vérification SHA-256 et le rejet des flux invalides/concaténés
restent actifs. Une validation locale ciblée a traduit les **17 événements**
d’un dictionnaire embarqué exact, sans erreur ni modification de la bibliothèque.

## Compatibilité et données existantes

macOS **15 minimum**, **Apple Silicon**. Version du parseur **1.4.1**, projection
SQLite **8**, schémas de bibliothèque et d’annotations conservés.
Les nouvelles explications s’appliquent immédiatement aux messages déjà importés,
sans réimport ni téléchargement supplémentaire.

Les détails précédemment enregistrés avec le parseur 1.4.0 sont recalculés à
l’ouverture si leur source locale vérifiée est disponible. Leur ancienne
révision est conservée. Si la source est absente, l’ancien détail demeure
consultable et signalé comme ancien. Les anciens résumés ne sont pas recalculés
automatiquement et aucun réimport global n’est déclenché.

Messages, niveaux, familles personnalisées, groupes, occurrences, identités,
clients, favoris, notes, réglages et ULogs sont préservés.

## Sources et contrôles locaux

Le package qualifié provient du candidat
`1f544cd722d98c67ccf92a75193356e81035b6af`, arbre
`e1fcc2442543ef7a06135551eadb4e36f7f4cc19`. Les mises à jour ultérieures de
documentation et du flux ne modifient pas les archives qualifiées.

- **509 tests Swift** réussis, sans échec ni test ignoré ; **18 tests JavaScript** réussis.
- **556 cas Python publics réussis après reprise isolée** : l’exécution groupée
  initiale a rencontré un timeout de verrou sur un test de packaging ; ce test
  a réussi isolément. Le cas nécessitant le corpus privé n’a pas été exécuté.
  Ce résultat ne présente pas le gate global initial comme entièrement réussi.
- Générateur du catalogue à jour ; les **388 patterns** sont couverts par des
  exemples artificiels publics. La contre-review Foundation indépendante
  reconnaît les 388 exemples, rejette 776 variantes adverses et ne trouve aucun
  chevauchement entre fiches sur ces exemples.
- Les régressions vérifient le renouvellement d’un cache 1.4.0 invalide en détail
  1.4.1 traduit depuis sa source vérifiée, et sa conservation si la source manque.

Les résultats distants figurent dans la
[CI du candidat](https://github.com/mehdi7129/KataLog/actions/runs/38737889282).
Cette recette distingue les contrôles locaux, les jobs distants et les
vérifications après publication.

## Package et recette native

Le DMG et le ZIP final sont notarisés ; les **9/9 contrôles de distribution**
réussissent. Une copie de l’app extraite du DMG est vérifiée fichier par fichier
(**200 fichiers et liens**), puis lancée après éjection du volume dans une
bibliothèque isolée sur **macOS 27.0.1**. Le helper embarqué annonce le parseur
**1.4.1**.

La recette native confirme :

- consultation de **six fiches d’explication**, avec vérifications, limites,
  sources et niveau de preuve ;
- ouverture d’un ancien détail, puis actualisation de la liste : les
  **17 événements** du cache sont désormais traduits et visibles ;
- export natif de **quatre fichiers**, dont HTML et JSON enrichis, pour
  **deux logs et seize messages** ;
- conservation au redémarrage et banc de migration **17/17**, incluant notes,
  favoris, sources et révisions d’analyse. Les **200 fichiers et liens** du
  bundle restent inchangés ; signature, ticket et Gatekeeper sont encore valides.

Les empreintes finales, calculées après notarisation et stapling, sont :

| Fichier | SHA-256 |
| --- | --- |
| `KataLog-0.8.7-macOS-arm64.dmg` | `a1bbad89188589734e75c947e3b3719e5cd972996a08eafe84486773550ff40e` |
| `KataLog-0.8.7-macOS-arm64.zip` | `5ecd83c18d8383e4462c64596c3c1806793f1cd7cfc698c735acfb4a04e4511e` |

Les nouveaux commits contrôlés ne présentent aucun signalement au scan de
secrets. Ces contrôles utilisent une bibliothèque isolée et des fixtures publiques.
Les captures et preuves détaillées restent locales. Aucun nouveau transfert
Aqua réel ni cycle d’installation Sparkle en production n’est qualifié.
Les tests de messages et d’événements ne constituent pas un diagnostic physique.

## Publication et flux stable

Les tags et archives antérieurs restent immuables. La release 0.8.7 comporte quatre assets : DMG, ZIP de mise à jour, archive des sources du tag et
`SHA256SUMS.txt`. Leur téléchargement sans authentification doit
correspondre aux fichiers qualifiés avant la fusion de la PR de publication.

Le flux signé build **26** est préparé depuis le build **25**. Le fichier signé
est conservé octet pour octet ; il référence le ZIP final de **21 414 949 octets**.
L’activation suit la publication et la vérification des archives, puis la fusion
du flux. Après fusion, télécharger sans authentification le
[flux canonique](https://raw.githubusercontent.com/mehdi7129/KataLog/main/updates/stable/appcast.xml),
comparer ses octets au fichier signé et vérifier ses signatures ainsi que celle
du ZIP public avec les outils officiels Sparkle. La préparation locale du flux
ne vaut pas preuve de sa mise en ligne.
