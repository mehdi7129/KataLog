# KataLog 0.8.4 — recette de release

Version **0.8.4**, build **23**, publiée le **10 octobre 2026**.
État : **release publique ; distribution et téléchargements vérifiés, flux non activé**.

## Changements

Cette version fiabilise la collecte GCS et permet de télécharger rapidement un
log précis. La progression conserve son dernier état valide pendant les recalculs,
le débit est affiché par trajet, et les demandes manuelles sont prioritaires sur
les fichiers en attente. Le parallélisme est réglable de 1 à 4 drones, avec
2 par défaut et un seul transfert par drone.

Les erreurs réseau des téléchargements et inventaires de collecte sont retentées
sans limite par défaut. Les choix 3 et 10 bornent le nombre total de tentatives
par fichier ou inventaire. Un drone indisponible ne bloque pas les téléchargements
des autres pendant l’attente. Pause, Arrêter et les erreurs permanentes restent
explicites. Le client, l’hôte et le dossier de chaque demande sont conservés ;
la suppression d’un client suit le nettoyage des attributions existant.

La collecte maintient le Mac éveillé pendant l’activité et l’attente d’une
reconnexion, sans empêcher la veille de l’écran. La fermeture du capot et la
mise en veille explicite restent possibles.

## Compatibilité et limites

macOS 15 minimum, Apple Silicon. Identité stable et bibliothèques existantes
conservées ; parseur **1.4.0** et projection SQLite **8** inchangés. Aucun réimport
n’est requis pour les analyses déjà présentes.

La reprise au bon octet **GCS → Mac** exige un ETag fort et une réponse HTTP
Range cohérente. Le préfixe et son identité sont contrôlés avant réutilisation.
Si le serveur ne permet pas cette reprise ou si le staging a changé, une nouvelle
copie peut être nécessaire. L’API Drotek utilisée ne permet pas de demander un
offset **Drone → GCS** : ce trajet peut devoir repartir du début.

Une interruption conserve un couple cohérent entre octets et empreinte du
préfixe HTTP. Le marqueur de finalisation n’est publié qu’une fois complet et
persisté ; sa reprise ne remplace pas une preuve étrangère. Une réponse invalide
du collecteur est une erreur permanente, même lorsque les réessais réseau sont
sans limite.

La lecture manuelle « Voir les logs » hors collecte garde trois essais. Après
fermeture de l’app, les inventaires incomplets se relancent explicitement avec
« Tout collecter ». Les copies partielles HTTP valides restent récupérables.
La nouvelle reprise et le parallélisme à 3/4 drones sont vérifiés sur fixtures ;
aucune nouvelle qualification radio ou flotte physique n’est revendiquée.

La recette a relevé une limite préexistante des exports résumés : la liste
`unavailableSections` du manifeste JSON peut rester vide alors que le HTML
énumère les détails non chargés. Les trois logs, leurs six messages, leurs
empreintes et l’attribution de drone sont conformes ; le JSON indique bien
la couverture résumée. Les quatre fichiers de code concernés sont identiques
entre la base 0.8.3 et cette candidate. L’alignement de cette métadonnée reste
à corriger ; aucune perte de données exportées n’a été observée dans la recette.

## Validation du candidat

