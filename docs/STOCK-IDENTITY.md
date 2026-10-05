# Identifier les drones

## Numérotation locale

Depuis 0.5.0, un opérateur peut saisir un numéro depuis la flotte GCS, le registre
ou une fiche de log. Le numéro reste éditable et disponible au redémarrage,
même pour un drone sans log. Les numéros sont des chaînes : les zéros initiaux
sont conservés.

Cette numérotation est une annotation locale. Elle ne change ni l'ULog ni son
identité source et n'autorise pas un drone à être collecté.

## Clés et rapprochement

- Utiliser un UUID GCS prouvé lorsqu'il est disponible ; sinon conserver l'identité ULog.
- Conserver les identifiants source et la provenance de chaque association.
- Deux contrôleurs portant le même numéro ne sont jamais fusionnés automatiquement.
- Une contradiction entre identités est signalée ; elle ne crée pas de lien implicite.
- Une série de batterie, un MAV_SYS_ID ou un numéro de vol n'est pas une série de drone.

Aucun rapprochement automatique avec une base de stock n'est livré. Il faudrait
une clé commune vérifiée et une confirmation explicite en cas d'ambiguïté.
Un remplacement de contrôleur demandera une association datée au drone physique.

Les annotations sont conservées dans `annotations.json`, hors du dépôt. Les
exemples et fixtures publics emploient exclusivement des identités synthétiques.
Voir le [contrat d'import](IMPORT-CONTRACT.md) et le [roadmap actuelle](ROADMAP.md).
