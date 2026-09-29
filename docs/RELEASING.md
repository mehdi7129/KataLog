# Publier une version macOS

Le dépôt est destiné à devenir public. La visibilité reste privée tant que la
[préparation publique](PUBLICATION.md) n’est pas terminée. La mise à jour utilisateur est décrite
dans le [README](../README.md#mettre-à-jour-une-app-déjà-installée) ; KataLog ne
possède pas encore d’updater automatique.

## Distribution cible 0.6.0 : DMG hors App Store

Le téléchargement utilisateur fournit un **DMG signé et notarisé**, avec
**KataLog.app** et un lien **Applications**. Installation : ouvrir le DMG,
glisser l'app dans Applications, éjecter puis lancer. Aucun Terminal, Homebrew,
Python séparé ou App Store n'est requis une fois le moteur embarqué.

L'app est signée avant le packaging ; les tickets de notarisation sont agrafés
aux livrables appropriés avant vérification. L'archive ZIP utilisée par Sparkle,
si distincte, provient du même bundle final contrôlé. Clés privées de signature
et de mise à jour restent dans le Trousseau ou un stockage de secrets.

La release 0.5.1 privée est encore un ZIP avec Python externe. Ses chemins de
compilation imposent un nouveau build audité avant publication publique ; elle
ne doit pas être exposée simplement en changeant la visibilité du dépôt.

## Préparer

1. Mettre à jour `CFBundleShortVersionString` et `CFBundleVersion` dans
   `tools/build-app.sh`, les versions correspondantes dans `project.yml`, puis
   exécuter `xcodegen generate`. Incrémenter le build pour chaque nouvelle version.
2. Actualiser README, CHANGELOG et les résultats réellement vérifiés.
3. Exécuter les tests Swift, Python et Node documentés. Les tests Python complets
   utilisent les fixtures ULog privées, qui ne doivent pas entrer dans Git.
4. Vérifier le diff, le statut Git, l’identité Developer ID et le profil de
   notarisation du Trousseau. Conserver les logs, bibliothèques, rapports et
   identifiants d’authentification hors des fichiers publiés.
5. Contrôler les sources exportées, l'historique destiné au public, les métadonnées
   d'auteur, les notes et tous les assets. Inspecter les octets des exécutables,
   les scripts du bundle et les métadonnées des images ; `.gitignore` et notarisation
   ne remplacent pas cet audit. Construire avec chemins de compilation neutralisés.

## Pipeline ZIP actuel (0.5.1)

Le build local utilise une signature ad hoc par défaut. Pour une release :

```sh
KATALOG_SIGN_IDENTITY='Developer ID Application: NOM (TEAMID)' \
  bash tools/build-app.sh

xcrun notarytool submit dist/KataLog.zip \
  --keychain-profile MON_PROFIL --wait
```

Continuer uniquement lorsque le service retourne **Accepted**. La copie préparée
hors du Bureau est indiquée dans `dist/LOCAL-APP-PATH.txt` :

```sh
katalog_release_app="$(cat dist/LOCAL-APP-PATH.txt)"
xcrun stapler staple "$katalog_release_app"
xcrun stapler validate "$katalog_release_app"
codesign --verify --strict --verbose=2 "$katalog_release_app"
spctl --assess --type execute --verbose=2 "$katalog_release_app"
```

Recréer ensuite le ZIP avec `ditto -c -k --norsrc --keepParent`, **après** le
stapling, depuis cette copie. Nommer l’asset
`KataLog-VERSION-macOS-arm64.zip`, produire `SHA256SUMS.txt`, puis extraire le ZIP
dans un dossier temporaire et répéter `codesign`, `stapler validate` et `spctl`.
Le résultat attendu de Gatekeeper est **Notarized Developer ID**. Ne pas déposer
un bundle `.app` décompressé sur le Bureau synchronisé : le file provider peut
ajouter des attributs qui invalident la signature.

## Publier et vérifier

- Committer les sources et la documentation vérifiées, pousser la branche et un
  tag annoté `vVERSION` pointant exactement vers ce commit.
- Créer la release avec `gh release create --verify-tag`, les notes via
  `--notes-file`, le ZIP installable et `SHA256SUMS.txt`. Les assets sont les seuls
  binaires distribués ; les archives « Source code » de GitHub ne contiennent
  pas l’app compilée.
- Vérifier le tag distant, le statut publié, les deux assets et la visibilité attendue
  du dépôt et le périmètre audité. Retélécharger les assets via GitHub avec un compte autorisé et
  contrôler leurs empreintes avec `shasum -a 256 -c SHA256SUMS.txt`.
- Ne pas réutiliser un tag publié pour remplacer silencieusement une autre
  version. En cas de correction après publication, préparer une nouvelle version.

La notarisation ne remplace pas les tests fonctionnels. Python, `pyulog` et
`numpy` ne sont pas embarqués dans la release 0.5.1 ; ils restent des prérequis
sur un nouveau Mac.
