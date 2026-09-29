# KataLog — roadmap

## Référence disponible : 0.5.1

App native SwiftUI/MapKit pour macOS 15+ Apple Silicon. Import ULog par pyulog,
cache SQLite, déduplication SHA256, collecte GCS, identification manuelle,
classement des alertes et rapport HTML interactif sont livrés.

Les événements binaires et séries temporelles ne sont pas encore extraits.
Les détails sont chargés à la demande ; le snapshot global reste en mémoire.
Python est externe et les mises à jour sont manuelles.

## Prochaine version : 0.6.0

Le [plan détaillé](PLAN-0.6.0.md) précise les lots, dépendances et critères :

1. Contrats et corpus synthétique reproductible.
2. Moteur autonome et installation standard par DMG, hors App Store.
3. Sauvegarde/restauration et archives SD sans double copie GCS.
4. Index SQLite, agrégats et pagination pour le grand historique.
5. Périmètre commun, filtres persistants et rapports de sélection.
6. Événements PX4 bruts, dictionnaire exact et explications sourcées.
7. Courbes Batterie/GNSS/EKF et curseur temporel partagé avec la carte.
8. Mise à jour Sparkle avec feed et releases publics signés.
9. Recette complète, audit de confidentialité et publication.

Le dépôt reste privé pendant sa préparation. L'ancien historique et ses assets
sont maintenant isolés dans une archive privée distincte ; cette base a un historique neuf.
Voir la [préparation publique](PUBLICATION.md). Les nouveaux écrans gardent le
bento monochrome et font l'objet d'une validation de maquettes avant intégration.

## Suite après 0.6

- Associer explicitement plusieurs contrôleurs à un drone physique, avec dates et preuves.
- Journal de maintenance et comparaison avant/après.
- Tendances avec durée, couverture et dénominateurs visibles.
- Sélecteur universel de séries, IMU/ESC et analyses approfondies.
- Davantage de transferts parallèles uniquement après qualification réelle.

La numérotation ne fusionne pas les identités ; une alerte n'est pas une panne
confirmée ; un banc synthétique ne qualifie pas 500 drones sur le réseau.
