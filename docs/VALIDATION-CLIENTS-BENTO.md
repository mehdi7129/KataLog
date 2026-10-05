> **Document historique.** Les résultats et statuts ci-dessous décrivent leur
> version à la date de la recette. Pour la version actuelle :
> [KataLog 0.8.1](RELEASE-0.8.1.md) et [guide utilisateur](README.md).

# Validation de la Preview clients et Bento

État : recette de la Preview locale terminée, interface approuvée. Recette effectuée
sur macOS 27 / Apple Silicon. Ce document conserve les résultats de cette Preview ;
la qualification du package stable **0.8.0 (build 18)** est suivie séparément dans
[RELEASE-0.8.0.md](RELEASE-0.8.0.md).

## Contrats vérifiés

- Création, renommage, suppression et attribution en lot des clients.
- Périmètre conservé dans statistiques, historique, registre, carte et rapports.
- Déduplication entre clients sans déplacement implicite d'un log déjà connu.
- Client de collecte fixé dans chaque travail de la file, avec persistance et
  retrait des références au client lorsqu'il est supprimé.
- Ancien schéma consultable en lecture seule ; compatibilité en tables temporaires
  sans modification de la base principale.
- Recherche géographique sur la trajectoire complète, y compris traversée entre
  deux points, méridien de changement de date et exclusion des lacunes GPS.
- Mise en cache lors de la première recherche dans une ancienne bibliothèque,
  puis recherche possible après déconnexion de la source.
- Fenêtres de logs indépendantes et redimensionnables ; réouverture ciblée,
  annulation des chargements et fermeture avant restauration de bibliothèque.
- Réinitialisations préservant les originaux internes et externes, refus de
  suppression récursive et conservation du verrou stable de bibliothèque.
- Rapports partagés sans noms ou identifiants de clients, dans le HTML interactif,
  sa variante synthétique et les pièces jointes.

## Résultats

| Vérification | Résultat |
| --- | --- |
| Suite native complète | 320 tests réussis, aucun échec ou test ignoré |
| Isolation de Preview et collecte desktop, après derniers ajouts | 10 tests ciblés réussis |
| Menus clients et noms de 120 caractères | 1 test de dimensions et rendu réussi |
| Suite Python complète | 371 réussis ; 1 test de corpus privé externe non exécuté |
| Régression du packaging | 5 tests réussis |
| Moteur réellement embarqué | Import, client, doublon, carte hors ligne, réattribution et réinitialisations vérifiés |
| Paquet applicatif | Métadonnées, dépendances autonomes, signature locale, confidentialité et import synthétique vérifiés |
| Apple Maps en ligne | Recherche d'une ville publique réussie |
| Interface | Captures natives clair/sombre, fenêtres étroites et larges ; collecte avec longue file d'erreurs synthétiques |

La Preview dispose d'une bibliothèque distincte, conservée au redémarrage. Son
canal de mise à jour est désactivé. Elle ne remplace pas la release installée.

## Limites de cette recette

Les nouvelles collectes ont été exercées avec des fixtures et un transport simulé,
sans drone réel. La recherche d'adresse dépend du service Apple ; les coordonnées
peuvent être saisies directement. Le test privé absent n'est pas remplacé par une
qualification terrain. Le paquet local n'est pas une nouvelle release notarisée.