Les résultats ci-dessous concernent les sources `6b165f4` de la
[PR #37](https://github.com/mehdi7129/KataLog/pull/37) et les archives construites
depuis ce commit. Les contrôles plus anciens restent associés à leurs propres
commits ; ils ne qualifient pas à eux seuls cette archive.

| Contrôle | État vérifié |
| --- | --- |
| [CI du candidat `6b165f4`](https://github.com/mehdi7129/KataLog/actions/runs/38065464636) | **4/4 jobs réussis** : sur chacun des systèmes macOS 15 et 26, **468 tests Swift, 532 tests Python et 18 tests Node réussis** ; seul le test Python réservé au corpus privé absent est exclu, sans skip inattendu. Deux packages ARM64 sur macOS 15 et 27, six contrôles réussis chacun |
| Distribution finale | **9/9 contrôles réussis** : métadonnées, confidentialité, runtime natif autonome, infrastructure de mise à jour signée, signature stricte, import synthétique, notarisation et Gatekeeper de l’app et du DMG, intégrité et présentation du DMG |
| Copie depuis le DMG | Copie puis éjection vérifiées ; **199 fichiers et liens** concordants avec le bundle qualifié |
| Recette native de la copie du DMG, macOS 27 | Import de trois logs, un drone identifié, carte et groupe de trois logs, export HTML/JSON avec six messages et empreintes conformes ; thèmes clair/sombre et conservation du numéro, des sources, de la destination et des réglages après redémarrage |
| Téléchargement individuel depuis l’UI | Une GCS loopback et un log synthétique : inventaire, sélection, progression Drone → GCS, débit GCS → Mac visible, puis **1/1 fichier vérifié** ; **1 705 279 octets** et SHA-256 conformes. Le rafraîchissement reconnaît la copie déjà présente ; une seule requête HTTP |
| Après fermeture de la recette | Les 199 éléments du bundle restent identiques, signature stricte, ticket et Gatekeeper valides ; sources synthétiques inchangées et bibliothèque de production préservée |

Le contrôle de distribution utilise des données synthétiques et ne contacte
aucun service réseau externe. Il ne qualifie ni un transfert radio réel ni le
cycle Sparkle de l’app installée. La recette native reste distincte de ces
contrôles automatisés.

La recette native observe le débit GCS → Mac avec des délais artificiels ;
elle ne mesure pas une performance radio et ne relève pas de valeur numérique
de débit Drone → GCS. La reprise HTTP Range et la concurrence entre plusieurs
drones restent couvertes par les tests déterministes, pas par cette recette.

Les mesures de capacité et leurs variations publiées pour 0.8.3 restent dans
[leur rapport historique](RELEASE-0.8.3.md#performance-et-limites) ; elles ne sont
pas attribuées à ce nouveau package.

## Publication

La [release `v0.8.4`](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.4)
contient le DMG, le ZIP de mise à jour, les sources correspondantes et
`SHA256SUMS.txt`. Les quatre assets ont été téléchargés sans authentification :
octets, tailles, empreintes GitHub et manifeste SHA-256 correspondent aux fichiers
qualifiés. Le DMG téléchargé sous quarantaine passe signature, ticket et Gatekeeper.

Le tag annoté pointe sur le merge `5f48496`, dont l’arbre est strictement
identique au commit qualifié `6b165f4`. Les **314 fichiers** de l’archive source
correspondent octet pour octet au tag. Les mises à jour ultérieures de cette
documentation et du flux ne déplacent ni ce tag ni les archives qualifiées.

L’activation du flux 0.8.4 a été suspendue. La [CI de publication](https://github.com/mehdi7129/KataLog/actions/runs/38078636049),
sur le même code applicatif, a révélé une course préexistante lors d’une reconnexion
immédiate après déconnexion : un clic pouvait être ignoré tant que l’ancienne
tâche de découverte n’avait pas terminé. Le test supposait aussi une barrière de
terminaison qui n’attendait pas cette tâche. Un test échoue sur macOS 26 ; les
trois autres jobs réussissent. Ces résultats ne remplacent pas ceux du candidat
ci-dessus et ne sont pas présentés comme une validation réussie de la publication.

Le flux stable reste sur le build **22** de 0.8.3 pendant la préparation du
[correctif 0.8.5](RELEASE-0.8.5.md). Le flux préparé pour 0.8.4 et le ZIP public
avaient des signatures Sparkle valides, mais ce flux n’a pas été activé.
Aucun asset ni tag publié n’est remplacé. Cette qualification n’installe pas
la mise à jour dans l’app de production.

## Traçabilité et empreintes

Commit qualifié : `6b165f40c043dfca0945b917a2b798eaf7ae925a`.
Arbre qualifié : `e2c4c008a9e0389a8b52c581c23a43d169d3119a`.
Commit du tag annoté : `5f48496bb894e97a5b8aa8df7c886676820d3c65`.

| Archive publique vérifiée | SHA-256 |
| --- | --- |
| `KataLog-0.8.4-macOS-arm64.dmg` | `9f91076f413e1c82b26fd006faaa7de1589ff228622f8c9ab72d044539cfacf1` |
| `KataLog-0.8.4-macOS-arm64.zip` | `1e277f3a745feac1d09ee0054f17b1b73c7060c8ac099278e49888679f36c5db` |
| `KataLog-0.8.4-source.zip` | `75ac1c649cfd924d21d9801690efac6883a3aad957bc7b9c94c2e19bb3e32402` |

Ces empreintes ont été recalculées sur les archives téléchargées depuis GitHub.

Les instructions de distribution sont dans [RELEASING.md](RELEASING.md) et les
contrats de collecte dans [GCS-COLLECTION.md](GCS-COLLECTION.md). Les logs et preuves
contenant des chemins locaux restent hors du dépôt public.
