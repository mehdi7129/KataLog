# Audit UX — candidate 0.8.1

Revue du 3 octobre 2026. **Recette native, tests et qualification locale du
package réalisés ; publication en attente.** Ce document distingue les interactions réalisées,
les corrections du code et les tests. La validation d’un écran ne qualifie pas
à elle seule le DMG qui sera distribué.

## Direction conservée

Bento monochrome, thèmes clair/sombre, boutons sans cadre permanent, survol et
focus visibles. Les données de flotte restent locales. Le parcours courant doit
permettre d’importer, de situer un vol, de comprendre une alerte et d’exporter un
rapport ; le mode avancé donne accès aux outils techniques supplémentaires.

Les passes utilisent une **bibliothèque Preview isolée** : 180 ULogs
synthétiques, 18 identités, deux clients, lectures complètes et partielles,
messages, trajectoires, paramètres et séries temporelles. Les captures et
bibliothèques de recette restent hors Git et hors des archives distribuées.
Les observations sur ce corpus ne qualifient pas une flotte ou un firmware réel.

## Parcours natif et captures

Les noms ci-dessous repèrent les captures locales de la première passe, avant
la reconstruction intégrant toutes les corrections. « Visité » signifie que
l’écran a été ouvert dans la Preview ; ce n’est pas une validation de toutes
ses branches d’erreur ou de chaque commande destructive.

| Zone | Interaction ou état observé | Captures locales |
| --- | --- | --- |
| Vue d’ensemble | Ouverture, thème clair/sombre, aide du temps de vol | `01-overview-dark`, `02-flight-time-help`, `03-overview-light` |
| Historique | Liste, résultat vide après filtre, dialogue d’attribution | `04-history`, `21-history-empty-filter`, `22-assign-client` |
| Alertes | Liste, détail de groupe et aperçu d’impact du masquage | `05-alerts`, `23-alert-detail`, `24-mask-impact` |
| Carte | Vue générale et repères du corpus synthétique | `06-map` |
| Drones | Registre et actions proposées | `07-drones` |
| Collecte GCS | État sans GCS connectée ; aucune collecte réelle dans cette passe | `08-collection` |
| Stockage et sources | Ouverture de la liste, confirmation de retrait puis annulation | `09-storage`, `15-sources`, `16-sources-retire-confirmation` |
| Rapports | Périmètre et options de préparation | `10-reports` |
| Réglages | Ouverture, confirmation de réinitialisation puis annulation | `11-settings`, `12-reset-confirmation` |
| Diagnostic | Ouverture et explications des options | `13-diagnostic`, `14-diagnostic-explanations` |
| Clients | Menu, gestion et création dans la bibliothèque de démonstration | `17-clients-menu`, `18-clients-management`, `19-client-created` |
| Filtres | Ouverture du panneau de sélection | `20-filter-editor` |
| Fenêtre de log | Ouverture native, synthèse, messages et courbes | `25-flight-summary`, `26-flight-messages`, `27-flight-curves` |

Les neuf onglets courants ont chacun été capturés en clair et en sombre dans la
seconde passe : séries `final-light-*` et `final-dark-*`. Cette passe reprend
les corrections dans une Preview reconstruite. Les captures de détails et
d’interactions complètent ces dix-huit vues d’onglets.

