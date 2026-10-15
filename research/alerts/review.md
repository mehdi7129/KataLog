# Contre-audit des explications — 15 octobre 2026

**Résultat : aucun finding bloquant restant dans le périmètre vérifié.** Une règle logger trop large a été corrigée par son auteur, puis contrôlée indépendamment. La revue ne vaut pas attestation du code exact des firmwares constructeur et ne remplace pas un essai de l’application distribuée.

## Mesure indépendante du catalogue final

La mesure relit directement les trois JSON de recherche, compile chaque regex en mode insensible à la casse et applique un match complet au texte dont seuls les blancs externes sont retirés. Elle ne réutilise pas les chiffres du générateur. La comparaison porte sur les 1 507 variantes anonymisées représentant 1 840 variantes sources et 12 906 occurrences.

| Mesure | Résultat |
|---|---:|
| Fiches | 321 : 208 PX4, 110 constructeur, 3 marine |
| Patterns complets | 388 |
| Fiches avec niveau `documented` | 209 |
| Fiches avec niveau `interpretation` | 112 |
| Occurrences avec fiche spécifique | 12 904 / 12 906 |
| Variantes sources avec fiche spécifique | 1 838 / 1 840 |
| Occurrences d’alerte avec fiche spécifique | 5 500 / 5 500 |
| Variantes sources d’alerte avec fiche spécifique | 531 / 531 |
| Occurrences avec fiche documentée | 6 054 tous niveaux, dont 2 866 alertes |
| Occurrences avec interprétation prudente | 6 850 tous niveaux, dont 2 634 alertes |
| Chevauchements entre fiches dans le corpus | 0 |

Les deux textes sans définition spécifique sont des nombres sans intitulé émis par `dance`, chacun présent une fois au niveau `INFO`. La valeur seule n’identifie ni une grandeur ni une unité : conserver `context` est correct. Ils ne sont pas comptés comme explications spécifiques ou documentées.

Un suffixe ` [negated]`, puis une seconde ligne `not actually`, ont été ajoutés indépendamment à chacun des 1 505 textes anonymisés reconnus : les **3 010 variantes négatives** sont toutes rejetées. Les exemples positifs PX4 ont également été relus par les regex et ne présentent ni rejet ni chevauchement. Les huit adresses IPv6 du corpus ont été remplacées par des adresses de documentation déterministes dans `2001:db8::/32`, sans fusion de lignes ni changement des compteurs ; la mesure et les 3 010 variantes négatives ont été revérifiées ensuite. Le test Swift de couverture, exécuté séparément par l’intégrateur, vérifie la même couche avec `NSRegularExpression` ; cette contre-mesure Python ne se substitue pas à ce contrôle Foundation.

## Relecture primaire des messages prioritaires

Les sources upstream ont été relues dans l’archive PX4 v1.14.0 associée au commit `b8c541dd7277ed735139d7d1bfb829d61fbe29fb`. Les SHA-256 des **49 fichiers** du manifest final ont été recalculés indépendamment et concordent tous avec les fichiers locaux.

| Fiche | Contrôle indépendant | Conclusion |
|---|---|---|
| `gps-emergency-yaw-reset` | `gps_control.cpp` : test de divergence du cap, état en vol, timeout de fusion de vitesse, succès du reset de secours | La fiche décrit une récupération d’estimation, sans prétendre à un redémarrage du GPS ni à une cause matérielle. |
| `gyro-clipping`, `accel-clipping` | `VehicleIMU.cpp` : compteurs d’écrêtage, notification récurrente, description d’événement demandant d’atterrir et de vérifier le montage | Saturation et consigne sont sourcées. Les indices restent des instances logicielles ; la fiche ne transforme pas le message en diagnostic de capteur défectueux. |
| `motor-failure-detected` | `failureDetectorCheck.cpp` : flag `FAILURE_MOTOR` ; `FailureDetector.cpp` : télémétrie ESC périmée et sous-courant relatif à la commande | Les conditions de référence sont établies. Les limites évitent de conclure à un moteur matériellement hors service ou à un événement forcément au sol. |
| `crash-dumps-present` | `sdcardCheck.cpp` : recherche de `fault_*.log`, dépendance à `COM_ARM_HFLT_CHK` | La présence d’une trace historique est distinguée d’un nouveau crash lors de chaque répétition. |
| `compass-calibration-land` | `estimatorCheck.cpp` : flag `cs_mag_fault`, événement d’arrêt d’utilisation du compas, demande de calibration | La demande de calibration n’est pas présentée comme preuve que la calibration était la cause initiale. |
| `esc-offline` | `escCheck.cpp` : masque des ESC en ligne et liste des fonctions moteur manquantes | Plusieurs ESC sont reconnus ; absence de télémétrie et arrêt physique du moteur restent distincts. |

Les fiches documentées constructeur `dance-battery-rtl-disabled` et `dance-geocage-horizontal` ont été vérifiées dans le manuel local IO Star 3 MUE v1.2, aux pages imprimées 177 et 178. Le SHA-256 du PDF concorde avec `documentReference` : `cec5819536db3dc3f7f23821262b93d5b11cbb2f2c86bf0a17ba63c4ce890597`. La première table décrit l’inhibition RTL/Land pour les failsafes batterie près de la fin du show. La seconde décrit une détection horizontale de flyaway à partir du GNSS et des autres capteurs ; cette source n’établit pas un seuil géométrique précis. Aucun PDF ni extrait documentaire brut n’est ajouté aux artefacts de cette contre-revue.

