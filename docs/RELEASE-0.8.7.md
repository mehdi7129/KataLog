# KataLog 0.8.7 — recette de release

Version **0.8.7**, build **26**, candidat du **15 octobre 2026**.
La qualification du candidat, de la distribution et du flux public est suivie
séparément. Le flux stable conserve 0.8.6 jusqu’à la vérification des archives.

## Changements

Le catalogue embarqué passe de **4 à 321 fiches**, couvrant messages PX4,
Drotek/show, batterie, éclairage, communications et périphériques marins.
Chaque fiche fournit sens, vérifications, limites, provenance et sources.
Les **209 définitions documentées** et **112 interprétations du texte** sont
identifiées séparément ; un module connu fournit un contexte lorsque la
définition précise manque. Aucun diagnostic causal n’est déduit de la famille
ou du niveau du message. Les rapports HTML affichent aussi ce niveau de preuve.

Les sources upstream sont épinglées et vérifiées ; leur correspondance au
firmware constructeur exact demeure explicitement non attestée. Voir la
[méthode et les références](../research/alerts/README.md). Les extraits de logs
réels, ventilations par firmware et preuves opérationnelles sont conservés
localement ; les tests publics utilisent des messages synthétiques.

Le décodeur XZ autorise **65 Mio** de mémoire pour un dictionnaire LZMA2 de
64 Mio et sa mémoire de gestion. Les plafonds **4 Mio compressés / 16 Mio
extraits**, la vérification SHA-256 et le rejet des flux invalides/concaténés
restent actifs. Une validation locale ciblée a traduit les **17 événements**
d’un dictionnaire embarqué exact, sans erreur ni modification de la bibliothèque.

## Compatibilité et données existantes

macOS **15 minimum**, **Apple Silicon**. Version du parseur **1.4.1**, projection
SQLite **8**, schémas de bibliothèque et d’annotations conservés.
Les nouvelles explications s’appliquent immédiatement aux messages déjà importés,
sans réimport ni téléchargement supplémentaire.

Les détails précédemment enregistrés avec le parseur 1.4.0 sont recalculés à
l’ouverture si leur source locale vérifiée est disponible. Leur ancienne
révision est conservée. Si la source est absente, l’ancien détail demeure
consultable et signalé comme ancien. Les anciens résumés ne sont pas recalculés
automatiquement et aucun réimport global n’est déclenché.

Messages, niveaux, familles personnalisées, groupes, occurrences, identités,
clients, favoris, notes, réglages et ULogs sont préservés.

## Contrôles du candidat

Les résultats finaux et les références CI seront consignés après exécution :

- génération du catalogue cohérente avec ses sources et fixtures synthétiques ;
- suites Swift, Python et JavaScript ;
- cache historique 1.4.0 invalide → détail 1.4.1 traduit depuis source vérifiée,
  et conservation du cache lorsque la source est absente ;
- signature Developer ID, notarisation, tickets et neuf contrôles de distribution ;
- copie depuis le DMG puis éjection, lancement dans une bibliothèque isolée,
  consultation des nouvelles explications et génération d’un rapport ;
- correspondance du tag, des sources et des archives publiées ;
- signatures Sparkle et contrôle anonyme du flux réellement servi.

Le matériel radio et le comportement en vol ne sont pas modifiés par cette
release. Les contrôles de messages et événements qualifient leur interprétation
logicielle ; ils ne constituent pas un diagnostic physique du véhicule.

## Publication

Le tag et les archives des versions précédentes restent immuables. La release
0.8.7 proposera le DMG, le ZIP de mise à jour, les sources du tag et le manifeste
SHA-256. Le flux build **26** sera préparé depuis le build **25** vérifié, puis
publié après les archives, et contrôlé séparément depuis son URL canonique.
