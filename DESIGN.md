# KataLog — direction UI

App macOS locale pour une flotte PX4. Direction validée : bento noir et blanc,
surfaces gris neutre, accents discrets réservés aux états et aux graphiques.

## Référence visuelle et évolution clients

La composition de la version 0.5.2 reste la référence demandée : sidebar compacte,
barre supérieure discrète, bande de compteurs commune et bento asymétrique.
Les parcours 0.6 s’intègrent à cette composition et partagent exactement sa palette.
La Vue d’ensemble est l’écran d’accueil. Historique conserve sa navigation paginée ;
les indicateurs et le radar couvrent toujours toute la sélection.

Le bouton soleil/lune bascule directement entre clair et sombre. Le choix
Système est dans les réglages. Une préférence absente ouvre le thème sombre ; les choix
explicites existants sont conservés et enregistrés dans la bibliothèque.
Les actions n'ont ni cadre ni fond permanent ; survol et focus les soulignent.
Les filtres restent accessibles dans le header. Le sélecteur de clients remplace
les vues enregistrées dans la barre supérieure. Le [contrat clients](docs/CLIENTS-BENTO.md)
définit les périmètres, les destinations d'import et les réinitialisations.

Recette avant release : inspecter chaque écran en clair et sombre, les fenêtres
900×620 et la Vue d’ensemble à 1440×980 ; vérifier les données globales, l’ouverture
des groupes, la persistance du thème et les actions au clavier. La recette visuelle
de la Preview fait partie des portes de sortie de 0.6.0.

## Parcours

Vue d'ensemble → groupe d'alertes → inspecteur des preuves. Drones et historique
donnent accès aux fiches de logs ; Carte situe les enregistrements disposant de GPS.
Collecte GCS alimente la même bibliothèque locale. Les nombres proviennent des
fichiers importés : les corpus de recette ne préremplissent pas l'app et ne qualifient pas une flotte de 500 drones.

## Composition de la vue d'ensemble

- Sidebar compacte : marque monochrome, Vue d'ensemble, Carte, Drones, Alertes,
  Rapports et Collecte GCS ; état de la bibliothèque locale en bas.
- Barre supérieure discrète : source, thème clair/sombre, filtre drone lorsque
  pertinent et action d'import.
- Titre « Vue d'ensemble » et période disponible dans les enregistrements.
- Bande de couverture : drones identifiés, nombre de logs, durée enregistrée et
  logs avec alertes. La durée enregistrée n'est pas assimilée au temps de vol.
- Bento asymétrique : panneau « À examiner » alimenté par les groupes d'alertes,
  radar à droite avec légende chiffrée.
- Cartes « Alertes repérées » et « Activité récente » alignées en hauteur,
  avec défilement interne et accès « Tout voir ». Ouvrir une fiche et
  révéler le fichier dans le Finder sont deux actions distinctes.

## Radar

Les axes correspondent aux familles d'alertes présentes dans les logs du périmètre
drone sélectionné. Unité : nombre de logs concernés ; maximum : nombre de logs
valides de ce périmètre. Une famille compte une fois par log, même si le message
se répète. Les axes peuvent se recouper. Sous trois familles, des barres remplacent
le radar ; l'absence d'alerte produit un état vide explicite. Aucun zéro de santé
n'est inventé pour un domaine non analysé. Le radar indique les signaux repérés,
pas un score de santé.

## Alertes

Table + inspecteur latéral. Recherche dans titre/famille/message brut, sévérité
et famille ; réinitialisation. Sélection toujours parmi les résultats filtrés.
États vides explicites. Gravité issue du log ou qualification proposée, jamais
confondue avec une panne confirmée. Le détail comprend source, messages et contexte.
Ne pas exposer des contrôles qui prétendent appliquer des filtres non implémentés.

## Carte

Apple Maps s'ouvre depuis la sidebar. Recherche de logs et filtre drone limitent le
périmètre ; les **80 logs géolocalisés les plus récents** de ce périmètre sont
dessinés, avec **256 points maximum par log**. Cette limite est affichée et la liste
permet toujours d'ouvrir les autres fiches. Plan/satellite, zoom, compas, échelle et
recentrage restent des contrôles MapKit natifs.

Une recherche distincte accepte ville, adresse ou coordonnées et un rayon.
Elle vérifie la trajectoire complète avant la limite d'affichage : une portion
traversant la zone suffit. Les trajectoires complètes indisponibles sont annoncées.

Les trajectoires sont séparées aux lacunes et aux échantillons GPS invalides.
Les segments d'un point ont un repère isolé ; aucune liaison n'est inventée.
Les marqueurs d'alertes utilisent les positions réelles présentes dans les
résumés à partir du parseur **1.1.1**. L'état sans trajectoire affichable explique
la couverture disponible. Les anciennes analyses proposent **Actualiser les
analyses**, qui relit les copies locales sans téléchargement GCS.

