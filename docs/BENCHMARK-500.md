> **Mesure historique — benchmark du 29 septembre 2026.**
> Les chiffres ci-dessous restent attachés à ce corpus et à cette exécution.
> Les mesures ultérieures sont dans [PERFORMANCE-MAP-NAVIGATION.md](PERFORMANCE-MAP-NAVIGATION.md) ;
> la qualification courante est suivie dans la [release 0.8.1](RELEASE-0.8.1.md).

# Benchmark synthétique : 500 identités de drones

Exécuté le 29 septembre 2026 sur le Mac de développement (Apple M2 Pro, 16 Go), avec Python 3.13 et le moteur pyulog local.

## Méthode

500 variantes indépendantes d’un petit ULog de recette privée, 915 843 octets chacune. Le fichier source et ses identifiants ne sont pas publiés. Seuls les 36 caractères hexadécimaux de `sys_uuid` ont été remplacés par 500 identités distinctes, sans changer la taille des messages ULog. Chaque copie est placée dans sa propre arborescence carte/log/date. Cela force 500 SHA256 différents et 500 analyses complètes, sans déduplication de contenu. Volume des fixtures : 457 921 500 octets.

Un premier import crée une base SQLite neuve. Un second import identique mesure la reprise via le cache de métadonnées. Chaque mesure lance un processus Python neuf avec un wrapper de mesure Python `resource.getrusage(RUSAGE_SELF)` : temps mural mesuré depuis le parent, RSS maximum du processus enfant mesuré par macOS (ru_maxrss exprimé en octets sur Darwin). Le JSON de progression est activé comme dans l'app.

Les fichiers, la base et le snapshot sont créés dans un TemporaryDirectory puis supprimés automatiquement. Aucun fichier de la carte source n'est modifié.

## Résultats

| Mesure | Premier import | Réimport inchangé |
|---|---:|---:|
| Temps mural (s) | 15.911 | 0.502 |
| RSS maximum (octets) | 65126400 | 61276160 |
| Logs conservés | 500 | 500 |
| Identités distinctes | 500 | 500 |
| Messages conservés | 10000 | 10000 |
| Messages alertes | 500 | 500 |
| Snapshot JSON (octets) | 5385268 | 5385268 |
| Base SQLite (octets) | 6668288 | 6668288 |

Statistiques du premier import : `{"discovered": 500, "imported": 500, "unchanged": 0, "duplicates": 0, "failed": 0}`.

Statistiques du réimport : `{"discovered": 500, "imported": 0, "unchanged": 500, "duplicates": 0, "failed": 0}`.

## Interprétation et limites

Cette charge synthétique valide le passage de 500 identités dans le moteur, SQLite et le snapshot, avec 500 parsings distincts et zéro échec. Elle ne représente pas 500 cartes réelles ni plusieurs années de vols. Les 500 logs ont exactement les mêmes données de télémétrie et une taille de 0,9 Mo. Les performances avec des fichiers plus volumineux, beaucoup plus de messages ou un disque externe peuvent différer. La mémoire du moteur est mesurée, pas celle du rendu SwiftUI ni de l'export HTML.
