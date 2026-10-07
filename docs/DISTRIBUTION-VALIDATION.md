> **Document historique — recette 0.5.2 (7) du 29 septembre 2026.**
> Les mentions de dépôt privé et de Sparkle planifié décrivent cette recette.
> La procédure courante figure dans [RELEASING.md](RELEASING.md) ; la dernière
> qualification stable est celle de [0.8.2 (build 21)](RELEASE-0.8.2.md).

# Recette de distribution 0.5.2 (7)

Recette locale du 29 septembre 2026, **Mac Apple Silicon sous macOS 27.0**.
Le package est disponible localement ; le dépôt reste privé. Les autres lots
0.6.0 et Sparkle restent planifiés. Cette recette ne qualifie pas toutes les
versions de macOS ni une collecte radio réelle.

## Artifact final

| Élément | Résultat |
|---|---|
| DMG | `KataLog-0.5.2-macOS-arm64.dmg` |
| Taille | 15 857 309 octets, soit 15,86 Mo |
| SHA-256 | `489a73609ffa541a006357f3b2339d9cf0caf753bd351855cd74c53e36b390be` |
| App / helper | Developer ID, hardened runtime et timestamp |
| Notarisation | App et DMG Accepted ; tickets agrafés et validés |
| Gatekeeper | App et DMG acceptés lors de la recette complète |
| Installation | App et lien `/Applications`, sans script utilisateur |
| Runtime | Python 3.13.15, NumPy 2.5.3 et pyulog 1.2.4 embarqués |

Le background Retina a été corrigé après la première recette visuelle : le
contexte AppKit appliquait déjà l'échelle du bitmap. Le PNG corrigé a été
inspecté, puis le DMG reconstruit, signé, notarisé et revérifié. Les métadonnées
Finder indiquent une fenêtre 660 × 420 avec positions explicites des icônes.

## Tests réalisés

| Périmètre | Preuve |
|---|---|
| Swift | 79 tests réussis, dont résolveur partagé import/collecte |
| Python, suite complète avant restriction du poste | 86 tests réussis, aucun skip ; corpus de 9 ULog inchangé |
| JavaScript du rapport | 9 tests réussis |
| Vérificateur de distribution après ajout du fond DMG | 5 tests ciblés réussis |
| App et DMG finaux | 8 contrôles de distribution réussis |
| Confidentialité du bundle | 81 fichiers et 464 payloads décompressés, aucun signalement |
| Portabilité native | 17 fichiers Mach-O ARM64 inspectés, aucune dépendance externe |

Les contrôles du package couvrent metadata, signatures strictes, tickets et
Gatekeeper, contenu du DMG monté en lecture seule, lien Applications et égalité
des fichiers entre l'app vérifiée et celle du DMG. Les archives Python sont
inspectées après décompression ; les chemins personnels et données de flotte
ne sont pas embarqués.

Le moteur fonctionne avec PATH système, HOME isolé et variables Python invalides :
import ULog synthétique, réimport sans doublon, snapshot et détails conservés
après indisponibilité des sources. Le simulateur GCS localhost valide inventaire,
transfert vers un seul dossier et réutilisation sans second téléchargement.

## Recette native sur macOS 27

- Copie du bundle depuis le DMG, éjection du volume puis lancement de la copie.
- Import d'un dossier synthétique : un log, une identité, deux messages et zéro erreur.
- Consultation de la fiche, des messages et de la carte Apple Maps.
- Export HTML natif réussi ; numéro et famille personnalisée présents dans le fichier.
- Relancement : bibliothèque, numéro manuel et famille personnalisée conservés.
- Dossier personnalisé accessible avant relancement ; configuration conservée
  après relancement. Les tests Swift vérifient aussi la persistance de ce réglage.

La recette utilise une bibliothèque isolée et une GCS non connectée. Les sources
réelles, logs collectés et app installée de l'utilisateur sont préservés.

## Limites et derniers contrôles

Le poste est ensuite passé dans un environnement restreint : la nouvelle suite
Python découvre 87 tests, dont 70 réussissent et 17 méthodes réseau sont bloquées
par `socket.bind` sur localhost. Ces erreurs de permission ne sont pas présentées
comme des tests réussis. Le nouveau test du fond DMG passe ; la suite complète
précédente et la recette du package ont eu lieu avant cette restriction.

Ce même environnement refuse Computer Use pour Finder et KataLog, le montage
d'une nouvelle image et l'accès de codesign à la validation de confiance.
Un contrôle d'un binaire Apple système échoue aussi. Les SHA-256 du DMG et de
l'exécutable restent identiques à ceux de la recette complète réussie. La
nouvelle copie avec quarantaine simulée n'a donc pas pu être qualifiée.

Restent à qualifier séparément : affichage Finder du DMG corrigé, téléchargement
réel avec quarantaine depuis la future release, remplacement d'une ancienne app,
Mac vierge et macOS 15 physique. Le minimum macOS 15 est déclaré et les minima
Mach-O sont contrôlés ; il ne constitue pas une recette sur cette version.

Les rapports détaillés et données de recette restent locaux et ignorés par Git.
Le contrôle de publication et Gitleaks n'ont détecté ni secret ni donnée privée
dans les sources sélectionnées et l'historique isolé. Aucun nouveau tag, release
ou passage du dépôt en public n'a été effectué pour cette livraison locale.
