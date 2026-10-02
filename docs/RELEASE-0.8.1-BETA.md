# KataLog Preview 0.8.1 — beta 1

Candidate **`v0.8.1-beta.1`**, version du bundle **0.8.1**, build **19**.
État au 3 octobre 2026 : **tests et recette native réalisés ; package final
qualifié localement, publication en attente**. Les neuf contrôles de distribution finale ont réussi avec
notarisation requise. App, helper et DMG sont signés, notarisés et leurs tickets
attachés. La copie depuis le DMG, l’éjection et le lancement de cette copie ont
réussi ; cette beta n’est pas encore annoncée comme publiée.

## Nouveautés

- **Couverture de la carte** : tous les logs géolocalisés du périmètre sont
  représentés, même anciens. Les repères proches sont regroupés ; la trajectoire
  détaillée reste disponible dans la fenêtre du log. Le cadrage est conservé
  lors du retour sur la carte.
- **Navigation** : retour sur les résultats valides déjà consultés sans relancer
  le moteur ; actualisation du même périmètre sans faire disparaître son contenu.
- **Présentation** : temps de vol sur une ligne, intitulé simple, explications
  dans l’aide ; conservation du Bento monochrome et des thèmes clair/sombre.
- **Parcours allégés** : identifiants et outils techniques en mode avancé,
  filtres plus compacts, actions adaptées à l’onglet, raisons des indisponibilités
  expliquées dans leur contexte.
- **Collecte** : analyse et transfert peuvent se chevaucher dans une file bornée.
  La sélection de nouveaux fichiers respecte la recherche affichée et annonce
  les sélections conservées hors recherche.

Voir l’[audit UX](UX-AUDIT-0.8.1.md) et les
[mesures de carte, navigation et collecte](PERFORMANCE-MAP-NAVIGATION.md).

## Installation et isolation prévues

Distribution **KataLog Preview.app**, pour Mac Apple Silicon, macOS 15 minimum.
La recette locale utilise macOS 27. Le moteur Python autonome doit être embarqué
dans le package final ; aucune installation séparée de Python n’est nécessaire.

La Preview s’installe à côté de **KataLog.app** et utilise
`~/Library/Application Support/KataLogPreview-0.8.1/`. Elle ne reprend pas
automatiquement les données de la bibliothèque stable. Pour l’essayer, importer
des fichiers dans sa bibliothèque dédiée ; les données de recette ne sont pas
livrées dans l’app.

Les mises à jour automatiques sont désactivées dans cette Preview. Une prochaine
Preview s’installera manuellement par DMG. **La release stable reste 0.8.0,
build 18 ; son appcast et ses archives ne sont pas remplacés par cette beta.**

La projection SQLite passe de 7 à 8. Sa préparation conserve les résumés
canoniques et crée une sauvegarde de migration. La recherche par proximité garde
son contrôle sur les trajectoires complètes et ne relie pas les lacunes GPS.

## Preuves de performance

| Contrôle | Résultat déjà obtenu | Portée |
| --- | --- | --- |
| Carte sur copie isolée | 180 marqueurs, dont les onze anciens enregistrements exclus par la limite de 80 | Lecture d’une copie ; bibliothèque installée et originaux conservés |
| Requête carte | 5,3 ms contre 115,9 ms ; 51 341 contre 2 929 065 octets | Python déjà chargé ; hors lancement et rendu MapKit |
| Navigation | 40 retours en 2,7 ms, sans helper | Store natif et moteur synthétique ; hors dessin de fenêtre |
| Collecte simulée | 2,927 s contre 5,200 s pour huit fichiers | Une exécution par variante ; aucun débit réseau réel mesuré |

Ces résultats isolent les coûts mesurés. Ils ne représentent pas la durée de
tous les parcours utilisateur ou le débit d’une GCS réelle.

## Tests et recette native

