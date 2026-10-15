# Dictionnaire événement rejeté à 64 MiB

Le décodeur XZ de la version 0.8.6 limitait sa mémoire totale à 64 MiB. Un dictionnaire LZMA2 annoncé à 64 MiB exige aussi de la mémoire de gestion : le flux peut donc être valide tout en étant rejeté par `Memory usage limit exceeded`.

La correction porte ce plafond à 65 MiB. Elle conserve les budgets applicatifs de 4 MiB compressés et 16 MiB décompressés, la liaison stricte SHA-256 avec le log, la validation du JSON et les rejets des flux concaténés. Elle ne garantit pas la lecture de dictionnaires LZMA2 plus grands.

`Tests/test_px4_events.py:test_64_mib_xz_dictionary_allows_decoder_overhead_and_translates` construit un petit catalogue libevents entièrement synthétique, le compresse avec un dictionnaire LZMA2 de 64 MiB, démontre l’échec de l’ancien plafond puis vérifie chargement et traduction avec le moteur corrigé.

Une validation locale en lecture seule a également traduit 17 événements réels sur 17 avec le dictionnaire embarqué exact, sans erreur et sans réimport. Les [résultats agrégés](../event-translation-validation.json) sont publics ; les scripts ciblés, empreintes de la source et du firmware, dictionnaire et arguments restent privés. Cette validation technique ne constitue pas un diagnostic physique ni la preuve d’une réanalyse de la bibliothèque installée.
