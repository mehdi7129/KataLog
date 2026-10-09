# Capacités des commandes

`LibraryStore` conserve ses points d’entrée et son rôle de propriétaire de l’état.
Les extensions `LibraryStore+Import`, `+Reports` et `+Maintenance` regroupent les
cycles de vie correspondants ; les tâches, les leases et l’ordre des opérations
restent inchangés. `GCSStorageIO` possède les accès ordonnés au stockage GCS.
Les graphiques du profil sont isolés dans `AlertProfileChart.swift`, sans
modification de leur rendu ou de leurs données.

`LibraryCommandCapabilities` décrit l’admission des commandes du store.
`WorkspaceCommandCapabilities` décrit les commandes disponibles dans l’interface.
Ces snapshots ne lancent aucun travail et ne prennent aucun lease. Une tâche
admise garde ses contrôles après `await`, son annulation et ses drains existants.

| Commande | Activités qui bloquent son admission |
| --- | --- |
| Choisir/importer un dossier via le store | Lecture seule, maintenance, import |
| Admission d’un import GCS | Lecture seule, maintenance ; attend ensuite import, requête, chargement du snapshot ou fiche indépendante |
| Actualiser les analyses | Lecture seule, maintenance, import, requête, snapshot, fiche indépendante ; une actualisation déjà lancée reste également exclue |
| Rapport legacy | Autre export ; le rapport lit une capture immutable |
| Maintenance | Lecture seule, maintenance, import, export, snapshot, requête, chargement de fiche, fiche indépendante, activité externe |
| Navigation de la fenêtre | Import, maintenance, requête de la fenêtre, snapshot, chargement de sa fiche |
| Import/annotations depuis l’interface | Blocages navigation, lecture seule, lecteurs de la bibliothèque, collecte, fiche indépendante, export/récupération de diagnostic |
| Rapport depuis l’interface | Blocages import/annotations et autre export |
| Mise à jour | Lecture seule, import, maintenance, export, lecteurs de la bibliothèque, collecte, fiche indépendante, export/récupération de diagnostic |

Différences conservées explicitement :

- L’import automatique peut attendre un lecteur déjà admis ; l’interface évite de
  proposer une mutation dans ce même état.
- La capture paginée d’un rapport possède son export et peut donc traverser le
  garde de maintenance avec `allowOwnedExport`. Un lecteur propriétaire bénéficie
  de l’exception `allowOwnedQuery`. Aucune de ces exceptions n’ignore les autres
  activités bloquantes.
- Le chargement du snapshot bloque la navigation mais ne bloquait pas
  l’installation d’une mise à jour : cette différence reste conservée.
- Une annulation de requête reste une requête active jusqu’au retour du helper.
- Une navigation par fenêtre peut remplacer les deux flags locaux de lecture ;
  les mutations et mises à jour utilisent toujours l’activité agrégée.

La matrice de tests couvre les 8 192 combinaisons de 13 activités, plus les
exceptions de propriétaire et de navigation indépendante. Les tests de parcours
existants restent responsables de la persistance, des erreurs et de l’ordre des
opérations réelles. Les champs partagés entre les extensions restent internes au
module ; aucun nouveau point d’entrée public ni format persistant n’est ajouté.
