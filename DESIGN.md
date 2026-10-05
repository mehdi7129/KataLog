# KataLog — direction UI 0.8.1

Contrat de l’interface **0.8.1 (build 20)**, publiée le 5 octobre 2026.
App macOS locale pour une flotte PX4 : Bento monochrome, surfaces gris neutre,
accents discrets réservés aux états et aux graphiques. La qualification de cette
version est suivie dans la [recette de release](docs/RELEASE-0.8.1.md).

## Espace de travail

Sidebar compacte, barre supérieure discrète, bande de compteurs commune et Bento
asymétrique. La Vue d’ensemble est l’écran d’accueil. La bibliothèque regroupe
Vue d’ensemble, Historique, Alertes, Carte et Drones ; les outils regroupent
Collecte GCS, Stockage, Rapports et Réglages. L’accès aux sources locales et l’état
lecture seule restent visibles dans la sidebar.

Le sélecteur de clients définit le périmètre : tous les clients, un client nommé
ou les logs sans client. L’import et la collecte précisent leur destinataire ;
un changement de sélection ne réattribue pas un log existant. Les filtres de
dates, drones, messages et qualité de lecture restent accessibles dans le header.
Les filtres persistants, vues enregistrées et masquages réversibles sont livrés.
Le [contrat clients](docs/CLIENTS-BENTO.md) précise les attributions, les rapports
et les opérations globales de stockage.

Le bouton soleil/lune bascule directement entre clair et sombre. Le choix
Système est dans les réglages. Une préférence absente ouvre le thème sombre ;
les choix explicites sont conservés dans la bibliothèque.

Les actions utilisent un style discret sans cadre ni fond permanent. Le survol,
l’appui et le focus clavier rendent leur état visible. Les actions indisponibles
donnent une explication dans leur contexte. L’actualisation dépend de l’écran :
elle actualise l’aperçu dans Rapports et n’apparaît pas dans Réglages.

Un retour sur un onglet restaure ses résultats encore valides. Une actualisation
du même périmètre garde son contenu visible ; un changement de périmètre annonce
la nouvelle lecture. Le cache de navigation est invalidé par les mutations et
les modifications externes de la bibliothèque.

## Vue d’ensemble et alertes

Les quatre indicateurs présentent **Drones scannés**, **Logs enregistrés**,
**Temps de vol cumulé** et **Avec alerte** sur toute la sélection, indépendamment
de la page d’historique. Le temps de vol tient sur une ligne en minutes, puis son
intitulé ; méthode et couverture restent dans l’aide. Une durée absente affiche
« Indisponible ». La durée enregistrée inclut le sol et reste distincte du temps
de vol. Les copies de même contenu ne multiplient pas les compteurs.

Le Bento associe le panneau « À examiner », le profil des alertes et l’activité
récente. Les cartes Alertes et Activité gardent des hauteurs alignées, un
défilement interne et l’accès « Tout voir ». L’activité récente indique sa portée
sur les logs datés de la page courante. Ouvrir une fiche et révéler sa source
dans le Finder sont deux actions distinctes.

Le radar compte les logs concernés par famille, une fois par log même si un
message se répète. Ses axes peuvent se recouper. Jusqu’à huit axes sont
personnalisables ; le choix automatique prend les huit premières familles par
ordre alphabétique. La liste complète des familles reste disponible, triée par
nombre de logs concernés. Sous trois axes, des barres remplacent le radar ;
l’absence d’alerte donne un état vide explicite. Un domaine non analysé ne reçoit
pas de score de santé inventé.

La vue Alertes associe liste et inspecteur des preuves. Recherche, famille,
niveau et réinitialisation portent sur les messages du périmètre. L’inspecteur
conserve le texte source, l’explication, les vérifications possibles et leurs
limites. La classification manuelle est distincte et réversible. La gravité
observée n’est pas présentée comme une panne matérielle confirmée.

## Carte

La vue générale représente **tous les logs géolocalisés du périmètre** par des
marqueurs compacts issus d’échantillons enregistrés. Les repères proches sont
regroupés par MapKit ; leur sélection permet d’accéder aux logs concernés. Les
pages de chargement sont bornées à 5 000 marqueurs et 4 Mio, puis réunies pour
l’affichage. La trajectoire détaillée se charge à l’ouverture d’un log.

