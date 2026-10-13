# Collecte GCS — améliorations candidates après 0.8.5

## Décision et contexte

La référence stable reste **0.8.5 (build 24)**. Aucune release 0.8.6 n'est
planifiée pour l'incident de téléchargement HTTP 404.

Le transfert drone → GCS était annoncé terminé, puis le serveur HTTP ne trouvait
pas la copie temporaire à transmettre au Mac. Le même échec était reproductible
depuis l'interface GCS. Le développeur GCS a identifié un dossier manquant ;
l'utilisateur a ensuite confirmé des téléchargements réussis avec la preview
KataLog après les correctifs des firmwares GCS et drone.

Ce retour confirme le rétablissement du parcours testé. La 0.8.5 utilise la même
chaîne de collecte, mais son essai après ces mises à jour n'a pas été rapporté
séparément. Une validation de la preview ne vaut pas qualification de toutes les
combinaisons de firmwares ni d'une nouvelle release.

Les éléments ci-dessous sont un suivi pour une future décision d'intégration.
Le code du prototype local n'est pas inclus dans cette PR de documentation.

## Améliorations déjà prototypées dans la preview

| Sujet | Bénéfice attendu | Validation avant intégration |
| --- | --- | --- |
| Adresse GCS avec port facultatif | Accepter un hôte, `gcs.local:4200` ou `http://gcs.local:4200/`. Résoudre le port de l'API depuis la configuration de l'interface. | Recettes Aqua et drones volants, API directe, IPv6, persistance et anciens réglages sans port. Conserver la distinction entre MQTT TCP, WebSocket et HTTP. |
| Journaux de diagnostic avec la même adresse | Récupérer les journaux des services après saisie d'une adresse avec port. | Export sur un firmware compatible, annulation, changement d'adresse ou de port pendant une récupération et diagnostic local toujours disponible si l'export distant échoue. |
| Message de téléchargement HTTP 404 plus précis | Expliquer que la copie temporaire attendue n'est pas accessible après la fin annoncée du transfert drone → GCS. | Aucun faux succès, copies locales conservées, pas de réessais automatiques inutiles après un premier 404. Préserver la reprise existante lorsqu'un staging précédemment valide a disparu. |

Ces améliorations rendent la connexion et le diagnostic plus clairs. Elles
n'étaient pas le correctif des firmwares à l'origine de l'incident.

## Points à compléter avant une intégration

- [ ] Borner aussi la réception des **en-têtes HTTP** lors de la lecture de la
  configuration. Le prototype borne la taille et la lecture du corps, y compris
  le framing chunked. La lecture initiale par `urllib` ne borne que l'inactivité
  et peut dépasser le budget total attendu si les en-têtes arrivent au
  compte-gouttes. Ajouter une reproduction locale qui vérifie le délai total,
  l'annulation et la fermeture du transport.
- [ ] Consigner les versions GCS et drone effectivement testées, avec leur
  résultat. Les références exactes des firmwares corrigés restent à relever.
- [ ] Refaire un téléchargement avec la **0.8.5 (24)**, puis qualifier le
  prototype sur de petits et grands logs, le cache après relancement et une
  coupure/reprise sur banc autorisé. Contrôler taille et intégrité locale ; une
  égalité bit à bit avec la source exige une empreinte ou une copie de référence.
- [ ] Lorsqu'une intégration est décidée, revalider le code retenu, les suites
  requises et la recette du bundle correspondant avant toute publication.

Le prototype local avait obtenu **555 tests Python réussis sur 556**, le seul
test non exécuté nécessitant un corpus privé absent, et **192 tests Swift GCS
réussis sans skip**. Le moteur compilé avait également passé des essais
synthétiques de résolution du port, téléchargement, cache et staging manquant.
Ces résultats concernent ce prototype : ils ne sont pas les résultats de CI de
cette PR et ne remplacent pas les validations requises pour une future release.

## Option à réévaluer : collecte MAVLink directe

Une source MAVLink UDP directe pourrait récupérer les logs par la voie utilisée
par QGroundControl, indépendamment du stockage temporaire HTTP de la GCS.
**Ce mode n'est pas implémenté dans la preview et n'est pas planifié.** Son
intérêt devra être confirmé par un besoin distinct de l'incident désormais résolu.

Il s'agirait d'un transport supplémentaire : identification explicite du
véhicule, inventaire et récupération des logs, pertes et reprise, annulation,
coexistence avec les autres clients et conservation des contrôles d'intégrité.
Un changement du port HTTP de Collecte GCS ne fournit pas ce fonctionnement.

## Références

- [Contrat actuel de collecte GCS](GCS-COLLECTION.md)
- [Diagnostic local et journaux GCS](DIAGNOSTICS.md)
- [Roadmap générale](ROADMAP.md)
- [Qualification et publication](RELEASING.md)

Les essais matériels et leurs données détaillées restent privés. Cette note
contient uniquement le contexte général, l'état des pistes et les validations
attendues.
