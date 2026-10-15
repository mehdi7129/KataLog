# KataLog 0.8.8 — recette de release

Version **0.8.8**, build **27**, préparée le **15 octobre 2026** depuis la 0.8.7. La qualification signée, la recette native, la publication et le flux stable sont des étapes distinctes. Ce document sera complété avec leurs résultats effectifs avant activation.

## Changements

- **322 fiches d’explication**, avec des textes principaux courts, des vérifications ciblées et les références techniques dans un second volet replié, dans l’app et les rapports.
- **45008 : contrôle du show**, distinct de **45000 : couleur des LED**, avec une preuve primaire constructeur vérifiée indépendamment. Le suffixe `is ok` ne confirme ni succès ni échec et reste signalé comme non décodé dans le sens principal.
- **209 définitions documentées**, **108 sens déduits** et **5 fiches non résolues**. Un code simplement reconnu ne compte pas comme un sens établi. Les codes Torqeedo 50/54 restent inconnus pour cette installation.
- README public recentré sur l’installation, les usages, les données et la contribution ; détails de recherche et qualification conservés dans les documents dédiés.

La [recherche complémentaire](../research/alerts/CLARITY-20261015.md) donne les preuves, leurs versions et les limites de correspondance au firmware constructeur. Les messages, niveaux, groupes et filtres sont conservés.

## Compatibilité

Mac Apple Silicon, macOS **15 minimum**. Parseur **1.4.1** et projection SQLite **8** inchangés par rapport à la 0.8.7. Aucun réimport ni migration de bibliothèque n’est requis pour les nouvelles explications. Les notes, favoris, clients, réglages et ULogs sont conservés.

## Validation du changement fonctionnel

La PR #47 a réussi ses quatre jobs : [CI des explications](https://github.com/mehdi7129/KataLog/actions/runs/38753175822). Sa fusion conserve l’arbre qualifié. Les contrôles ciblés comprennent 35 tests Swift et 18 tests JavaScript, 390 exemples synthétiques et une contre-relecture indépendante.

## Qualification de la distribution

La nouvelle version et son build doivent réussir leur CI, le package Developer ID notarisé, les neuf contrôles de distribution et une recette native de l’app copiée du DMG après éjection. Cette recette utilise une bibliothèque synthétique isolée ; elle ne modifie pas l’app installée ni la bibliothèque active. Les résultats et empreintes finaux seront ajoutés à la publication.

## Confidentialité publique

Les contenus actuels sont contrôlés pour les noms personnels, adresses privées, chemins locaux, secrets et données opérationnelles. Les tests et captures publics utilisent des données synthétiques. Les identifiants techniques stables de l’app, le propriétaire GitHub, la signature Apple et l’historique existant sont conservés. Les nouveaux commits utilisent un nom public et une adresse noreply.

## Publication

La release comporte quatre fichiers : DMG, ZIP applicatif, sources exactes du tag annoté et SHA256SUMS. Le build **27** est préparé depuis le build effectivement servi **26**. La publication des fichiers et leur contrôle anonyme précèdent la fusion du flux signé. Le flux canonique, son URL ZIP, sa taille et les signatures Sparkle doivent être vérifiés après activation. Les tags et archives déjà publiés restent immuables.