| Parcours complémentaire | Résultat de l’interaction native | Captures locales |
| --- | --- | --- |
| Recherche géographique | Recherche de lieu et affichage des résultats autour de Londres sur les données synthétiques | `28-map-search-results`, `29-map-london` |
| Mode avancé | Ouverture des événements et de leur détail ; visite des mesures, paramètres, topics, couverture et révisions d’un log | `30-events-advanced` à `37-flight-revisions` |
| Rapport | Export HTML depuis l’interface : 180 logs et 942 messages synthétiques | `38-report-exported`, `38-report-exported-complete` |
| Réglages simplifiés | Accès guidé au diagnostic et groupe Réinitialisation replié | `40-final-settings-simple` |
| Carte exhaustive | 180 repères ; clic sur le groupe anglais donnant accès aux onze logs anciens | `41-final-map`, `42-final-cluster-UK` |
| Retour sur la carte | Zoom et fond satellite conservés après Carte → Alertes → Carte | `43-map-return` |
| Filtres et rapports | Liste des drones bornée dans le filtre ; périmètre visible dans les rapports | `44-final-filters`, `45-final-reports` |
| Fiche simplifiée | Messages et courbes parcourus ; libellés usuels en français | `46-final-curves-simple`, `47-final-flight-messages` |
| Identification | Numéro de démonstration enregistré puis retrouvé dans la fiche et l’historique ; conservation vérifiée après redémarrage | `48-identify`, `49-identity-saved` |
| Accès depuis une alerte | « Voir le log » ouvre directement la fenêtre native du log | `50-final-alert-detail`, `51-alert-opens-native-log` |
| Rapport dans Chrome | Clic sur Batterie dans le radar : 70 / 180 logs et 70 messages ; clic sur décembre 2025 : 11 / 180 logs et 55 messages | `52-report-overview`, `53-report-filter`, `54-report-timeline` |
| Réimport depuis l’interface | 180 fichiers parcourus, zéro nouveau, 180 inchangés, zéro erreur et zéro copie identique supplémentaire | `55-import-options`, `56-reimport-complete` |
| Sauvegarde depuis l’interface | Sauvegarde complète des 180 ULogs ; aucun fichier manquant | `57-backup-complete` |
| Stockage détaillé | Panneaux de cache et de détails ouverts ; limite de lecture de l’arbre d’accessibilité signalée ci-dessous | `58-storage-cache`, `59-storage-details` |
| Cadrage final de la carte | Groupe des onze logs anglais sous la barre de commandes ; sous-titres de regroupement encombrants retirés | `60-map-final-fit` |
| Installation depuis le DMG | Copie isolée, éjection puis lancement réussis ; carte à 180 / 180 dans l’app installée | `61-dmg-installed-map` |

La dernière harmonisation de libellés et l’ajustement du cadrage de carte ont
été intégrés. Le cadrage est confirmé par une nouvelle capture et la suite
Swift complète a réussi sur ces dernières sources. Les neuf contrôles de
distribution ont réussi, puis la copie depuis le DMG a été lancée après éjection.
Aucun clic de collecte
sur du matériel réel n’est inclus dans cette recette. Une galerie HTML locale
regroupe les captures par thème et par parcours ; elle reste hors publication,
car les fenêtres peuvent révéler des chemins de travail du Mac.

## Constats et corrections

| Priorité | Constat | Correction dans la candidate | Preuve et limite |
| --- | --- | --- | --- |
| Haute | Les 80 logs récents limitaient la couverture visible de la carte. | Marqueurs pour toute la sélection, pages bornées, regroupement MapKit ; trajectoire chargée à la demande. | Tests backend, copie isolée de bibliothèque et contrôle natif des annotations. Dans la Preview, 180 repères et accès par clic aux onze logs anglais synthétiques. |
| Haute | Changer d’onglet relançait des lectures coûteuses et masquait le contenu. | Cache mémoire de huit résultats, invalidation sur mutation, conservation du contenu pendant l’actualisation du même périmètre. | Tests de cache, d’annulation et de cohérence ; mesure distincte du temps de dessin. |
| Haute | Un choix dans la liste pouvait correspondre à un repère regroupé ; revenir sur la carte perdait le cadrage. | Sélection cohérente avec les groupes et état de présentation conservé pendant la navigation. | Clic sur le groupe anglais ; zoom et satellite conservés au retour depuis Alertes dans la Preview reconstruite. |
| Moyenne | Le cadrage pouvait placer un groupe de repères sous la barre de commandes. | Marge de cadrage accrue et suppression des sous-titres encombrants sur les repères. | Capture finale du groupe anglais : onze logs accessibles sous la barre ; suite Swift complète réussie après correction. |
| Moyenne | Le temps de vol était chargé en explications permanentes. | Valeur en minutes, puis « Temps de vol cumulé » ; méthode et couverture dans l’aide. Suppression de la mention de déduplication dans les indicateurs. | Rendus natifs clair/sombre et aide ouverte. La déduplication des données reste active. |
| Moyenne | Des commandes apparaissaient sans effet utile dans leur contexte. | Pas d’actualisation de données dans Réglages ; actualisation propre à l’aperçu des Rapports et périmètre filtré visible. | Réglages et Rapports revus dans la Preview reconstruite ; export HTML exécuté depuis l’interface. |
| Moyenne | « Sélectionner les nouveaux » pouvait agir sur des fichiers masqués par la recherche GCS. | Sélection limitée aux fichiers affichés ; indication des sélections conservées hors recherche. | Tests de sélection de l’inventaire ; vérification native avec inventaire simulé à compléter. |
| Moyenne | Le compteur de bibliothèque dans la collecte pouvait afficher le nombre d’éléments chargés, au lieu du total du périmètre. | Total de la sélection quand il est disponible ; état explicite sinon. | Code corrigé ; contrôle des états en cours de recette. |
| Moyenne | Les filtres exposaient les identifiants techniques et pouvaient produire une longue liste. | Noms usuels en mode standard, identifiants en avancé, liste bornée et sélection conservée entre pages. | Panneau corrigé ouvert et liste bornée contrôlée dans la Preview reconstruite. |
| Moyenne | Les courbes et liens de fiche pouvaient exposer des outils techniques en mode standard. | Catalogue de champs, événements liés et lien vers la couverture réservés au mode avancé. Batterie, GNSS et EKF restent accessibles. | Parcours standard et panneaux avancés visités ; courbes simples et messages contrôlés après reconstruction. |
| Moyenne | Les options indisponibles et la Preview donnaient parfois une explication trop générale. | Aides contextuelles pour diagnostic et mises à jour ; mise à jour manuelle annoncée dans la Preview, sans bouton de recherche inactif. | Explications initiales visitées ; aides corrigées à vérifier sur le build final. |
| Faible | L’attribution en lot réutilisait une aide destinée aux nouveaux imports. | L’aide annonce le remplacement de l’attribution des logs sélectionnés. | Dialogue visité et correction du texte dans le code. |
| Faible | Réglages présentait en permanence diagnostic détaillé et réinitialisations. | Accès au diagnostic guidé en standard, diagnostic détaillé en avancé ; réinitialisations sous un groupe dépliable. | Confirmations ouvertes puis annulées ; groupe replié et nouveau parcours contrôlés après reconstruction. |
| Faible | Certains libellés de courbes et de messages manquaient d’uniformité. | Intitulés français cohérents entre les panneaux. | Écrans parcourus ; dernière harmonisation incluse dans la reconstruction et la suite Swift complète réussie. |