Les coordonnées viennent des ULog. L'app ne demande pas la localisation du Mac ;
les tuiles Apple nécessitent un accès réseau. La recette de tuiles indisponibles
hors connexion reste à faire.

## Fiche de log

Une fenêtre macOS indépendante, déplaçable et redimensionnable, charge les détails
à la demande depuis le cache SQLite
`flight_details`. Un état de chargement, une erreur avec nouvel essai et la source
restent visibles. Les détails déjà calculés sont consultables si l'original manque.
Rouvrir le même log remet sa fenêtre au premier plan. Les événements PX4 et les
données techniques sont accessibles en mode avancé, désactivé par défaut.

- **Vue du log** : carte bornée à 4 096 points et chronologie des alertes. Le clic
  sur un message positionnable place le curseur sur un échantillon réel à deux
  secondes au plus, dans le même segment ; aucune interpolation dans une lacune.
- **Messages** : textes source, recherche, niveau et famille, avec état vide.
- **Mesures** : valeurs, unités et méthodes disponibles. Pas de graphique annoncé
  sans série temporelle extraite.
- **Paramètres** : inventaire initial filtrable et changements horodatés séparés.
- **Topics** : instances, nombre d'échantillons et champs. Une unité absente reste
  inconnue ; elle n'est pas déduite du nom du champ.
- **Couverture** : limites, erreurs, provenance et SHA256 ; accès Finder séparé.

L'export distingue **Rapport HTML · messages et mesures** et **Données de la fiche
(JSON)**. Ce JSON contient les données de la fiche, dont GPS borné, paramètres et
topics ; il ne prétend pas contenir toutes les séries brutes de l'ULog. Les filtres
persistants, le décodage des événements binaires et les graphiques de télémétrie
restent au plan de développement.

## Style

Typographie système sobre, titres 28–32 px, texte UI 13–14 px, labels 11–12 px.
Chiffres normaux sans zéros initiaux. Cartes rayon 16–18, bordures 1 px peu contrastées.
Surfaces sombres #0B0B0B/#111111/#191919 ; surfaces claires #F7F7F5/#EEEEEC/#FFFFFF.
Texte sombre #F3F3F1, clair #171717 ; secondaire #A4A4A4/#666666.
Vert limité au radar/état local, ambre avertissements, rouge failsafe.
Actions principales blanc sur noir ou noir sur blanc. Pas de décoration colorée.

## Périmètre

App native fonctionnelle et maquettes visuelles. L’import de dossier et la collecte
GCS alimentent la bibliothèque avec des fichiers réels. La collecte suit la
composition validée : réseau et options en haut, flotte,
inventaire et file de transfert ; palette monochrome et accents d’état discrets.
Les maquettes basées sur des logs privés sont conservées localement, hors du
futur dépôt public. Tout nouvel aperçu public doit provenir de fixtures synthétiques.

## Collecte GCS — depuis la version 0.3.0 (build 3)

L’évolution conserve cette composition bento et les deux thèmes. Les actions
principales **Tout collecter** et **Arrêter** restent visibles en haut de l’écran.
**Tout collecter** concerne les drones actuellement connectés à la GCS ; les
nouveaux appareils sont inscrits automatiquement. Les appareils explicitement armés
sont exclus. La sélection manuelle
de logs reste accessible par drone.

Une carte **Progression globale** présente le lot courant : pourcentage, volume,
fichiers vérifiés, attentes et échecs, avec l’indication **2 drones maximum en
transfert**. La file conserve une ligne par fichier, un transfert actif par UUID
et les états de nouvel essai, arrêt et interruption. Un transfert achevé reste
en vérification/analyse jusqu’à la validation effective du fichier.

- **Mettre en pause** laisse finir les fichiers actifs ; **Reprendre** réactive la file.
- **Arrêter** interrompt immédiatement les opérations locales et conserve les
  fichiers vérifiés. Le texte associé précise que la GCS peut finir un transfert
  déjà lancé ; aucune confirmation d’arrêt distant n’est inventée.
- **Relancer** remet en file les fichiers arrêtés, interrompus ou en échec.
  Les erreurs transitoires disposent de trois tentatives automatiques au total,
  après 5 puis 15 secondes et l’éventuelle attente d’une session distante.
- Les logs dont le manifeste et le SHA256 sont valides apparaissent déjà présents,
  même après changement d’adresse GCS ou restauration d’une ancienne file.
  Lorsqu’aucun fichier n’est à télécharger, la carte affiche **À jour** et le
  nombre de logs déjà vérifiés, sans progression vide `0 / 0`.
