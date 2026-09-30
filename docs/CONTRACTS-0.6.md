# Contrats KataLog 0.6

Statut : implémentation et qualification en cours. Ces contrats sont indépendants de la version 0.5.2 installée.

## Versions et compatibilité

| Format | Version | Règle |
|---|---:|---|
| Snapshot JSON | 1 | Champs nouveaux optionnels ; une version future est refusée |
| Bibliothèque canonique SQLite | 1 | Résumés, sources et détails conservés ; projections dérivées reconstruisibles |
| Projections / requête | 7 / 1 | Révision du contenu, empreinte du scope et curseur liés ; page de 1 à 200 entrées et réponse bornée à 4 Mio |
| Protocole helper / GCS | 1 | Handshake de versions ; inventaires en pages identifiées ; compatibilité avec un inventaire ancien borné |
| File GCS SQLite / réglages | 1 / 1 | Migration transactionnelle ; JSON ancien conservé ; actifs interrompus au restart |
| Analyse | 1.4.0 | Détails antérieurs restent lisibles sans source et sont signalés |
| Révisions d’analyse | 1 | Résumé et détail immuables, SHA du payload vérifié, capture datée |
| Observations GCS | 1 | Autorisation sans date inventée, dernière télémétrie reçue datée |
| Backup / vues / événements / séries | 1 | Hashes et limites vérifiés ; inconnus conservés |
| Rapport | 1 | Scope, révision, sections disponibles et exclusions annoncés |

Une mise à jour du parseur ne transforme pas une analyse ancienne en analyse courante. Le log est identifié par son SHA256 ; une source modifiée ne remplace pas silencieusement le contenu historique.

## Identité, source et date

- L'identité du contrôleur provient du ULog, ou d'une liaison GCS vérifiée. Le numéro de stock est une annotation ; deux numéros égaux ne fusionnent jamais deux contrôleurs.
- La clé de numéro est `gcs:<UUID>` lorsqu'une preuve univoque existe ; sinon `ulog:<identité source>`. Résumé, fiche et rapport utilisent la même identité canonique.
- Une carte SD, un contrôleur et un drone physique sont des notions distinctes. L'association datée de plusieurs contrôleurs à un drone physique reste un futur workflow.
- La provenance comprend tous les chemins connus. Disponibilité : present, missing, offline, inaccessible, modified ou unknown, avec date de contrôle. L'absence d'une source conserve l'historique.
- La liste globale des sources d’import est indépendante de la page de logs et de leur provenance. Retirer/restaurer un root modifie sa visibilité persistante, conserve les fichiers et analyses, et invalide les curseurs. Un nouvel import explicite réactive une source retirée.
- Une date GPS est UTC. Une date tirée d'un chemin reste un jour du calendrier sans fuseau inventé. Les dates inconnues sont incluses par défaut et disposent d'une option explicite.

## Mesures et comptages

| Mesure | Définition |
|---|---|
| Message | Une occurrence textuelle source, avec niveau et timestamp |
| Événement | Une occurrence binaire distincte ; aucune fusion heuristique avec un texte |
| Groupe | Occurrences d'un message normalisé ; les variantes brutes restent accessibles |
| Log | Un contenu SHA unique ; ses copies ne multiplient pas les mesures |
| Drones scannés | Identités de contrôleurs distinctes observées dans les logs sélectionnés ; les identités provisoires sans identifiant fiable sont comptées séparément |
| Log avec alerte | Log valide contenant un texte d'alerte visible ou un état failsafe observé sans filtre de message |
| Famille du profil | Nombre de logs valides uniques contenant un texte d'alerte de cette famille |
| Durée enregistrée | Étendue observée du log, incluant le sol |
| Durée en vol | Durée qualifiée seulement avec couverture suffisante du détecteur ; portion observée et couverture restent séparées |
| Temps de vol cumulé | Somme des temps qualifiés finis et non négatifs des logs lisibles sélectionnés ; zéro mesuré reste zéro, une absence reste indisponible ; couverture N / M logs |
| Badge du log | Gravité maximale observée des messages, événements PX4 et failsafe dans le périmètre ; critique / erreur / avertissement / aucune alerte détectée / indéterminé, sans diagnostic de panne |
| RTK fixé | Pourcentage sur la durée observée d'un récepteur identifié ; jamais concaténation implicite de récepteurs |
| Failsafe | État réellement observé ; aucune occurrence textuelle créée pour remplir un filtre |

Une famille ou un niveau de sévérité ne constitue pas un diagnostic de panne. Les familles n'étant pas exclusives, leur somme peut dépasser le nombre de logs.

