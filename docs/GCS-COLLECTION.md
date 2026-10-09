# Collecte de logs depuis une GCS Drotek

## Périmètre

Le protocole est compatible avec la GCS Drotek 3.7.2 testée. Les fixtures de
simulateur sont synthétiques. Les captures réseau, UUID réels, chemins de logs
et preuves opérationnelles sont conservés hors du dépôt.

KataLog demande uniquement l'inventaire et le téléchargement des logs des drones
éligibles connectés à la GCS. **Tout collecter** inscrit automatiquement les
appareils inconnus ; aucun ajout manuel préalable n’est requis. L'app ne pilote pas les drones et ne
modifie ni firmware, paramètres ni fichiers distants.

## Comportement de l'app

- Connexion MQTT, reconnexion et expiration de télémétrie après 10 secondes.
- UUID complet valide comme clé ; aucun numéro de stock inventé.
- **Tout collecter** : enregistrement groupé des appareils éligibles visibles
  sur la GCS connectée, puis inventaire et collecte. Le registre conserve aussi
  les appareils sans logs. La simple découverte n’inscrit pas un appareil.
- Avec **Tout collecter**, registre et réglages sont sauvegardés avant l’inventaire.
  Un échec annule le départ et restaure le registre précédent ; aucun transfert ne démarre.
- Appareil explicitement armé exclu ; champ absent = état inconnu.
- **Voir les logs**, sur un drone, ouvre son inventaire avec recherche, sélection
  multiple et bouton **Télécharger** par fichier. Une demande manuelle passe avant
  les fichiers encore en attente, sans interrompre les transferts actifs ni changer
  le client associé aux jobs déjà préparés. Pendant la collecte, les inventaires
  déjà lus restent consultables ; une nouvelle lecture attend la fin de l’activité.
- Deux transferts réseau en parallèle par défaut, réglables de **1 à 4 drones**
  dans les options. Toujours un fichier à la fois par UUID. Réduire la limite
  laisse finir les fichiers actifs avant d’en admettre d’autres.
- Depuis 0.8.1, un worker séparé analyse les fichiers vérifiés pendant les transferts
  suivants. Au plus quatre fichiers sont en transfert ou en analyse/en attente
  d’analyse. Une erreur d’analyse conserve la copie vérifiée.
- Pause après les fichiers actifs ; arrêt immédiat sur le Mac et reprise manuelle.
- Téléchargements : **réessais sans limite par défaut** pour les erreurs réseau
  transitoires, avec choix de 3 ou 10 tentatives au total. Délais de 5, 15, 30 puis
  60 secondes, prolongés si une session distante reste en attente de fin. Un drone
  hors ligne attend de redevenir disponible. Les erreurs permanentes de destination,
  d’intégrité ou d’analyse demandent une intervention. Pause et Arrêter restent disponibles.
- Le parallélisme et la limite de tentatives sont conservés au redémarrage.
  Les inventaires gardent leurs trois essais bornés ; leur échec est signalé dans
  la couverture de flotte et ne bloque pas les autres inventaires.
- Une collecte active ou attendant une reconnexion empêche la veille automatique
  du Mac, sans empêcher celle de l’écran. La pause libère cette activité après les
  fichiers actifs ; Arrêter et la fin de la collecte la libèrent aussi. Cela ne
  contourne pas une fermeture du capot ou une mise en veille explicite.
- Destination choisie conservée au redémarrage ; aucun fallback si elle est inaccessible.
- Changement de destination : nouvelle progression à zéro, inventaire local
  invalidé puis revérifié pour le drone sélectionné s’il est connecté. Les anciens
  transferts et fichiers conservent leur destination dans l’historique. Les
  transferts actifs ou en attente doivent être arrêtés avant le changement.
- Progression globale pondérée par la taille des logs : première moitié pour
  Drone → GCS, deuxième moitié pour GCS → Mac. La fin reste sous 100 % jusqu’à
  vérification et, si activée, analyse. Le compteur d’octets désigne seulement
  les données reçues sur le Mac. Les copies déjà présentes sont revérifiées.
- Le recalcul des totaux conserve le dernier affichage connu du même lot ; il
  n’efface plus momentanément la barre et le pourcentage. Une erreur de lecture
  reste signalée et une ancienne complétion n’est jamais présentée comme actuelle.
- Le débit récent est mesuré séparément pour **Drone → GCS** et **GCS → Mac**, en
  additionnant seulement les workers du même trajet. Les octets d’une copie déjà
  présente ne comptent pas comme du trafic nouveau ; une mesure périmée disparaît.
- Cache de copie vérifié par UUID, chemin distant, taille, manifeste et SHA256.
- Import automatique des fichiers vérifiés ; réanalyse locale sans nouveau transfert.

Une copie déjà demandée peut continuer sur la GCS après l'arrêt local. Le délai
client de 300 à 3 600 secondes n'est pas une preuve d'arrêt distant. Les travaux
actifs restaurés deviennent interrompus ; une reprise attend le contexte réseau.

## Reprise après interruption

