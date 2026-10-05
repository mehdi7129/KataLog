# Contribuer à KataLog

KataLog est une app macOS locale sous **GPL-3.0-only**. Pour utiliser l’app,
téléchargez le [DMG stable](https://github.com/mehdi7129/KataLog/releases/latest) :
les outils ci-dessous concernent le développement depuis les sources.

## Préparer le développement

Prérequis : Mac Apple Silicon sous macOS 15 ou ultérieur, Xcode avec Swift 6,
Python 3.13 et Node.js pour les tests des rapports. XcodeGen sert uniquement à
régénérer le projet Xcode à partir de `project.yml`.

Depuis la racine du dépôt :

```sh
python3.13 -m venv .venv
.venv/bin/python3 -m pip install --only-binary=:all: --require-hashes -r requirements-runtime.txt
```

Pour les lancements de développement depuis Xcode, renseignez
`KATALOG_PYTHON` avec le chemin absolu de `.venv/bin/python3` et
`KATALOG_LIBRARY_DIR` avec un dossier de bibliothèque de test distinct.
L’environnement placé dans `~/Library/Application Support/KataLog/python`
est également reconnu par le moteur de développement.

Une distribution installée par DMG utilise son moteur embarqué et refuse un
fallback Python externe. Ne modifiez pas le bundle distribué pour développer.
L’override de bibliothèque ne qualifie pas l’isolation après un redémarrage
effectué par Sparkle : les recettes d’update utilisent un environnement dédié.

## Vérifier une modification

Exécuter les contrôles concernés par le changement ; les suites complètes et
les recettes de distribution sont requises pour une nouvelle release.

```sh
.venv/bin/python3 tools/run-python-tests.py --summary reports/python-tests.json

CLANG_MODULE_CACHE_PATH=/private/tmp/katalog-clang-cache \
XDG_CACHE_HOME=/private/tmp/katalog-xdg-cache \
  .venv/bin/python3 tools/run-swift-tests.py \
  --summary reports/swift-tests.json \
  -- --disable-sandbox --scratch-path /private/tmp/katalog-validation-build

node --test Tests/test_report_interaction.cjs
python3 tools/check-publication.py --include-untracked
git diff --check
```

Le wrapper Swift configure les fixtures Python et exige une session graphique
macOS pour les tests natifs. Les fixtures synthétiques sont autonomes. Le test
qui nécessite `KATALOG_PRIVATE_FIXTURES` est explicitement signalé comme non
exécuté si ce corpus externe n’est pas fourni ; aucun ULog privé n’est livré.

La [CI](.github/workflows/ci.yml) exécute les suites sur macOS 15 et 26, et la
recette du package ARM64 sur macOS 15 et 27. Le
[banc SDK Sparkle](.github/workflows/update-sdk-smoke.yml) est déclenché séparément.
Les tests simulés ne qualifient pas une flotte radio réelle.

## Compiler et utiliser la CLI

```sh
bash tools/build-app.sh
```

Le script construit hors du Bureau, vérifie les dépendances épinglées, embarque
le moteur et écrit un ZIP dans `dist/`. `dist/LOCAL-APP-PATH.txt` indique la copie
vérifiée. Par défaut, la signature est ad hoc et les updates sont désactivées :
ce build local n’est pas une release publique. Une variante Debug utilise
`KATALOG_CONFIGURATION=debug` et un `KATALOG_BUILD_DIR` distinct.

Après ce build, `Installer KataLog.command` installe dans `~/Applications`,
conserve l’ancienne copie et refuse de remplacer une app ouverte.
`Ouvrir KataLog.command` extrait et ouvre une copie temporaire du ZIP local.
Ces scripts utilisent le nom **KataLog** et sa bibliothèque habituelle. Pour une
recette isolée, privilégier le lancement depuis Xcode avec le dossier de test
explicite décrit ci-dessus. La procédure de
[signature, DMG, notarisation et mise à jour](docs/RELEASING.md) reste séparée.

Exemple de CLI avec un dossier de logs choisi explicitement :

```sh
KATALOG_PYTHON="$PWD/.venv/bin/python3" \
  swift run --disable-sandbox katalog-cli \
  --folder /chemin/vers/logs --database reports/library.sqlite \
  --output reports/library.json --html reports/KataLog-rapport-flotte.html
```

Les fichiers générés dans `reports/`, `dist/` et `.build/` restent locaux.
Si `project.yml` change, régénérer `KataLog.xcodeproj` avec `xcodegen generate`.

## Proposer une pull request

1. Décrire le problème, le comportement attendu et une reproduction synthétique.
2. Limiter le diff au changement proposé et respecter le
   [design bento](DESIGN.md) ainsi que les [contrats documentés](docs/README.md).
3. Indiquer les contrôles réellement exécutés et leurs limites.
4. Relire `git diff --cached` et utiliser une identité de commit publique ou
   l’adresse GitHub `noreply`.

Les Issues et Discussions ne sont pas activées actuellement. Les
[pull requests](https://github.com/mehdi7129/KataLog/pulls) sont publiques.
N’y joignez aucun log réel, diagnostic privé, numéro de série, position GPS,
capture de flotte, mot de passe ou clé. Un export de diagnostic ne devient pas
publiable du seul fait qu’il est généré par l’app. Préférez une fixture inventée
et un extrait minimal relu. Voir la [politique de publication](docs/PUBLICATION.md).

Les tags, archives de release et signatures publiés restent immuables. Une
modification de documentation n’autorise pas leur remplacement ni la diffusion
de données utilisées pendant les essais.
