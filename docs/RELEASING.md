# Distribution macOS hors App Store

La génération 0.9.0 distribue deux apps natives : **arm64** pour Apple Silicon et
**x86_64** pour Intel, avec macOS **15 minimum**. Chaque app contient son moteur
Python et utilise un flux Sparkle stable propre à son architecture. Aucun Python,
Homebrew ni Rosetta n’est nécessaire chez l’utilisateur.

La version préparée est **0.9.0, build 28**, après **0.8.8, build 27**. Revérifier
le dernier build public avant de publier. Les tags et assets antérieurs restent
immuables. La [recette 0.8.8](RELEASE-0.8.8.md) conserve ses résultats historiques ;
ils ne remplacent pas ceux du nouveau candidat.

## Préparer le candidat

1. Fixer version/build dans `tools/build-app.sh`, `tools/package-smoke.sh` et
   `project.yml`, puis exécuter `xcodegen generate`.
2. Exécuter les suites Swift, Python et Node décrites dans [CONTRIBUTING](../CONTRIBUTING.md).
   Le corpus privé est facultatif et reste hors dépôt ; son absence est signalée.
3. Contrôler `tools/check-publication.py --include-untracked`, le diff, l’historique,
   les auteurs et les assets. Aucun log réel, identifiant de flotte, secret ou chemin
   personnel ne doit être ajouté aux sources ou aux rapports publics.
4. Qualifier le commit exact sur des runners natifs ARM64 et Intel. Conserver les
   rapports, l’architecture effective, la version de macOS et les SHA des archives.
   Une compilation croisée ou une inspection des en-têtes ne qualifie pas le runtime.

