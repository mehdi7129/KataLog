# Shell SwiftPM conservé

`main.swift` assemble les stores partagés et choisit le shell via `AppPreviewConfiguration`. Le workspace approuvé s’ouvre dans les bundles stables dont la version sémantique est au moins `0.6.0`, dans les bundles de review, ou avec `KATALOG_UI_PREVIEW=1`.

Sans version de bundle ni flag, un lancement SwiftPM utilise toujours `LegacyWorkspaceView.swift`. Ce fichier contient l’ancien shell, déplacé sans changer ses vues ni son comportement. Il reste utile pour ce chemin de lancement ; ce refactor n’autorise pas sa suppression.

Les deux shells partagent `LibraryStore`, `GCSStore` et les services Core. Le choix visuel ne change pas le dossier de bibliothèque : seuls la configuration explicite et le statut de bundle de review déterminent ce dossier, selon les règles existantes.

Validation : tests de `AppPreviewConfiguration` et rendu natif du shell legacy dans les thèmes clair/sombre avec une bibliothèque synthétique isolée. Aucun collecteur réseau n’est lancé pendant ce rendu.
