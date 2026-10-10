# KataLog 0.8.5 — recette de release

Version **0.8.5**, build **24**. État : **candidate en qualification, non publiée**.

## Correction

Un clic sur « Connecter » immédiatement après « Déconnecter » pouvait être ignoré
pendant la fermeture de l’ancienne session de découverte. Cette course existait
avant 0.8.4 ; un nouveau test de cache l’a révélée dans la CI de publication.
La reconnexion demandée est désormais conservée jusqu’à la fin de cette fermeture.
Les clics répétés sont regroupés ; Annuler, l’arrêt et le changement d’hôte
invalident la demande. La terminaison attend aussi la découverte.

Cette version reprend toutes les [améliorations de collecte 0.8.4](RELEASE-0.8.4.md).
Elle garde l’identité de l’app, les bibliothèques existantes, le parseur **1.4.0**
et la projection SQLite **8**. Aucun réimport n’est requis.

## Validation

Les résultats seront attribués au commit exact : tests déterministes de reconnexion
et d’annulation, suites CI macOS 15/26, deux packages ARM64, copie du DMG et recette
native isolée, signature Developer ID, notarisation, téléchargements publics et
signatures Sparkle. Les preuves 0.8.4 restent attribuées à cette version ; elles
ne qualifient pas à elles seules les nouveaux fichiers de distribution.

## Distribution et limites

macOS 15 minimum, Apple Silicon. La release 0.8.4 est déjà publique ; son tag et
ses assets restent inchangés. Le flux stable passe directement du build 22 de
0.8.3 au build 24 une fois les nouveaux assets publiés et vérifiés.

La reprise GCS → Mac reste conditionnée par un ETag fort et HTTP Range. Le trajet
Drone → GCS peut recommencer faute d’offset dans le protocole. Aucune nouvelle
qualification radio ou flotte physique n’est revendiquée. Une métadonnée des
exports JSON résumés peut décrire moins précisément les détails absents que le
HTML ; cette limite préexistante reste documentée, sans perte de données observée
dans la recette 0.8.4.

Les procédures sont dans [RELEASING.md](RELEASING.md). Les preuves contenant des
chemins locaux et les fixtures privées restent hors du dépôt public.
