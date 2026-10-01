# KataLog 0.8.0 — recette de release

Version **0.8.0**, build **18**. État : **en validation avant publication**.
La Preview et sa direction visuelle ont été approuvées. Le package stable,
sa notarisation, la CI et la publication sont qualifiés séparément ci-dessous.

## Nouveautés

- Clients locaux personnalisables : votre organisation ou les clients dont vous
  suivez les drones, sans compte ni service cloud.
- Attribution des logs à l’import ou à la collecte, modification en lot et
  statistiques, historique, carte et rapports limités au client sélectionné.
- Interface Bento plus sobre : actions sans cadre permanent, survol et focus
  visibles, thème clair/sombre en un clic et activité récente défilante.
- Recherche de logs autour d’une ville, d’une adresse ou de coordonnées, avec
  rayon, sur les trajectoires complètes disponibles.
- Une fenêtre macOS indépendante par log, déplaçable et redimensionnable.
- Collecte groupée sans inscription manuelle des drones éligibles connectés à
  la GCS ; client destinataire conservé dans chaque travail de la file.
- Outils PX4 spécialisés dans un mode avancé facultatif et diagnostic GCS guidé.
- Retrait groupé des sources, vidage de bibliothèque et réinitialisation globale
  avec confirmation, sans supprimer les fichiers `.ulg`.

Voir [le contrat clients, carte et conservation des fichiers](CLIENTS-BENTO.md).

## Installation et migration

Mac Apple Silicon, macOS 15 minimum. Installation par DMG hors App Store,
moteur autonome embarqué. À partir de 0.7.0, la mise à jour est proposée par
le flux stable signé après publication de ses assets ; les versions plus
anciennes peuvent installer directement le nouveau DMG.

La bibliothèque stable, les identifications et les dossiers choisis sont
conservés. Les anciens logs restent dans **Sans client** jusqu’à attribution
explicite. Un doublon ou une réanalyse ne change jamais cette attribution.
Les rapports complets portent sur le client choisi ; **Tous les clients**
permet de couvrir la bibliothèque entière.

La première recherche géographique met en cache les trajectoires complètes
accessibles. Les sources absentes sans cache sont annoncées comme non vérifiables.
La recherche ne relie pas les lacunes GPS et précède la limite des 80 logs affichés.

KataLog Preview utilise une bibliothèque distincte et n’active pas les updates.
Son contenu n’est pas transféré automatiquement dans la bibliothèque stable.

## Validation préalable de la Preview

La [recette détaillée](VALIDATION-CLIENTS-BENTO.md) consigne 320 tests natifs,
10 tests ciblés d’isolation/collecte desktop et un contrôle des menus clients,
ainsi que 371 tests Python réussis et un corpus privé explicitement absent.
Les contrats clients, fenêtres indépendantes, cache géographique, réinitialisations
et exports partagés ont été exercés avec des données synthétiques. Les rendus
natifs couvrent clair/sombre, tailles minimale/desktop et longue file d’erreurs.

Ces résultats qualifient la Preview ; ils ne remplacent pas les contrôles du
package stable final.

## Qualification du package stable

| Contrôle | Résultat |
| --- | --- |
| Swift complet, Core et app | 323 tests réussis, aucun échec ni test ignoré |
| Python autonome | 371 tests réussis ; 1 test de corpus privé externe non exécuté |
| Interactions JavaScript des rapports | 18 tests réussis |
| Banc SDK de mise à jour, macOS 27.0.1 | 5 recettes réussies ; six fichiers de données synthétiques conservés |
| Build stable | 0.8.0, build 18, construit |
| Notarisation de l’app | Acceptée par Apple ; stapling et DMG en cours |
| DMG final et moteur embarqué | À compléter après contrôle des assets finaux |
| Confidentialité du commit et des archives | À compléter après contrôle du contenu exact |
| CI publique sur le commit de release | À compléter après résultat des jobs |
| Assets GitHub, SHA-256 et flux Sparkle | À compléter après publication et téléchargement anonyme |

Le banc SDK utilise des applications jetables, une clé de test et un serveur
loopback. Ses cinq recettes couvrent installation/relancement, flux modifié,
archive modifiée, téléchargement interrompu et archive absente. L’app installée
et la bibliothèque réelle ne sont pas remplacées par ce banc.

Les rapports détaillés, bibliothèques de test et captures locales restent hors
du dépôt public. Les résultats finaux doivent correspondre au commit tagué et
aux octets des assets distribués ; aucun résultat CI ou statut de notarisation
n’est déduit du seul succès de compilation.

## Limites

- Aucune nouvelle collecte sur un drone réel n’est revendiquée pour cette release.
  Les transports simulés ne qualifient pas une flotte radio de 500 appareils.
- Les recherches de ville/adresse dépendent du service Apple ; la saisie directe
  de coordonnées reste possible. Une source absente sans trajectoire complète
  en cache limite la couverture de la recherche et est signalée.
- La recette locale sur macOS 27 ne remplace pas un essai physique sur macOS 15.
- Les événements PX4 nécessitent le dictionnaire exact du firmware pour être
  traduits. Une alerte décrit un signal observé, pas une panne confirmée.
- Vider la bibliothèque ou réinitialiser l’app efface les données locales
  décrites dans la confirmation pour tous les clients. Les fichiers `.ulg`
  conservés peuvent ensuite être réimportés ; leur attribution précédente
  n’est pas recréée après une réinitialisation complète.