Le compteur « Avec alerte » conserve le périmètre messages textuels/failsafe.
Les événements binaires restent évalués dans les badges ; leur niveau connu est
conservé même sans traduction. La lecture du fichier et la gravité du signal
sont indépendantes. Un failsafe sans niveau textuel ne reçoit aucun niveau
CRITICAL inventé. Les filtres de messages excluent les événements et l’état
failsafe de leur badge ; masquer un texte ne masque pas les événements bruts.
Les aides et libellés communs sont définis dans `LibraryHelp` et `LogAssessment`.

## Périmètre commun

`SelectionScope` comprend identités multiples, bornes calendrier inclusives, dates inconnues, familles, niveaux, alertes, recherche de messages, recherche de fichiers, statuts de lecture et inclusion des masqués. Les recherches de la bibliothèque tolèrent espaces, casse et accents ; elles traitent %, _ et apostrophes comme du texte.

| Surface | Périmètre |
|---|---|
| Dashboard / historique / groupes / carte | Scope courant, agrégats sur tous les résultats |
| Registre | Toute la flotte ; recherche propre, identités sans log incluses |
| Fiche | Un log SHA, détail chargé à la demande |
| Rapport sélection | Scope et annotations capturés à une même révision |
| Rapport complet | Toute la bibliothèque capturée ; masquages explicités |
| Collecte | Flotte GCS autorisée ; indépendant des filtres d'analyse |

Un filtre famille, niveau ou texte requiert une occurrence correspondante. Un failsafe sans texte ne fabrique pas cette correspondance. Reset remet un scope vide et retrouve la sélection complète. Une famille active devenue vide reste visible et réinitialisable.

Les masquages utilisent une clé de texte/niveau normalisés `text-v1:`, gardent les occurrences originales, et sont réversibles. Une vue enregistrée inclut le scope, sans copier les logs.

## Coordination et conservation

Un verrou OS sur un inode stable réserve le writer. Une deuxième instance lit mais ne collecte, ne migre ni ne modifie les annotations. Les helpers mutateurs héritent du même verrou via stdin ; si le parent disparaît, ils le retiennent jusqu’à leur sortie. Un PID inscrit seul n'est pas une preuve de verrou actif. La restauration garde le dossier et l'inode du verrou en place. L’arrêt normal ferme le lancement de nouveaux helpers et attend la fin des processus possédés après annulation bornée.

| Opération | Coordination |
|---|---|
| Import / index | Un writer ; commits courts, source originale en lecture |
| Fiche / pages | Lecture bornée ; révision et token rejettent une réponse périmée |
| Annotations / vues | Écriture atomique, fichier externe modifié signalé comme conflit |
| Backup / restore / archive | Writer réservé ; opérations actives terminées ou arrêtées avant la maintenance |
| Export | Capture cohérente sous maintenance, génération indépendante après capture, publication atomique |
| Update | Installation différée tant qu'import, collecte, export ou maintenance est actif |
| Découverte GCS | La découverte seule ne bloque pas indéfiniment une opération exclusive |

Backup analyses/réglages : DB via API SQLite backup et configurations versionnées. Backup complet : ajoute les ULog disponibles SHA vérifiés, avec liste explicite des sources absentes. Aucun secret du Trousseau n'est exporté. La restauration valide ZIP, chemins, tailles, SHA, schémas et intégrité SQLite avant bascule ; l'ancien état et un journal de récupération sont conservés. Les collectes restaurées ne redémarrent pas automatiquement.

Le preflight de backup vérifie l’espace du volume de destination avant toute capture. Son estimation conservatrice couvre le staging, l’archive, les sources disponibles et une réserve ; elle annonce les sources absentes. Un ENOSPC ultérieur ne remplace pas une archive déjà publiée.

Les révisions retiennent séparément résumé et détail, sous SHA exact et version de parseur. La date est celle de capture, jamais une date de vol inventée. Le budget global est de 512 Mio compressés, avec refus avant remplacement si la rétention ne tient plus. La dernière analyse exploitable reste lisible après retrait de la source et nettoyage des caches. La comparaison de paramètres conserve valeurs et types ; absence d’extraction et changement de contrôleur empêchent un diff trompeur. Une différence de paramètres ou de firmware ne prouve pas une cause matérielle.

## GCS

Deux UUID maximum en parallèle ; une opération FTP par UUID. Destination persistante explicite, sans fallback silencieux vers Téléchargements. Progression séparée : inventaire, drone→GCS, GCS→Mac, vérification, analyse, terminé. 100 % de transfert drone n'est pas 100 % de copie Mac. Un inventaire manquant empêche le verdict complet.

Les pages d'inventaire portent un ID, un index et une fin avec totals. Trames de 256 éléments maximum, bornées en octets ; doublons, ordre incorrect, fin absente ou totals incohérents sont refusés. Le stockage charge tous les travaux actifs et 200 terminaux récents ; l'historique complet reste paginé dans SQLite.

