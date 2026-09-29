# Validation de l'interface macOS

## Référence 0.5.1

La recette de publication a exécuté 68 tests Python, 64 Swift et 9 JavaScript,
avec des ULog privés pour les tests qui les nécessitent. Ces ULog et les preuves
opérationnelles ne sont pas publiés. Les tests publics emploient des données
synthétiques ; les tests privés sont identifiés et ignorés sans corpus explicite.

La release 0.5.1 ARM64 a été signée Developer ID et notarisée. L'audit de
publication publique a néanmoins identifié des chemins de build dans son binaire :
cette archive privée ne doit pas être rendue publique. Une nouvelle archive doit
être construite, auditée, signée et notarisée pour la distribution publique.
La signature et la notarisation ne certifient pas l'absence de données personnelles.

## Parcours à vérifier

| Parcours | Vérification |
|---|---|
| Installation | App extraite/déplacée, lancement, version et signature |
| Import | Dossier sélectionné, progression, annulation, erreurs par fichier |
| Réimport | Même jeu de SHA, aucune duplication |
| Filtres | Recherche/famille/niveau/drone, reset et état vide |
| Identité | Saisie/modification/retrait de numéro, persistance et conflits |
| Carte | Avec/sans GPS, segments, limite de rendu et ouverture du bon log |
| Fiche | Cache, paramètres, topics, messages et couverture |
| Collecte | Flotte autorisée, queue, arrêt/reprise, retries et cache |
| Export HTML | Autonomie, filtres combinés, thèmes, échappement et liens |
| Impression | Périmètre annoncé, détails visibles et retour de l'état après annulation |
| Redémarrage | Bibliothèque, annotations, dossier et queue préservés |

## Preuves privées

Captures d'app réelle, rapports, bibliothèques de recette, coordonnées et réponses
GCS restent dans un stockage local exclu de Git. Les maquettes publiées doivent
provenir exclusivement d'un jeu synthétique et porter une indication démonstration.
Les essais simulés, logiciels et matériels sont consignés séparément.

## Recette de distribution 0.6.0

Sur Mac Apple Silicon propre, sans Python/Homebrew/outils développeur : télécharger
le DMG, l'ouvrir, glisser KataLog dans Applications, éjecter puis lancer l'app.
Vérifier Gatekeeper, import, fiche, export et mise à jour. Tester les dossiers
Applications système et utilisateur, réseau absent, volume plein et ancien
bundle déjà ouvert. La mise à jour conserve les données locales.
Voir le [plan 0.6.0](PLAN-0.6.0.md) et la [procédure de release](RELEASING.md).