- Les erreurs permanentes et les inventaires manquants restent visibles ; un lot
  terminé avec des échecs ne prend pas l’apparence d’un succès complet.

Le délai client de 300 à 3 600 secondes indique une temporisation avant nouvelle
tentative, pas une preuve d’arrêt du transfert distant. Une fin de session reçue libère cette
attente. La validation 0.3 comprend 46 tests Python et 28 tests Swift. La recette
réelle du 29 septembre, entre 18 h 15 et 18 h 20 CEST, confirme dans l’app Release
installée la collecte de flotte, l’arrêt de deux actifs et d’un fichier en attente,
la reprise de deux UUID en parallèle et quatre fichiers reconnus après redémarrage
sans nouveau téléchargement. Les réessais après erreur réseau restent testés en
simulation ; aucune capacité de collecte de 500 drones n’est annoncée comme validée.

La version 0.4 conserve cette interface et corrige la reprise après changement
d'adresse, l'analyse des copies déjà présentes et la publication ULog/manifeste
interrompue. La bibliothèque relit aussi les imports validés dans SQLite après
annulation. Voir [l'audit et les suites prévues](docs/AUDIT-2026-09-29.md).

## Ajouts 0.5

L’icône du bundle reprend `square.stack.3d.up.fill`, noir sur tuile claire ;
`tools/render-app-icon.swift` produit les tailles natives et le fichier ICNS.

Les actions d’identification sont proches du drone : registre GCS, fiche et liste
flotte. Le numéro est édité dans une sheet courte avec identité source, annulation,
enregistrement et retrait. Les erreurs d’enregistrement restent visibles.

Dans l’inspecteur de message, l’explication est concise, avec vérifications et
limites en disclosure, provenance et liens de référence. La classification manuelle
est distincte et réversible. Les familles ajoutées apparaissent dans les filtres
et statistiques ; le radar garde un ordre stable et offre toutes les valeurs.

Le dossier de collecte affiche son chemin, sa persistance et son indisponibilité
éventuelle. L’information sur les copies déclenchées par le navigateur GCS est
placée près de la destination, où elle permet une décision utile.


## Rapport HTML — version 0.5.1

Le document exporté reprend le monochrome et les accents sobres de l’app :
navigation par sections, titre éditorial, quatre indicateurs, deux graphiques,
groupes de messages puis historique et traçabilité. Les surfaces bento et les
thèmes clair/sombre restent lisibles dans une fenêtre étroite ; les tableaux
disposent de leur propre défilement horizontal lorsque nécessaire.

La synthèse annonce le périmètre réellement affiché. Les filtres drone, famille,
niveau, recherche et période se combinent ; **Réinitialiser** retrouve tout le
contenu exporté. Les états sans résultat donnent une explication, pas un score de
santé nul. Une identité conserve son UUID même si plusieurs drones ont le même numéro.

Le profil des alertes utilise un radar de **3 à 8 familles**. Pour une, deux ou
plus de huit familles, des barres montrent toutes les valeurs, dans un ordre
alphabétique stable. Un point du radar, sa légende ou une barre active le filtre
famille. L’unité reste le nombre de logs concernés, une fois par famille et par
log ; les domaines peuvent se recouper. Les interactions sont aussi accessibles
au clavier.

La chronologie compare tous les fichiers aux logs avec alertes. Elle agrège par
jour, mois ou année pour conserver une lecture simple. Une colonne filtre la
période correspondante ; le bandeau rappelle cette sélection. Les dates inconnues
restent visibles séparément. Aucun fuseau horaire n’est attribué aux dates de chemin.

Les groupes de messages se déplient sur les explications, les limites et les
sources. Les liens ouvrent directement le log concerné dans l’historique. Chaque
log conserve son nom source, son numéro manuel, ses métadonnées, mesures, couverture
et messages bruts. **Déplier les logs visibles** facilite la lecture détaillée.

**Imprimer / PDF** conserve les filtres actifs, leur rappel et les graphiques,
déplie les détails visibles et retire les contrôles interactifs. L’impression
revient au thème clair ; à sa fermeture, les états dépliés/repliés de l’écran sont
restaurés. Pour imprimer toute la bibliothèque exportée, réinitialiser les filtres.

Le fichier fonctionne hors ligne : aucun CDN, police distante ou connexion GCS
n’est requis. Sans JavaScript, le contenu source reste consultable et les contrôles
indisponibles sont masqués. Les liens PX4 ne sollicitent le réseau que si le lecteur
les ouvre. La recette du rapport est suivie dans [UI-VALIDATION.md](docs/UI-VALIDATION.md).