Les corrections conservent les fonctions utiles et les données analysées. Le
mode avancé change leur présentation ; il ne retire pas les messages, événements
ou séries de la bibliothèque. Les deux réinitialisations restent distinctes,
avec leur confirmation et la conservation annoncée des fichiers `.ulg`.

## Performance et qualité

Les [mesures détaillées](PERFORMANCE-MAP-NAVIGATION.md) isolent chaque coût :
requête de carte, navigation du store et banc de collecte. Elles ne sont pas
des mesures de bout en bout sur une GCS réelle.

- Carte : 180 marqueurs et environ 51 ko de JSON, au lieu de 80 trajectoires
  et environ 2,93 Mo. Les trajectoires complètes restent utilisées pour la
  recherche géographique ; les détails d’un vol se chargent à son ouverture.
- Navigation : résultats en mémoire bornés, réutilisés seulement si le périmètre
  et les données n’ont pas changé. Les états d’annulation sont testés.
- Collecte : deux transferts sur des drones distincts, un worker d’analyse et
  quatre fichiers au maximum en transfert ou en attente/analyse. Le débit
  réseau réel reste à mesurer.

Après les dernières corrections de carte et de courbes, la suite native complète
confirme **348 tests Swift réussis, zéro échec et zéro test ignoré**. Les **18 tests JavaScript** du
rapport réussissent aussi. Le nouveau passage complet Python confirme
**379 tests réussis** ; le test nécessitant un corpus privé externe reste
explicitement non exécuté. Ces résultats ne remplacent pas les contrôles de
distribution du dernier bundle reconstruit.

## Accessibilité et limites de recette

La revue porte sur les intitulés, les aides des commandes indisponibles, la
hiérarchie visuelle et les états clair/sombre. Les contrôles natifs automatisés
complètent les interactions réalisées dans la fenêtre. Les captures hors écran
peuvent ne pas restituer les tuiles MapKit : elles ne suffisent pas à valider la
carte affichée à l’écran.

La carte a été contrôlée dans une fenêtre réelle et le rapport exporté depuis
l’interface. Le parcours clavier/focus exhaustif, les variations de largeur et
la sélection GCS avec inventaire simulé ne sont pas déclarés entièrement validés
par ces seules captures. Une lecture des attributs d’accessibilité ne remplace
pas un parcours VoiceOver ; aucune certification WCAG ou VoiceOver exhaustive
n’est revendiquée. La GCS est restée hors ligne pendant la recette native.

Les panneaux de stockage détaillés étaient visibles, mais l’outil de recette
renvoyait un arbre d’accessibilité vide pour ces fenêtres. Les captures attestent
leur ouverture ; elles ne suffisent pas à conclure sur l’accès à chacun de leurs
contrôles. Ce constat n’établit pas un défaut applicatif confirmé. La sauvegarde
complète, exercée séparément depuis l’interface, contient bien les 180 ULogs.

Le résultat final des suites, de la signature, de la notarisation et de la
publication figure dans la [recette de prérelease](RELEASE-0.8.1-BETA.md).