| Contrôle | Résultat | Portée |
| --- | --- | --- |
| Suite Swift complète finale | **348 tests réussis**, aucun échec ni test ignoré | Nouveau passage terminé après les derniers changements de carte et de courbes |
| Interactions JavaScript des rapports | **18 tests réussis** | Rapport autonome |
| Suite Python | **379 tests réussis** ; un test de corpus privé externe non exécuté | Suite complète rejouée sur les sources finales Python |
| Recette native | Neuf onglets capturés chacun en clair et sombre ; parcours détaillés complémentaires | Bibliothèque Preview synthétique ; détails dans l’audit UX |
| Carte reconstruite | 180 repères ; clic sur le groupe donnant accès aux onze logs anglais anciens | Corpus synthétique, interaction MapKit réelle |
| Cadrage final de carte | Groupe des onze logs anglais visible sous la barre de commandes ; sous-titres encombrants retirés | Nouvelle capture dans le dernier bundle |
| Retour sur la carte | Zoom et satellite conservés après Carte → Alertes → Carte | Interaction dans la Preview reconstruite |
| Parcours simplifiés | Filtres bornés, réinitialisation repliée, courbes et messages revus | Derniers libellés harmonisés après cette passe |
| Identité et accès au log | Identité de démonstration conservée après redémarrage, visible dans fiche/historique ; ouverture directe depuis une alerte | Données synthétiques uniquement |
| Export HTML depuis l’interface | 180 logs et 942 messages dans le rapport généré | Aucun log ou client réel dans l’export de recette |
| Interactions du rapport dans Chrome | Radar Batterie : 70 / 180 logs, 70 messages ; décembre 2025 : 11 / 180 logs, 55 messages | Clics réalisés dans le HTML exporté |
| Réimport depuis l’interface | 180 fichiers, zéro nouveau, 180 inchangés, zéro erreur, zéro copie identique supplémentaire | Bibliothèque synthétique conservée sans multiplication des analyses |
| Sauvegarde complète depuis l’interface | 180 ULogs sauvegardés, aucun fichier manquant | Corpus synthétique ; capture du bilan |

## Qualification du package — à compléter avant publication

| Contrôle | État |
| --- | --- |
| Vérification après derniers libellés et cadrage de carte | Suite complète Swift réussie ; cadrage final contrôlé dans l’app |
| Engine reconstruit avec les nouvelles ressources | Moteur autonome et imports synthétiques vérifiés dans le package final |
| Version, build, isolation et désactivation des mises à jour | Bundle Preview 0.8.1, build 19, bibliothèque séparée et mises à jour désactivées vérifiés dans les métadonnées finales |
| Signature Developer ID et notarisation | App, helper et DMG finaux signés, notarisés et tickets attachés |
| Validation de distribution finale | **Neuf contrôles réussis sur neuf**, avec notarisation requise ; archives embarquées décompressées et inspectées |
| Installation depuis le DMG et lancement après éjection | Copie dans un dossier isolé, éjection et lancement réussis ; Gatekeeper accepte la distribution notarisée ; carte à 180 / 180 visible |
| Confidentialité du bundle | Contrôle intégré à la validation finale, y compris le contenu décompressé |
| Confidentialité des sources, historique pertinent et archives publiées | Contrôle de publication à finaliser |
| Tag exact, archive source et empreintes SHA-256 | À générer après gel des sources |
| Publication GitHub marquée prerelease, téléchargement anonyme et intégrité | À effectuer après validation |
| Appcast stable inchangé | À contrôler avant et après publication |

Les captures, mesures détaillées et bibliothèques privées restent hors du dépôt.
La distribution ne doit embarquer ni bibliothèque de démonstration ni données
utilisateur. Les archives source doivent correspondre au tag de cette beta.

## Limites

- Une Preview validée localement reste une prérelease : aucune garantie
  d’absence totale de défaut n’est formulée.
- Aucun nouveau test sur une flotte réelle ou une GCS réelle n’est revendiqué
  dans cette recette. La concurrence sur deux drones et les bancs synthétiques
  ne qualifient pas une flotte radio de 500 appareils.
- Les chiffres de performance ne couvrent pas tous les coûts de bout en bout.
  Le service Apple Maps et la recherche d’adresses dépendent du réseau.
- Les fichiers partiels restent signalés. Une position sur la carte n’atteste
  ni une lecture complète du log ni l’absence de panne.
- Le corpus privé externe absent et les éventuels essais manuels non exécutés
  doivent rester explicitement identifiés dans le bilan final.
