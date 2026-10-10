# Distribution macOS hors App Store

La version **0.8.5 (build 24)** corrige la reconnexion GCS et reprend les
améliorations de collecte de 0.8.4. Elle conserve l’installation autonome par DMG
et le flux Sparkle stable signé introduit en 0.7.0. La
[recette 0.8.5](RELEASE-0.8.5.md) consigne la CI, la distribution, la recette
native et les téléchargements publics vérifiés, avec une observation de
métadonnées d’export.
La release 0.8.4 est publique et immuable, sans activation de son build 23 dans
le flux. Toute nouvelle publication exige la validation
de l’historique, des métadonnées GitHub et des assets ; une CI ad hoc ne
qualifie pas à elle seule une distribution signée et notarisée.

## Parcours utilisateur

Télécharger le **DMG signé et notarisé**, l’ouvrir, glisser **KataLog.app** dans
**Applications**, éjecter puis lancer. Aucun Python, Homebrew, Terminal ni App Store
n’est requis pour utiliser le package. Mac Apple Silicon, macOS 15 minimum.
La recette native de 0.8.5 a été exécutée sur sa copie du DMG après éjection ;
une recette sur macOS 27 ne vaut pas recette physique sur toutes les versions de macOS.

## Préparer et tester

1. Fixer version et build dans `tools/build-app.sh`, `tools/package-smoke.sh` et
   `project.yml`, puis `xcodegen generate`. Le build 24 de 0.8.5 succède au build
   23 de la release 0.8.4 ; le flux passe directement du build 22 au build 24.
   Conserver l’identité stable de l’app ; la Preview utilise son identité séparée.
2. Exécuter les suites Swift, Python et Node du README. `KATALOG_PRIVATE_FIXTURES`
   désigne uniquement le corpus local ; les ULog et résultats privés restent hors Git.
3. Exécuter `python3 tools/check-publication.py --include-untracked` et un scanner
   de secrets ; vérifier historique, auteurs et tous les assets séparément.
4. Vérifier certificat Developer ID et profil de notarisation disponibles dans le
   Trousseau. Les noms et secrets du poste ne doivent pas entrer dans les sources.

## Construire le moteur et l’app

```sh
KATALOG_SIGN_IDENTITY='Developer ID Application: NOM (TEAMID)' \
  bash tools/build-app.sh
```

Le script construit par défaut le helper via `tools/build-engine.sh`. CPython
portable, wheels et outils PyInstaller sont épinglés avec SHA-256 ; téléchargement
et build s’effectuent dans `/private/tmp`. Aucun Python global n’est modifié.
Les licences et le manifest sont embarqués dans le bundle du helper.

Le package utilise `Contents/Helpers/KataLogEngine.app`, avec les composants natifs
dans Frameworks et les données dans Resources. Ce format évite de placer des
metadata Python dans un emplacement macOS réservé au code. Le résolveur commun
vérifie protocole/parseur et n’utilise aucun Python externe dans une app distribuée.

La compilation neutralise les chemins source. Avant signature, les chemins de
recherche propres à Xcode sont retirés des binaires. Les composants natifs sont
signés avec hardened runtime et timestamp, puis les bundles imbriqués, puis l’app.
Un moteur préconstruit peut être désigné par `KATALOG_ENGINE_PATH` ; ses hashes
source doivent correspondre exactement aux scripts actuels.

Sorties : `dist/KataLog-VERSION-macOS-arm64.zip`, alias local `dist/KataLog.zip`,
et `dist/LOCAL-APP-PATH.txt` indiquant une copie vérifiée hors Bureau. Les anciennes
sorties sont conservées en `previous-build.*`. La signature ad hoc par défaut
sert au développement ; une distribution requiert Developer ID.

## Notariser l’app, puis le DMG

### Créer un profil si le Trousseau n’en possède pas

Le profil est un nom choisi localement, par exemple `KataLog-notary`. Il ne
correspond pas à un certificat Developer ID et n’existe pas automatiquement.
Depuis Terminal, le titulaire exécute :

```sh
xcrun notarytool store-credentials KataLog-notary
```

Les questions interactives demandent l’Apple ID du compte Developer, son Team ID
(page Membership du compte) et un mot de passe spécifique à l’app créé dans le
compte Apple. Le titulaire saisit ces informations directement dans Terminal ;
elles ne sont ni demandées dans une conversation ni ajoutées aux sources.
`notarytool` les valide et les conserve dans le Trousseau. Ce choix n’installe
pas l’app via l’App Store. Le pipeline peut ensuite utiliser ce seul nom de
profil. Ne pas soumettre une release tant que le profil n’a pas été validé.

### Soumettre les fichiers qualifiés

```sh
xcrun notarytool submit dist/KataLog-VERSION-macOS-arm64.zip \
  --keychain-profile MON_PROFIL --wait
```

Continuer uniquement lorsque le statut est **Accepted**. Agrafer le ticket au
helper imbriqué puis à l’app indiquée dans `LOCAL-APP-PATH.txt`, valider les deux
tickets avec `xcrun stapler validate`, puis vérifier `codesign --verify --deep --strict`
et `spctl --assess --type execute --verbose=2` sur l’app. Recréer le ZIP final
avec `ditto -c -k --norsrc --keepParent` depuis cette app après stapling.