Le [plan et sa double vérification](PLAN-USB-INTEL-RELEASE.md) décrivent les décisions
USB/Intel. Le [banc USB](USB-COLLECTION.md#banc-sans-matériel) ne contacte aucun matériel.

## Construire nativement

Sur chaque architecture :

```sh
KATALOG_ARCH="$(uname -m)" bash tools/build-app.sh
```

Le script refuse une architecture différente de celle du processus natif et une
exécution sous Rosetta. Il compile Swift et le moteur Python pour cette architecture.
CPython portable, wheels et outils PyInstaller sont épinglés avec SHA-256 ; les
caches et builds s’effectuent hors du Bureau, dans `/private/tmp` par défaut.
Aucun Python global n’est modifié. `KATALOG_ENGINE_BUILD_DIR`, `KATALOG_BUILD_DIR`
et `KATALOG_DIST_DIR` permettent de choisir des dossiers séparés.

Le helper est dans `Contents/Helpers/KataLogEngine.app`, ses composants natifs dans
Frameworks et ses données dans Resources. Les versions, architecture, licences et
hashes des sources sont embarqués. Un `KATALOG_ENGINE_PATH` préconstruit doit
correspondre exactement aux sources, dépendances et architecture attendues.

Les sorties sont `KataLog-VERSION-macOS-ARCH.zip` et `LOCAL-APP-PATH.txt` dans le
dossier de distribution. Les exécutables propres à KataLog et le helper sont natifs
à l’architecture ; le framework Sparkle peut être universel. Le vérificateur inspecte
chaque Mach-O, ses dépendances, son minimum macOS et sa cohérence avec le manifeste.
Les anciennes sorties locales sont conservées dans des dossiers `previous-build.*`.

Par défaut, l’app est signée ad hoc avec les updates désactivées. Une candidate
stable exige avant signature :

```sh
KATALOG_UPDATE_CHANNEL=stable \
KATALOG_UPDATE_FEED_URL=URL_DU_FLUX_DE_L_ARCHITECTURE \
KATALOG_UPDATE_PUBLIC_KEY="$(cat updates/stable/public-key.txt)" \
KATALOG_SIGN_IDENTITY='Developer ID Application: NOM (TEAMID)' \
  bash tools/build-app.sh
```

La clé privée reste dans le Trousseau local. Une CI de build n’en a pas besoin.
Les workflows peuvent produire une archive ad hoc avec les métadonnées stables ;
cette archive est récupérée et signée localement après contrôle de son SHA et de
son commit. La signature de l’archive Intel peut être réalisée sur un Mac ARM :

```sh
python3 tools/sign-bundle.py --app /chemin/KataLog.app \
  --identity 'Developer ID Application: NOM (TEAMID)'
```

Cela ne remplace pas l’exécution de ce bundle final sur un runner Intel.

## Notariser l’app et le DMG

Vérifier le certificat Developer ID et un profil `notarytool` déjà validé dans le
Trousseau. S’il manque, son titulaire crée le profil localement avec
`xcrun notarytool store-credentials NOM_DU_PROFIL`, sans saisir les secrets dans une
conversation, un script ou un workflow. Ne pas soumettre tant que le profil échoue.

1. Archiver l’app signée avec `ditto -c -k --norsrc --keepParent`, puis soumettre le
   ZIP avec `xcrun notarytool submit ARCHIVE --keychain-profile PROFIL --wait`.
2. Exiger **Accepted**. Agrafer les tickets au helper puis à l’app avec `xcrun stapler staple`.
   Vérifier les tickets, `codesign --verify --deep --strict` et Gatekeeper.
3. Recréer le ZIP final après stapling. Aucune signature Sparkle ni checksum final
   ne doit précéder cette opération.
4. Créer le DMG à partir de cette même app :

```sh
KATALOG_APP_PATH=/chemin/KataLog.app \
KATALOG_DMG_PYTHON=python3.13 \
KATALOG_SIGN_IDENTITY='Developer ID Application: NOM (TEAMID)' \
KATALOG_NOTARY_PROFILE=NOM_DU_PROFIL \
  bash tools/build-dmg.sh
```

Le DMG porte automatiquement le suffixe de l’architecture de l’app. Ses outils
Python sont installés avec hashes dans un venv temporaire. Le script construit
sur un volume local, vérifie la copie montée, signe, notarise, agrafe et valide
l’image avant de copier ses octets vers la destination. Un DMG existant n’est
jamais remplacé. `KATALOG_DMG_PATH` permet un autre chemin.

Pour fabriquer le DMG Intel sur ARM, `KATALOG_DMG_SKIP_RUNTIME=1` autorise uniquement
l’inspection croisée. Son rapport est incomplet par définition : la recette native
Intel du bundle final reste obligatoire. Aucun attribut FinderInfo n’est ajouté
au bundle signé ; cela casserait sa vérification stricte.

## Qualifier les fichiers finaux

Sur un Mac de l’architecture de l’app :

```sh
python3 tools/verify-distribution.py --app /chemin/KataLog.app \
  --dmg dist/KataLog-VERSION-macOS-ARCH.dmg \
  --report reports/verification-distribution-ARCH.json --require-notarized

python3 tools/verify-usb-runtime.py --app /chemin/KataLog.app \
  --bench-python /chemin/venv/bin/python3 \
  --report reports/verification-usb-ARCH.json
```

Le premier contrôle vérifie signatures, tickets, symlinks, metadata, licences,
Mach-O et contenu des archives Python, puis exécute le moteur avec HOME isolé et
sans Python externe : import, cache et collecte GCS localhost. Le second teste le
helper réellement embarqué sur un pseudo-terminal : MAVLink 1/2, blocs perdus,
SHA exact, cache, mauvais UID, appareil armé, SIGTERM et libération du port.

`--skip-runtime` du vérificateur est réservé à une inspection depuis l’autre
architecture. Le résultat `inspection-passed` n’est pas une qualification native.
Les workflows conservent la preuve de l’exécution native finale séparément.

Copier également l’app depuis le DMG, éjecter celui-ci et tester l’interface avec
une bibliothèque synthétique isolée. Vérifier collecte, ajout de plusieurs appareils,
import et conservation après redémarrage. Ne jamais prendre la bibliothèque réelle
comme fixture. Une recette CI Intel ne constitue pas un essai physique USB Aqua.

## Publier puis activer les mises à jour

Committer les sources et docs qualifiées. Créer un tag annoté correspondant à cet
arbre exact ; une fusion peut changer le SHA du commit, mais pas son arbre qualifié.
Publier les deux DMG, les deux ZIP, les sources correspondantes et `SHA256SUMS`.
Calculer les hashes après tous les staplings. Vérifier les téléchargements publics,
leurs signatures et la concordance des sources avec le tag. Ne remplacer aucun asset.

| Architecture | Flux stable |
| --- | --- |
| Apple Silicon | `updates/stable/appcast.xml` — emplacement historique conservé |
| Intel | `updates/stable-intel/appcast.xml` |

Les URLs embarquées pointent vers ces fichiers de la branche `main` sur
`raw.githubusercontent.com/mehdi7129/KataLog/`. Les deux flux utilisent la clé
publique stable vérifiée. Sparkle 2.10 reconnaît la contrainte `arm64` ; il ne
fournit pas de filtre équivalent `x86_64`. La séparation des URLs empêche de proposer
le mauvais package. Le générateur vérifie architecture, URL, nom d’archive et build.

Préparer et signer chaque ZIP et chaque feed avec `tools/update-feed.py prepare`,
en indiquant `--architecture arm64` ou `x86_64`, l’URL de l’asset immuable et le
build effectivement servi auparavant. Le premier flux Intel utilise `--previous-build 0`, après vérification de l’absence
d’un flux antérieur.
Utiliser l’outil officiel `sign_update` et la clé du Trousseau ; ne pas exporter de clé
privée dans le dépôt. Publier les feeds uniquement après vérification des assets.

Après fusion, télécharger chaque flux canonique sans authentification et vérifier
ses octets, sa signature, son build, sa clé publique et son enclosure. La signature
d’un fichier local ne prouve pas que GitHub sert ce fichier. Conserver les archives
encore référencées et consigner les résultats dans la recette de release.
