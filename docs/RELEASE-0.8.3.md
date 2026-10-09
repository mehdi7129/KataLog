# KataLog 0.8.3 — recette de release

Version **0.8.3**, build **22**, publiée le **9 octobre 2026**.
État : **Stable publique ; distribution et téléchargements vérifiés**.

## Corrections

Cette version regroupe les 26 corrections de l’[audit de qualité](AUDIT-QUALITE-2026-10-08.md)
et de la [PR d’intégration #34](https://github.com/mehdi7129/KataLog/pull/34).
Elle conserve les fonctions, les parcours et les résultats métier existants.

- **Imports et données** : rollback transactionnel, protection des sorties,
  conservation de la provenance, contrôle des sources avant lecture et prise
  en charge des grandes sélections sans dépasser les limites SQLite.
- **Restauration et maintenance** : reprise après interruption, traitement des
  bibliothèques endommagées, clients et collecte réconciliés avant reprise,
  erreurs de réinitialisation explicites.
- **Navigation** : chaque fenêtre garde son état de lecture ; les alertes suivent
  les filtres actifs et la recherche de proximité réutilise sa sélection exacte
  entre les pages.
- **Collecte** : accès disque sérialisés hors du thread d’interface, progression
  et compteurs cohérents, délais HTTP appliqués jusqu’à la fin du corps,
  inventaires MQTT et flux d’événements bornés.
  La resélection du destinataire valide déjà courant reste sans effet pendant
  la réconciliation des clients ou du stockage : aucune erreur ni écriture
  superflue. Une vraie modification reste protégée par les mêmes gardes.
  Après sauvegarde, les index des grandes files en attente sont préparés hors
  du thread d’interface ; génération, révision et activité sont recontrôlées
  avant leur publication, sans changer les priorités de collecte.
- **Exports et maintenance du code** : résultat de diagnostic fiable, états
  partagés entre Swift et SQL, capacités des commandes explicites, fichiers
  Swift/Python découpés par responsabilité, builds isolés et métadonnées vérifiées.

## Installation et conservation des données

Mac Apple Silicon, macOS 15 minimum. L’identité stable **KataLog.app**, le moteur
Python embarqué, le parseur **1.4.0** et la projection SQLite **8** sont conservés.
Depuis 0.8.2, aucun réimport, nouveau téléchargement GCS ou nouvelle migration
n’est nécessaire. Les analyses, clients, attributions, identités, dossiers et
réglages restent conservés ; KataLog Preview garde sa bibliothèque séparée.

Les modalités de mise à jour restent décrites dans [UPDATING.md](UPDATING.md).
Le [DMG 0.8.3](https://github.com/mehdi7129/KataLog/releases/download/v0.8.3/KataLog-0.8.3-macOS-arm64.dmg)
est disponible. Le XML stable versionné propose le build 22 ; ses signatures
et celles du ZIP public sont vérifiées localement avec l’outil officiel Sparkle.

## Preuves logicielles obtenues

Le candidat `caff7eb` rassemble les corrections de l’audit et la version
0.8.3 build 22. La qualification a également conduit à corriger la resélection
du destinataire GCS courant et le coût des index de file après sauvegarde.
Le package a été reconstruit, signé et notarisé depuis ce commit ; les neuf
contrôles de distribution sont réussis. Sa recette native et la CI sont
consignées séparément ci-dessous.

| Contrôle | Résultat vérifié |
| --- | --- |
| [CI du candidat `caff7eb`](https://github.com/mehdi7129/KataLog/actions/runs/37929722401) | **4/4 jobs réussis** : tests sur macOS 15 et 26, packages ARM64 sur macOS 15 et 27. Sur chaque OS de test : 433 tests Swift, 508 tests Python et 18 tests Node réussis ; seul le corpus Python privé absent est explicitement exclu, sans skip inattendu |
| Resélection du destinataire GCS | Deux tests déterministes : 14 assertions rouges avant correction, puis 20 tests ciblés réussis après correction ; relecture indépendante favorable |
| Réactivité avec 50 000 transferts en attente | 81 tests ciblés réussis, zéro échec et zéro skip ; heartbeat maximal local de 187,98 ms pour un budget inchangé de 500 ms ; relecture indépendante favorable |
| [Banc SDK Sparkle 2.10.0](https://github.com/mehdi7129/KataLog/actions/runs/37923450954) | 5/5 recettes sur macOS 15.7.9 et 5/5 sur macOS 27.0.1 ; remplacement/relance et quatre rejets ; six fichiers synthétiques préservés par essai |
| Revue native préliminaire, macOS 27 | Vue d’ensemble : 180 logs, 1 512,9 min, 4 drones en clair et sombre ; carte Apple chargée, 12 groupes de 15 repères ; clic d’un groupe : 15 logs, retour au périmètre complet : 180 |
| Helper embarqué, bibliothèque synthétique préparée | 50 000 logs, 5 millions de messages, 500 drones ; cinq lectures conformes à l’oracle après contrôle et normalisation des seuls timestamps courants ; fichier SQLite inchangé |

La [CI du premier candidat `91b4464`](https://github.com/mehdi7129/KataLog/actions/runs/37923415746)
a révélé un échec des tests macOS 15 lors de la resynchronisation du destinataire
GCS courant pendant une réconciliation. Ce résultat reste un échec historique.
Le correctif `999e455` rend cette resélection valide sans effet : état `nil` ou
vide préservé, aucun I/O superflu ni nouvelle erreur. Un identifiant invalide
reste refusé, et une vraie modification attend toujours la fin du stockage.
Les deux tests retiennent les opérations par un verrou SQLite réel.

La [CI suivante `999e455`](https://github.com/mehdi7129/KataLog/actions/runs/37925807697)
a mesuré un heartbeat de **641,13 ms** avec 50 000 transferts en attente,
pour un budget de **500 ms**. Le test inchangé reproduit localement l’échec
à **551,65 ms**. Le correctif `caff7eb` prépare les deux index du snapshot
retenu sur l’executor de stockage, puis revalide les gardes avant publication.
Le même test passe à **187,98 ms** dans la série finale de 81 tests locaux ;
la variante historique terminé mesure 15,78 ms et l’arrêt/persistance 94,54 ms.
Aucun seuil, aucune fenêtre de mesure ni priorité de collecte n’est modifié.
La CI finale mesure le même heartbeat à **186,05 ms** sur macOS 15 et
**263,86 ms** sur macOS 26, sous le même budget de 500 ms. Ces observations
locales et CI ne constituent pas une garantie universelle de latence.

La revue des 180 logs utilise un bundle ad hoc avec identité isolée et
sections Mach-O de code/données inchangées. Elle qualifie le rendu réel de la
fenêtre malgré la limite des bitmaps MapKit automatisés ; elle reste distincte
de la recette du package final depuis le DMG, consignée ci-dessous. Les résultats
initiaux de l’audit restent accessibles dans la [CI `91a392a`](https://github.com/mehdi7129/KataLog/actions/runs/37908235149)
et son [rapport](AUDIT-QUALITE-2026-10-08.md), sans être attribués au nouveau commit.

## Performance et limites

Le [banc du candidat `caff7eb`](https://github.com/mehdi7129/KataLog/actions/runs/37929722383)
réussit les **8/8 requêtes** et leurs cinq répétitions sous le budget inchangé
de **500 ms**, sur 50 000 logs, 5 millions de messages et 500 drones. Les
maxima sont **356,05 ms** pour le dashboard et **372,78 ms** pour le registre ;
les répétitions suivantes mesurent 40,4–52,6 ms et 61,7–62,9 ms. Le RSS atteint
**362,69 Mio** sur 512 Mio, l’oracle d’identité est conforme et les sept tests
Swift du banc réussissent. Aucun seuil n’est relevé.

La génération synthétique des données prend 61,43 s et leur première
indexation 417,74 s ; ces étapes préparent le banc et sont distinctes des
latences de lecture sur un index prêt. Le cache OS n’est pas contrôlé.
Le résultat de ce run n’est pas attribué au déplacement des index Swift de
la collecte, qui ne modifie pas les requêtes Python/SQLite mesurées ici.

Les essais précédents à [631,1/542,1 ms](https://github.com/mehdi7129/KataLog/actions/runs/37908235241)
puis [551,9/710,3 ms](https://github.com/mehdi7129/KataLog/actions/runs/37923415725)
et [536,9/506,6 ms](https://github.com/mehdi7129/KataLog/actions/runs/37925807917)
restent des échecs historiques. Ces écarts montrent une variabilité des premières
lectures ; ils ne suffisent pas à en attribuer la cause au cache OS, qui n’est
pas contrôlé dans ce protocole.

Un essai local du helper réellement embarqué en lecture seule mesure
**1,044 s** pour les contrôles runtime et les deux lectures initiales de
l’historique, puis **0,489 s** pour leur répétition ; la lecture du registre
prend **0,555 s**, contrôle runtime inclus. Cette bibliothèque synthétique est
déjà préparée ; le cache du système n’est pas contrôlé, et le temps Swift de
décodage et de rendu n’est pas inclus. Ces résultats montrent une attente
initiale possible sur un grand historique, sans écart de données détecté dans
ces essais. Ils ne constituent pas une garantie de latence pour toute bibliothèque.

Le profilage de la variabilité des premières lectures reste suivi dans la
[roadmap](ROADMAP.md#qualification-et-limites-encore-ouvertes), sans relever le
budget ni masquer les échecs. Cette version ne revendique pas de nouvelle
qualification de flotte physique, de corpus privé absent, de parcours physique
complet sur macOS 15 ou de cycle Sparkle réel de 0.8.2 vers 0.8.3.

## Qualification de la distribution

Les résultats de cette section sont attribués au bundle reconstruit depuis
`caff7eb`. Les packages des candidats précédents ne qualifient pas ce code.

| Contrôle du candidat `caff7eb` | Résultat |
| --- | --- |
| Métadonnées version/build | 0.8.3 build 22, parseur 1.4.0 et projection 8 inchangés ; huit contrats metadata réussis sur la préparation `91b4464` |
| Signature Developer ID et notarisation | App, helper et DMG signés ; notarisation Apple acceptée, tickets attachés, signature stricte et Gatekeeper validés |
| Distribution finale | **9/9 contrôles réussis** sur 0.8.3 build 22 : métadonnées, confidentialité, runtime ARM64 autonome, infrastructure Sparkle, signature, import synthétique, notarisation et layout DMG |
| Confidentialité et runtime du bundle | 186 fichiers et 482 payloads embarqués inspectés, zéro signalement ; 19 modules Python source vérifiés, 22 fichiers natifs ARM64 et aucune dépendance externe |
| Copie depuis le DMG et éjection | Copie depuis le DMG puis éjection, 199 fichiers et liens concordants ; signature, tickets et Gatekeeper vérifiés sur cette copie |
| Parcours natif final sur macOS 27 | App copiée du DMG puis volume éjecté : import de 3 ULogs, 1 drone, 0 erreur ; numéro 083 conservé, groupe MapKit de 3 logs cliquable, export HTML/JSON de 3 logs et 6 messages avec empreintes vérifiées ; données et dossier conservés après redémarrage |
| Sources finales | 303 fichiers qualifiés `caff7eb`, 157 commits et 845 blobs examinés : aucun secret réel ni aucune donnée privée non classée confirmés ; auteurs et committers GitHub noreply |
| Métadonnées et surfaces GitHub finales | Logs et annotations CI, 43 fichiers d’artifacts, métadonnées des PR #35/#34/#6, notes de release, tag et archive source examinés sans signalement non classé ; digests des artifacts confrontés à l’API GitHub |

La recette native utilise le bundle Developer ID exact, sans re-signature,
dans une bibliothèque synthétique isolée. L’écran Collecte reste sans faux
message de stockage en clair et sombre, après resélection de « Sans client »,
navigation et redémarrage. Le numéro `083` conserve son zéro initial ; les
trois logs, leur source accessible et le dossier de collecte sont retrouvés.
Les ULogs source et les 199 fichiers/liens du bundle restent inchangés ;
signature stricte, ticket et Gatekeeper repassent après les deux lancements.
Les instances de recette sont fermées et l’app installée est préservée.
Cette observation UI reste distincte des tests déterministes sous verrou SQLite
et ne qualifie ni une collecte GCS réelle ni une installation Sparkle.

Les deux détections brutes du scanner de secrets correspondent à des noms de
métriques GNSS synthétiques préexistants, revus explicitement ; aucune nouvelle
exclusion n’est ajoutée. Le périmètre source se limite aux refs
disponibles dans le clone.

Le banc SDK de mise à jour emploie des apps ad hoc jetables, une clé éphémère et
HTTP loopback signé. Il observe le remplacement et le relancement, ou une erreur
SDK avec maintien de l’ancien bundle. Les essais de payload altéré n’assertent
pas un code d’erreur de signature précis. Ils ne qualifient pas les dialogues,
les gardes d’activité ni le cycle 0.8.2 → 0.8.3 de la vraie app. Ses dix JSON ont
été relus dans les logs ; aucun artifact séparé n’est téléversé par ce workflow.

## Qualification de la publication

| Contrôle | Résultat |
| --- | --- |
| Tag `v0.8.3` | Tag annoté publié sur le commit 97ff13f, dont l’arbre est exactement celui des sources caff7eb qualifiées |
| Archive de sources correspondantes | Archive source contrôlée : 303 fichiers identiques octet par octet à ceux du tag ; checksum et revue de confidentialité vérifiés |
| DMG, ZIP et SHA-256 | Quatre fichiers publics : DMG, ZIP de mise à jour, archive source et SHA256SUMS.txt ; octets identiques aux fichiers qualifiés, empreintes du manifeste et digests GitHub concordants |
| Téléchargements anonymes et quarantaine | Les quatre assets ont été téléchargés sans authentification. Le DMG public, avec attribut de quarantaine appliqué, conserve ses octets et passe stapler, la signature stricte et Gatekeeper (Notarized Developer ID). La signature Sparkle du ZIP public est valide |
| Flux stable signé build 22 | XML stable 0.8.3 build 22 signé, pointant vers le ZIP final de 20 896 937 octets ; signatures EdDSA du flux et du ZIP vérifiées localement avec l’outil officiel Sparkle |

Les copies, captures et rapports détaillés de recette restent hors du dépôt
public. Les archives et signatures publiées restent immuables ; cette mise à
jour documentaire ne remplace aucun installateur qualifié. La procédure est
décrite dans [RELEASING.md](RELEASING.md).

## Traçabilité et empreintes

Le package final est construit depuis `caff7eb`. Le tag `v0.8.3` cible
`97ff13f4456b0100708fa24560d1ffb4e6b2fc39` ; son arbre `87ebb6dfb61879fde2908d27aab6bd1d95a3ed13` est exactement
celui du code qualifié `caff7ebaadb24b3b617ac1c9ab6504fe7ab7c606`. Les contrôles ci-dessus restent
attribués à leurs commits et artefacts respectifs.

| Archive | SHA-256 des octets qualifiés |
| --- | --- |
| `KataLog-0.8.3-macOS-arm64.dmg` | `143e04f8811a7d2f294db524ab8fdf420ebf43fb6d7d5b777eb403a7324d0663` |
| `KataLog-0.8.3-macOS-arm64.zip` | `dbf382b9aaa5004b08e227c18c78e97adb1fa9eae51fd76a9a07ad10a8501c46` |
| `KataLog-0.8.3-source.zip` | `f938cf42a9dbdd8e29db1dcfeb03e1919f7cd32af30c507524c8e2edcbdce6ce` |
