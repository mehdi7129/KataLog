# Améliorations du suivi des logs

Évolutions proposées après la **0.8.5**, dans une PR distincte du suivi GCS
[#41](https://github.com/mehdi7129/KataLog/pull/41). Aucune nouvelle release
n'est publiée par cette PR. Le fonctionnement de la collecte Aqua en 0.8.5 a
été confirmé après les mises à jour des firmwares GCS et drone.

## Parcours

| Fonction | Utilisation |
| --- | --- |
| Filtres favoris | Le menu **Favoris** enregistre les filtres courants, puis les applique ou les supprime. Le client est conservé. Un client supprimé est signalé ; un client encore en chargement n'est pas considéré comme supprimé. |
| Comparaison | Dans **Historique**, cocher exactement deux logs, puis **Comparer**. La fenêtre présente firmware et écarts entre les valeurs finales des paramètres typés, avec recherche et inversion A/B. Les logs doivent avoir la même identité de contrôleur établie. |
| Notes personnelles | Ajouter ou modifier une note datée dans **Synthèse** d'un log ou depuis le registre des drones. Une note concerne un log, l'autre son drone. Une modification concurrente est signalée avant écrasement. |
| Espace de collecte | Le collecteur vérifie le volume de destination avant le réseau, puis avant la copie HTTP. Un manque d'espace est signalé sans relance automatique inutile. |
| Dernière sauvegarde | La page de stockage affiche la date de création de la dernière sauvegarde vérifiée, sa couverture et les nouveaux logs depuis celle-ci. Le compteur compare les identités de contenu, même si des logs ont été retirés entre-temps. |
| Couverture des exports | Le HTML interactif, la synthèse des gros rapports, le JSON et le manifeste décrivent les mêmes détails disponibles ou absents. Un champ disponible pour certains logs peut aussi être absent pour d'autres. |

## Conservation et limites

- Les notes et favoris restent locaux et sont inclus dans les sauvegardes.
  Les notes figurent dans les exports privés ; le partage anonymisé les retire
  de toutes les pièces. Les ULogs originaux restent inchangés.
- Les annotations existantes restent lisibles. Les nouvelles notes sont des
  champs additionnels du même format, avec une limite de 4 000 caractères.
- La comparaison utilise les détails disponibles ou la source locale vérifiée.
  Une extraction absente reste inconnue. Un écart n'établit pas une cause de panne.
- Le contrôle d'espace estime les octets restant à écrire, une marge de 16 Mio
  et les besoins des autres transferts actifs. Un cache vérifié ne nécessite
  pas une seconde copie. Un partiel validé ne réduit le besoin que pour ses
  octets déjà alloués. Le budget peut être surestimé pour plusieurs volumes ;
  les écritures d'autres applications restent susceptibles de remplir le disque.
- Le suivi de sauvegarde commence avec cette version. Les anciennes archives
  restent restaurables. Une restauration réussie enregistre l'archive réellement
  restaurée. Le suivi ne vérifie pas la présence actuelle du fichier et son
  compteur de nouveaux logs ne mesure pas les modifications de notes/réglages.
  Une erreur d'enregistrement du suivi n'annule pas une sauvegarde déjà vérifiée.

## Validation attendue avant intégration

- Persistance des favoris, application en lecture seule, client absent ou encore
  en chargement ; comparaison annulée, détails absents et identités distinctes.
- Notes : sauvegarde/restauration, conflits d'édition, compatibilité des anciennes
  annotations, échappement HTML et absence dans toutes les pièces partagées.
- Collecte : cache, reprise HTTP partielle, transferts concurrents, disque plein
  avant réseau et pendant la copie, conservation des fichiers vérifiés.
- Sauvegarde : échec sans mise à jour de date, archive restaurée correcte,
  compteur par identité, historique absent ou illisible.
- Exports : couverture complète, partielle, résumée et vide ; concordance entre
  les pièces ; rendu natif clair et sombre avec des données synthétiques.

Les résultats exécutés sont consignés dans la PR. Ces contrôles locaux ne
remplacent pas la qualification d'un futur package ni celle d'une flotte réelle.
