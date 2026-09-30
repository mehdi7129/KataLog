# KataLog — backlog exécutable 0.5.3 / 0.6.0

**Suivi de développement du 30 septembre 2026 : 117 tickets suivis, aucune release 0.6.0 publiée.**
Référence installée : **0.5.2 (7)**, parseur **1.2.0**. Branche en développement : parseur **1.4.0**, projection SQLite **7**, révisions d’analyse **1**. Les nouveaux écrans ont été approuvés le 30 septembre ; les builds stables 0.6.0 les activent par défaut. La Preview conserve un stockage distinct. L'installation utilisateur
sur macOS 27 a réussi. L'audit de référence compte **87 tests Python, 79 Swift et
9 Node réussis, soit 175 tests**. Cela ne qualifie ni macOS 15 sur machine réelle,
ni plusieurs années d'historique, ni une collecte réelle de 500 drones.

La passe locale précédant la recette GCS compte **523 tests uniques réussis :
302 Python privés, 208 Swift et 13 Node**, sans échec ni skip. Le gate Python
public exécute 302 cas : 301 réussissent et l’absence du corpus privé est
annoncée séparément, sans skip inattendu. Les sous-suites et les recettes du
helper/SDK ne sont pas ajoutées à ces totaux. Le helper est reconstruit sur les
sources gelées. Le package preview Developer ID 0.6.0 (8) possède sept gates
locaux réussis et l’audit final précommit est validé. La CI hébergée était
indisponible lors de la tentative observée : quatre jobs refusés avant runner, zéro étape exécutée,
aucun test ou build distant. La notarisation et le parcours quarantiné ont leurs
portes séparées.
L’installation 0.5.2 reste inchangée.

La recette suivante a révélé un défaut d’isolation GCS de la Preview et une
reconnexion initiale prématurée ; leurs corrections passent 38 tests ciblés,
puis 214 tests Swift complets sans échec ni skip. Le premier gate Swift de ces
corrections avait échoué sur un cas simulé de retry GCS ; sa cause exacte reste
inconnue. Le package corrigé 0.6.0 (9) a d'abord passé sept gates locaux, sans
notarisation. Sa nouvelle recette notarise l'app et le DMG, valide les tickets
du helper et de l'app dans le volume monté et passe neuf gates sur macOS 27.0.1.
La matrice conserve les gels et résultats historiques séparément.
La licence **GPL-3.0-only** a été choisie par le titulaire. La CI attend la
visibilité publique et n’alloue aucun runner pendant que le dépôt est privé.

