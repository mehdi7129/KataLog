# Mettre à jour KataLog

## Installation manuelle

Téléchargez le nouveau DMG depuis la page Releases officielle, ouvrez-le, puis
glissez **KataLog.app** dans **Applications** et acceptez le remplacement de
l’ancienne app. Fermez KataLog avant ce remplacement. La bibliothèque, les
numéros de drones, les vues enregistrées et le dossier de collecte restent dans
Application Support et ne sont pas contenus dans l’app.

Les versions **0.5.1 et 0.5.2** utilisent cette procédure. Leur premier passage
à une version contenant Sparkle reste manuel.

### Package de review 0.6

**KataLog Preview.app** s’installe à côté de KataLog. Il utilise une bibliothèque
séparée sous `~/Library/Application Support/KataLogPreview-0.6/` et ouvre les
nouveaux écrans directement. Glisser cette Preview dans Applications ne constitue
pas une mise à jour de l’app existante. Elle n’active aucun flux de mise à jour.

## Intégration présente dans les sources

Sparkle **2.10.0** est épinglé dans SwiftPM et XcodeGen. Le pipeline embarque le
framework, son updater et ses services XPC, puis signe les composants imbriqués
avant l’app. Cette version de Sparkle prend en charge macOS 27 ; le minimum de
KataLog reste **macOS 15**, sur **Apple Silicon**.

Les builds sont configurés avec le canal **disabled** par défaut : aucun flux ni
clé ne sont embarqués et aucune recherche distante n’est démarrée. Le service
présente alors la procédure manuelle. L’intégration locale ne signifie pas
qu’un flux public est disponible ni qu’une mise à jour réelle a été publiée.

Un build activé exige un flux HTTPS et sa clé publique Ed25519. Le flux et
l’archive doivent être signés. La signature est vérifiée avant extraction ;
l’expiration permettant un repli vers un flux non signé est désactivée. Les
recherches automatiques, l’installation automatique, le profil système et le
JavaScript des notes de version sont désactivés.

La recherche et l’installation sont refusées pendant les imports, collectes,
exports ou opérations de stockage. Si le redémarrage devient nécessaire alors
qu’une opération a commencé, Sparkle attend que l’app soit disponible. La
configuration du canal ne se change pas pendant l’utilisation.

## Préparer un flux local

Les commandes suivantes préparent des fichiers locaux ; elles ne publient
rien. Utilisez les outils du SDK officiel Sparkle 2.10.0 résolu par SwiftPM.
Gardez les clés privées dans le Keychain ou dans un fichier extérieur au dépôt
et au dossier de préparation. Seule la clé publique entre dans Info.plist.

Les deux canaux utilisent des comptes de signature distincts :

- `katalog-sparkle-staging` pour les essais ;
- `katalog-sparkle-stable` pour les versions publiques.

Un flux stable contient des versions sans tag de canal. Le flux de staging
utilise le tag `staging`, accepté uniquement par les builds de staging. Des URLs
séparées sont prévues, par exemple `updates/staging/appcast.xml` et
`updates/stable/appcast.xml` sur GitHub Pages. Ces endpoints doivent être créés
et vérifiés avant toute activation d’un build destiné aux utilisateurs.

Configurer un build de staging :

```bash
KATALOG_VERSION=0.6.0 KATALOG_BUILD_NUMBER=9 \
KATALOG_UPDATE_CHANNEL=staging \
KATALOG_UPDATE_FEED_URL=https://updates.example.org/staging/appcast.xml \
KATALOG_UPDATE_PUBLIC_KEY='<cle-publique-base64>' \
bash tools/build-app.sh
```

`updates.example.org` est un exemple, pas un serveur KataLog. Fournissez un vrai
endpoint et une clé validée avant de construire un build activé.

Pour relire un brouillon, une archive ZIP existante suffit :

```bash
python3 tools/update-feed.py prepare \
  --archive dist/KataLog-0.6.0-macOS-arm64.zip \
  --archive-url https://updates.example.org/KataLog-0.6.0-macOS-arm64.zip \
  --output /private/tmp/katalog-update-draft \
  --release-notes /private/tmp/katalog-release-notes.txt \
  --channel staging --previous-build 8 --draft
```

Le brouillon est nommé `appcast.draft.xml` et reste non signé. Pour préparer un
flux signé, retirez `--draft` et ajoutez `--sign-update` avec le chemin de l’outil
officiel. `--previous-build` est obligatoire pour un flux signé ; utilisez `0`
uniquement pour son premier build. Le compte Keychain correspondant au canal doit déjà exister ; l’outil
de préparation ne crée aucune clé. L’archive activée doit embarquer sa clé
publique et le même canal. Une seed exportée par Sparkle peut être fournie avec
`--ed-key-file` ; sa clé publique est vérifiée avant signature.

La préparation refuse les builds qui n’augmentent pas par rapport à
`--previous-build`, une URL qui ne porte pas le nom exact du ZIP, les clés qui
ne correspondent pas, une configuration de sécurité affaiblie et un dossier de
sortie contenant déjà un flux. Les notes sont intégrées au feed signé et les
chemins personnels évidents sont refusés. Le manifeste local conserve la
version, le SHA-256, les octets et `uploaded: false`, sans chemin de clé privée.

## Vérifications avant publication

La signature EdDSA du feed ne remplace pas Developer ID ni la notarisation.
Le DMG et le ZIP doivent provenir du **même bundle final signé et notarisé**.
Le pipeline public reste soumis aux contrôles de
[publication](PUBLICATION.md) et de [distribution](DISTRIBUTION-VALIDATION.md).

Avant activation publique, qualifier un cycle staging complet : proposition de
version, refus d’une mauvaise signature de feed et d’archive, téléchargement
interrompu, refus d’un downgrade, attente pendant une collecte, installation et
relancement avec bibliothèque et dossier de collecte conservés. Répéter le
cycle sur macOS 15 et macOS 27. Les tests unitaires et les signatures locales
constituent des preuves logicielles ; ils ne remplacent pas cette recette
d’installation.

Sources : [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0),
[sécurité et configuration](https://sparkle-project.org/documentation/customization/),
[publication des mises à jour](https://sparkle-project.org/documentation/publishing/).