Arrêt local : file arrêtée, helper possédé interrompu puis terminé après délai de grâce si nécessaire. Cela ne prouve pas l'annulation d'un FTP déjà en cours sur la GCS. Les UUID encore occupés restent temporairement bloqués. Les erreurs permanentes ne sont pas retentées automatiquement.

Le registre inclut les identités GCS autorisées sans log et sans numéro de stock. `lastGCSDate` vient uniquement d’une télémétrie reçue ; charger le registre ou autoriser un UUID ne crée pas de présence. `sourceCheckedAt` date le contrôle enregistré d’un chemin, sans annoncer sa disponibilité actuelle. Révision de bibliothèque et empreinte des observations lient les pages du registre ; une observation nouvelle invalide un curseur ancien.

## Événements et séries

Le dictionnaire doit correspondre exactement au SHA du log. Dans PX4, `metadata_events_sha256` identifie l'artefact compressé ; les octets compressés sont vérifiés avant décompression bornée. Aucun dictionnaire master n'est choisi implicitement. [Référence PX4](https://github.com/PX4/PX4-Autopilot/blob/v1.14.0/src/modules/logger/logger.cpp)

Les messages normaux et avec tag conservent leur source, index, timestamp et niveau brut ; le tag est un champ distinct. Les interruptions de journalisation conservent durée et timestamp associé par pyulog au dernier échantillon de données : cette précision est annoncée. Les paramètres initiaux et changements gardent leur valeur typée Python décodée et la valeur précédente disponible, sans prétendre retrouver un type ULog que pyulog n’expose pas. Les détails batterie/GNSS sont séparés par instance, avec unités connues ou explicitement inconnues ; un numéro de pack n’est jamais une identité de drone.

ID, arguments, séquence, instance, niveaux interne/externe et timestamp brut des événements sont conservés. Un timestamp invalide est null, sans faux zéro. Les uint64 des métadonnées ne passent pas par Double. Les états du dictionnaire/traduction sont exposés : ready/translated, missing, incompatible, unknown ou invalid.

La commande `event-dictionary` importe uniquement un artefact local XZ de 4 Mio maximum, décompressé à 16 Mio maximum. La bibliothèque le conserve sous son SHA et l’inclut dans les backups. Une fiche compatible est recalculée à l’ouverture si sa source vérifiée est accessible ; sinon son ancien cache brut reste disponible. La requête `events` annonce séparément les fiches en cache, absentes, anciennes et invalides. Un total de zéro dans les caches n’est jamais présenté comme une absence d’événements dans toute la flotte. Les filtres interne/externe sont distincts des filtres de messages textuels.

La requête `catalogue` liste les familles et niveaux de toute la bibliothèque, y compris les familles uniquement INFO et les niveaux RAW/UNKNOWN. Elle est paginée à 200 entrées ; le sélecteur natif accumule au maximum 8 192 valeurs et conserve les filtres déjà sélectionnés.

Le catalogue énumère les champs réellement présents, leur type, instance, unité et source de conversion documentée. Les courbes sont extraites à la demande, pour une fenêtre explicite. Quatre courbes partagent au maximum 2 048 points ; min/max, transitions et frontières de segments sont préservés lorsque le budget le permet. Pertes de transitions/extrema/segments sont comptées et annoncées.

NaN, timestamps inversés/égaux, sentinelles documentées et lacunes séparent les segments. Aucune courbe ne relie silencieusement un trou. Les valeurs inconnues restent inconnues. Le curseur utilise un échantillon réel ; hors du segment GPS ou trop loin d'une mesure, la position est indisponible.

## Rapport et partage

Le rapport n'est pas une copie ULog complète. Il annonce scope, date de capture, révision, compte total, données disponibles et absentes. HTML interactif cible 10 Mio ; au-delà, une synthèse accompagnée de données intégrales et d'un manifeste SHA remplace le document massif, sans tronquer silencieusement.

Un rapport interne conserve la traçabilité. Le mode partagé conservateur retire textes et métadonnées brutes dès qu'une exclusion privée est demandée : ces champs libres peuvent contenir une identité, un chemin ou une coordonnée. Les exclusions effectives et la réduction sont annoncées avant export. Le diagnostic par défaut contient seulement versions, OS, états d'opérations et comptes agrégés autorisés.

## Limites de qualification

Les tests synthétiques ne qualifient pas 500 drones physiques, un firmware constructeur sans dictionnaire exact, macOS 15 sur matériel ou une collecte réelle. La recette macOS 27, le grand index, le corpus privé local, les navigateurs et les mises à jour possèdent des preuves séparées.
