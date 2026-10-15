# Corpus de recherche privé — 15 octobre 2026

L’inventaire a été extrait de la bibliothèque en SQLite lecture seule, avec `mode=ro`, `query_only=ON` et une transaction cohérente. Les distributions de messages canoniques et indexés ont été comparées exactement avant la mesure de couverture.

Le corpus reste dérivé de vols réels même après remplacement des chemins, noms de réseau et adresses. Les textes par occurrence, valeurs de mesures, fréquences par message, identités et distributions de firmware, scripts d’investigation et preuves détaillées sont donc conservés localement sous le dossier ignoré `private-data/alerts-research-20261015/`. Aucun ULog ni extraction réelle n’est nécessaire aux tests publics, à la génération du catalogue ou à l’application distribuée.

Les résultats publics sont des agrégats datés du snapshot : 298 logs, 12 906 occurrences de messages, dont 5 500 classées en alerte. Ils ne constituent pas une garantie de couverture des futurs logs. La méthode de classification conserve le drapeau `isAlert` existant ; les explications ne modifient pas ce classement.

Les tests publics utilisent exclusivement `Tests/fixtures/synthetic/alert-catalogue.json`, construit depuis les motifs du catalogue avec des valeurs artificielles. Il couvre les 388 motifs des 321 fiches et les fallbacks de contexte et de texte brut. Le générateur vérifie la cohérence de cette fixture, et Swift vérifie sa correspondance avec le moteur Foundation réel.

Un gate local facultatif mesure séparément le corpus privé. Il n’est compilé que sur demande et échoue si la variable de chemin n’est pas fournie ; il n’est ni ignoré ni prétendu exécuté par la CI publique :

```sh
KATALOG_PRIVATE_ALERT_CORPUS="$PWD/private-data/alerts-research-20261015/original-research/corpus/messages.anonymized.json" swift test -Xswiftc -DKATALOG_PRIVATE_ALERT_CORPUS --filter AlertCatalogueTests.testRealCorpusCoverageUsesSwiftMatchingAndKeepsContextSeparate
```

Une mesure Python indépendante peut être relancée explicitement, sans lire la bibliothèque active et sans écrire de données réelles dans les sources publiques :

```sh
python3 tools/generate-alert-catalogue.py --check --coverage private-data/alerts-research-20261015/original-research/corpus/messages.anonymized.json
```
