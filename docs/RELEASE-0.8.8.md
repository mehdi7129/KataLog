# KataLog 0.8.8 — recette de release

Version **0.8.8**, build **27**, livraison du **15 octobre 2026** depuis la
0.8.7. Les contrôles du candidat, du package final, de la recette native et
de la publication sont décrits séparément.

## Changements

- **322 fiches d’explication**, avec des textes principaux courts, des vérifications ciblées et les références techniques dans un second volet replié, dans l’app et les rapports.
- **45008 : contrôle du show**, distinct de **45000 : couleur des LED**, avec une preuve primaire constructeur vérifiée indépendamment. Le suffixe `is ok` ne confirme ni succès ni échec et reste signalé comme non décodé dans le sens principal.
- **209 définitions documentées**, **108 sens déduits** et **5 fiches non résolues**. Un code simplement reconnu ne compte pas comme un sens établi. Les codes Torqeedo 50/54 restent inconnus pour cette installation.
- README public recentré sur l’installation, les usages, les données et la contribution ; détails de recherche et qualification conservés dans les documents dédiés.

La [recherche complémentaire](../research/alerts/CLARITY-20261015.md) donne les preuves, leurs versions et les limites de correspondance au firmware constructeur. Les messages, niveaux, groupes et filtres sont conservés.

## Compatibilité

Mac Apple Silicon, macOS **15 minimum**. Parseur **1.4.1** et projection SQLite **8** inchangés par rapport à la 0.8.7. Aucun réimport ni migration de bibliothèque n’est requis pour les nouvelles explications. Les notes, favoris, clients, réglages et ULogs sont conservés.

## Validation du changement fonctionnel

La PR #47 a réussi ses quatre jobs : [CI des explications](https://github.com/mehdi7129/KataLog/actions/runs/38753175822),
avec **511 tests Swift**, **556 tests Python publics** et **18 tests JavaScript**
sur chacun de macOS 15 et 26. Les contrôles ciblés comprennent aussi 35 tests
Swift, 390 exemples synthétiques et une contre-relecture indépendante.

Le candidat de distribution est `b723061e88be9e704e553e427366a13b9ec5689f`,
arbre `a3c006d7cdf8a57f36293870396d010437892ed2`.
Les résultats propres à ce candidat figurent dans sa
[CI de release](https://github.com/mehdi7129/KataLog/actions/runs/38760043324).

## Qualification de la distribution

Le package final est signé Developer ID. L’app et le DMG sont notarisés par
Apple avec le statut **Accepted** ; les tickets sont agrafés et les contrôles
Gatekeeper réussissent. Les **9/9 contrôles de distribution** passent.

Une copie de l’app extraite du DMG est vérifiée fichier par fichier
(**200 fichiers et liens**), puis le volume est éjecté. Le contrôle du moteur
embarqué sur une bibliothèque synthétique retrouve **3 logs, 21 messages et
17 événements traduits**, en conservant notes, favoris, réglages, sources et
révisions d’analyse.

Les empreintes finales après notarisation et stapling sont :

| Fichier | SHA-256 |
| --- | --- |
| `KataLog-0.8.8-macOS-arm64.dmg` | `263069dc2742945f497cf26c385c777bdc2a9aa98d36797bf2220814689bd89b` |
| `KataLog-0.8.8-macOS-arm64.zip` | `bc6840d689b5251dba0c08bffa71e87cb4e54bd6b3c63f18f34cba0f10adec1c` |

## Recette native

L’app copiée du DMG est lancée après éjection avec une bibliothèque
synthétique isolée. Quatre fiches sont contrôlées dans l’interface native :
commande de show **45008**, température de charge Torqeedo **48**, défaut
Torqeedo **50** au sens inconnu et réalignement de secours du cap par GPS.
Le sens principal, l’incertitude et les deux volets repliables sont vérifiés.

L’export depuis l’interface produit **quatre fichiers** pour **3 logs et
21 messages**. Le rapport HTML contient les nouvelles explications ; le JSON
conserve les messages et leur provenance brute, sans y ajouter ces fiches.

Après fermeture et relancement de cette copie isolée, les **3 logs**, le drone,
le favori, les notes du log et du drone, ainsi que l’identification locale sont
retrouvés. La copie de recette est ensuite quittée. L’app installée et la
bibliothèque active restent inchangées.

Ces observations natives complètent le contrôle séparé du moteur embarqué ;
elles ne qualifient ni un nouveau transfert Aqua réel ni une installation
Sparkle en production.

## Confidentialité publique

Les contrôles du package ne signalent aucun chemin utilisateur ni donnée
opérationnelle. Les tests et captures publics utilisent des données synthétiques.
Les identités techniques de signature restent dans les métadonnées Apple de
distribution ; les identifiants stables de l’app, le propriétaire GitHub et
l’historique existant sont conservés. Les commits de préparation de cette
release utilisent un nom public et une adresse noreply.

## Publication

La release comporte quatre fichiers : DMG, ZIP applicatif, sources exactes du tag annoté et SHA256SUMS. Le build **27** est préparé depuis le build effectivement servi **26**. La publication des fichiers et leur contrôle anonyme précèdent la fusion du flux signé. Le flux canonique, son URL ZIP, sa taille et les signatures Sparkle doivent être vérifiés après activation. Les tags et archives déjà publiés restent immuables.