Client, dates, drones et filtres de messages s’appliquent avant comptage et
pagination. Le cadrage et le mode plan/satellite sont conservés entre les
onglets. Zoom, compas, échelle et recentrage utilisent les contrôles MapKit.

Une recherche distincte accepte ville, adresse ou coordonnées et un rayon.
Elle vérifie les trajectoires complètes : une portion valide traversant la zone
suffit. Le marqueur est l’échantillon enregistré le plus proche du lieu ; il
peut être hors du rayon lorsqu’un segment traverse la zone entre deux points.
Les trajectoires non vérifiables sont annoncées. Aucune liaison n’est créée à
travers une lacune GPS.

Les coordonnées viennent des ULog ; aucune localisation du Mac n’est demandée.
Les tuiles et la recherche de noms de lieux Apple dépendent du réseau. Les logs
sans position restent accessibles dans l’historique.

## Fiche de log et accès avancé

Chaque fiche possède une fenêtre macOS indépendante, déplaçable et redimensionnable,
avec son propre état de lecture. Rouvrir le même log remet sa fenêtre au premier
plan. Les détails se chargent à la demande ; chargement, erreurs, nouvel essai et
provenance sont explicites. Une analyse déjà conservée reste consultable si
l’original manque, avec indication de sa version et de ses limites.

Les onglets usuels sont **Synthèse**, **Messages** et **Courbes**. La carte du log
est bornée à **4 096 points** ; lacunes et échantillons invalides séparent les
segments. Un message positionnable utilise un échantillon réel à deux secondes
au plus, dans un segment valide. Les courbes Batterie, GNSS et EKF sont extraites
à la demande depuis une source vérifiée ; unités, données manquantes et limites
d’échantillonnage sont annoncées.

**Réglages → Accès avancé**, désactivé par défaut, donne accès aux événements PX4
et aux données techniques. Dans la fiche, le menu **Plus** regroupe Événements,
Mesures, Paramètres, Topics, Couverture et Révisions. Le choix d’un champ libre
de télémétrie appartient également à ce mode. Le décodage des événements exige
le dictionnaire exact du log ; sans correspondance, les enregistrements bruts et
l’absence de traduction restent visibles.

Les paramètres initiaux et leurs changements horodatés restent distincts. Les
topics annoncent instances, nombre d’échantillons et champs ; les unités absentes
restent inconnues. Les révisions permettent de consulter les analyses conservées.
Le JSON d’une fiche contient ses détails disponibles et leur couverture ; il ne
constitue pas une copie complète des séries brutes de l’ULog.

## Collecte GCS

La collecte conserve la composition Bento : réseau et options en haut, flotte,
inventaire et file de transfert. **Tout collecter** et **Arrêter** restent visibles.
Les nouveaux appareils éligibles connectés sont inscrits à la flotte ; les
appareils explicitement armés sont exclus. La sélection manuelle de logs reste
accessible par drone. Chaque travail conserve son client destinataire.

La progression distingue drone → GCS, GCS → Mac, vérification et analyse. Deux
transferts réseau sont autorisés sur des drones distincts, avec un seul transfert
FTP par UUID. Une file séparée analyse les fichiers vérifiés avec un worker ; au
plus quatre fichiers sont simultanément en transfert, en analyse ou en attente
d’analyse. La fin du transfert ne signifie pas encore que l’analyse est terminée.

**Mettre en pause** laisse finir les transferts actifs et les analyses de fichiers
déjà vérifiés. **Reprendre** réactive les transferts en attente. **Arrêter** annule
les opérations locales en conservant les fichiers vérifiés ; une copie déjà
demandée peut encore finir sur la GCS. **Relancer** remet en file les travaux
arrêtés, interrompus ou en échec. Les erreurs et inventaires manquants restent
visibles ; un lot incomplet ne prend pas l’apparence d’un succès complet.

