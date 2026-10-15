# Recherche constructeur et messages de show — 15 octobre 2026

110 fiches dans `catalogue.json`, avec expressions régulières ancrées, explication, contrôles, limites, provenance et référence de firmware. Ce catalogue est une contribution au catalogue principal ; il ne modifie pas l’analyse ULog ou l’interface.

## Méthode et résultat vérifié

- Lecture des messages réels anonymisés, tous niveaux compris, fournis par l’inventaire de la bibliothèque.
- Lecture des quatre explications existantes et de la classification Python. Les IDs déjà utilisés sont conservés pour SMBus, perte Wi-Fi et protection LED.
- Recherche exacte sur le Web des textes constructeur, des modules Wi-Fi, maestro, dance et rf_switch ; aucun code source public correspondant à ces textes n’a été trouvé dans les sources inspectées. Cela n’établit pas l’absence universelle de source.
- Vérification des sources primaires PX4 v1.14.0, MAVLink, NuttX et des dépôts publics Drotek. Le compte GitHub Drotek inspecté contient six anciens dépôts de documentation/hardware ; le dépôt softwares ne donne pas le code lightshow de cette génération.
- Consultation en lecture seule du manuel IO Star 3 MUE v1.2 et du changelog FMU 3.6.2–3.4.14 déjà présents localement. Les pages du manuel citées pour l’éclairage et la table de messages ont été rendues et relues visuellement. Seuls le titre, les pages et l’empreinte SHA256 sont conservés, sans redistribuer le PDF, ses images, son texte complet ou ses données de configuration.
- Validation des 110 regex : zéro ambiguïté interne sur le corpus. Après trim des blancs extérieurs, les règles couvrent 6 995 occurrences / 1 156 textes anonymisés distincts (tous sous-systèmes de cette contribution compris). `coverage.json` donne les détails. Ce n’est pas la couverture globale de l’app : les autres agents traitent les autres familles.

## Définitions étayées par le manuel constructeur

- Page 177 : « RTL disabled, … ms until end of show » concerne l’inhibition RTL/Land des failsafes batterie près de la fin du show. Ne pas le présenter comme la désactivation de toutes les protections. Référence strictement IO Star 3 / édition du manuel.
- Page 178 : « Geocage horizontal EKF/GNSS violation! » décrit une détection de dérive ou de fuite horizontale (flyaway) fondée sur le GNSS et les autres capteurs utilisés par l’EKF. Le message ne suffit pas à établir le franchissement d’une frontière géométrique ; le critère et le seuil ne sont pas fournis.
- Page 20 : la protection LED coupe au-delà de 90 °C et autorise le retour sous 70 °C pour l’IO Star 3 de cette édition. Les messages LED eux-mêmes ne donnent pas ces seuils ; ils restent une interprétation du texte avec référence documentaire et restriction de version, sans appliquer ces valeurs aux Aqua Drones.
- Page 30 : Wi-Fi et XBee sont deux liaisons distinctes. La perte du Wi-Fi ne prouve donc pas la perte de tous les canaux ou du RTCM. Aucune temporisation du manuel n’est injectée comme seuil universel dans les fiches.

## Précautions sémantiques retenues

- Les codes SMBus −1/−5/−22 restent des retours de pilote non décodés. Aucun errno ou défaut de pack précis n’est inventé.
- `wapi_scan_stat()` public traite EAGAIN comme un état non prêt, mais les implémentations consultées ne correspondent pas exactement au −11 du log Drotek. La fiche décrit l’échec de récupération de résultat et conserve cette divergence.
- La commande MAVLink 246 est documentée (reboot/shutdown). Le suffixe constructeur `is ok 1` n’est pas un résultat COMMAND_ACK démontré : ne pas le convertir en succès, échec ou MAV_RESULT=1.
- Les commandes 45000/45008, codes numériques de contrôle du show et type de paquet constructeur restent explicitement non décodés.
- `Replacement` est relié par le texte à un repositionnement vers un temps de show. Ce n’est pas une preuve de remplacement d’un drone par un autre.
- Les violations de vitesse GPS/Local indiquent le critère violé et la valeur ; ni seuil, ni cause, ni action automatique ne sont inventés.
- `remaining battery_time nan(s)` représente une estimation numérique indisponible. Le texte `less than` ne permet pas de transformer NaN en autonomie insuffisante calculée.
- Réception d’une commande, changement d’état, envoi CAN et événement pyro logiciel ne prouvent pas un mouvement, une coupure électrique, une réception matérielle ou une mise à feu.
- Deux messages `[dance]` ne contiennent qu’un nombre : ils restent au contexte de module dans l’app, sans inventer la grandeur ni l’unité. Les erreurs Torqeedo sont traitées par l’agent principal.

## Sources publiques primaires consultées

- [Pilote batterie SMBus PX4 v1.14.0](https://github.com/PX4/PX4-Autopilot/blob/v1.14.0/src/drivers/batt_smbus/batt_smbus.cpp)
- [Transitions d’armement PX4 v1.14.0](https://github.com/PX4/PX4-Autopilot/blob/v1.14.0/src/modules/commander/Arming/ArmStateMachine/ArmStateMachine.hpp)
- [Shell MAVLink PX4 v1.14.0](https://github.com/PX4/PX4-Autopilot/blob/v1.14.0/src/modules/mavlink/mavlink_shell.cpp)
- [MAVLink common](https://mavlink.io/en/messages/common.html)
- [MAVLink commandes](https://mavlink.io/en/services/command.html)
- [NuttX WAPI](https://github.com/apache/nuttx-apps/blob/master/wireless/wapi/src/wireless.c)
- [NuttX errno](https://github.com/apache/nuttx/blob/master/include/errno.h)
- [Dépôts publics Drotek](https://github.com/drotek)
- [Documentation publique Drotek](https://docs.drotek.com/)

`evidence/source-manifest.json` identifie les documents constructeur locaux sans en redistribuer le contenu.
