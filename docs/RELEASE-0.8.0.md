# KataLog 0.8.0 — recette de release

Version **0.8.0**, build **18**, préparée le 1er octobre 2026.
État : **publiée le 1er octobre 2026**. La Preview et sa
direction visuelle ont été approuvées. Les résultats du package, de la CI et
des contrôles de publication sont distingués ci-dessous.

## Nouveautés

- Clients locaux personnalisables : votre organisation ou les clients dont vous
  suivez les drones, sans compte ni service cloud.
- Attribution des logs à l’import ou à la collecte, modification en lot et
  statistiques, historique, carte et rapports limités au client sélectionné.
- Interface Bento plus sobre : actions sans cadre permanent, survol et focus
  visibles, thème clair/sombre en un clic et activité récente défilante.
- Recherche de logs autour d’une ville, d’une adresse ou de coordonnées, avec
  rayon, sur les trajectoires complètes disponibles.
- Une fenêtre macOS indépendante par log, déplaçable et redimensionnable.
- Collecte groupée sans inscription manuelle des drones éligibles connectés à
  la GCS ; client destinataire conservé dans chaque travail de la file.
- Outils PX4 spécialisés dans un mode avancé facultatif et diagnostic GCS guidé.
- Retrait groupé des sources, vidage de bibliothèque et réinitialisation globale
  avec confirmation, sans supprimer les fichiers `.ulg`.

Voir [le contrat clients, carte et conservation des fichiers](CLIENTS-BENTO.md).

## Installation et migration

Mac Apple Silicon, macOS 15 minimum. Installation par DMG hors App Store,
moteur autonome embarqué. À partir de 0.7.0, la mise à jour est proposée par
le flux stable signé après publication de ses assets ; les versions plus
anciennes peuvent installer directement le nouveau DMG.

La bibliothèque stable, les identifications et les dossiers choisis sont
conservés. Les anciens logs restent dans **Sans client** jusqu’à attribution
explicite. Un doublon ou une réanalyse ne change jamais cette attribution.
Les rapports complets portent sur le client choisi ; **Tous les clients**
permet de couvrir la bibliothèque entière.

La première recherche géographique met en cache les trajectoires complètes
accessibles. Les sources absentes sans cache sont annoncées comme non vérifiables.
La recherche ne relie pas les lacunes GPS et précède la limite des 80 logs affichés.

KataLog Preview utilise une bibliothèque distincte et n’active pas les updates.
Son contenu n’est pas transféré automatiquement dans la bibliothèque stable.

## Validation préalable de la Preview

La [recette détaillée](VALIDATION-CLIENTS-BENTO.md) consigne 320 tests natifs,
10 tests ciblés d’isolation/collecte desktop et un contrôle des menus clients,
ainsi que 371 tests Python réussis et un corpus privé explicitement absent.
Les contrats clients, fenêtres indépendantes, cache géographique, réinitialisations
et exports partagés ont été exercés avec des données synthétiques. Les rendus
natifs couvrent clair/sombre, tailles minimale/desktop et longue file d’erreurs.

Ces résultats qualifient la Preview ; ils ne remplacent pas les contrôles du
package stable final.

## Qualification du package stable

| Contrôle | Résultat |
| --- | --- |
| Swift complet, Core et app, local | 323 tests réussis, aucun échec ni test ignoré |
| Adaptations des tests aux runners | 9 tests révisés réussis localement ; code applicatif inchangé |
| Arrêt du moteur et libération des verrous | 17 tests réussis ; 8 répétitions du cas d’annulation réussies |
| Isolation de l’export de diagnostic | 32 tests groupés réussis ; 4 répétitions du contexte client et diagnostic réussies |
| Python autonome | 371 tests réussis ; 1 test de corpus privé externe non exécuté |
| Interactions JavaScript des rapports | 18 tests réussis |
| Banc SDK de mise à jour | 5 recettes réussies sur macOS 15 et 5 sur macOS 27 |
| Build stable | 0.8.0, build 18, moteur autonome embarqué |
| Signature et notarisation | Developer ID ; app et DMG acceptés par Apple ; tickets app, helper et DMG validés |
| Distribution finale | 9 contrôles réussis |
| Installation locale | Copie depuis le DMG, éjection puis lancement graphique réussis |
| Contrats clients dans le moteur final | 4 groupes de vérifications réussis |
| Confidentialité des sources et du bundle | Aucun finding dans les périmètres inspectés |

Le moteur final est exercé avec des données synthétiques : attribution des logs,
déduplication, cache et changements de client, sans accès à une flotte réelle.
La recette de distribution inspecte aussi les signatures, les dépendances
embarquées et le contenu des archives Python. Les preuves détaillées restent
locales ; elles ne sont pas distribuées avec l’app.