## Finding corrigé : notification de chemin logger

Le pattern initial de `logger-file-name-notification` acceptait tout texte après le double préfixe logger. Il attribuait ainsi une annonce de fichier documentée à des textes tels que `[logger] [logger] write failed` ou `[logger] [logger] no log file created`. Le token de chemin des fiches concernées a été resserré pour exiger une extension finale `.ulg` ou `.ulgc`, tout en acceptant le placeholder `<path>` du corpus anonymisé.

Contre-vérification après correction : les deux faux messages précédents, `Opened full log file: false` et un chemin suivi de `: false` sont rejetés. Les chemins absolus/relatifs finissant par `.ulg`, les fichiers chiffrés `.ulgc` et le placeholder anonymisé sont reconnus. Les règles clipping et multi-ESC rejettent également les suffixes négatifs et les ajouts multilignes.

## Niveaux de preuve et formulations

La revue des textes constructeur et marine n’a pas trouvé de code numérique transformé sans preuve en cause précise. Points particulièrement utiles :

- `is ok 0/1` reste un suffixe constructeur non assimilé à `MAV_RESULT` ou à un accusé de réussite ; le niveau `ERROR` ne dicte pas le sens de cette ligne.
- `XBee link recovered` décrit une récupération, même lorsque le firmware l’enregistre en `WARNING`.
- Les codes Torqeedo 50 et 54 restent explicitement non résolus. Le rapprochement du code 48 avec la température de charge n’atteste pas le modèle ni la passerelle du matériel observé.
- Une tentative d’association, un timeout, une perte de liaison et sa récupération ne deviennent ni une panne matérielle, ni une preuve de coupure de tous les canaux.
- Les messages de températures manquantes sont distingués des températures trop élevées. Les seuils IO Star de référence ne sont pas généralisés aux Aqua Drones.
- Les transitions et commandes de show restent des annonces logicielles ; elles ne prouvent pas à elles seules un déplacement terminé, une coupure moteur ou un événement pyro physique.

Le catalogue peut expliquer un texte upstream sans connaître la branche exacte Drotek. Cette limite demeure visible dans `provenance`, `referenceFirmware` et les limites des fiches. La sémantique détaillée des cinq priorités ci-dessus a reçu une relecture de code indépendante ; la revue n’affirme pas une lecture ligne par ligne des 321 implémentations possibles sur les firmwares propriétaires.

## Intégration et fallback

`AlertKnowledge` n’utilise ni la famille manuelle ni le niveau pour inventer une définition. Le match est complet, après retrait des blancs externes, avec comparaison de la plage Foundation à celle du texte entier. Les regex sont compilées une fois par entrée. La connaissance est embarquée dans le module partagé app/CLI sans lecture réseau à l’exécution.

La confiance est désormais propre à chaque fiche. `isDocumented` n’est vrai que pour `documented`. Les fallbacks de module et de texte brut gardent l’ID `unknown`, n’affichent pas de firmware de référence supposé et précisent que la signification exacte n’est pas établie. Le contexte de module ne gonfle donc pas les chiffres de couverture spécifique.

La vue d’explication existante affiche le niveau de preuve, la version du catalogue, les limites et les liens. Le rapport HTML affiche également la confiance et la version pour les explications d’alerte ; ses chaînes et liens restent échappés. Le changement ne reclasse pas les messages et ne modifie ni leurs niveaux, ni leurs groupes, ni leurs occurrences. La revue du rendu est statique ; aucune installation ou vérification graphique de l’app livrée n’est revendiquée ici.

## Correction événement séparée

Le finding du dictionnaire XZ est détaillé dans `corpus/event-memory-limit.md`. La correction limitée à 65 MiB du décodeur conserve les budgets de 4 MiB compressés et 16 MiB décompressés, le binding exact SHA-256 et les rejets existants. Le test de régression utilise un petit catalogue libevents synthétique compressé avec un dictionnaire LZMA2 de 64 MiB : il prouve l’échec de l’ancien plafond, le chargement du nouveau et une traduction effective.

Après l’investigation initiale, le chercheur PX4 a également [validé la chaîne réelle](event-translation-validation.md) en mémoire avec le cache connu et le dictionnaire exact : **17/17 événements traduits, zéro erreur, 17 textes non vides, cinq descriptions et 50 arguments décodés**. Le résultat agrégé se trouve dans [event-translation-validation.json](event-translation-validation.json). Cette validation lit la bibliothèque et la source en lecture seule, sans les réimporter ni publier leurs textes ou arguments privés. Elle prouve la traduction technique, sans attester un diagnostic physique ou une mise à jour de l’app installée.

Validation effectuée par cet agent avec le runtime complet 0.8.6 : **16/16 tests `test_px4_events.py` et 15/15 tests `test_event_dictionary*.py` réussis**. Les bibliothèques utilisées par ces tests sont temporaires et synthétiques. Aucune application installée, bibliothèque active ou préférence utilisateur n’a été modifiée, et aucun lot de logs n’a été réimporté.

## Préparation de la publication

Les mesures ci-dessus décrivent l’audit local initial sur le corpus réel. Ce corpus, les fréquences par message et les preuves de firmware ont été conservés intégralement dans un dossier local ignoré et sont absents des sources publiques. La CI publique et les snapshots de packaging utilisent une fixture synthétique couvrant les 388 motifs ; le test du corpus réel est un gate local distinct, compilé uniquement sur demande. Les exemples publics et les sources du catalogue restent reproductibles sans accès à la bibliothèque privée.
