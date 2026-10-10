# KataLog 0.8.5 — recette de release

Version **0.8.5**, build **24**, publiée le **10 octobre 2026**.
La [release stable](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.5)
propose quatre assets vérifiés par téléchargement anonyme. CI, distribution
signée et notarisée, et recette native requise sont validées, avec
l’observation de métadonnées d’export décrite ci-dessous.

## Correction et fonctions reprises

Un clic sur « Connecter » immédiatement après « Déconnecter » pouvait être ignoré
pendant la fermeture de l’ancienne session de découverte. Cette course existait
avant 0.8.4 ; un test de cache l’a révélée dans la CI de publication de 0.8.4.
La reconnexion demandée est désormais conservée jusqu’à la fin de cette fermeture.
Les clics répétés sont regroupés ; Annuler, l’arrêt et le changement d’hôte,
même suivi d’un retour à l’hôte initial, invalident la demande. Une nouvelle
connexion explicite reste possible après annulation.

La terminaison attend la découverte avant de confirmer sa fin. Restauration et
réinitialisation attendent aussi l’ancienne découverte, bloquent les nouvelles
connexions pendant cette attente et invalident l’auto-reconnexion avant de poursuivre.

Cette version reprend les améliorations de collecte introduites en 0.8.4 :

- téléchargement d’un log précis, avec priorité sur les fichiers en attente ;
- progression conservée pendant les recalculs et débit affiché par trajet ;
- parallélisme de 1 à 4 drones, 2 par défaut et un seul fichier par drone ;
- réessais réseau des fichiers et inventaires de collecte sans limite par
  défaut, ou 3/10 tentatives au total ; erreurs permanentes explicites ;
- reprise HTTP quand le serveur la permet, avec contrôle du préfixe et de son
  empreinte, et maintien éveillé pendant l’activité et l’attente du réseau.

## Compatibilité et limites

macOS 15 minimum, Apple Silicon. Identité de l’app et bibliothèques existantes
conservées ; parseur **1.4.0** et projection SQLite **8** inchangés depuis
0.8.3/0.8.4. Aucun réimport n’est requis. Les clients, attributions, identités,
analyses et dossiers existants sont conservés.

La reprise au bon octet **GCS → Mac** exige un ETag fort et une réponse HTTP
Range cohérente. Si le serveur ne permet pas cette reprise ou si le staging a
changé, une nouvelle copie peut être nécessaire. Le protocole utilisé ne propose
pas d’offset **Drone → GCS** : ce trajet peut devoir repartir du début.

La lecture manuelle « Voir les logs » hors collecte garde trois essais. Après
fermeture de l’app, relancer les inventaires incomplets avec « Tout collecter ».
Les copies HTTP partielles valides restent récupérables. Le maintien éveillé
n’empêche ni la fermeture du capot ni une mise en veille explicite.

Les contrôles logiciels utilisent des fixtures synthétiques et loopback.
Aucune nouvelle qualification radio ou flotte physique n’est revendiquée.
Une recette native locale ne vaut pas recette physique sur tous les macOS pris
en charge, ni cycle d’installation Sparkle dans l’app de production.

Une limite préexistante des exports résumés est confirmée sur les exports
natifs de la copie du DMG **0.8.5** : `unavailableSections` vaut `[]` dans le
manifeste JSON alors que le HTML énumère dix catégories de détails non chargés.
Les trois logs, leurs six messages et l’attribution au drone **085** concordent
entre les fichiers exportés ; tailles et SHA-256 des trois assets et des trois
sources sont conformes. Le périmètre est complet, sans troncature, avec une
couverture résumée et les détails en cache exclus. Aucune perte de données
exportées n’a été observée. L’alignement de cette métadonnée reste à corriger.
Ce constat provient de la validation 0.8.5 ; les preuves 0.8.4 restent distinctes.

## Validation des sources et du package

