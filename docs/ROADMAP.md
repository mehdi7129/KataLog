# KataLog — roadmap

État au **9 octobre 2026**. Référence livrée : **0.8.3 (build 22)**,
[release stable publique](https://github.com/mehdi7129/KataLog/releases/tag/v0.8.3).
Les pistes ci-dessous ne constituent ni un calendrier ni une promesse de version.

## Corrections livrées en 0.8.3

Les 26 corrections de l’[audit du 8 octobre](AUDIT-QUALITE-2026-10-08.md) sont
assemblées : intégrité de l’import et de la restauration, cohérence des états,
réactivité de la collecte, indépendance des fenêtres et séparation des
responsabilités. La resélection du destinataire GCS courant ne provoque plus
d’erreur de stockage pendant la réconciliation. Les index des grandes files
en attente sont préparés hors du thread d’interface après sauvegarde, en
conservant les gardes de publication. La version **0.8.3 (build 22)** conserve
les parcours métier.

Les preuves de CI, de signature/notarisation, de parcours natif depuis le DMG et
de publication sont consignées dans la [recette 0.8.3](RELEASE-0.8.3.md). La
variabilité des premières requêtes du grand historique reste suivie : aucun
budget n’a été relevé pour faire passer les essais.

## Correctif livré en 0.8.2

Le build **21** corrige le budget des pages d’historique et rend la lecture des
clients indépendante, avec conservation du dernier résultat valide et nouvel
essai explicite. Il attend l’arrêt des lectures avant une maintenance de la
bibliothèque. Il conserve le parseur 1.4.0 et la projection SQLite 8.
La [recette 0.8.2](RELEASE-0.8.2.md) consigne les tests, les parcours natifs,
la distribution signée et notarisée ainsi que la vérification de la publication.

## Disponible en 0.8.3

KataLog est une app native SwiftUI/MapKit pour **macOS 15+ sur Apple Silicon**,
distribuée en DMG signé et notarisé, avec moteur Python embarqué.

- Bibliothèque locale ULog, déduplication SHA-256, index SQLite, historique paginé
  et agrégats sur l’ensemble du périmètre choisi.
- Clients locaux, attribution par log, numérotation manuelle des drones et
  familles d’alertes personnalisables.
- Archivage vérifié à l’import, sauvegarde/restauration, réassociation des sources
  et conservation des analyses antérieures.
- Messages texte, événements PX4 bruts et traduction avec dictionnaire exact,
  paramètres et courbes Batterie/GNSS/EKF selon les champs disponibles.
- Carte de tous les logs géolocalisés, regroupement des repères, recherche par
  proximité et fenêtres macOS indépendantes par log.
- Rapports HTML autonomes, export JSON, sélection et périmètre client explicites.
- Collecte Drotek avec file durable, deux drones en parallèle, analyse des fichiers
  vérifiés pendant la collecte et reprise manuelle après arrêt.
- Interface clair/sombre/système, mode avancé et diagnostic local prévisualisé.
- Mises à jour stables signées depuis l’app à partir de 0.7.0, recherche automatique
  facultative et installation choisie par l’utilisateur.
- Dépôt public sous GPL-3.0-only, fixtures synthétiques, sources correspondantes
  aux releases et CI autonome.

Les nouveautés, les migrations et les résultats de qualification
figurent dans la [recette de release](RELEASE-0.8.3.md) et le
[changelog](../CHANGELOG.md).

## Qualification et limites encore ouvertes

| Sujet | État actuel | Travail restant |
| --- | --- | --- |
| macOS 15 | Minimum déclaré ; CI et contrôles du package | Recette physique complète de l’app sur macOS 15 |
| Mise à jour 0.8.2 → 0.8.3 | Banc SDK 5/5 sur macOS 15 et 27 ; app signée/notarisée et neuf contrôles de distribution réussis ; parcours natif et contrôles publics détaillés dans la recette | Recette Sparkle réelle entre ces versions dans une autre session macOS |
| Collecte physique | Protocole Drotek 3.7.2 testé avec deux drones ; gain 0.8.1 mesuré sur simulateur | Débit, stabilité et reprise à mesurer sur une flotte réelle plus importante |
| Arrêt distant | Arrêt local et fichiers vérifiés conservés | Commande d’abandon FTP distant et reprise à un offset réseau non confirmées |
| Grands historiques | Banc final 50 000 logs réussi : huit requêtes sous 500 ms, maxima dashboard 356,05 ms et registre 372,78 ms ; dépassements des premières lectures conservés dans les résultats historiques. Helper embarqué local : première lecture historique en 1,044 s, répétition en 0,489 s | Profilage de la variabilité CI, parsing massif et mesures des parcours complets avec rendu dans l’app |
| Maintenance CI | Jobs réussis ; cinq avertissements liés aux actions épinglées pour Node 20 exécutées sous Node 24 par GitHub | Actualiser les actions épinglées après validation de leur compatibilité |
| Explications d’alertes | Messages source conservés, observations et interprétations distinguées | Affiner provenance constructeur et applicabilité selon le firmware |

Ces limites ne sont pas effacées par des tests unitaires ou un benchmark
synthétique. Voir les [mesures de performance](PERFORMANCE-MAP-NAVIGATION.md),
le [banc 500 identités](BENCHMARK-500.md) et le
[contrat GCS](GCS-COLLECTION.md).

## Pistes à étudier

- Associer explicitement plusieurs contrôleurs à un drone physique, avec dates
  et preuves, sans fusion implicite des identités.
- Journal de maintenance et comparaison avant/après.
- Tendances avec durée, couverture et dénominateurs visibles.
- Sélecteur de séries plus large, IMU/ESC et analyses complémentaires.
- Davantage de transferts parallèles après qualification réseau et matérielle.

Aucune de ces pistes n’est annoncée pour une version déterminée. La priorité
dépendra des besoins constatés et des validations disponibles.

## Historique de planification

Le [plan 0.6.0](PLAN-0.6.0.md), son [backlog](BACKLOG-0.6.0.md) et son
[suivi d’implémentation](IMPLEMENTATION-0.6.0.md) conservent les décisions et gates
de cette étape. Leurs formulations sur un dépôt privé, des écrans en Preview ou
un feed désactivé décrivent leur contexte historique. Pour l’état courant,
consulter le [guide de documentation](README.md) et la release stable ci-dessus.