Le dossier choisi affiche son chemin et son éventuelle indisponibilité. Les
copies avec manifeste et SHA256 valides sont reconnues après redémarrage. Une
erreur d’analyse conserve la copie vérifiée. Le [contrat de collecte](docs/GCS-COLLECTION.md)
précise les réessais, l’arrêt local et les copies supplémentaires du navigateur GCS.

## Style et accessibilité

Typographie système sobre : titres 28–32 pt, textes UI 13–14 pt, labels 11–12 pt.
Les compteurs n’ajoutent pas de zéros initiaux ; les numéros de stock conservent
la saisie de l’utilisateur. Les tokens partagés fixent rayon des cartes à 18 pt,
rayon des boutons à 12 pt, padding des cartes à 24 pt, espacement à 18 pt et
sidebar à 230 pt.

| Palette | Sombre | Claire |
| --- | --- | --- |
| Fond / sidebar / carte | `#0B0B0B` / `#111111` / `#191919` | `#F7F7F5` / `#EEEEEC` / `#FFFFFF` |
| Texte principal | `#F3F3F1` | `#1B1B1B` |
| Texte secondaire | `#A4A4A0` | `#71716D` |

Vert discret pour profil/états, ambre pour avertissements, rouge pour états
critiques et actions destructives. Les icônes partagent un dessin et une taille
cohérents. Survol, focus, libellés accessibles et aides complètent la couleur.
Les dialogues conservent annulation et retour d’erreur ; les actions globales de
réinitialisation précisent leur portée sur tous les clients et demandent confirmation.

## Rapports HTML et impression

Le rapport reprend le monochrome, les accents sobres, les surfaces Bento et les
thèmes clair/sombre. Les tableaux disposent de leur propre défilement horizontal
dans une fenêtre étroite. Le document annonce son périmètre, sa date de capture,
sa révision et ses exclusions. Ses indicateurs distinguent durée enregistrée et
temps de vol cumulé, avec la couverture du temps de vol. Le rapport complet couvre
tous les logs du client sélectionné ; « Tous les clients » couvre la bibliothèque
entière.

Les filtres du rapport (drone, famille, niveau, texte et période) se combinent.
**Réinitialiser** retrouve tout le contenu exporté. Le radar représente trois à
huit familles ; des barres montrent les autres cas, dans un ordre alphabétique
stable. Cliquer un axe, sa légende ou une barre filtre la famille. Chaque log
compte une fois par famille ; ces valeurs ne s’additionnent pas en un nombre
d’incidents. Les interactions sont également accessibles au clavier.

La chronologie regroupe par jour, mois ou année ; une colonne filtre la période.
Les dates inconnues restent séparées et aucun fuseau n’est inventé pour les dates
issues des chemins. Les groupes donnent accès aux explications et aux logs.
Le mode de partage retire les informations privées selon les exclusions annoncées.

**Imprimer / PDF** conserve le périmètre filtré et les graphiques, déplie les
détails visibles et retire les contrôles. L’impression utilise le thème clair ;
les états de lecture sont restaurés ensuite. Le HTML fonctionne hors ligne sans
CDN ni police distante ; les liens documentaires ne sollicitent le réseau que
sur action du lecteur. Pour un rapport volumineux, une synthèse accompagnée des
données et d’un manifeste remplace le document massif sans tronquer les données.

## Vérification et références

Avant release, inspecter chaque écran en clair et sombre, les fenêtres 900×620
et la Vue d’ensemble à 1440×980 : compteurs, filtres, groupes, persistance du thème,
retour sur la carte, états vides et actions au clavier. Les aperçus publics
utilisent exclusivement des données synthétiques ; captures opérationnelles et
bibliothèques privées restent hors du dépôt.

Les preuves datées sont conservées dans l’[audit UX de la Preview 0.8.1](docs/UX-AUDIT-0.8.1.md),
les [mesures carte/navigation/collecte](docs/PERFORMANCE-MAP-NAVIGATION.md) et les
[recettes historiques de l’interface](docs/UI-VALIDATION.md). Les comportements
de stockage et de lecture sont définis dans le [contrat courant](docs/IMPORT-CONTRACT.md).
