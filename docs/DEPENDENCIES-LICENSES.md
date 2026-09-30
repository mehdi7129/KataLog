# Dépendances et licences de distribution

Cet inventaire couvre les inputs des sources actuelles. Les versions réellement
embarquées sont consignées dans le `runtime-manifest.json` du helper et dans
Info.plist pour Sparkle. Les fichiers de licences upstream sont conservés dans
le bundle ; ce document ne les remplace pas.

## Composants distribués

| Composant | Version épinglée | Rôle | Textes inclus dans l’app |
| --- | --- | --- | --- |
| CPython, build Astral python-build-standalone | 3.13.15, build 20260929 | Interpréteur autonome du helper | `Contents/Helpers/KataLogEngine.app/Contents/Resources/Licenses/CPython/` : licence Python et licences des composants natifs du build |
| NumPy | 2.5.3 | Lecture et calculs de télémétrie | `…/Resources/Licenses/numpy/` : licence BSD et notices des composants intégrés au wheel |
| pyulog | 1.2.4 | Décodage ULog, dont support des événements PX4 | `…/Resources/Licenses/pyulog/` : licence BSD à trois clauses |
| Bootloader PyInstaller | 6.22.3 | Démarrage du helper gelé | `…/Resources/Licenses/pyinstaller/` : GPL avec exception pour les applications embarquées |
| Sparkle | 2.10.0 | Vérification et installation des mises à jour | `Contents/Resources/Licenses/Sparkle-LICENSE.txt` : licence MIT du projet et notices de ses composants externes |

Les frameworks macOS, MapKit, SwiftUI, WebKit et la bibliothèque système SQLite
sont utilisés depuis macOS. Ils ne sont pas copiés depuis le SDK dans le DMG.
Le toolkit Sparkle et le helper Python sont embarqués dans l’app. La GCS/MQTT
utilise le collecteur du projet ; aucun broker ni SDK de pilotage externe n’est
distribué avec KataLog.

## Outils de build

Les requirements de build épinglent aussi `pyinstaller-hooks-contrib 2026.7`,
`altgraph 0.17.5`, `macholib 1.16.4`, `packaging 26.3` et `setuptools 84.0.0`.
Ils servent à construire le helper et ne sont pas installés sur le Mac de
l’utilisateur. Les outils de fabrication du DMG figurent séparément dans
`requirements-dmg-build.txt`. Les outils officiels `generate_keys`,
`sign_update` et `generate_appcast` de Sparkle ne sont pas copiés dans l’app.

SwiftPM vérifie le checksum de l’archive binaire Sparkle et `Package.resolved`
épingle sa révision. Les wheels Python sont vérifiés avec `--require-hashes`.
Le build CPython et l’archive contenant ses licences ont chacun leur SHA-256
dans `tools/build-engine.sh`. Aucun téléchargement de dépendances Python
n’est nécessaire après installation.

## Contrôles du pipeline

`tools/build-engine.sh` exige des fichiers de licences pour NumPy, pyulog et
PyInstaller et copie les textes natifs du build CPython. Le helper contient
également `THIRD-PARTY-NOTICES.txt` et son manifeste de versions et d’inputs.
`tools/build-app.sh` ajoute le texte complet fourni avec le SDK Sparkle.
`tools/verify-distribution.py` refuse un bundle privé de ces notices.

La CI `package-smoke` construit une app **ad hoc** et teste uniquement des ULogs
synthétiques et une GCS de loopback. Elle ne signe aucune release Developer ID,
ne notarise rien, ne contacte aucun drone et n’active aucun feed public. Ses
contrôles de runtime sont distincts des téléchargements publics des outils de
build. Les runners ciblent macOS 15 ARM64 et macOS 27 ARM64 via le label
`xcode-27`, actuellement en public preview ; leur disponibilité ne constitue
pas une preuve d’exécution de la CI.

Les labels `macos-15`, `macos-26` et `xcode-27` appartiennent à l’offre standard
GitHub, gratuite sur les dépôts publics. Chaque job exige une visibilité
`public` avant son allocation à un runner. Tant que le dépôt est privé, tous
les déclencheurs sont ignorés, y compris `workflow_dispatch`, pour conserver
ce choix de runners gratuits. Aucun runner `-large`, `-xlarge` ou auto-hébergé
n’est configuré. Les commandes de tests locaux restent indépendantes de la CI.
Un statut GitHub « skipped » ne qualifie aucun test ni build.

## Licence du dépôt KataLog

Copyright (C) 2026 **mehdi7129**.

Le code propre de KataLog, les tests, scripts, documentation et ressources
originales sont sous **GNU GPL version 3 uniquement**, identifiant SPDX
`GPL-3.0-only`. Le [texte officiel complet](../LICENSE) est reproduit sans
modification. Aucune permission d’utiliser une future version de la GPL n’est
accordée par cette notice.

Cette licence ne remplace pas celles des dépendances et ne réattribue aucun
copyright tiers. Les licences CPython, NumPy, pyulog, PyInstaller et Sparkle
restent conservées dans l’app avec leurs notices. L’exception du bootloader
PyInstaller est également conservée ; elle ne modifie pas la licence du code
propre de KataLog. Les frameworks système restent soumis aux conditions de
leur fournisseur.

Pour chaque binaire distribué, les sources correspondantes doivent être
disponibles, avec le tag exact de la release, les scripts et instructions de
construction et les notices nécessaires. Les données privées des utilisateurs
ne font pas partie de ce code source. La release doit conserver cette
correspondance entre binaire et sources, indépendamment de la notarisation.

Un changement de dépendance ou de wheel doit entraîner une nouvelle inspection
des licences et des notices du bundle final.

Sources : [GNU GPL v3](https://www.gnu.org/licenses/gpl-3.0.html),
[identifiant SPDX GPL-3.0-only](https://spdx.org/licenses/GPL-3.0-only.html),
[CPython](https://docs.python.org/3/license.html),
[python-build-standalone](https://github.com/astral-sh/python-build-standalone),
[NumPy](https://github.com/numpy/numpy/blob/main/LICENSE.txt),
[pyulog](https://github.com/PX4/pyulog/blob/main/LICENSE.md),
[exception PyInstaller](https://pyinstaller.org/en/stable/license.html),
[licences Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE),
[runners GitHub](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[image macOS 27](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).
