# Workspaces Paradev

`config.json` exécute `setup.sh` à la création du workspace. Prérequis : macOS 15+,
Xcode / Swift 6 et Python 3.13 (`brew install python@3.13`). Si nécessaire,
`KATALOG_SETUP_PYTHON` peut désigner un autre chemin vers Python 3.13.

Le setup crée un `.venv` local, installe NumPy, pyulog et les dépendances USB
(pymavlink / pyserial et leurs dépendances) depuis
`requirements-runtime.txt` avec vérification des hashes, puis résout Sparkle
avec Swift Package Manager et `Package.resolved`. Il peut être relancé.
Aucun fichier `.env` ni service externe n'est requis pour développer et tester.
La collecte réelle demande une GCS accessible, configurée dans l’app, ou un
contrôleur PX4 exposant MAVLink sur son port USB serial.

Dans un terminal du workspace :

```sh
source .venv/bin/activate
python tools/run-python-tests.py
python tools/run-swift-tests.py
node --test Tests/test_report_interaction.cjs
```

Node.js (22 dans la CI) sert uniquement aux tests du rapport HTML.
Le build de distribution reste disponible via `bash tools/build-app.sh` ; il
prépare lui-même son moteur embarqué et ses outils de packaging.

KataLog est une app native macOS : il n'y a pas de dev server, donc pas de
commande `run`. Le teardown est vide : aucun service ni ressource externe n'est
créé ; Paradev supprime le worktree et ses dépendances locales à sa suppression.