Les outils de création du DMG sont testés avec Python 3.13. Si `python3`
désigne le Python 3.9 fourni avec certains Command Line Tools, préparer le
venv avec l'interpréteur 3.13 puis le désigner explicitement :

```sh
python3.13 -m venv /private/tmp/katalog-dmg-tools-313
```

```sh
KATALOG_DMG_BUILD_DIR=/private/tmp/katalog-dmg-tools-313 \
KATALOG_SIGN_IDENTITY='Developer ID Application: NOM (TEAMID)' \
KATALOG_NOTARY_PROFILE=MON_PROFIL \
  bash tools/build-dmg.sh
```

`KATALOG_DMG_PYTHON=python3.13` permet aussi de choisir l’interpréteur lors de la
création d’un nouveau venv. Le script vérifie Python 3.10 minimum, y compris
pour un venv existant, avant de lancer l’installation des dépendances.

Le script installe uniquement ses outils de build dans un venv temporaire, avec
requirements et hashes épinglés. Il génère la fenêtre monochrome et le lien
Applications, vérifie l’image ainsi que la copie du bundle sur le volume monté,
signe le DMG, attend **Accepted**, puis agrafe et valide son ticket. Un DMG existant
n’est jamais écrasé ; `KATALOG_DMG_PATH` permet de choisir un nouveau chemin.
La création et la vérification utilisent un volume local temporaire ; seuls les
octets vérifiés sont ensuite copiés vers la destination choisie. Cela permet
de livrer aussi dans un dossier géré par FileProvider.

Aucun attribut FinderInfo n’est ajouté au bundle signé : masquer son extension
avec SetFile casserait la vérification stricte. Les réglages de fenêtre restent
dans le .DS_Store généré du volume, sans coordonnées ni état de flotte.

## Recette finale

```sh
python3 tools/verify-distribution.py \
  --app /chemin/vers/KataLog.app \
  --dmg dist/KataLog-VERSION-macOS-arm64.dmg \
  --report reports/verification-distribution.json \
  --require-notarized
```

La recette inspecte signatures, ticket/Gatekeeper, metadata et symlinks, tous les
Mach-O/minima/dépendances, et le contenu décompressé des archives Python. Elle
exécute le moteur sans Python dans le PATH, avec HOME isolé et variables Python
invalides : import synthétique, réimport/cache/détails conservés hors source et
simulateur GCS localhost avec réutilisation d’un téléchargement vérifié.

Vérifier aussi le lancement après copie puis éjection du DMG, l’import et l’export
natifs, et la conservation du numéro/dossier après redémarrage avec une bibliothèque
isolée. Une recette locale sur macOS 27 ne remplace pas un Mac vierge/macOS 15 ou
un essai radio GCS réel. Calculer SHA256SUMS après toutes les opérations de stapling.

## Publication séparée

Committer les sources et docs validées. Lorsqu’une publication est demandée,
fixer un tag annoté correspondant au commit, puis créer la release avec le DMG,
le ZIP de mise à jour, les sources correspondantes et leurs checksums.
L’arbre du tag doit correspondre exactement à celui du commit qualifié, y compris
si le commit de merge porte un autre identifiant. Les mises à jour documentaires
et du flux effectuées ensuite ne déplacent pas ce tag. Vérifier le téléchargement et la quarantaine
des assets depuis GitHub. Ne pas exposer les anciens assets 0.5.1 : ils restent
dans l’archive privée distincte. Les clés privées et rapports de flotte restent locaux.

## Flux stable 0.8

Construire avec `KATALOG_UPDATE_CHANNEL=stable`, l’URL HTTPS publique et la clé
publique vérifiée sous `updates/stable/public-key.txt`. Garder la clé privée dans
le Trousseau, compte `katalog-sparkle-stable`. Notariser et agrafer le bundle,
puis recréer le ZIP final avant toute signature Sparkle ou calcul de checksum.
Le flux 0.8.5 (build 24) a été préparé avec `tools/update-feed.py prepare` et
`--previous-build 22`, après vérification du dernier build effectivement servi
par le flux stable. La release publique 0.8.4 (build 23) n’a jamais été activée
dans ce flux ; son existence ne change donc pas la transition **22 → 24**.
Pour chaque release suivante, utiliser le dernier build servi et vérifié,
**24** après activation publique de 0.8.5.
Revérifier ce build au moment de publier : il ne doit pas avoir changé entre
préparation et publication.
Publier d’abord le ZIP et le DMG vérifiés, puis le flux signé sous
`updates/stable/appcast.xml`. La signature du fichier préparé localement et celle
du ZIP ne prouvent pas la mise en ligne du feed : après fusion, télécharger le
flux effectivement servi sans authentification et vérifier ses octets et signatures.

Ne pas remplacer les assets d’une release déjà publiée : une nouvelle archive
exige un nouveau numéro de build. Conserver les ZIP encore référencés par le flux.
