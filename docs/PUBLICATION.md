# Préparer KataLog pour une publication publique

## État

L'ancien historique, ses tags et sa release sont isolés dans une archive GitHub
**privée distincte**. Ce dépôt repart de sources nettoyées avec un historique
neuf et une identité d'auteur `noreply`, sans ancien tag ni asset.

La visibilité reste privée pendant la préparation de la distribution publique.
L'app et ses futures archives doivent être reconstruites et auditées avant livraison.
Les fichiers utilisateur et les originaux restent conservés localement.

La revue du 30 septembre couvre aussi les surfaces GitHub : historique,
auteurs noreply, branches, PR, runs et annotations. Deux anciennes entrées de
runs ont été sauvegardées en privé puis supprimées avec autorisation explicite ;
leurs check-runs ne sont plus accessibles. Le dernier run est skipped sans
runner ni étape. Il faut refaire cette revue avant le passage public et après
tout nouveau contenu GitHub. L’absence de données dans l’arbre source ne suffit
pas à qualifier les métadonnées, pièces jointes, assets ou logs de CI.

## Ce qui entre dans le dépôt public

- Code source, contrats, documentation technique et scripts reproductibles.
- Fixtures entièrement synthétiques, avec identifiants et scénarios fictifs.
- Icônes abstraites et futurs aperçus issus uniquement de données synthétiques.
- Clé **publique** de vérification des mises à jour, versions et appcast public.
- Archives de distribution reconstruites, auditées, signées et notarisées.

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

Avant publication :

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

## Installation utilisateur cible

La distribution autonome 0.6.0 se font **hors App Store** : télécharger le DMG, l'ouvrir,
glisser KataLog dans Applications, éjecter puis lancer. Le moteur est embarqué.
Un futur appcast public signé permettra les updates Sparkle sans compte GitHub utilisateur ;
ce flux reste désactivé dans la release 0.6.0.
Voir le [plan 0.6.0](PLAN-0.6.0.md) et la [procédure de release](RELEASING.md).
