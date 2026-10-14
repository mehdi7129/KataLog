# KataLog 0.8.6 — recette de release

Version **0.8.6**, build **25**, en cours de qualification. La version publique
reste 0.8.5 tant que les archives 0.8.6 et le flux ne sont pas publiés et vérifiés.
Ce document distingue les preuves des sources, du package final et de sa
publication. Un résultat de 0.8.5 ne qualifie pas une archive 0.8.6.

## Nouveautés

Les six améliorations sont intégrées par la
[PR #42](https://github.com/mehdi7129/KataLog/pull/42) :

- **Filtres favoris** : enregistrer, appliquer ou supprimer les filtres courants,
  en conservant le client choisi et en signalant un client devenu indisponible.
- **Comparer deux logs** : sélectionner exactement deux logs du même contrôleur
  dans l’historique pour comparer firmware et valeurs finales des paramètres
  typés, rechercher un paramètre et inverser A/B.
- **Notes personnelles** : ajouter une note datée au log ou au drone, avec
  protection contre l’écrasement d’une modification concurrente. Les notes sont
  sauvegardées, incluses dans les exports privés et retirées des rapports partagés.
- **Espace disque** : vérifier le volume de destination avant le réseau, puis
  avant la copie HTTP, en tenant compte du reste à écrire et des transferts actifs.
- **Dernière sauvegarde vérifiée** : afficher sa date, sa couverture et les
  nouveaux logs depuis celle-ci ; enregistrer aussi l’archive effectivement restaurée.
- **Couverture des exports** : fournir la même indication des détails disponibles
  ou absents dans le HTML, le JSON et le manifeste, pour un rapport ou une fiche.

Le [guide des parcours](WORKFLOW-IMPROVEMENTS.md) précise l’utilisation.
Cette release reprend la collecte de 0.8.5, dont le fonctionnement Aqua a été
confirmé après les mises à jour des firmwares GCS et drone. Les prototypes GCS
restent distincts des nouveautés de cette release.

## Compatibilité et conservation

macOS **15 minimum**, **Apple Silicon**. L’identité stable de l’app est conservée.
Depuis 0.8.5, le parseur **1.4.0** et la projection SQLite **8** restent inchangés ;
aucun réimport n’est requis. Analyses, clients, attributions, identités, dossiers
et réglages restent conservés. Les notes ajoutent des champs facultatifs au
format d’annotations existant. Les ULogs sources ne sont pas modifiés.

Le suivi des sauvegardes commence avec cette version. Les anciennes archives
restent restaurables. Une erreur d’enregistrement du suivi n’annule pas une
archive déjà vérifiée.

## Sources et contrôles logiciels

Les fonctionnalités et le correctif des exports individuels proviennent des
commits `eaeb76d` et `438c84b`, intégrés par la PR #42. Les résultats de CI de
cette PR restent attachés à ces sources. Le candidat de distribution ajoute les
métadonnées de version et les documents de release ; sa référence et ses
contrôles propres sont à renseigner ci-dessous.

| Contrôle | État et preuve |
| --- | --- |
| Sources et arbre du candidat | À compléter avec le commit exact et son arbre avant construction |
| Suites Swift, Python et JavaScript | Résultats des fonctionnalités dans la PR #42 ; contrôle du candidat à consigner |
| CI du candidat et packages ad hoc | À compléter avec l’URL du run et les résultats |
| Confidentialité des sources et métadonnées | À compléter avec le périmètre et les résultats des scans |
| Archive source | À comparer fichier par fichier avec le tag final |

## Qualification du package final

| Contrôle | État et preuve |
| --- | --- |
| Version, build et contenu embarqué | À vérifier sur le bundle final 0.8.6 (25) |
| Signature Developer ID, app et helper | À vérifier sur les fichiers distribués |
| Notarisation et tickets, app et DMG | À compléter avec les statuts Apple et validations des tickets |
| Distribution et moteur autonome | À compléter avec le rapport du package final |
| Copie du DMG puis éjection et lancement | À vérifier sans modifier l’app de production |
| Fonctions nouvelles, thèmes clair/sombre | À consigner depuis la copie du package, avec données isolées |
| Export privé/partagé et détails absents | À comparer dans les fichiers produits par cette copie |
| Conservation depuis 0.8.5 | À consigner avec la méthode de mise à jour et les données comparées |
| Collecte depuis le package | À consigner en distinguant simulateur et matériel réel |
| Redémarrage et intégrité après recette | À vérifier sur la même copie, sans nouvelle signature |

## Publication et flux stable

La publication doit fournir quatre assets : le DMG, le ZIP de mise à jour,
l’archive des sources du tag et `SHA256SUMS.txt`. Le DMG et le ZIP doivent
provenir du même bundle final signé et notarisé.

Préparer le build **25** depuis le dernier build stable réellement servi,
attendu **24**. Publier les archives avant d’activer le flux signé. Après
publication, télécharger les quatre assets sans authentification et comparer
leurs octets, tailles et empreintes aux fichiers qualifiés. Vérifier le DMG
sous quarantaine et les signatures Sparkle du ZIP et du flux réellement servi.

| Élément | Référence vérifiée |
| --- | --- |
| Sources qualifiées et arbre | À compléter |
| Commit et objet du tag `v0.8.6` | À compléter après création |
| Release publique | À compléter après publication |
| Flux stable effectivement servi | À compléter après activation et vérification anonyme |

| Asset 0.8.6 | Octets | SHA-256 après téléchargement anonyme |
| --- | ---: | --- |
| `KataLog-0.8.6-macOS-arm64.dmg` | À compléter | À compléter |
| `KataLog-0.8.6-macOS-arm64.zip` | À compléter | À compléter |
| `KataLog-0.8.6-source.zip` | À compléter | À compléter |
| `SHA256SUMS.txt` | À compléter | À compléter |

## Limites de la qualification

- La comparaison porte sur firmware et paramètres de deux logs d’un même
  contrôleur ; elle ne superpose pas les courbes et n’établit pas une cause de panne.
- Le contrôle d’espace prend une marge de 16 Mio et le budget des autres
  transferts actifs. Il peut surestimer ce budget sur plusieurs volumes et ne
  réserve pas l’espace contre les écritures d’autres applications.
- Le suivi de sauvegarde est historique : il ne vérifie pas que l’archive est
  encore présente. Son compteur porte sur les nouveaux logs, sans mesurer les
  modifications de notes ou de réglages.
- Une section d’export peut être disponible pour certains logs et absente pour
  d’autres. Le JSON d’une fiche ne contient pas toutes les séries brutes ULog.
- Les fixtures et transferts loopback ne qualifient pas un réseau radio ou une
  flotte physique. Un test Aqua réussi sur 0.8.5 ne prouve pas un transfert sur
  le package 0.8.6. La reprise GCS → Mac dépend du support HTTP Range ; le trajet
  Drone → GCS peut devoir repartir du début.
- Les tests unitaires et les signatures de fichiers ne prouvent pas un cycle
  réel d’installation Sparkle. La méthode et l’OS d’un essai de mise à jour
  doivent être consignés ; un essai local ne vaut pas recette sur tous les macOS.

Les procédures sont dans [RELEASING.md](RELEASING.md) et
[UPDATING.md](UPDATING.md). Les logs, bibliothèques, captures et preuves contenant
des données opérationnelles restent hors du dépôt public.
