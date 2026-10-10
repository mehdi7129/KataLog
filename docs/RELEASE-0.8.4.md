# KataLog 0.8.4 — recette de release

Version **0.8.4**, build **23**. État : **candidate en qualification, non publiée**.

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

La lecture manuelle « Voir les logs » hors collecte garde trois essais. Après
fermeture de l’app, les inventaires incomplets se relancent explicitement avec
« Tout collecter ». Les copies partielles HTTP valides restent récupérables.
La nouvelle reprise et le parallélisme à 3/4 drones sont vérifiés sur fixtures ;
aucune nouvelle qualification radio ou flotte physique n’est revendiquée.

## Validation et distribution

Les contrôles de la candidate seront attribués au commit exact une fois terminés :
CI macOS 15/26, packaging ARM64, recettes natives isolées, signature Developer ID,
notarisation, copie/éjection du DMG, téléchargements anonymes et flux Sparkle.
Les résultats antérieurs de la [PR #37](https://github.com/mehdi7129/KataLog/pull/37)
restent associés à leurs commits et ne qualifient pas à eux seuls cette archive.

Les instructions de distribution sont dans [RELEASING.md](RELEASING.md) et les
contrats de collecte dans [GCS-COLLECTION.md](GCS-COLLECTION.md). Les logs et preuves
contenant des chemins locaux restent hors du dépôt public.
