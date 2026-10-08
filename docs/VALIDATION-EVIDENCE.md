# Preuves de validation synthétiques

Le workflow `Autonomous tests` conserve les résumés Python/Swift, les logs de tests et le résultat du package smoke pendant 14 jours, y compris après un échec. Le nom de chaque artifact contient le SHA testé et la tentative. `context.json` précise le commit, les versions disponibles, l’architecture et l’image du runner ; aucun dump d’environnement ni corpus utilisateur n’est publié. Pour le package, les versions installées après ce contexte sont précisées dans la vérification du runtime embarqué.

Les quatre checks requis restent inchangés. Un artifact absent ou un test rouge ne devient pas un succès : les pipelines utilisent `pipefail`, le wrapper Swift refuse les skips et l’upload utilise `always()`.

## Capacité

`Synthetic capacity` réutilise les budgets existants de `Tests/benchmark_library_repository.py` (latence p95 de 500 ms, pic mémoire Python de 512 MiB) et les tests natifs GCS/rendu. Il est lancé le lundi, à la demande (1 000, 10 000 ou 50 000 logs), et lorsqu’une PR modifie son instrumentation. Le calendrier devient actif après fusion dans la branche par défaut. Il n’ajoute pas de check requis aux PR ordinaires.

La fixture est entièrement synthétique : 100 messages/log, 500 drones, cinq répétitions. Les rapports JSON, logs, conditions et captures natives sont conservés 30 jours, même en cas d’échec. Les mesures sur un runner partagé décrivent ce runner ; elles ne qualifient ni une flotte physique ni un corpus privé.

```sh
python3 Tests/benchmark_library_repository.py --logs 50000 --messages 100 --drones 500 --repeats 5 --output /tmp/katalog-capacity.json
```

Sur GitHub, ouvrir Actions → Synthetic capacity → Run workflow pour choisir la taille, puis télécharger les artifacts du run. Les mesures à comparer doivent partager fixture, versions et architecture. Un dépassement reste visible et doit être expliqué ou corrigé, sans relever le budget pour faire passer le test.