Ce document transforme le [plan de version](PLAN-0.6.0.md) en tâches avec
responsabilité, dépendance et recette. Le [rapport d'audit](AUDIT-2026-09-30.md)
porte les preuves et limites des constats C01–C12. Les résultats et les limites sont consignés dans [IMPLEMENTATION-0.6.0.md](IMPLEMENTATION-0.6.0.md). Chaque état distingue le code, sa preuve ciblée et la qualification restante ; aucun test simulé ne ferme une recette matérielle.

## Lecture et suivi

- **P1** : à traiter tôt pour la cohérence, la conservation ou l'exploitation de
  l'historique. **P2** : nécessaire à la version, après ses dépendances.
  **P3** : amélioration pouvant être différée explicitement. Il s'agit d'une
  priorité de développement, pas d'une nouvelle gravité d'incident observé.
- Chaque ticket possède un ID unique, un responsable technique, ses dépendances,
  une recette et un état de suivi vérifiable. La recette complète reste la condition de fermeture, même lorsque le code et ses tests ciblés existent.
- États : **Validé ciblé** = critères logiciels exercés ; **Validé simulé** = protocole/queue sans matériel ; **Backend validé · UI preview** ou **Implémenté · preview** = code présent, recette visuelle restante ; **Partiel** = le libellé indique un critère encore ouvert ; **Qualification externe** ou **Décision requise** = condition distincte du code. **En cours** indique les gates d’intégration finales. Aucun de ces états n’annonce une livraison.
- Aucun changement de visibilité, release ou choix de licence ne découle de ce
  plan. La publication et le choix de licence font l'objet de décisions explicites.
- Les nouvelles interfaces sont maquettées en bento monochrome clair/sombre avec
  accents, puis approuvées avant intégration. Les tests et migrations peuvent
  avancer indépendamment de cette validation visuelle.

### Définition commune de « terminé »

1. Comportement et limites documentés ; API/stockage compatibles ou migration
   réversible testée. Origine, SHA, identités et annotations sont préservés.
2. Cas nominal et cas d'erreur pertinents exécutés sur fixtures reproductibles,
   avec résultats exacts. Tests privés, simulés et matériels restent distingués.
3. Toute opération longue montre son état ; l'annulation et les réponses périmées
   ne publient pas une réussite, un fichier partiel ou un résultat obsolète.
4. UI adaptée aux thèmes et clavier ; nouveaux écrans conformes aux maquettes
   validées. Toute limite de rendu/échantillonnage est annoncée.
5. Aucun ULog, chemin personnel, adresse GCS réelle, position, UUID réel, stock
   privé ou secret dans les fichiers publics, captures de démonstration et CI.
6. Revue du diff, documentation et preuve de recette associées au ticket ; un
   résultat synthétique ne devient pas une qualification de flotte réelle.

## Référence historique 0.5.2 (7)

Le tableau ci-dessous décrit le point de départ de l’audit, avant les changements. Les états actuels des 117 tickets figurent dans les tableaux par lot et la matrice de preuves liée ci-dessus.

| Bloc | Déjà réalisé | Travail restant dans ce backlog | Statut |
|---|---|---|---|
| Distribution L1 | Helper embarqué, résolveur commun, versions/hashes/licences, app/DMG signés et notarisés ; fonctionnement et installation utilisateur macOS 27 | Mac vierge/macOS 15, téléchargement quarantiné, remplacement et qualification finale des futures builds | Socle réalisé en 0.5.2 ; qualifications restantes Non commencé |
| Stabilisation S | Défauts/écarts auditables et reproductions ciblées | Correctifs C01/03/04/05/06/07/09/11/12 ; disponibilité minimale C02 ; état occupé C08 | Non commencé |
| Cache S10 | Cache de détail courant existant | Conservation après hausse de parseur et perte de source | Non commencé ; prérequis avant hausse du parseur |
| L0, L2, L3, L4 | Contrats/SQLite/annotations/exports actuels constituent la baseline | Nouveaux contrats, conservation, migrations/index et périmètre commun | Non commencé |
| GCS | Collecte, destination persistante, arrêt/retry/cache et limite de 2 UUID actuels | File durable/inventaires bornés/Tout collecter avec appareil hors ligne et nouvelles recettes | Non commencé |
| L5, L6, L7 | Certains modèles de données préparatoires existent | Conservation/traduction événements, séries et updater | Non commencé |
| L8 | Les175tests audit et gates distribution0.5.2 sont des preuves historiques | CI et recette des nouveaux lots, performance/accessibilité/matériel/préparation publique | Non commencé |

Le registre actuel et les numéros manuels ne sont pas à supprimer. L'association
avancée et datée entre plusieurs contrôleurs et un drone physique reste après
0.6 ; le présent backlog préserve d'abord l'identité source et ses annotations.

## Ordre conseillé et portes de validation

| Porte | Travail | Condition pour poursuivre |
|---|---|---|
| G0 | Pré-lot S, baseline et décisions L0 | C01–C12 reproduits et correctifs prioritaires vérifiés ; définitions communes écrites |
| G1 | L0, recette restante L1, prototype L7 | Contrats versionnés, corpus autonome et packaging stable ; maquettes approuvées avant les nouvelles UI |
| G2 | L2 | Sauvegarde/restauration et copie vérifiée validées avant migration destructive ou remplacement de bibliothèque |
| G3 | Socle SQL L3 + GCS durable | Migration sans perte, lectures paginées exactes, écritures coordonnées et file persistante ; intégration carte et banc UI final continuent avec L4 |
| G4 | Scope et rapports de sélection L4 | Périmètre et comptes identiques entre app, queries et exports des données actuelles ; reset retrouve tout ; enrichissements de fiche intégrés avec L5/L6 |
| G5 | L5/L6 | Événements inconnus préservés, séries et lacunes correctes, anciennes analyses toujours consultables |
| G6 | L7/L8 | Recettes de mise à jour, macOS, confidentialité et publication réunies ; approbation de publication distincte |

Chemin principal : **contrats initiaux L0 + S → compléments L0 → L2 → socle L3 → L4 → L8**. L1 est surtout une
qualification du socle déjà livré ; extraction L5, prototype L7 et maquettes
peuvent avancer en parallèle. L6 dépend des contrats L0 et de l'intégration
L3/L4/L5. Les adaptations GCS prennent leurs dépendances dans ces mêmes lots.
Ne pas modifier simultanément `Models.swift`, `LibraryStore`, les formats SQLite
et JSON sans responsable d'intégration et ordre de fusion explicites.

Les portes portent sur des fonctionnalités, pas sur la fermeture de tous les
tickets d'un lot : L3-09 et le banc final L3-12 utilisent le scope Core L4-01.
La matrice d'export L4-12 est spécifiée avant les extractions ; son intégration
aux événements/séries est vérifiée ensuite en L5-05/L6-08. Aucun cycle de tâches
ne doit être introduit pour imposer artificiellement un ordre strict entre ces lots.

## Pré-lot S — correctif 0.5.3 proposé

Cette version courte corrige les incohérences actuelles ; elle ne remplace pas
les lots de grand historique. S10 doit être fermé **avant toute hausse de version
du parseur** ; le correctif 0.5.3 propose déjà de préserver l'accès à
l'ancien cache, et L2 approfondit le versionnement des analyses. Aucune release 0.5.3 n'est créée par ce document.

| ID / constat | P | Tâche et responsabilité | Dépendances | Recette / critère de sortie | État |
|---|---|---|---|---|---|
| S01 / C01 | P1 | Préserver la même identité canonique résumé/fiche sans UUID ; moteur `analyzer.py`, Core modèles/annotations, `LibraryStore` | Reproduction synthétique C01 | Carte anonyme avec/sans nom : numéro reste visible après chargement ; Identifier modifie la même clé ; fiche HTML/JSON et export flotte gardent SHA/identité ; familles restent inchangées | Validé ciblé · identité/exports |
| S02 / C02 | P2 | Signaler minimalement qu'un chemin source est actuellement inaccessible, sans effacer sa provenance ; `LibraryStore`, fiche/moteur | Contrat transitoire compatible JSON1 | Source supprimée ou SD retirée signalée avant lecture/réanalyse ; résumé conservé ; aucune disparition définitive inférée ; états complets et réassociation livrés en L2-09 | Validé ciblé · disponibilité |
| S03 / C03 | P2 | Décoder la phase GCS et calculer une progression fidèle ; `GCSModels`, `GCSStore`, `GCSCollectionView`, `gcs_collect.py` | Fixtures phase/transfert | Drone à 100 % puis HTTP à 0/25/100 % ne déclare pas copie Mac terminée ; vérification et analyse visibles ; cache/stop/retry et deux appareils couverts ; fin seulement après publication vérifiée | Validé simulé · phases GCS |
| S04 / C04 | P2 | Rendre les cellules d'occurrences HTML cohérentes avec filtres ; `ReportRenderer`, `ReportInteraction`, tests DOM | Reproduction texte avec espaces variables | Deux textes d'un même groupe normalisé, recherche ne conservant qu'un texte : groupe, cellule, logs et messages affichent le même sous-périmètre ; reset retrouve les deux | Validé ciblé · Core/DOM |
| S05 / C05 | P2 | Garder une famille sélectionnée accessible lorsqu'elle devient vide ; `main.swift`, annotations | Fixture reclassification active | Reclassification ou changement de drone : valeur active avec compteur zéro et reset accessible, ou réconciliation explicitement annoncée ; aucun filtre caché bloquant | Implémenté · preview |
| S06 / C06 | P2 | Clarifier registre global et historique filtré ; `DroneRegistryView`, navigation | Décision de périmètre dans L0-02 | Un filtre drone ne semble pas filtrer un registre qui reste global ; libellés/compteurs exacts ; drones sans log gardent un accès ; état recherche vide différent de registre vide | Implémenté · preview |
| S07 / C07 | P2 | Unifier définition du profil et traitement failsafe ; Core agrégats, native, HTML | L0-03 peut être cadré avant le code | Failsafe sans texte : indicateur réel distinct, aucun message fabriqué ; même profil ou différence explicitement annoncée ; famille/niveau/texte n'inventent pas de correspondance | Validé ciblé · oracle partagé |
| S08 / C08 | P2 | Ajouter état occupé d'export unique et garde immédiate ; `LibraryStore`, export fiche/native | Contrat opérations L0-09 minimal | Doubles clics ne lancent pas deux exports actifs ; feedback immédiat et succès/erreur explicites ; atomicité préservée ; progression/annulation complète reportées à L4-09 | Validé ciblé · garde export |
| S09 / C09 | P2 | Qualifier la tuile RTK par instance et durée observée ; `FlightDetailView`, métriques Core | Fixture récepteurs différents | Instance 0 absente ou de moindre couverture, instance 1 disponible : récepteur et dénominateur visibles ; aucune agrégation implicite ; données manquantes distinctes de 0 % | Validé ciblé · instance/couverture |
| S10 / C10 | P1 | Conserver l'accès à une ancienne fiche en cache après upgrade sans source ; `analyzer.py`, contrat détail | Avant changement parseur ; stratégie version d'analyse L0-01 | Détail version N calculé puis source retirée, parseur N+1 : ancienne fiche lisible et signalée ; recalcul proposé sans fausse réussite ; copie retrouvée par SHA crée nouvelle analyse sans perte | Validé ciblé · cache/révisions |
| S11 / C11 | P2 | Exposer couverture et qualification de durée de vol courte ; `analyzer.py`, Core métriques, fiche/rapports | L0-03 règle de couverture | Log de 1,5 s / landed de 0,1 s ne prétend pas avoir une durée complète connue ; bornes/portion observée distinctes ; cas courts, zéro/une/deux mesures et lacunes testés | Validé ciblé · couverture courte |
| S12 / C12 | P2 | Empêcher verdict complet quand un inventaire échoue ; `GCSStore`, `GCSCollectionView` | Fixture inventaire multi-appareils | A en cache et B inventaire en erreur → incomplet ; A téléchargé et B erreur → partiel ; reprise B réussie permet verdict complet et compte couvert/attendu exact | Validé simulé · verdict partiel |

**Porte du correctif :** recettes S01–S12 exécutées ; non-régression des 175 tests
et des contrats existants, sources intactes, DMG reconstruit/signé/notarisé et
contrôlé si cette version est effectivement livrée. Une difficulté de protocole
GCS n'est pas transformée en preuve d'arrêt distant.

## L0 — Contrats, baseline et décisions

| ID | P | Tâche et responsabilité | Dépendances | Recette / critère de sortie | État |
|---|---|---|---|---|---|
| L0-01 | P1 | Séparer versions DB, JSON, protocole et calcul ; Core contrats, `analyzer.py`, docs | Baseline 0.5.2 | Table de compatibilité écrite ; JSON1/scan/snapshot/detail gardés ; lecteur refuse lisiblement version future ; conservation de cache spécifiée avant recette S10 | Validé ciblé · contrats |
| L0-02 | P1 | Spécifier `SelectionScope` et périmètre du registre/fiche/carte/rapport ; Core, produit/native | Audit C06 et baseline | Matrice écran×filtre, dates inconnues, multi-identité, familles/niveaux/texte/statuts/masquages et reset ; pas d'ambiguïté entre registre et historique | Validé ciblé · matrice scope |
| L0-03 | P1 | Définir mesures et comptages ; Core agrégats/moteur/report | Audits C07/C09/C11 et baseline | Glossaire messages/événements/groupes/logs/contrôleurs/failsafe/vol/couverture ; oracle synthétique ; famille ne compte pas une panne confirmée ni somme d'incidents | Validé ciblé · oracle |
| L0-04 | P1 | Définir identité, source et date structurées ; Core modèles, moteur, annotations | S01/S02 | Contrôleur/drone physique/carte distingués ; confiance/provenance ; UTC vs calendrier sans fuseau ; numéro stock non clé ; pas de fusion homonyme | Validé ciblé · provenance |
| L0-05 | P1 | Définir formats backup/archive/révisions/cache/événements/séries/pages ; Core + helper | L0-01/02/04 | Exemples synthétiques validés des deux côtés ; taille bornée, IDs stables, contrats d'erreur et réponse périmée ; inconnus conservés | Validé ciblé · contrats bornés |
| L0-06 | P1 | Générer corpus autonome partageable ; `Tests`, outils fixtures | L0-01..05 | Dates inconnues, multi-UUID/récepteur, partial/error, sources absentes, familles nombreuses, tags, événements/dictionnaires et pics/gaps ; aucune dépendance à ULog privé pour gates autonomes | Validé ciblé · corpus public |
| L0-07 | P1 | Créer grand index déterministe et oracle de résultats ; outils benchmark, moteur/Core | L0-03/06 | 500 identités, 50 000 résumés, 5 millions de messages multi-années, numéros partagés et drones sans log ; jeux d'IDs/agrégats exportés ; ce n'est pas un test de parsing de 50 000 ULog | Validé ciblé · 50k/5M |
| L0-08 | P1 | Mesurer baseline et fixer budgets ; outils benchmark, QA | L0-07 | Cold/warm, disque, p50/p95, RSS Swift/helper/navigateur, taille rapports et réimport ; protocole répétable ; objectifs fixés avant optimisation et limites écrites | Validé ciblé · moteur et banc natif final |
| L0-09 | P1 | Définir coordination des opérations et doubles instances ; Core services, stores | L0-05 | Tableau import/collecte/archive/backup/migration/export/update, verrou writer et révisions ; test deux processus/configs, propriétaire du lock disparu et relance ; aucun global preference hack | Validé ciblé · leases/process |
| L0-10 | P2 | Maquetter flux nouveaux et variantes d'état ; SwiftUI/design | L0-02/03/09 | Scope/historique/stockage/courbes/événements/update + vide/loading/erreur/offline, clair/sombre/petit écran ; approbation visuelle enregistrée avant intégration | Preview · approuvée, recette en fonctionnement restante |

## L1 — Distribution autonome : qualification restante

Le helper, le résolveur commun, les versions épinglées, la signature et le DMG
existent en 0.5.2. Les tickets suivants qualifient et entretiennent ce socle ; ils
ne demandent pas de reconstruire l'architecture déjà livrée.

| ID | P | Tâche et responsabilité | Dépendances | Recette / critère de sortie | État |
|---|---|---|---|---|---|
| L1-01 | P1 | Formaliser matrice macOS/architecture/runtime ; packaging Core/outils | L0-01 | macOS 15 minimum et27 supporté, Apple Silicon, limites Intel explicites ; chaque Mach-O/dépendance/minimum audité ; version app/build/parser/runtime cohérente | Implémenté · audit final attendu |
| L1-02 | P1 | Faire recette d'app réellement téléchargée/quarantinée ; QA macOS, DMG | L1-01 | Mac macOS 15 disponible et poste27 : télécharger→Applications→éjecter→launch, sans Python/Homebrew/Xcode/gh ; Gatekeeper accepté ; preuve machine/OS/architecture | Qualification externe · macOS15/27 |
| L1-03 | P1 | Qualifier remplacement d'ancienne app et déplacement ; QA distribution, stores | L0-09, S | Fermeture/remplacement manuel, app dans deux emplacements ; même bibliothèque/numéros/familles/destination ; copie obsolète détectée ou parcours documenté sans perte | Qualification externe · remplacement |
| L1-04 | P2 | Rendre build et audit reproductibles depuis checkout propre ; outils packaging | L0-06, L1-01 | Hashes/licences/manifeste vérifiés ; chemins de compilation neutralisés ; helper manquant/mauvaise version refusé ; aucune dépendance à path du poste | Implémenté · package final attendu |
| L1-05 | P2 | Mesurer taille/démarrage/helper et prévoir refus runtime ; Core resolver/outils | L0-08, L1-04 | Cold/warm et environnements Python/PATH hostiles ; import/fiche/report/simulateur restent autonomes ; message de réparation compréhensible si bundle endommagé | Validé ciblé · helper final et banc natif |
| L1-06 | P1 | Automatiser contrôles app/DMG/ZIP ; `verify-distribution.py`, release tooling | L1-04 | Outils éprouvés sur fixtures de manifeste/symlinks/contenus/signatures/tickets/SHA et packages de staging ; gate final exécuté en L8-10 après audit L8-09, avec mêmes bits dans DMG/ZIP | Validé ciblé · Preview 9 notarisée |

## L2 — Conservation, sauvegarde et archives

| ID | P | Tâche et responsabilité | Dépendances | Recette / critère de sortie | État |
|---|---|---|---|---|---|
| L2-01 | P1 | Introduire coordinateur writer et capture révisions ; Core service proposé, stores/helper | L0-09 | Imports/configs sérialisés ; deux instances ne perdent pas les annotations ; lock expiré récupérable ; lectures courtes restent possibles | Validé ciblé · writer lease |
| L2-02 | P1 | Concevoir manifeste backup et inventaire des sources ; service backup proposé | L0-05, L2-01 | Versions, date, contenus/configs, SHA/taille/statut sources et omissions ; distinguer backup analyses+réglages / complet ULog ; aucun secret Trousseau exporté | Validé ciblé · manifeste |
| L2-03 | P1 | Capturer DB via API SQLite backup et configs cohérentes ; moteur/stores | L2-01/02 | Backup pendant import/WAL et édition de numéro produit une révision commune ; integrity_check et comptes/IDs oracle ; pas simple copie isolée library.sqlite | Validé ciblé · SQLite/WAL |
| L2-04 | P1 | Copier ULog pour backup complet de manière bornée ; service backup/archives | L2-03 | Taille prévue/espace, SHA et absence/mutation/perms détectés ; données disponibles listées ; annulation/disque plein ne publie pas un backup complet mensonger | Validé ciblé · préflight/ENOSPC |
| L2-05 | P1 | Valider backup et restaurer dans staging ; service restore proposé | L2-02..04 | Formats/hashes/liens/contenus/taille décompressée vérifiés ; backup corrompu/incompatible ou chemin échappant au staging refusé ; aucune écriture active | Validé ciblé · staging/hash |
| L2-06 | P1 | Prévisualiser et basculer restauration avec rollback ; Core/stores UI Stockage | L2-05, L0-10 | Comptes et sources annoncés, annotations conservées ; ancien état gardé ; panne/annulation à chaque étape ne remplace pas une bibliothèque saine | Backend validé · UI preview |
| L2-07 | P1 | Réassocier archives et chemins à un nouveau Mac/dossier ; moteur/restore UI | L2-06, L0-04 | Même SHA/identités, ancienne provenance conservée ; dossier collecte préservé ou inaccessible signalé ; jobs actifs restaurés interrompus, jamais transférant | Validé ciblé · relink/restart |
| L2-08 | P1 | Ajouter archivage SD optionnel choisi ; service archives proposé, import UI | L2-01, L0-10 | Référencer ou copier ; temporaire→taille/SHA→publication→import ; SD retirée puis détail/réanalyse possibles ; copie finale GCS réutilisée | Backend validé · UI preview |
| L2-09 | P1 | Réconcilier disponibilité et retrouver source déplacée par SHA ; moteur/Stockage | S02, L2-07/08 | Dossier débranché/inaccessible/manquant/modifié distingué ; scan borné choisi ; mauvaise copie refusée ; historique ne disparaît pas | Backend validé · UI preview |
| L2-10 | P1 | Versionner analyses et rétention de caches ; moteur/schema/Core | S10, L0-01, L2-03 | Ancien détail reste lisible sans source ; nouveau calcul ajoute revision/version ; nettoyage ne détruit pas la dernière analyse exploitable sans décision explicite | Validé ciblé · révisions schéma1 |
| L2-11 | P2 | Définir gestion stockage et suppressions réversibles ; UI Stockage/services | L2-06/10, L0-10 | Tailles sources/cache/DB, éléments sélectionnés, effet annoncé ; fichier source utilisateur pas supprimé avec cache ; suppression logique/restauration et recovery vérifiés | Backend validé · impact historique expliqué en preview |
| L2-12 | P1 | Tester crashes, full disk et journal de récupération ; QA backup/archive | L2-03..11 | Injection arrêt avant/après publication, crash writer, fichiers modifiés, volumes débranchés ; reprise idempotente et ancien état valide ; preuves sans données privées | Validé ciblé · neuf injections SIGKILL |

## L3 — Grand historique, requêtes et migration

| ID | P | Tâche et responsabilité | Dépendances | Recette / critère de sortie | État |
|---|---|---|---|---|---|
| L3-01 | P1 | Spécifier projections normalisées et indexes ; moteur SQLite | L0-03/05/07 | Logs/messages/dates/contrôleurs/sources/analyses indexés, origine brute conservée ; FTS seulement selon requêtes/banc ; projections reconstruisibles | Validé ciblé · projection6 |
| L3-02 | P1 | Migrer transactionnellement les bases 0.5.1/0.5.2/0.5.3 ; moteur/migration proposée | L2-03/06, L3-01 | Backup vérifié préalable ; mêmes SHA/IDs/messages/annotations ; chaque base d'entrée qualifiée ; interruption reprise ou rollback ; version future refusée ; pas d'écrasement legacy | Legacy 0.5.1/0.5.2 validés · source 0.5.3 absente |
| L3-03 | P1 | Créer repository avec un writer et révisions de lecture ; helper/Core service proposé | L2-01, L3-02 | Reads pendant import, pas de longue transaction bloquant WAL ; conflits et retries bornés ; réponses portent une revision cohérente | Validé ciblé · révision/lease |
| L3-04 | P1 | Implémenter agrégats SQL par scope ; moteur/Core | L3-03, L0-02/03 | Comptes/durée/couverture/familles/failsafe identiques à oracle, y compris dates inconnues, error/partial, numéros communs et messages masqués | Validé ciblé · agrégats exacts |
| L3-05 | P1 | Implémenter pages de logs à curseur stable ; moteur/Core | L3-03, L0-05 | Tri date+ID stable, dates identiques/inconnues ; aucune omission/répétition pendant import ; revision et résultat expiré gérés | Validé ciblé · curseurs |
| L3-06 | P1 | Implémenter pages de groupes/occurrences et recherche ; moteur/Core | L3-03/04 | Unicode/accents, espaces, codes erreur et texte échappé ; requête bornée paramétrée ; mêmes IDs que référence ; pas de plafond silencieux100 | Validé ciblé · pages/recherche |
| L3-07 | P1 | Brancher LibraryStore sur agrégats/pages ; Core/`LibraryStore`, SwiftUI | L3-04..06, L0-10 | Pas de tableau global de tous messages ; load/error/empty/cancel ; changements rapides n'affichent jamais anciennes réponses | Implémenté · preview |
| L3-08 | P1 | Intégrer annotations aux projections et invalidations ; moteur/annotations | L3-03/07 | Numéro/famille changés mettent à jour compteurs, groupe, scope et export même revision ; conflits gardés ; anciennes clés migrées sans fusion | Validé ciblé · annotations |
| L3-09 | P2 | Charger carte et aperçus par périmètre à la demande ; moteur/MapKit | L3-05/07, L4-01 | Limite80 trajectoires annoncée ; compte total indépendant des points chargés ; gaps/points seuls conservés ; réponse de scope périmé rejetée | Implémenté · preview/carte80 |
| L3-10 | P2 | Paginer registre flotte, y compris sans log ; repository identité/native | L0-04, L3-03/07 | 500 identités recherchables, last-log/last-GCS/source/stock distincts ; aucun log n'est « fiable » par défaut ; deux contrôleurs homonymes non fusionnés | Backend validé · observations datées |
| L3-11 | P1 | Batcher import GCS et mise à jour de projections ; `LibraryStore`, moteur, GCSStore | L3-03/07, GCS-02 | Plusieurs fichiers finis partagent l'import sérialisé ; réimport n'exporte pas tout le grand snapshot à chaque job ; SHA et auto-import exacts, erreurs par fichier | Validé simulé · import batch |
| L3-12 | P1 | Qualifier banc grand index et comparer oracle ; QA/outils benchmark | L3-04..11, L0-08 | 50k/5M, requêtes p50/p95, RAM/cold-start/disque ; parité ID et comptes ; budgets manqués corrigés et limites consignées | Validé ciblé · moteur 8/8 et natif final |

## GCS — évolution de collecte rattachée à L3/L4

Les trois correctifs de cohérence immédiate sont S03/S12 et, si nécessaire,
une partie de GCS-01. Ce bloc prépare la file durable et l'usage quotidien d'une
flotte qui apparaît/disparaît. Il ne remplace pas le collecteur par des commandes
de vol : accès limité aux logs de la flotte explicitement autorisée.

| ID | P | Tâche et responsabilité | Dépendances | Recette / critère de sortie | État |
|---|---|---|---|---|---|
| GCS-01 | P1 | Débloquer Tout collecter quand un job hors ligne est pending ; GCSStore/UI | S12, L0-09 | A hors ligne en attente, B autorisé visible avec nouveaux logs : ajouter B sans arrêter/abandonner A ; déduplication identité/source/destination ; aucun job annulé silencieusement | Validé simulé · ajout hors ligne |
| GCS-02 | P1 | Migrer jobs/batches/inventaires vers stockage durable indexé ; GCS modèles/repository | L2-03, L3-02/03 | Import de file JSON existante, host/destination/UUID/tentatives préservés ; jobs actifs interrompus au restart ; historique séparé des actifs ; pas de réécriture de toute file à chaque octet | Validé ciblé · SQLite durable |
| GCS-03 | P1 | Rendre inventaires incrémentaux ou paginés ; Python/protocole/Core | L0-05, GCS-02 | Inventaire volumineux dépasse4 MiB total sans dépasser limites d'un frame ; séquence/révision/couverture/fin et erreurs explicites ; aucun appareil entier perdu par ligne énorme | Validé simulé · frames bornés |
| GCS-04 | P2 | Éviter construction quadratique et validations cache muettes ; GCSStore/Python | GCS-02/03, L0-08 | Index unique de jobs ; enqueue hors rendu / MainActor ; validation SHA conserve preuve et annonce progression ; mesure latence/write-size sur grande file | Validé simulé · 500×100 |
| GCS-05 | P1 | Qualifier autorisation, fraîcheur et télémétrie malformée ; `GCSModels`, discovery/Python | L0-05, GCS-03 | Appareil non autorisé jamais collecté ; entiers invalides isolés par appareil ; présence stale/horodatage inconnu annoncée ; un mauvais champ ne masque pas tous les bons appareils | Validé simulé · autorisation |
| GCS-06 | P1 | Borner annulation d'un helper défaillant ; Core ProcessService/helper | L0-09 | Process synthétique ignorant SIGTERM : délai de grâce puis escalade bornée, pipes clos et process reap ; UI et slots libérés ; arrêt local distinct d'une annulation FTP distante | Validé ciblé · process récalcitrant |
| GCS-07 | P1 | Qualifier queue offline/retry/retarget/contextes ; GCSStore/policy | GCS-01/02/05/06 | Host/destination changés, volume absent, reboot, remoteBusy, erreur import ; seulement erreurs transitoires retentées ; pas de reprise silencieuse après stop ni fallback Téléchargements | Validé simulé · contextes/retry |
| GCS-08 | P2 | Pipeliner inventaire et copie de manière contrôlée ; policy/Python | GCS-02..07, L0-08 | Un listing/transfert FTP par UUID ; maximum 2 UUID ; copies sur autre UUID possibles seulement après preuve ; premier transfert et slots mesurés ; aucune hausse de concurrence non qualifiée | Validé simulé · qualification physique distincte |
| GCS-09 | P1 | Étendre simulateur et banc de file/inventaire ; Tests GCS/benchmark | GCS-01..08 | Homonymes, caches altérés, logs croissants, HTTP incomplet, réponses tardives, 500 identités synthétiques ; couverture exacte/une copie ; limites protocole documentées | Validé simulé · banc flotte |
| GCS-10 | P1 | Faire recette réelle à deux drones, puis qualification progressive ; QA matériel/docs | GCS-09, L1-02, matériel disponible | Destination persistante, collect-all/stop/retry/offline/cache/host/mise à jour ; origine et SHA vérifiés ; deux appareils réels ne qualifient pas500 ; request-ID/hash distant/reprise octets non promis | Qualification externe · deux drones |

## L4 — Périmètre commun, vues, navigation et rapports

| ID | P | Tâche et responsabilité | Dépendances | Recette / critère de sortie | État |
|---|---|---|---|---|---|
| L4-01 | P1 | Implémenter et versionner SelectionScope partagé ; Core/native/repository | L0-02/05, L3-04/07 | Multi-identité/période/inconnues/famille/niveau/texte/statut/masquage ; même scope app/query/report ; changement invalide annule/rejette ancienne réponse | Validé ciblé · scope partagé |
| L4-02 | P1 | Ajouter barre de scope et sélecteur searchable multi-drone ; SwiftUI | L4-01, L0-10, L3-10 | Sélection clavier de 500 contrôleurs par nom/stock/identité ; scope actif toujours lisible ; reset unique ; numéro partagé ne sélectionne pas une identité arbitraire | Implémenté · preview |
| L4-03 | P1 | Construire Historique dédié avec pages/tri/recherche ; SwiftUI/repository | L3-05/06, L4-01/02 | Récent par défaut modifiable ; SHA/fichier/drone/date et errors accessibles ; résultats >100 retrouvables sans export ; chargement suivant/erreur/retry au clavier | Implémenté · preview |
| L4-04 | P2 | Rendre registre et état vide cohérents avec son périmètre ; DroneRegistryView | S06, L3-10, L4-01 | Registre vide vs recherche zéro distingués ; no-log/offline inclus selon contrat ; numéros et identités séparés ; compte rendu ne contredit pas le filtre | Implémenté · preview |
| L4-05 | P1 | Enregistrer vues nommées et règles de masquage réversibles ; store vues proposé, Core | L2-01/03, L4-01 | Vue restaurée après restart ; aperçu messages concernés ; masqués conservés, compteur/afficher/reset ; migrations/backup gardent les règles | Validé ciblé · vues/masques |
| L4-06 | P2 | Rendre profil et classement de familles actionnables ; dashboard/Core | S07, L3-04, L4-01 | Ensemble et ordre des axes choisis persistants, zéros gardés sous filtre, tout changement d'axes annoncé ; classement fréquent séparé en logs uniques/dénominateur ; familles toutes accessibles ; clic/clavier ouvre occurrences | Implémenté · preview |
| L4-07 | P1 | Créer preview d'export scope/complet/données disponibles ; UI Reports/Core | L4-01/05, L0-10 | Comptes avant export, filtres/date/révision, masqués, données incluses/absentes et taille ; sélection vide traitée ; report n'est pas prétendu copie complète ULog | Validé ciblé · preview scope/privacy/couverture |
| L4-08 | P1 | Capturer export cohérent DB+annotations+scope ; service export proposé | L2-03, L3-03, L4-07 | Import et édition pendant export : une revision cohérente ; snapshot temporaire via backup API ; pas longue transaction WAL ni mélange de numéros | Validé ciblé · capture cohérente |
| L4-09 | P1 | Générer rapports à partir de pages/stream ; ReportRenderer/service | L4-08, L3-05/06 | Export de toutes pages indépendamment de pages affichées ; RAM bornée ; progression/annulation et publication atomique ; double demande gardée via S08 | Validé ciblé · stream/cancel |
| L4-10 | P1 | Définir budget HTML et variante synthèse+données jointes ; Core/report HTML | L0-08, L4-09 | Document dépassant budget propose format explicite ; jamais truncation silencieuse ; données jointes intégrales sélectionnées avec manifeste et SHA ; mesure navigateur | Validé ciblé · données jointes |
| L4-11 | P1 | Aligner native/HTML/JSON sur un oracle de scope ; Core/Node/DOM tests | S04/S07, L4-01/09 | INFO alerte, failsafe sans texte, dates inconnues, partial/error, variantes espaces, familles manuelles, no-log et homonymes ; mêmes IDs/comptes et reset | Validé ciblé · oracle/DOM |
| L4-12 | P2 | Spécifier matrice export fiche : paramètres/topics/séries/événements ; fiche/report | L4-07/09, L0-05 | Choix synthèse/détail et sections présentes/absentes définis sur fixtures de contrat ; initial/changed params, instances, provenance/couverture ; événements/séries effectifs branchés et testés en L5-05/L6-08 | Validé ciblé · détail typé |
| L4-13 | P2 | Ajouter options explicites de partage d'un rapport ; UI/report | L4-07/12 | Preview chemins/identités/coordonnées à inclure ; rapport interne traçable ; rapport partagé n'expose pas une donnée exclue dans payload/HTML/metadata | Validé ciblé · canaries privacy |
| L4-14 | P1 | Tester HTML réel, sans JS et impression ; QA navigateur | L4-10..13 | Safari/Chrome clavier, thème, DOM long/Unicode/texte hostile, radar, zéro résultat, print scope puis restitution après annulation ; suite Node seule insuffisante | Qualification externe · navigateurs/print GUI ; WK validé |
| L4-15 | P2 | Adapter layout, thème Système et focus ; SwiftUI/design | L0-10, L4-02..07 | Petit espace utile et texte agrandi, colonnes/scroll adaptés ; Système/Clair/Sombre persistants ; fermeture panel/sheet rend le focus ; actions toujours accessibles | Preview · thèmes/petit écran |

## L5 — Événements et explications traçables

| ID | P | Tâche et responsabilité | Dépendances | Recette / critère de sortie | État |
|---|---|---|---|---|---|
| L5-01 | P1 | Extraire et conserver événements binaires bruts ; `px4_events.py` proposé, Core | L0-05/06, L2-10 | Chaque occurrence : ID, args bruts, timestamp, séquence, instance, niveaux interne/externe, provenance ; unknown/internal conservés ; nombre exact comparé source | Validé ciblé · brut sans perte |
| L5-02 | P1 | Préserver provenance des textes, dropouts et infos ; analyzer/flight_data/Core | L0-04/05, L5-01 | Tags normal/tagged, événements dropout datés, métadonnées infos multiples/boot/performance disponibles gardés ; tailles et types bornés ; noms et inconnus non inventés | Validé ciblé · tags/dropouts/infos |
| L5-03 | P1 | Associer dictionnaire exact firmware avec empreinte ; service dictionnaire proposé | L5-01, L0-01 | Métadonnée embarquée ou association locale prouvée ; mauvais hash/firmware/structure/taille décompressée refusé ; aucun fallback silencieux master | Validé ciblé · dictionnaire SHA |
| L5-04 | P1 | Décoder arguments et niveaux sans perte ; moteur/Core | L5-03 | Dictionnaire exact synthétique, unknownID, payload court/extra, enums/inconnus/endian ; ID/args bruts restent ; états Traduit/Manquant/Incompatible/Inconnu/Invalides exposés | Validé ciblé · types/niveaux |
| L5-05 | P1 | Intégrer événements aux requêtes/chronologie/export ; Core/repository/UI | L3-03/06, L4-01/12, L5-04 | Messages et événements ont IDs/provenances distincts ; pas fusion heuristique texte similaire ; filtre niveau interne par défaut avec accès externe ; counts uniques exacts | Backend validé · UI preview |
| L5-06 | P1 | Versionner catalogue d'explications et confiance ; AlertKnowledge/docs | L0-03, L5-03/04 | Documenté/interprétation/inconnu séparés ; firmware applicable, source exacte/version, vérifications/limites ; matcher testé sans transformer WARN en diagnostic matériel | Validé ciblé · confiance/source |
| L5-07 | P2 | Enrichir détails batterie/GNSS et catalogue de champs ; moteur/Core | L0-04/05, L2-10 | Cellules/cycles/serial/capacité/erreurs et âge RTCM présents exploitables ; absent=inconnu ; serial batterie distinct de drone ; unités/provenance explicites | Validé ciblé · unités/instances |
| L5-08 | P2 | Préserver paramètres typés et diff temporel de base ; moteur/Core/fiche | L0-05, L2-10 | Init/changes avec type et time ; valeur affichée n'altère pas origine ; disparition/changement firmware signalé ; diff ne devient pas causalité automatique | Validé ciblé · paramètres typés et comparaison de révisions |
| L5-09 | P1 | Tester décodage/absence dictionnaire/volumes hostiles ; Tests Python/Swift | L5-01..08 | Corpus autonome exact, fichiers compressés bornés, firmware constructeur sans dictionnaire reste lisible ; vieux caches et sauvegarde/restauration intacts | Validé ciblé · corpus autonome |

## L6 — Courbes et chronologie commune

| ID | P | Tâche et responsabilité | Dépendances | Recette / critère de sortie | État |
|---|---|---|---|---|---|
| L6-01 | P1 | Construire catalogue selon topics/champs présents ; flight_data/Core | L0-05, L5-07/08 | Batterie/GNSS/EKF selon disponibilité ; type, unité/conversion, instance/récepteur, timestamps ; aucune courbe vide interprétée comme valeur saine | Validé ciblé · catalogue |
| L6-02 | P1 | Extraire série choisie/fenêtre à la demande ; helper/API/Core | L6-01, L3-03, L2-10 | Paramètres validés, réponse bornée/annulable, cache versionné ; aucune réanalyse universelle UI ; données absentes et refus d'unité lisibles | Validé ciblé · fenêtres/cache |
| L6-03 | P1 | Implémenter réduction conservant extrema/transitions/gaps ; moteur | L6-02, L0-06 | NaN, pics courts, temps inversés, états discrets et segments nombreux ; maximum2048 points proposé ; nombre original/valide/rejeté/affiché, budget et perte indiqués | Validé ciblé · réduction/gaps |
| L6-04 | P1 | Présenter quatre courbes initiales et recettes ; SwiftUI/design | L6-03, L0-10, L4-15 | Axes/unités/récepteur distincts, états en marches, trous non reliés ; zoom/fenêtre et reset ; pas de promesse de garder tous pics si budget insuffisant | Implémenté · preview |
| L6-05 | P1 | Synchroniser selectedTime messages/events/map/séries ; Core/fiche/MapKit | L6-04, L5-05 | Temps relatif identique ; clic sur sample réel ; gap=Sans position ; positions voisines qualifiées sans reconstruire trajectoire ni causalité | Implémenté · preview/temps |
| L6-06 | P2 | Rendre sélection récepteur et couverture explicites ; fiche/map/metrics | S09/S11, L6-01/05 | Instances comparables séparément ; pas concaténation capteurs ; GNSS estimé vs brut identifiable ; interpolation/extrapolation non silencieuse | Validé ciblé · récepteurs |
| L6-07 | P2 | Conserver séries/recettes/fenêtre choisies par vue ; Core/store vues | L4-05, L6-04/05 | Relance restaure choix disponibles, champs absents annoncés ; aucune clé de série désormais incompatible appliquée sans vérification | Validé ciblé · recettes/vues |
| L6-08 | P1 | Exporter relevé de courbes et manifeste ; report/API | L4-12, L6-03..07 | Window/field/topic/instance/unit/counts/stratégie et gaps ; relevé réduit distinct des échantillons originaux ; HTML/JSON et affichage alignés | Validé ciblé · relevé/manifeste |
| L6-09 | P1 | Qualifier courbes contre oracle et corpus privé ; QA séries | L6-01..08 | Conversions, multi-GNSS, inversions, NaN/gaps/extrema/transitions aux fenêtres qualifiées ; RAM/cold/latence/annulation mesurées ; périmètre d'exactitude explicitement consigné | Validé ciblé · oracles et banc natif final |

## L7 — Mise à jour Sparkle hors App Store

| ID | P | Tâche et responsabilité | Dépendances | Recette / critère de sortie | État |
|---|---|---|---|---|---|
| L7-01 | P1 | Choisir feed HTTPS et canaux stables/staging ; release/Core | L0-01, décision hébergement | URL pérenne et schéma version/build/OS/arch ; aucune GCS/donnée privée ; staging distinct du canal utilisateur | Décision requise · feed HTTPS |
| L7-02 | P1 | Intégrer Sparkle et clé publique vérification ; app/Core/package | L7-01, L1-01/04 | Framework/version/licences explicités ; privateKey/certificats hors repo ; vérification signature activée ; pas de compte GitHub utilisateur requis | Implémenté · configuration désactivée |
| L7-03 | P1 | Produire ZIP update depuis même bundle final que DMG ; release tooling | L1-06, L7-02 | Même build/manifest, DeveloperID+notary+signature update distincts ; archive altérée refusée ; pas réutilisation ancienne archive privée | Implémenté · signature ZIP/gate final |
| L7-04 | P1 | Ajouter recherche version et états update ; SwiftUI/Core service | L7-02, L0-10 | Notes/install disponible/offline/erreur/aucune version ; update incompatible ou downgrade bloqué selon règle écrite ; vérification manuelle accessible | Implémenté · preview |
| L7-05 | P1 | Coordonner installation avec opérations actives ; update/coordinateur | L2-01, L0-09, L4-09, GCS-07 | Import/archive/export/collecte terminés ou arrêtés explicitement ; découverte seule ne bloque pas sans fin ; aucune annulation silencieuse | Validé ciblé · opérations actives |
| L7-06 | P1 | Exécuter staging entre deux builds et conservation ; QA updater | L7-03..05, L2-06 | Download/validation/remplacement/relaunch sans gh ni GitHub ; bibliothèque/numéros/familles/scope/destination/jobs conservés ; preuve versions et sig | SDK deux apps validé · GUI KataLog distincte |
| L7-07 | P1 | Qualifier interruptions et rollback de données ; updater/QA | L7-06, L2-06, L3-02 | Download interrompu, asset invalide, signature fausse, source absente, disque plein ; app actuelle utilisable ; backup compatible nécessaire au retour app avant migration | SDK six recettes + attestation postquit validés · erreur GUI non observée |
| L7-08 | P2 | Documenter adoption depuis 0.5.2 sans updater ; docs/release | L7-06/07 | Première installation de version Sparkle reste manuelle ; mises à jour suivantes depuis app ; notes de compatibilité/migrations et limites explicites | Implémenté · documentation |

## L8 — Recette complète, accessibilité, CI et préparation publique

| ID | P | Tâche et responsabilité | Dépendances | Recette / critère de sortie | État |
|---|---|---|---|---|---|
| L8-01 | P1 | Définir et lancer CI autonome multi-langage ; `.github/workflows` proposés, Tests | L0-06, L1-04 | Python/Swift/Node sur fixtures synthétiques ; synthétique package smoke ; privés signalés séparément, aucun skip masquer gate critique ; pas de secrets dans logs/artifacts | Qualification externe · CI hébergée indisponible avant runner, zéro étape |
| L8-02 | P1 | Exécuter corpus privé de non-régression localement ; QA local | S, L2..L6 | SHA/taille/mtime originaux identiques ; exacts messages/IDs/agrégats ; résultats privés conservés localement ; aucune fixture originale publiée | Validé privé · neuf SHA préservés |
| L8-03 | P1 | Recette complète clavier/VoiceOver native et web ; QA accessibilité | L0-10, L4/L6 UI | Import→scope→groupe→fiche→identifier→export et collecte/update : labels/focus/raccourcis, statut live, aucun trap ; graphes équivalent textuel, états non portés par couleur seule | Qualification externe · VoiceOver |
| L8-04 | P1 | Vérifier contrastes, tailles, thèmes et layout réels ; QA/design | L4-15, L6-04 | Clair/sombre/Système, petit espace utile/texte agrandi ; contenu et boutons accessibles ; focus visible et cibles adéquates ; preuves écran synthétiques | Preview · captures/recette GUI |
| L8-05 | P1 | Qualifier hors ligne/GCS absente/MapKit en erreur ; QA app | L3/L4/L6, GCS-07 | Bibliothèque et fiche cached/report disponibles ; manque de tuiles distinct du GPS absent ; retry/load explicites ; aucune demande de position du Mac pour logs | Qualification externe · MapKit réel ; offline logiciel validé |
| L8-06 | P1 | Fermer bancs de performance et stress ; QA/outils | L3-12, L4-10/14, L6-09, GCS-09 | Matrice cold/warm/RSS/p95/annulation/disque/50k5M ; objectifs retenus satisfaits ou défauts corrigés ; séparations synthétique/moteur/UI/réseau respectées | Validé ciblé · moteur, SwiftUI, courbes et WebKit |
| L8-07 | P1 | Créer diagnostic local exportable avec preview ; Core service/UI proposé | L0-09, L4-13 | Version/OS/runtime/opérations/codes/états, sans payload privé par défaut ; inclure détails uniquement via choix explicite ; export borné et utile pour reproduire un ticket | Validé ciblé · diagnostic borné selon scope |
| L8-08 | P1 | Auditer licences/droits des sources et dépendances ; docs/release | L1-04, L7-02, décision utilisateur | Inventaire licences/notices avec versions ; droits réutilisations documentés ; choix LICENSE explicite par titulaire, aucun ajout automatique ; blocage public tant que choix/droits non résolus | Validé ciblé · GPL-3.0-only choisie, notices du bundle vérifiées |
| L8-09 | P1 | Auditer arbre/history/assets/surfaces GitHub publiables ; outils publication/release | L8-08, code final | Guard + secrets scan + revue images/metadonnées/historique/branches/tags/CI/reports ; apps/DMG/ZIP/PYZ inspectés ; aucune donnée personnelle ; archive historique reste privée | Validé ciblé · audit final précommit, aucune publication |
| L8-10 | P1 | Recette version finale signée/notarisée ; QA distribution | L1-02/06, L7-03/06, L8-09 | macOS 15 réel et27, app téléchargée/quarantinée, DMG drag-copy/eject/launch et update ; sig/Gatekeeper/tickets vérifiés sur fichiers livrés | Qualification externe · package final |
| L8-11 | P1 | Faire recette matérielle finale et consigner limites ; QA GCS | GCS-10, app finale | Deux drones réels si disponibles, collecte/recovery/cache/cancel/update ; matériel indisponible déclaré ; aucune qualification500 annoncée par extrapolation | Qualification externe · matériel |
| L8-12 | P1 | Mettre à jour docs, changelog et matrice de preuves ; documentation/release | Tous tickets de livraison | README install/update, contrats/migrations/storage/GCS/export, versions/tests/mesures/limites cohérents ; aucune checklist future présentée comme feature actuelle | Validé ciblé · documentation consolidée, tentative CI sans exécution consignée |
| L8-13 | P1 | Préparer livraison et revue finale sans publier ; release | L8-01..12 | Assets finaux, SHA/notices/appcast/notes et verdict de gates reviewables ; pas de défaut bloquant ouvert ; listing de limites explicite et chemins privés absents | Validé ciblé · package de revue sept gates, publication distincte |
| L8-14 | P1 | Publier uniquement après instruction explicite puis vérifier accès anonyme ; release | L8-13, autorisation publication | Visibilité/feed/release décidés séparément ; source/assets propres, download anonyme, SHA/signatures/install/update cohérents ; historique archive privé intact | Décision requise · aucune publication |

## Budgets proposés : à mesurer puis figer en L0

Le banc du moteur sur index préparé a validé les huit requêtes 50k/5M sous 500 ms, première requête incluse, avec RSS 173,1 MiB. Le banc natif avec helper final mesure séparément les stores, le premier bitmap et les processus WebKit ; ses valeurs par scénario figurent dans la matrice de preuves. Les colonnes ci-dessous conservent les objectifs initiaux ; un cache OS réellement froid et les recettes matérielles restent distincts.

| Mesure | Proposition initiale | Vérification propriétaire |
|---|---|---|
| Grand index | 500 identités, 50 000 logs, 5 millions de messages multi-années | L0-07/L3-12 ; index synthétique, pas parsing de 50 000 ULog |
| Première page exploitable | ≤2 s après accès moteur, cold-start séparé | L0-08/L3-12 |
| Requête de première page filtrée | p95 ≤500 ms index chaud | L0-08/L3-12, suffisamment de répétitions |
| Mémoire navigation SwiftUI | RSS ≤512 Mo, indépendante de tous messages | L3-07/12, moteur/navigateur mesurés séparément |
| Annulation | Feedback immédiat, retour UI ≤1 s | S08/L0-09/GCS-06/L4-09 ; process fin mesurée séparément |
| Courbes | Quatre visibles, ≤2 048 points au total par recette | L6-03/09 ; pertes/reduction/gaps déclarés, métriques sur originaux |
| HTML interactif | Cible 10 Mo ; au-delà synthèse+données complètes proposées | L4-10/14, temps/RSS navigateur mesurés |
| Collecte parallèle | Deux UUID maximum, un fichier/opération FTP par UUID | GCS-08/10 ; hausse seulement après qualification réelle |
| Carte flotte | 80 trajectoires récentes du scope, limite annoncée | L3-09 ; export/agrégats couvrent tous résultats |

Un budget manqué déclenche analyse et correction, pas une hausse du seuil pour
faire passer la recette. L'exactitude des IDs/comptes et l'absence de perte ne
sont pas des compromis de performance.

## Décisions ouvertes à traiter au bon moment

| Décision | Avant | Proposition de départ | Ce qui permet de la fermer |
|---|---|---|---|
| UX nouveaux écrans | Intégration L4/L6/L7 | Continuité bento monochrome ; scope lisible | Maquettes et variantes approuvées |
| Périmètre registre vs historique | S06/L0-02 | Registre explicitement nommé et drones sans log préservés | Contrat écran×filtre et recette compteurs |
| Absence de source/cache ancien | S02/S10 puis L2 | Provenance conservée et dernière analyse lisible | Fixtures retrait, upgrade, réassociation SHA |
| Backup et rétention | L2-02/10/11 | Deux modes, nettoyage explicitement choisi | Restore d'une bibliothèque déplacée et impact annoncé |
| Politique validation cache GCS | GCS-04 | Garder SHA vérifié, optimiser seulement avec contrat de confiance | Corruption/mutation/volume absent et mesures |
| Dictionnaires constructeur | L5-03/04 | Exact firmware/hash, brut lisible si absent | Artefact exact ou métadonnée embarquée vérifiable |
| Publication/licence | L8-08/14 | Repository privé jusqu'aux gates et décision | Choix explicite, droits/notices, audit et autorisation distincte |
| Feed updater | L7-01 | URL stable, HTTPS, staging distinct | Staging end-to-end et revue confidentialité |
| Mac minimum et matériel | L1-02/L8-11 | Recette macOS 15 et27, deux drones réels | Matériel disponible et résultats enregistrés ; sinon limite ouverte |

## Hors du socle 0.6.0 sauf décision de périmètre explicite

- Fusion datée de plusieurs contrôleurs dans un drone physique, maintenance et
  comparaison avancée avant/après : préparer identité/provenance maintenant,
  livrer cette workflow après validation spécifique.
- Score automatique de fiabilité/panne ou diagnostic matériel : aucun score
  sans dénominateur, couverture et méthodologie qualifiés.
- Extraction universelle de tous champs ULog et analyses avancées IMU/ESC :
  prioriser Batterie/GNSS/EKF et les informations réellement disponibles.
- Plus de deux transferts simultanés, reprise à l'octet ou annulation distante :
  dépendent des capacités/proofs du protocole et de recette réelle.
- Port Intel, Windows ou mobile : pas implicites dans cette roadmap macOS
  Apple Silicon ; décision et banc séparés si demandés.

**Prochaines portes :** terminer la recette GUI (Computer Use expire), puis exécuter les recettes externes disponibles. Le profil local de notarisation est validé ; la Preview 0.6.0 (9) et son DMG sont acceptés par Apple et passent neuf gates, dont Gatekeeper et les tickets dans la copie montée. Le helper signé a récupéré et analysé les deux logs d’un drone réel : arrêt local, fin distante observée, relance, SHA, cache et réimport sans doublon vérifiés. Cela ne ferme pas la recette à deux drones ni les transitions GUI. Le diagnostic Swift est réussi ; le premier échec simulé garde sa limite de cause inconnue. La CI utilisera les runners standard après publication publique, conformément au choix utilisateur. L’approbation UI et le choix GPL-3.0-only sont enregistrés. Le feed, la release et le passage public gardent leurs portes distinctes. La branche de développement et les tests ne modifient pas l’installation utilisateur.