Sources qualifiées : `40a6463fe2d9e38ceb231249a230ff32fd432a3a`,
[PR #39](https://github.com/mehdi7129/KataLog/pull/39).
Arbre du commit : `71e96d24a632c1e46815e9b6b90269d1c0b24dd9`.
Les trois fichiers Swift concernés concordent avec les fichiers du dernier
run local ciblé. Les preuves plus anciennes restent associées à leur propre
état des sources ; elles ne qualifient pas à elles seules une archive 0.8.5.

| Contrôle | Résultat |
| --- | --- |
| Reproduction avant correction | Deux tests en échec, cinq assertions : clic immédiat perdu et terminaison retournant avant libération du reader contrôlé |
| Premier run ciblé après correction | **10/10 tests Swift réussis**, aucun échec ni skip |
| Suite GCS locale | **176/176 tests réussis**, aucun échec ni skip, avant le dernier déplacement de l’invalidation de l’auto-reconnexion dans restore/reset |
| Dernier run ciblé, code Swift exact du candidat | **22/22 tests stockage, reconnexion et terminaison réussis**, aucun échec ni skip, après ce dernier ajustement |
| [CI des sources qualifiées](https://github.com/mehdi7129/KataLog/actions/runs/38080817609) | **4/4 jobs réussis** : sur chacun des deux OS, macOS 15 et macOS 26, **476 tests Swift, 532 tests Python et 18 tests Node réussis** ; 533 tests Python découverts, un seul skip attendu du corpus privé absent. Les deux packages ARM64, macOS 15 et Xcode 27, passent chacun leurs **six catégories de contrôle** |
| Contrôle des sources | **316 fichiers** de l’archive source correspondent octet pour octet au tag publié, dont l’arbre est identique aux sources qualifiées ; scan Gitleaks de l’export et du nouveau commit : **aucun signalement** |
| Distribution Developer ID finale | **9/9 contrôles réussis** sur 0.8.5/build 24 : métadonnées, confidentialité, runtime natif autonome, infrastructure de mise à jour signée, signature stricte, import synthétique, notarisation et Gatekeeper de l’app et du DMG, intégrité et présentation du DMG. App et DMG acceptés par Apple |
| Copie depuis le DMG puis éjection | Copie puis éjection avant lancement vérifiées ; **199 fichiers et liens** concordent avec le bundle qualifié, sans nouvelle signature de la copie |
| Exports natifs de la copie 0.8.5 | **Contrôles de contenu réussis, avec l’observation de métadonnées ci-dessus** : trois logs, six messages, un drone numéroté 085 ; identifiants et contenus des messages HTML/JSON concordants, tailles et empreintes des trois assets et des trois sources conformes, sources inchangées |
| Recette native de cette copie | **Réussie avec l’observation de métadonnées d’export** : version 0.8.5 (24), import de trois logs/un drone sans erreur, numéro **085** conservé avec son zéro initial, carte avec trois repères et groupe ouvrant la liste correspondante, collecte observée en thèmes clair et sombre |
| Reconnexion et téléchargement individuels depuis l’UI | Deux cycles Déconnecter/Connecter réussis, inventaire accessible ensuite. Un log synthétique téléchargé par son bouton individuel : **1/1 fichier vérifié**, **1 705 279 octets**, SHA-256 `2ca9a904640f207eb0e7c8c13112efa7401adf864fd3e84e8c57f87fa131512b` conforme au serveur. Après rafraîchissement, copie reconnue et bouton de téléchargement absent ; une seule requête HTTP |
| Redémarrage | Trois logs, un drone **085**, source active et accessible, thème sombre, concurrence **4**, limite de tentatives **10**, destination et résultat **1/1** conservés. Hôte vidé en fin de recette, sans auto-reconnexion |
| Intégrité après fermeture de la recette | Les **199 éléments** restent identiques ; signature stricte, ticket et Gatekeeper valides, sources synthétiques inchangées. App et simulateur de recette fermés ; bibliothèque et réglages isolés, app de production non lancée |

Les packages CI utilisent une signature ad hoc : leurs six catégories couvrent
les métadonnées, la confidentialité, le runtime natif autonome,
l’infrastructure de mise à jour signée, la signature stricte et l’import
synthétique. La notarisation et la distribution Developer ID sont vérifiées
séparément sur le package final. Aucun résultat CI ne vaut qualification de flotte.

Les huit nouveaux tests couvrent la coalescence des clics, la barrière de
terminaison, Annuler, Arrêter, le changement d’hôte aller-retour, l’annulation
de fermeture, restore et reset. Le clic immédiat est forcé sans suspension
MainActor. Les lectures simulées utilisent des continuations contrôlées ; la
barrière de terminaison est observée pendant 0,3 seconde avec une expectation
inversée. Son échec avant correction a été constaté ; cette observation bornée
n’est pas présentée comme une preuve sans dépendance temporelle.

Les mesures de capacité publiées pour 0.8.3 et les recettes du package 0.8.4
restent dans leurs rapports historiques. Aucun compte de bundle, mesure de
transfert ou résultat natif de ces versions n’est repris comme preuve 0.8.5.

Le contrôle de distribution 0.8.5 utilise des données synthétiques et ne
contacte aucun réseau externe. Il ne qualifie ni un transfert radio réel ni
une installation par Sparkle. Les 199 éléments ci-dessus proviennent du contrôle
de copie propre à 0.8.5.

La validation des exports 0.8.5 repose sur la lecture statique du HTML/JSON et
les empreintes des fichiers générés depuis l’app native. Elle ne prouve pas les
interactions HTML ; la persistance et le transfert loopback sont vérifiés
séparément par la recette native.

L’UI a montré un débit **GCS → Mac d’environ 240 KB/s** avec des délais
artificiels, puis la fin à 100 %. L’état **Drone → GCS** n’a été
observé qu’à 0 % : aucune progression non nulle ni valeur numérique de débit
sur ce trajet n’est revendiquée. Le serveur loopback ne supporte pas HTTP Range.
Ce scénario d’un seul drone et d’un seul log ne qualifie ni débit radio,
concurrence multi-drone, priorité sous charge, coupure Wi-Fi ni reprise Range.

Les deux reconnexions GUI réussies ne prouvent pas que les clics ont coïncidé
avec la fermeture encore en cours de l’ancienne découverte. Cette course,
l’arrêt retardé et l’invalidation des demandes sont couverts par les tests
déterministes distincts. L’origine réseau ou cache du fond de carte n’est pas
distinguée. Aucun cycle d’installation Sparkle n’a été exercé ; les panneaux
natifs Ouvrir/Enregistrer peuvent conserver leurs derniers emplacements malgré
l’isolation de la bibliothèque et des réglages de l’app.

## Publication et flux stable

La release publique [0.8.5](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.5)
propose le DMG, le ZIP de mise à jour, les sources correspondantes et
`SHA256SUMS.txt`. Les quatre assets téléchargés sans authentification sont
identiques aux fichiers qualifiés ; tailles, SHA-256, digests GitHub et manifeste
de sommes concordent. Le DMG public placé sous quarantaine conserve ses octets ;
sa signature, son ticket de notarisation et son acceptation Gatekeeper sont valides.

Le tag annoté pointe sur le commit issu de la fusion de la PR #39, dont l’arbre
est strictement identique aux sources qualifiées. Les **316 fichiers** de
l’archive source correspondent octet pour octet au tag. Les mises à jour
documentaires et du flux après publication ne déplacent ni le tag ni les
archives qualifiées.

La release **0.8.4 (build 23) est publique et immuable**. Son tag et ses assets
restent inchangés ; sa PR de publication du feed (#38) a été fermée sans merge
et ce build n’a jamais été activé dans le flux stable. Le flux versionné propose
directement **0.8.3/build 22 → 0.8.5/build 24** ; il a été préparé avec
`--previous-build 22` après vérification du build alors servi.

Le feed versionné 0.8.5, build **24**, est identique au feed signé localement.
Les outils officiels Sparkle valident sa signature et celle du ZIP téléchargé
publiquement, de **20 985 649 octets**. L’empreinte SHA-256 du feed est
`2a24cf91fb83d967581fbfa0f10fffd32cbffc67180cfc6d850a7af883067875`.
L’activation passe par la fusion de la PR de publication. Après fusion,
télécharger sans authentification le flux effectivement servi, comparer ses
octets au fichier versionné et vérifier ses signatures : la vérification du
feed local et du ZIP public ne prouve pas à elle seule ce qui est servi à
l’URL canonique. Aucun cycle réel d’installation Sparkle dans l’app de
production n’est qualifié par ces seules vérifications de fichiers.

## Traçabilité et empreintes

| Élément | Référence vérifiée |
| --- | --- |
| Sources qualifiées | `40a6463fe2d9e38ceb231249a230ff32fd432a3a` |
| Merge testé par la CI #38080817609 | `86a34dc60750e9f70785879946d30556241f88cf` |
| Commit publié, cible du tag `v0.8.5` | `02096357063dbe935a7a806bd16f7be3c17bca19` |
| Objet du tag annoté distant | `564da79bc19ea480f6eeb9922debe3ce402a5c17` |
| Arbre identique des sources qualifiées, du merge testé et du tag | `71e96d24a632c1e46815e9b6b90269d1c0b24dd9` |
| Publication | [10 octobre 2026 — v0.8.5](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.5) |

| Asset public 0.8.5 | Octets | SHA-256 vérifié après téléchargement anonyme |
| --- | ---: | --- |
| `KataLog-0.8.5-macOS-arm64.dmg` | 20 792 846 | `381cc27767d9e530be1da5413af7b85d94f38d13d7964d0903f3ada34b9eb8a2` |
| `KataLog-0.8.5-macOS-arm64.zip` | 20 985 649 | `7f251680072336a891616e59e4e79ed2d6403ba8f37eb6e21fe8ea495b00547c` |
| `KataLog-0.8.5-source.zip` | 2 542 941 | `742f4bc51a4546b1abf01d4079d476763235aa5b01c112831aaaf64f30faaad0` |
| `SHA256SUMS.txt` | 283 | `033fa1815338cf2302a9382d9b8dc19b99aaeea4604d92e864a5c30d0cff491f` |

Les procédures sont dans [RELEASING.md](RELEASING.md) et les contrats dans
[GCS-COLLECTION.md](GCS-COLLECTION.md). Les preuves contenant des chemins locaux,
les logs de flotte et les fixtures privées restent hors du dépôt public.
