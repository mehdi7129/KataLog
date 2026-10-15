# Catalogue de référence PX4 — 15 octobre 2026

`catalogue.json` contient **208 fiches**, **275 patterns ancrés**, leurs exemples positifs et les liens vers le code officiel. **206 fiches** documentent le sens upstream ; **2 fiches** (`ekf-start-3d-mag` et `gps-rtcm-instance-switch`) restent explicitement des interprétations : leur formulation exacte est présente dans les logs constructeur mais pas dans le snapshot officiel étudié.

## Sources et traçabilité

Référence principale : [PX4 v1.14.0](https://github.com/PX4/PX4-Autopilot/tree/b8c541dd7277ed735139d7d1bfb829d61fbe29fb), commit `b8c541dd7277ed735139d7d1bfb829d61fbe29fb`. Le tag annoté et sa cible ont été lus avec `git ls-remote`. L’archive officielle [codeload](https://codeload.github.com/PX4/PX4-Autopilot/tar.gz/refs/tags/v1.14.0) a pour SHA-256 `351ad0b641772f4a62ffacc3f8ea19b714609a0408c280c3c6746920e73c0681`.

**49 fichiers source officiels distincts ont été vérifiés** : chaque fiche vérifie la présence du texte ou de la fonction dont elle dépend, et référence des lignes du commit immuable. Les 49 URLs raw ont été relues par HTTP : **49 réponses 200 et 49 SHA-256 identiques au snapshot téléchargé**. `source-manifest.json` liste les fichiers et leurs empreintes ; `source-verification.json` contient le résultat de cette vérification. Le code source tiers reste hors du dépôt, sous `/tmp/PX4-Autopilot-1.14.0`.

Recherches Web complémentaires sur les sources officielles : [configuration des failsafes v1.14](https://docs.px4.io/v1.14/en/config/safety), [fonctionnement et réglage de l’EKF v1.14](https://docs.px4.io/v1.14/en/advanced_config/tuning_the_ecl_ekf), [contrôles avant vol v1.15](https://docs.px4.io/v1.15/en/flying/pre_flight_checks). Les détails opérationnels des fiches s’appuient sur le code épinglé, sans reprendre les seuils d’une autre version.

« Documenté » signifie **sens démontré dans PX4 upstream**, jamais « définition du firmware Drotek confirmée ». Les hashes et branches lightshow/geo des logs locaux ne sont pas assimilés à ce commit officiel. Chaque fiche porte cette limite dans `referenceFirmware` et `provenance`.

## Conclusions à préserver à l’intégration

- `GPS emergency yaw reset` est un réalignement de secours du **cap** sur l’estimateur GPS/IMU EKFGSF. Ce texte ne signifie pas un redémarrage du GPS ou une perte de fix. Il peut entraîner ensuite un recalage de vitesse et position.
- `Motor failure detected` rapporte le flag du détecteur de défaillance. Dans cette référence, une télémétrie ESC disparue ou un courant insuffisant par rapport à la commande peuvent le produire. Le texte ne démontre pas qu’un moteur est physiquement cassé.
- `Compass needs calibration - Land now!` correspond à `cs_mag_fault` ; le code demande d’atterrir/recalibrer mais ne démontre pas que la calibration a causé le défaut.
- `Crash dumps present on SD` constate des fichiers `fault_*.log`. Ils peuvent provenir d’un crash antérieur : une répétition du message n’est pas la preuve d’un nouveau crash.
- `High Accelerometer Bias` contrôle dans la référence **75 % de la limite plus 3 sigma d’incertitude**, axe par axe. Ne pas réutiliser ici les anciens seuils documentés pour d’autres versions.
- `Accel … inconsistent` avertit dès **80 %** de `COM_ARM_IMU_ACC`, tandis que `Gyro … inconsistent` avertit dès **50 %** de `COM_ARM_IMU_GYR`. Dans le code de référence, le blocage d’armement est demandé au-delà du seuil complet.
- Les messages `Preflight Fail` peuvent aussi être émis pendant que le drone est armé. Leur préfixe ne suffit pas à conclure « événement au sol ».
- `Failsafe activated` peut accompagner même une action **Warn** dans ce code. La ligne seule ne donne ni le motif ni l’action précise ; le module réellement observé est `failsafe`.
- Les offsets `ACC`/`GYRO … offset committed` sont des corrections apprises appliquées par le module IMU. Leur ligne est émise **avant** le résultat de sauvegarde des paramètres : elle ne garantit pas leur persistance après redémarrage.
- Les phases RTL, consignes d’altitude et transitions d’atterrissage décrivent une **décision du logiciel** ; leur réalisation physique doit être lue dans les données du vol.
- `GPS jamming detected` transmet une détection ou suspicion du récepteur. Le code d’état et l’indicateur sont conservés bruts ; l’interface n’attribue aucune unité physique à `jamming_indicator`. Ce message ne démontre ni brouilleur externe ni intention.
- `RTCM : Switching to instance` est interprété comme une sélection de source de corrections : l’architecture upstream sélectionne une instance `gps_inject_data`. La formulation exacte constructeur est introuvable dans ce snapshot ; le numéro n’est pas assimilé à un récepteur, une antenne ou une base identifiée.

## Couverture mesurée

Sur le corpus anonymisé conservé en privé, cette seule contribution explique **5 892 occurrences** : **2 863 occurrences d’alertes et 3 029 occurrences informatives**, soit **343 variantes anonymisées**. Aucun message de ce corpus ne correspond à plusieurs fiches PX4. Tous les messages présents du corpus sont couverts pour les modules `ekf2`, `health_and_arming_checks`, `vehicle_imu`, `logger`, `load_mon` et `mixer_module`. Les messages propres au constructeur sont traités dans l’autre catalogue.

`coverage.json` conserve ces mesures. Ce chiffre mesure le corpus disponible, pas tous les futurs messages possibles, et ne doit pas être additionné à la couverture constructeur sans vérifier les recouvrements.

## Reproduction

Le JSON relu constitue la source éditable du catalogue. `python3 tools/generate-alert-catalogue.py --check` vérifie les IDs, références, regex, exemples synthétiques et la cohérence du Swift et de la fixture publique. Les scripts ponctuels de construction initiale restent dans les archives privées de recherche.

Les patterns comprennent le module et le message complet, avec une liste fermée de variantes textuelles et des valeurs numériques paramétrées. Le moteur de l’application doit retirer les espaces/tabulations de début et fin comme le faisait déjà `AlertKnowledge`, puis appliquer les patterns en insensible à la casse. Aucun mot-clé de famille ne permet de déduire un diagnostic causal.
