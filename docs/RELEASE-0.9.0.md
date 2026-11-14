# KataLog 0.9.0 — qualification

Version **0.9.0**, build **28**, préparée depuis `main` 1f7c84d (0.8.8).
Les résultats ci-dessous distinguent le code, le package et le matériel réel.

## Changements

- Collecte USB serial PX4 avec sélection, file persistante par appareil, pause,
  annulation, reprise explicite et analyse optionnelle des fichiers vérifiés.
- Consultation et ajout de logs d’autres appareils pendant les transferts GCS,
  sans concurrence sur le même UUID.
- Deux distributions natives macOS 15+ : Apple Silicon et Intel, chacune avec
  son moteur Python autonome et son flux Sparkle signé.
- README réécrit, guide USB et setup Paradev pour les workspaces.

Parseur **1.4.1**, projection SQLite **8** et identité stable de l’app conservés.
Les notes, favoris, clients, analyses et sources existantes restent compatibles.

## Contrôles du protocole

Les tests utilisent les encodeurs MAVLink officiels v1 et v2, un simulateur
indépendant et un pseudo-terminal macOS avec de vraies lectures/écritures serial.
Ils couvrent pertes, doublons, désordre, CRC erronés, autres émetteurs, absence de
heartbeat, identité modifiée, log modifié, espace disque, annulation et fermeture.

La campagne de stress copie exactement **3 145 772 octets** malgré **2 453 offsets
perdus**, dont **669 redemandés trois fois**. Le SHA-256 est identique à la source.
Ces valeurs décrivent un scénario simulé, pas un débit USB matériel mesuré.

L’audit des sources PX4/QGroundControl a conduit à négocier MAVLink 2 avant de
fixer l’UID2, conserver l’état LOG_* entre inventaire et données, puis vider le
port après LOG_REQUEST_END avant sa fermeture. L’UID et les métadonnées du log sont
revérifiés après le transfert avant publication locale.

## Distribution

La qualification native des architectures, les rapports du moteur embarqué,
les tickets de notarisation et les hashes publics sont consignés à la livraison.
La CI ad hoc seule ne constitue pas une distribution signée et notarisée.
Le plan détaillé et les contrôles requis figurent dans
[PLAN-USB-INTEL-RELEASE](PLAN-USB-INTEL-RELEASE.md) et [RELEASING](RELEASING.md).

## Limites

Aucun AquaDrone physique ni câble USB réel n’a été utilisé pour cette qualification.
Les tests ne confirment pas le firmware installé, son exposition USB/MAVLink ou le
débit de sa carte SD. Un Mac Intel hébergé qualifie l’exécution native du logiciel ;
il ne remplace pas un essai USB physique sur chaque modèle de Mac.
