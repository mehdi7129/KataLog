# KataLog — roadmap

## Référence actuelle : 0.5.2 — distribution autonome

App native SwiftUI/MapKit pour macOS 15+ Apple Silicon. Import ULog par pyulog,
cache SQLite, déduplication SHA256, collecte GCS, identification manuelle,
classement des alertes et rapport HTML interactif sont livrés.

Les événements binaires et séries temporelles ne sont pas encore extraits.
Les détails sont chargés à la demande ; le snapshot global reste en mémoire.
Le moteur ARM64 est embarqué en 0.5.2 ; le DMG utilise le parcours macOS standard.
Les mises à jour restent manuelles. L’app est testée sur macOS 27 et annonce
macOS 15 minimum, avec contrôle des minima de tous les composants natifs.

L'[audit complet du 30 septembre](AUDIT-2026-09-30.md) vérifie l'existant,
les incohérences et les données ULog restant à exploiter. **175 tests réussis**
(87 Python, 79 Swift, 9 JavaScript) ; installation 0.5.2 (7) réussie sur macOS 27.
Ces preuves ne qualifient pas encore un grand historique, macOS 15 ou 500 drones physiques.

## Stabilisation intégrée aux sources 0.6

- Identité canonique conservée entre résumé, fiche, numéro manuel et export.
- Progression par phase et verdict honnête pour les inventaires GCS partiels.
- Comptes HTML filtrés, familles devenues vides et périmètres explicités.
- Indicateurs GNSS/durée qualifiés par récepteur et couverture.
- État minimal des sources et protection contre plusieurs exports simultanés.
- Dernière analyse conservée avant toute évolution du parseur/cache.

Ces corrections sont intégrées et testées dans les sources en préparation. Leur
recette est suivie dans [IMPLEMENTATION-0.6.0.md](IMPLEMENTATION-0.6.0.md) et le
[backlog](BACKLOG-0.6.0.md). L’app installée 0.5.2 n’est pas modifiée.

## Sources en préparation : 0.6.0

Le [plan détaillé](PLAN-0.6.0.md) précise les lots, dépendances et critères :

1. Contrats et corpus synthétique reproductible.
2. Installation autonome par DMG : socle réalisé en 0.5.2 ; recette macOS 15 et publication à compléter.
3. Sauvegarde/restauration et archives SD sans double copie GCS.
4. Index SQLite, agrégats et pagination pour le grand historique.
   File/historique GCS durables, inventaires progressifs et flux bornés.
5. Périmètre commun, filtres persistants et rapports de sélection.
6. Événements PX4 bruts, dictionnaire exact et explications sourcées.
7. Courbes Batterie/GNSS/EKF et curseur temporel partagé avec la carte.
8. Mise à jour Sparkle avec feed et releases publics signés.
9. Recette complète, audit de confidentialité et publication.

Le [backlog](BACKLOG-0.6.0.md) précise responsabilité, dépendance et recette de
chaque tâche. Sauvegarde vérifiée avant migration ; même sélection et mêmes
comptes dans app/rapports ; courbes à la demande selon les champs enregistrés.
Le grand index synthétique a été mesuré ; parsing massif, RSS de toute la navigation
SwiftUI, navigateur et flotte physique gardent des gates distincts.

Le dépôt reste privé pendant sa préparation. L'ancien historique et ses assets
sont maintenant isolés dans une archive privée distincte ; cette base a un historique neuf.
Voir la [préparation publique](PUBLICATION.md). Les nouveaux écrans bento monochrome
restent derrière `KATALOG_UI_PREVIEW=1` jusqu’à la validation visuelle ; Sparkle
est embarqué mais le feed est désactivé. Le suivi détaillé distingue code, tests
logiciels, recette matérielle et décisions de publication.

## Suite après 0.6

Une version 0.7 peut porter ces fonctions, après qualification du socle 0.6 :

- Associer explicitement plusieurs contrôleurs à un drone physique, avec dates et preuves.
- Journal de maintenance et comparaison avant/après.
- Tendances avec durée, couverture et dénominateurs visibles.
- Sélecteur universel de séries, IMU/ESC et analyses approfondies.
- Davantage de transferts parallèles uniquement après qualification réelle.

Avant ouverture du dépôt : choix de licence, CI avec fixtures synthétiques,
documentation de contribution/support et vérification des commits/assets.
Les mises à jour restent manuelles tant qu'un build avec Sparkle n'est pas livré.

La numérotation ne fusionne pas les identités ; une alerte n'est pas une panne
confirmée ; un banc synthétique ne qualifie pas 500 drones sur le réseau.
