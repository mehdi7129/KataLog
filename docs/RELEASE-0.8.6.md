# KataLog 0.8.6 — recette de release

Version **0.8.6**, build **25**, publiée le **14 octobre 2026**.
La [release publique](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.6)
propose quatre assets vérifiés par téléchargement anonyme. Le package final
signé et notarisé réussit ses neuf contrôles, sa CI et sa recette native.
Le flux signé build 25 est préparé ; son activation et sa vérification canonique
suivent la fusion de la PR de publication.

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

La recette native a aussi révélé une course préexistante : un clic sur
**Générer le rapport…** juste après un changement de configuration pouvait
utiliser l’aperçu précédent. La génération vérifie maintenant de façon
synchrone que l’aperçu correspond au périmètre et aux options actuels, avant
le choix de destination puis avant l’export. Un aperçu obsolète est rechargé ;
aucun rapport fondé sur cette ancienne configuration n’est produit.

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
commits `eaeb76d` et `438c84b`, intégrés par la
[PR #42](https://github.com/mehdi7129/KataLog/pull/42). La
[PR #43](https://github.com/mehdi7129/KataLog/pull/43) prépare la distribution
et corrige la génération depuis un aperçu obsolète.

Sources finales qualifiées : `602e3fe4b35914275323b98fa4dc670621b9ba6f`.
Arbre : `21d619cf01d1f465209462d76b76f103d0df34ef`.
Le premier candidat `25562ad` reste une étape de préqualification ; son package
et ses observations ne sont pas présentés comme ceux du bundle final.

| Contrôle | État et preuve |
| --- | --- |
| Aperçu obsolète, contrôles ciblés | **27 tests Swift réussis**, aucun échec ni skip ; deux nouvelles régressions changent le périmètre puis l’anonymisation sans attendre le rafraîchissement de l’aperçu |
| CI du candidat final | [Run #38558497627](https://github.com/mehdi7129/KataLog/actions/runs/38558497627) : **4/4 jobs réussis**. Sur chacun de macOS 15 et 26 : **502 tests Swift, 553 Python et 18 JavaScript réussis** ; un test Python du corpus privé absent non exécuté. Les deux packages ARM64 ad hoc passent chacun leurs six catégories de contrôle |
| Confidentialité du candidat final | **Aucun signalement Gitleaks** dans les sources exportées et les nouveaux commits ; les preuves opérationnelles restent privées |
| Archive source | **326 fichiers identiques octet pour octet au tag** ; arbre du merge et du tag identique au candidat qualifié |

## Qualification du package final

| Contrôle | État et preuve |
| --- | --- |
| Version, build et contenu embarqué | **0.8.6 (25)** ; sources finales et arbre identifiés ci-dessus |
| Signature Developer ID, app et helper | Vérifications incluses dans les neuf contrôles réussis du package final |
| Notarisation et tickets, app et DMG | Vérifications réussies sur le package final signé et notarisé |
| Distribution et moteur autonome | **9/9 contrôles réussis** |
| Copie du DMG puis éjection | **200 fichiers et liens identiques** au bundle qualifié ; volume éjecté avant lancement |
| Migration manuelle depuis 0.8.5 | **Réussie sur bibliothèque isolée** : trois logs, six messages, identité et numéro conservés, même client, réglages et documents d’annotations/vues conservés (aucun favori dans la bibliothèque 0.8.5 de départ) ; ULogs sources inchangés |
| Exports de la bibliothèque migrée | Trois logs et six messages identiques entre HTML et JSON ; dix catégories de détails absents concordantes ; tailles et empreintes conformes, aucune troncature |
| Clic rapide après changement du périmètre | **Refus de l’aperçu obsolète observé sur le package final** : après choix de destination, aucun rapport périmé créé ; aperçu complet actualisé ensuite |
| Relancement du package final | Deux ouvertures pour la migration, puis redémarrage de la recette native : favori final, notes, dernière sauvegarde et réglages de collecte conservés |
| Fonctions nouvelles, thèmes clair/sombre | Favori créé et appliqué ; paramètre typé `float` comparé **10 → 12**, inversion **12 → 10** et recherche observées ; notes du log et du drone éditées ; thèmes clair et sombre vérifiés |
| Notes privées/partagées et sauvegarde | **Rejouées sur le package final** : notes présentes dans HTML/JSON privés et sauvegarde, absentes des quatre pièces partagées ; **3 logs, 3 ULogs, aucune source absente**, neuf fichiers vérifiés et SQLite intègre ; compteur de nouveaux logs à zéro |
| Collecte depuis le package final | Découverte, reconnexion, téléchargement individuel puis reconnaissance du cache réussis sur simulateur : **1 fichier, 1 705 279 octets**, SHA-256 conforme ; une demande de copie drone et un téléchargement HTTP, aucune requête interdite enregistrée |
| Intégrité après recette | **200 fichiers et liens inchangés** après fermeture ; signature stricte, ticket et Gatekeeper valides ; recette et simulateur arrêtés, binaire de l’app stable installée inchangé |

La migration utilise successivement les applications 0.8.5 et 0.8.6 avec une
bibliothèque de recette isolée ; elle vérifie la conservation des données et le
remplacement manuel de l’app. Elle ne constitue pas un cycle d’installation
Sparkle. Les exports sont vérifiés statiquement, sans exécution de leur JavaScript.
La recette native a été exécutée sur **macOS 27.0.1**. Le clic immédiat après
activation du partage attend aussi le nouvel aperçu avant de proposer la
destination ; le rapport anonymisé généré ensuite ne contient aucune note privée.

L’essai matériel depuis la copie isolée de préqualification a été bloqué par
la politique réseau locale de macOS avant trafic. Aucun téléchargement Aqua
réel n’est donc qualifié avec le package 0.8.6. La collecte loopback finale
qualifie son propre parcours, sur un drone et un log synthétiques ; elle ne
mesure ni débit radio ni reprise HTTP Range, absente du simulateur.

## Publication et flux stable

La [release publique](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.6)
propose le DMG, le ZIP de mise à jour, l’archive des sources du tag et
`SHA256SUMS.txt`. Le DMG et le ZIP proviennent du même bundle final signé et
notarisé. Les quatre téléchargements anonymes sont identiques aux fichiers
qualifiés ; tailles, SHA-256, digests GitHub et manifeste concordent. Le DMG
placé sous quarantaine conserve ses octets et passe signature stricte, ticket
et Gatekeeper.

Le build **25** est préparé avec `--previous-build 24`, après vérification
anonyme du build **24** effectivement servi. Le flux est signé avec les outils
Sparkle officiels. Son activation passe par la fusion de la PR de publication,
après vérification des archives publiques. Le flux canonique servi doit être
téléchargé et vérifié après cette fusion : la signature du fichier préparé
ne suffit pas à prouver que le build 25 est déjà proposé aux utilisateurs.

| Élément | Référence vérifiée |
| --- | --- |
| Sources qualifiées et arbre | `602e3fe4b35914275323b98fa4dc670621b9ba6f` ; `21d619cf01d1f465209462d76b76f103d0df34ef` |
| Commit du tag `v0.8.6` | `05a2cab4fb9327538cb59ecb1d06709d21a70654` |
| Objet du tag annoté | `865f975587c5d2ef3719a83a014d892674a51f8a` |
| Merge testé par la CI | `d5faaf4a164b4ff3d778d169ae22d38b3a0cac96`, même arbre qualifié |
| Release publique | [14 octobre 2026 — v0.8.6](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.6) |
| Flux stable | Build 25 signé et préparé depuis le build 24 ; activation et vérification canonique après fusion de la PR de publication |

Le tag distant annoté, le merge de la PR #43 et le candidat qualifié ont le
même arbre. Les mises à jour documentaires et du flux ne déplacent ni ce tag
ni les archives qualifiées.

| Asset public 0.8.6 | Octets | SHA-256 vérifié après téléchargement anonyme |
| --- | ---: | --- |
| `KataLog-0.8.6-macOS-arm64.dmg` | 20 978 171 | `1a3cc1ac17b8a6da2f25e7b2403ca60132385fbc977a7c233ed7c8afb8e316dd` |
| `KataLog-0.8.6-macOS-arm64.zip` | 21 193 264 | `845447ff88fc2679dd58287574390c76818da213705bb62ead8f9ef93d366d58` |
| `KataLog-0.8.6-source.zip` | 2 586 395 | `29bdb4fd1397aabbc087f522205c19707182cf306d14729b19ed848f2773cb2b` |
| `SHA256SUMS.txt` | 283 | `dda3e45462eca33571908f80e16b3533cf0ef73807387c44c26d9bb2e2fe5cd5` |

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