Le [banc SDK de mise à jour](https://github.com/mehdi7129/KataLog/actions/runs/36919535988)
a réussi ses cinq cas sur macOS 15 et sur macOS 27. Il utilise des applications
jetables, une clé de test et un serveur loopback. Les recettes couvrent
installation/relancement, flux modifié, archive modifiée, téléchargement
interrompu et archive absente. Les six fichiers de données synthétiques sont
conservés ; l’app installée et la bibliothèque réelle ne sont pas remplacées.

## Traçabilité et CI

Le code applicatif et les entrées de build du package correspondent au commit
`8c4e6cd`. Les commits `416f32f`, `5afc5c3` et `003a8bd` ajustent uniquement les tests :
taille d’écran réelle, attente d’initialisation et attente du nettoyage asynchrone
du moteur. La vérification de l’arrêt et de la libération du verrou conserve une
borne totale de 1,5 seconde. Ces changements ne modifient ni les sources de l’app
ni les entrées du packaging. La suite complète locale ci-dessus précède ces
ajustements ; les groupes ciblés ont ensuite été rejoués avec succès. L’export de
diagnostic démarre avec un registre de processus vide et doit le laisser vide.

La [CI finale sur `003a8bd`](https://github.com/mehdi7129/KataLog/actions/runs/36925137172)
est entièrement réussie : 323 tests Swift sans échec ni test ignoré, 371 tests
Python réussis et 18 tests JavaScript réussis sur chacun des runners macOS 15
et 26. Le test nécessitant le corpus privé externe est explicitement exclu.
Les packages autonomes ARM64 passent sur macOS 15 et macOS 27.

Les changements de documentation de release suivent ces commits sans modifier
le code du package. Le tag `v0.8.0` identifie les sources correspondantes
et leur documentation finale.

## Contrôles de publication

La [release publique 0.8.0](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.0)
a été publiée après la réussite de la CI. Le tag cible `4e9be42` ; seuls les
comptes rendus et le flux de mise à jour sont ajoutés ensuite sur `main`.

- DMG, ZIP d’installation, sources et `SHA256SUMS` téléchargés sans authentification.
- Les quatre fichiers téléchargés correspondent exactement aux fichiers validés
  et aux empreintes renvoyées par GitHub.
- DMG téléchargé avec quarantaine : accepté par Gatekeeper comme distribution
  Developer ID notarisée ; ticket Apple validé.
- Archive source : 241 fichiers identiques au tag, aucun fichier supplémentaire,
  chemin dangereux ou lien symbolique ; garde de confidentialité sans finding.
- Flux stable publié après les archives, téléchargé depuis son URL HTTPS habituelle
  et identique aux octets signés préparés : version 0.8.0, build 18.
- Signatures du flux et du ZIP téléchargés vérifiées avec l’outil officiel Sparkle ;
  URL et taille de l’archive concordantes.

| Archive | SHA-256 |
| --- | --- |
| `KataLog-0.8.0-macOS-arm64.dmg` | `96cd780f8e57c65204e226bf50dd49884d8986d77bf00bc76ebbae2b355553ed` |
| `KataLog-0.8.0-macOS-arm64.zip` | `c390671a3faa861976af2e32be86f98c46cdbc2bd9fad17a0ce157f843b2397f` |
| `KataLog-0.8.0-source.zip` | `6e90a5bdde793de720c55eab3f767dab8db66960cb0196471faa136595b60885` |

Les rapports détaillés, bibliothèques de test et captures locales restent hors
Git. Aucun résultat CI, notarisation ou téléchargement public n’est déduit du
seul succès de compilation. Le [périmètre de confidentialité](PUBLICATION.md)
distingue les sources, les assets et les surfaces GitHub.

## Limites

- Aucune nouvelle collecte sur un drone réel n’est revendiquée pour cette release.
  Les transports simulés ne qualifient pas une flotte radio de 500 appareils.
- Les recherches de ville/adresse dépendent du service Apple ; la saisie directe
  de coordonnées reste possible. Une source absente sans trajectoire complète
  en cache limite la couverture de la recherche et est signalée.
- La recette locale sur macOS 27 ne remplace pas un essai physique sur macOS 15.
- Les événements PX4 nécessitent le dictionnaire exact du firmware pour être
  traduits. Une alerte décrit un signal observé, pas une panne confirmée.
- Vider la bibliothèque ou réinitialiser l’app efface les données locales
  décrites dans la confirmation pour tous les clients. Les fichiers `.ulg`
  conservés peuvent ensuite être réimportés ; leur attribution précédente
  n’est pas recréée après une réinitialisation complète.