Pendant **GCS → Mac**, le collecteur conserve un fichier partiel et une preuve
distincte de reprise lorsque le serveur fournit un **ETag fort**. La preuve lie
les octets déjà écrits, leur SHA256, l’identité du fichier local, la source, le
staging et l’endpoint. La tentative suivante demande uniquement les octets restants
avec HTTP `Range` / `If-Range`. Elle vérifie le validateur et la plage retournée
avant d’assembler le fichier, puis applique les contrôles ULog, taille et SHA256
habituels. Cette reprise évite une seconde demande Drone → GCS.

Si le serveur ignore `Range` mais confirme la même représentation, la copie HTTP
repart proprement de zéro. Si le staging a disparu ou changé, une nouvelle demande
au drone est nécessaire. Sans ETag fort, la reprise partielle n’est pas activée :
un nom et une taille identiques ne suffisent pas à garantir le même contenu.

L’API MQTT Drotek utilisée n’expose pas d’offset de reprise pour **Drone → GCS**.
Une coupure courte peut laisser survivre le transfert en cours ; s’il échoue, ce
trajet doit être redemandé. Le support `Range` et des validateurs forts doit encore
être qualifié sur la GCS réelle : les tests de reprise utilisent un serveur local
synthétique, y compris une pause de flux de cinq secondes et des connexions rompues.

## Contrat MQTT / HTTP

Ports configurables : MQTT 1999, HTTP 8080. L'utilisateur saisit l'hôte de sa GCS ;
aucune adresse de réseau personnel n'est distribuée comme valeur par défaut.

Les topics sont préfixés par `swarm_manager/` :

| Usage | Topic |
|---|---|
| Découverte | `send_mqtt_drone_status_list` |
| Inventaire | `recv_mqtt_ftp_list_request` |
| Téléchargement | `recv_mqtt_ftp_download_request` |

Souscrire aux réponses avant la requête et attendre SUBACK. Une demande cible
un UUID complet et un chemin ; le téléchargement inclut `filesize`. Corréler UUID,
opcode, chemins connus et fenêtre du transfert : les réponses n'ont pas de request ID.
Les noms sans suffixe `_request` ne conviennent pas au protocole testé.

Après la fin MQTT réussie, recevoir le fichier via la route HTTP
`/downloadFile/UUID_COMPLET_nom.ulg`. Un chemin de staging peut différer du chemin
sur la carte ; conserver les deux dans la provenance locale. Les fichiers de
répertoires différents portant le même basename doivent rester distincts sur le Mac.

## Validation et intégrité

Écrire dans un fichier temporaire, comparer taille annoncée et reçue, vérifier
signature ULog et SHA256, puis finaliser le fichier et son manifeste. Ces deux
opérations disposent d’une preuve intermédiaire durable pour reprendre après
interruption ; elles ne forment pas une transaction atomique commune.
Le SHA local identifie la copie ; sans empreinte distante, il ne prouve pas une
égalité de contenu distant ni ne détecte tout remplacement de même chemin/taille.

Un fichier existant sans manifeste valide est conservé et signalé, jamais écrasé
implicitement. Les commandes JSONL exposent `retryable` et les événements
`transfer_started`, `transfer_finished`, `transfer_end` et `error`.
Un arrêt local porte `cancelled:true`, `retryable:false` et
`cancellationRemoteStopped:false`.

Si iCloud a retiré du Mac le fichier ou son manifeste, la collecte s’arrête avec
une explication et sans nouvelle tentative automatique. Dans Finder, télécharger
le dossier, attendre la fin, puis relancer la collecte. Les copies, manifestes et
preuves intermédiaires sont conservés : une preuve temporairement dans le cloud
n’est pas traitée comme un fichier à télécharger de nouveau depuis le drone.

Les événements retained/anciens ne valident pas un nouveau transfert. La progression
indéterminée ne devient pas un faux pourcentage. Quitter un autre client FTP ciblant
le même drone évite des réponses concurrentes ambiguës.

## Identité entre MQTT et ULog

L'association repose sur `dance_status.uuid` valide et stable lorsqu'il est
présent. Conserver aussi `sys_uuid`, vérifier les contradictions et la provenance.
Un format constructeur reconnu peut servir à contrôler la cohérence ; il ne
constitue pas une règle universelle pour tout matériel ou firmware.
Aucune liste d'identifiants réels n'est publiée.

## Recette

Le simulateur couvre réseau, erreurs, cache, interruption et identités multiples.
Une recette réelle a couvert deux drones ; elle ne qualifie pas 500 appareils.
Avant livraison : collecte, pause/arrêt/reprise, cache après redémarrage et changement
d'hôte, fichiers homonymes, ULog invalide et coupure réseau sur banc autorisé.
La reprise à un offset Drone → GCS et l'abandon FTP distant restent non confirmés.
Le parallélisme à trois ou quatre drones est couvert par simulation, pas par une
nouvelle recette physique de flotte.

## Copies supplémentaires dans Téléchargements (GCS web 3.7.2)

Le frontend web peut observer un transfert lancé par un autre client, puis déclencher
son propre téléchargement navigateur. KataLog écrit seulement dans la destination
du job ; un onglet GCS peut créer une copie indépendante dans Téléchargements.

Fermer les onglets GCS pendant la collecte évite ce comportement. La connexion
KataLog est indépendante du navigateur. Distinguer les demandes de chaque client
nécessiterait une évolution du frontend GCS ; aucun réglage distant n'est changé.
