# Collecte USB direct

Disponible dans la section **USB direct** de **Collecte GCS**, en complément de
la collecte réseau. Un contrôleur PX4 doit exposer MAVLink et le service de logs
sur son port USB serial. La présence d’un connecteur USB ne suffit pas à prouver
que le firmware y expose ce service.

## Utilisation

1. Brancher l’appareil désarmé avec un câble USB de données.
2. Libérer le port dans QGroundControl ou toute autre application serial.
3. Choisir le dossier de collecte et le client destinataire dans les options.
4. Cliquer **Actualiser les ports**, sélectionner le port, puis **Lire les logs**.
   Le baud par défaut est 115200 ; les interfaces USB CDC peuvent l’ignorer.
5. Cocher les logs et **Ajouter à la file**. Les fichiers vérifiés sont analysés
   si l’option d’analyse automatique est active.

Chaque demande conserve l’identité du contrôleur, le log, sa taille et sa date,
le dossier et le client au moment de l’ajout. Un autre contrôleur sur le même port
ou avec le même system ID MAVLink ne peut pas satisfaire cette demande.

## Plusieurs appareils

Avec un seul câble, **Pause après ce fichier** laisse finir la copie active.
Brancher les appareils successivement, lire leurs logs et préparer leurs demandes.
Puis rebrancher un appareil, relire ses logs et **Reprendre cet appareil**.
Les autres demandes restent en attente. Les sélections d’un inventaire déjà lu
peuvent être ajoutées pendant la copie ; la lecture d’un nouveau port attend
la fermeture de la session serial active.

La file est conservée dans `usb-collection.json`, incluse dans les sauvegardes.
Au redémarrage, elle reste en pause. **Arrêter** interrompt la copie courante et
attend la fermeture du port avant une nouvelle session. Après une déconnexion,
rebrancher l’appareil, actualiser les ports, relire l’inventaire et reprendre.
Un téléchargement USB incomplet recommence depuis zéro ; les copies déjà vérifiées
peuvent être réutilisées. Les originaux restent sur la carte SD.

## Vérifications et limites

- Un heartbeat PX4 récent et désarmé est requis ; un port déjà occupé est refusé.
- MAVLink 2 est négocié lorsqu’annoncé par l’autopilote pour stabiliser son UID2.
  Les appareils réellement limités à MAVLink 1 utilisent leur UID64 non nul.
- L’identité et les métadonnées du log sont relues avant et après la copie.
- Les blocs manquants sont redemandés ; une copie partielle n’est pas finalisée.
- Taille, signature ULog et SHA-256 local sont contrôlés avant la finalisation du
  fichier et de son manifeste. Le SHA local ne remplace pas une empreinte distante
  que ce protocole ne fournit pas.
- Un fichier existant dépourvu de preuve valide est conservé et signalé.
- Aucune commande de pilotage, effacement de log ou changement de paramètre n’est envoyée.

Les tests simulent de vraies trames serial, erreurs, annulations et changements de
contrôleur. Ils ne qualifient ni le câble, ni le pilote, ni le firmware Aqua installé.
Aucun débit réel n’est annoncé. L’USB évite le réseau ; le débit reste limité par
le firmware, la carte SD et le service MAVLink de l’appareil.

## Dépannage

| Message ou situation | Vérification |
| --- | --- |
| Aucun port | Câble de données, alimentation du contrôleur, reconnexion USB, puis actualisation. |
| Port occupé | Déconnecter le véhicule dans QGroundControl et fermer les autres clients serial. |
| Aucun autopilote PX4 | Vérifier que le bon port expose MAVLink et le firmware attendu. |
| Appareil armé ou heartbeat expiré | Désarmer et rétablir la liaison avant de relire les logs. |
| Identité ou log modifié | Relire l’inventaire de l’appareil voulu ; ne pas réutiliser une demande pour un autre contrôleur. |
| Blocs manquants / interruption | Rebrancher et reprendre ; le fichier incomplet repart de zéro. |
| Format non ULog | Les anciens `.px4log` listés par certains firmwares ne sont pas pris en charge. |

## Banc sans matériel

Le banc ouvre uniquement un pseudo-terminal du système et génère deux ULogs
synthétiques. Il ne découvre ni n’ouvre un port USB physique.

```sh
.venv/bin/python tools/bench-usb-serial.py \
  --output reports/usb-serial-bench --log-mib 1.25 \
  --rate-kib 256 --drop-every 257 --noise-hz 2
```

`connection.json` indique le port `/dev/ttys…`, les fichiers et leurs SHA-256.
`control.json` permet d’injecter une coupure, de changer d’identité ou de suspendre
les données. Pour exposer ce port de test à l’app, définir `KATALOG_USB_BENCH_PORT`
avec ce chemin exact avant son lancement. Il apparaît comme **Banc serial simulé**.
Le collecteur effectue les mêmes contrôles que pour un port physique.

Utiliser une bibliothèque isolée selon [CONTRIBUTING](../CONTRIBUTING.md).
Les rapports et fichiers du banc restent dans `reports/`, hors Git.

```sh
.venv/bin/python -m unittest \
  Tests.test_usb_collect Tests.test_usb_collect_stress Tests.test_usb_serial_bench
```
