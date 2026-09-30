# Collecte de logs depuis une GCS Drotek

## Périmètre

Le protocole est compatible avec la GCS Drotek 3.7.2 testée. Les fixtures de
simulateur sont synthétiques. Les captures réseau, UUID réels, chemins de logs
et preuves opérationnelles sont conservés hors du dépôt.

KataLog demande uniquement l'inventaire et le téléchargement des logs des drones
inscrits dans la flotte, individuellement ou par l’action **Tout collecter**. L'app ne pilote pas les drones et ne
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
- Deux UUID en parallèle, un fichier à la fois par UUID.
- Pause après les fichiers actifs ; arrêt immédiat sur le Mac et reprise manuelle.
- Trois tentatives pour erreurs transitoires, délais de 5 puis 15 secondes,
  prolongés si une session distante reste en attente de fin.
- Destination choisie conservée au redémarrage ; aucun fallback si elle est inaccessible.
- Cache de copie vérifié par UUID, chemin distant, taille, manifeste et SHA256.
- Import automatique des fichiers vérifiés ; réanalyse locale sans nouveau transfert.

Une copie déjà demandée peut continuer sur la GCS après l'arrêt local. Le délai
client de 300 à 3 600 secondes n'est pas une preuve d'arrêt distant. Les travaux
actifs restaurés deviennent interrompus ; une reprise attend le contexte réseau.

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
La reprise à un offset réseau et l'abandon FTP distant restent non confirmés.

## Copies supplémentaires dans Téléchargements (GCS web 3.7.2)

Le frontend web peut observer un transfert lancé par un autre client, puis déclencher
son propre téléchargement navigateur. KataLog écrit seulement dans la destination
du job ; un onglet GCS peut créer une copie indépendante dans Téléchargements.

Fermer les onglets GCS pendant la collecte évite ce comportement. La connexion
KataLog est indépendante du navigateur. Distinguer les demandes de chaque client
nécessiterait une évolution du frontend GCS ; aucun réglage distant n'est changé.
