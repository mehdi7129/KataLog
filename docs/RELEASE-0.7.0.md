# KataLog 0.7.0 — recette de release

Version **0.7.0**, build **17**. Qualification locale terminée le 1er octobre 2026.
La publication et la CI publique sont suivies séparément ci-dessous.

## Contenu

- Dix onglets bento natifs, noir/blanc et clair/sombre, navigation et boutons harmonisés.
- Progression de collecte actualisée lors d’un changement de dossier.
- Diagnostic local KataLog/GCS, prévisualisation et choix privés explicites.
- Mises à jour Sparkle signées, recherche manuelle et recherche automatique facultative.
- Installation confirmée et différée pendant les opérations ; bibliothèque stable conservée.

## Distribution

Mac Apple Silicon, macOS 15 minimum. DMG hors App Store, moteur autonome embarqué.
Les utilisateurs de 0.6.x installent une fois ce DMG avant de bénéficier du flux public.
KataLog Preview conserve sa bibliothèque séparée.

## Qualification locale

| Contrôle | Résultat |
| --- | --- |
| Swift complet, Core et app | 303 tests réussis, 0 failure, 0 skip |
| Python autonome et loopback | 344 tests réussis, 0 failure ; 1 test de corpus privé explicitement non exécuté |
| Interactions JavaScript des rapports | 18 tests réussis, 0 skip |
| Rendus natifs bento | 87 captures générées, clair/sombre et tailles minimale/desktop |
| SDK de mise à jour | Installation, remplacement et relancement réussis ; six fichiers de données conservés |
| Échecs de mise à jour | Flux modifié, archive modifiée, téléchargement interrompu et archive absente : refus ou ancienne app conservée |
| Signature/notarisation | Developer ID ; app, helper et DMG acceptés et tickets agrafés ; Gatekeeper accepte app et DMG |
| Distribution finale | Neuf contrôles réussis, 0 finding de confidentialité, 22 binaires ARM64 autonomes |

La recette du moteur embarqué vérifie import et doublons, détails en cache,
sources retirées/restaurées, sauvegarde/restauration, archives, révisions,
événements et courbes synthétiques, inventaire et téléchargement loopback,
réutilisation des copies vérifiées et destination unique. Le bundle reste inchangé.
Les tests SDK utilisent des apps jetables et un serveur loopback ; ils ne modifient
ni l’application installée ni la bibliothèque réelle.

## Publication et validation externe

- Dernière passe sur le commit exact, l’archive source, les assets et les métadonnées GitHub avant passage public.
- CI gratuite sur runners standard, après publication du code.
- Archives disponibles avant publication du flux signé ; vérification HTTPS anonyme des octets, signatures et URLs.

Les rapports détaillés, captures et données du poste restent hors du dépôt.

## Limites

Les tests simulés ne qualifient pas une flotte radio réelle de 500 appareils.
La recette sur macOS 27 ne remplace pas un essai physique sur macOS 15.
Aucune collecte réelle supplémentaire n’est revendiquée pour cette release.
