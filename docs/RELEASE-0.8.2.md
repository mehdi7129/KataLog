# KataLog 0.8.2 — recette de release

Version **0.8.2**, build **21**, publiée le **7 octobre 2026**.
État : **release stable publiée ; téléchargements et flux signé vérifiés**.

## Corrections

- **Historique accessible avec de nombreux dossiers sources** : les métadonnées
  des sources et les statistiques d’import entrent dans le budget de réponse
  avant d’ajouter les logs à la page. Le nombre de logs par page s’adapte sans
  augmenter la limite de 4 Mio, retirer de données ou changer les totaux.
- **Clients chargés indépendamment de l’historique** : une erreur de lecture
  des logs ne masque plus la liste des clients. Un échec de lecture clients
  conserve le dernier résultat valide et permet de réessayer explicitement.
- **Maintenance et restauration coordonnées** : les lectures clients sont
  arrêtées avant une modification de la bibliothèque ; elles reprennent après
  restauration et préparation de l’index. Un lecteur annulé ne peut pas publier
  un ancien résultat à la place du contenu actuel.

Le problème corrigé affectait la consultation. La correction ne réinitialise
pas la bibliothèque et ne recrée pas les clients.

## Installation et conservation des données

Mac Apple Silicon, macOS 15 minimum. Le package garde le nom **KataLog.app** et
le moteur Python embarqué. Depuis 0.8.1, le parseur **1.4.0** et la projection
SQLite **8** ne changent pas : aucune nouvelle migration n’est nécessaire.

Les analyses, identités, clients, attributions, dossiers et réglages restent
conservés. Aucun réimport ni nouveau téléchargement GCS n’est requis. La
bibliothèque de **KataLog Preview** reste indépendante. Pour les migrations
depuis des versions antérieures et les modalités de mise à jour, voir
[UPDATING.md](UPDATING.md).

Le DMG signé et notarisé est disponible dans la
[release 0.8.2](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.2).
Les versions stables à partir de 0.7.0 peuvent installer la mise à jour depuis
**Réglages → Mises à jour → Rechercher une mise à jour**.

## Qualification obtenue

| Contrôle | Résultat |
| --- | --- |
| Suite Swift locale | 356 tests réussis |
| Suite Python locale | 383 tests réussis ; un test de corpus privé externe non exécuté |
| Interactions JavaScript des rapports | 18 tests réussis |
| CI sur `b433d2a` | [Exécution 37676552243](https://github.com/mehdi7129/KataLog/actions/runs/37676552243) réussie : tests macOS 15 et 26, packages ARM64 macOS 15 et 27 |
| Pagination synthétique | Respect du budget, pages complètes sans perte ni doublon, ordre, filtres clients, trajectoires et totaux conservés ; réponse vide et ligne trop volumineuse vérifiées |
| Chargement clients | Échec d’historique, nouvel essai, cache de navigation, annulation, restauration et création d’une bibliothèque testés |
| Moteur embarqué | Relecture complète d’une copie de bibliothèque et contrôle de son intégrité |
| App Developer ID | Signature, notarisation et tickets vérifiés |
| Distribution finale | Neuf contrôles réussis sur l’app copiée depuis le DMG, après éjection : metadata, confidentialité, runtime autonome, Sparkle, signatures et notarisation app/DMG |
| App installée sur macOS 27 | Démarrage et redémarrage, choix du client, historique paginé, alertes, carte et navigation vérifiés |
| Conservation des données | Comparaison des analyses, clients, attributions, fichiers et sources avant et après : inchangés |

Les scénarios de non-régression utilisent des données synthétiques. Les copies
de bibliothèques, captures, résultats et rapports détaillés de recette restent
hors du dépôt et des archives publiques.

## Qualification de la publication

| Contrôle | État |
| --- | --- |
| DMG final signé et notarisé | Developer ID, notarisation Apple acceptée, ticket et Gatekeeper vérifiés |
| Copie depuis le DMG et contrôle après éjection | Copie, éjection puis lancement natif réussis sur macOS 27 ; client et bibliothèque accessibles, données inchangées |
| Confidentialité des sources, PR et CI | Aucun nouveau signalement non classé ; archive source de 254 fichiers identique au tag |
| Concordance des distributions | 194 entrées identiques entre le ZIP, le DMG et l’app installée |
| Tag `v0.8.2`, archive des sources correspondantes et SHA-256 | Tag annoté sur `1c15e0c`, sources correspondantes et empreintes publiées |
| Publication et téléchargements anonymes | Quatre assets téléchargés sans authentification ; SHA-256 locaux, téléchargés et déclarés par GitHub concordants |
| DMG public téléchargé avec quarantaine | Gatekeeper et ticket Apple validés |
| Flux stable signé, version 0.8.2 build 21 | Publié après les assets, octets HTTPS publics identiques ; signatures du flux et du ZIP vérifiées ; archive de 20 690 181 octets |

## Limites

- Les suites et le package CI ne remplacent pas une recette physique complète
  sur macOS 15. Le parcours natif local a été exécuté sur macOS 27.
- Ce correctif ne revendique aucun nouvel essai radio GCS, débit de collecte
  réel ou essai sur une flotte physique plus importante.
- La recette de l’app installée ne prouve pas à elle seule un cycle de mise à jour
  Sparkle réel de 0.8.1 vers 0.8.2 ; signatures et publication sont contrôlées
  séparément.
- Une seule entrée trop volumineuse reste refusée explicitement plutôt que
  tronquée. La pagination corrige le dépassement dû à l’enveloppe des réponses.

## Traçabilité

Le correctif applicatif, ses tests et les versions du package sont dans le commit
`b433d2a`, contrôlé par la CI ci-dessus. Les mises à jour de documentation suivent
la qualification sans modifier le code applicatif. La PR #5 est fusionnée sous
`a7e6f9f` ; le tag annoté `v0.8.2` cible `1c15e0c`, après les compléments
documentaires. Le flux stable est publié ensuite dans `6f9d0a9`.

Les archives et signatures publiées restent immuables. Cette mise à jour du
compte rendu ne modifie pas les sources du tag ni les installateurs qualifiés.

## Empreintes des archives publiques

| Archive | SHA-256 |
| --- | --- |
| `KataLog-0.8.2-macOS-arm64.dmg` | `80b30ecd83c1f3a0906c166fd3bd2633bd5167dd6db6771da091d428259fd2ba` |
| `KataLog-0.8.2-macOS-arm64.zip` | `44743a17ef493598a90447281f116c31b6721da638ce8e1834843df9c7f4b4e7` |
| `KataLog-0.8.2-source.zip` | `971183660a7d2651cb2f4236e6b684324c6e589b7360af12ba9909ba7b35d569` |
