# Mettre à jour KataLog

## Depuis la version 0.7.0

Ouvrez **Réglages → Mises à jour → Rechercher une mise à jour**, ou la commande
du menu de l’app. Lorsqu’une nouvelle version est proposée, choisissez de la
télécharger puis **Installer et redémarrer**. La bibliothèque, les identités et
le dossier de collecte sont conservés. Terminez ou arrêtez les opérations avant
l’installation ; KataLog attend si un import, une collecte ou un export est en cours.

Activez **Rechercher automatiquement les mises à jour** si vous souhaitez être
prévenu des nouvelles versions. Ce choix est conservé au redémarrage. L’app
ne télécharge ni n’installe silencieusement : vous gardez le choix du moment.

Les utilisateurs de **0.5.x et 0.6.x** installent 0.7.0 une première fois par
DMG : leurs builds n’activent pas le flux public. Ensuite les mises à jour se
font depuis l’app. KataLog Preview reste une app de review indépendante.

## Installation manuelle

Téléchargez le nouveau DMG depuis la page Releases officielle, ouvrez-le, puis
glissez **KataLog.app** dans **Applications** et acceptez le remplacement de
l’ancienne app. Fermez KataLog avant ce remplacement. La bibliothèque, les
numéros de drones, les vues enregistrées et le dossier de collecte restent dans
Application Support et ne sont pas contenus dans l’app.

Les versions **0.5.x et 0.6.x** utilisent cette procédure. Le passage
à 0.6.0 conserve la bibliothèque existante ; la projection SQLite est reconstruite
localement sans imposer de réanalyse des ULogs. Sparkle est embarqué, mais aucun
flux public n’est activé dans cette release.

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
l’expiration permettant un repli vers un flux non signé est désactivée. Les recherches automatiques sont désactivées par défaut et activables par
l’utilisateur depuis les réglages. L’installation automatique, le profil
système et le JavaScript des notes de version restent désactivés.

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
séparées sont nécessaires pour les deux canaux. Le flux stable KataLog est servi
par GitHub Raw à l’adresse indiquée au début de ce document. Un éventuel flux
de staging doit être créé et vérifié séparément avant activation.

Configurer un build de staging :

```bash
KATALOG_VERSION=0.7.1 KATALOG_BUILD_NUMBER=18 \
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
  --archive dist/KataLog-0.7.0-macOS-arm64.zip \
  --archive-url https://updates.example.org/KataLog-0.7.0-macOS-arm64.zip \
  --output /private/tmp/katalog-update-draft \
  --release-notes /private/tmp/katalog-release-notes.txt \
  --channel staging --previous-build 16 --draft
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

KataLog est sous **GPL-3.0-only**. Chaque release binaire doit proposer son
code source correspondant, identifié par le tag exact, avec l’archive de
sources, les scripts et instructions de build et les notices des dépendances.
Les clés privées, credentials et données utilisateurs restent hors des archives
de sources. Voir [les licences de distribution](DEPENDENCIES-LICENSES.md).

La CI utilise uniquement des runners GitHub standard, gratuits lorsque le dépôt
est public. Tant qu’il reste privé, ses jobs sont ignorés, même sur lancement
manuel ; les tests et builds locaux restent disponibles. Publier le dépôt ne
publie pas une release, un appcast ou une mise à jour de l’app.

Avant activation publique, qualifier un cycle staging complet : proposition de
version, refus d’une mauvaise signature de feed et d’archive, téléchargement
interrompu, refus d’un downgrade, attente pendant une collecte, installation et
relancement avec bibliothèque et dossier de collecte conservés. Répéter le
cycle sur macOS 15 et macOS 27. Les tests unitaires et les signatures locales
constituent des preuves logicielles ; ils ne remplacent pas cette recette
d’installation.

Pour la 0.7.0, le [banc d’installation SDK](https://github.com/mehdi7129/KataLog/actions/runs/36877469286)
a réussi ses cinq recettes sur macOS 15 et 27 : installation et relancement,
flux et archive modifiés, téléchargement interrompu et archive absente.
Il utilise des apps jetables, une clé de test éphémère et un flux loopback signé.
Les fichiers de la bibliothèque et du dossier de collecte synthétiques sont conservés.
Les archives publiques et leur flux HTTPS sont contrôlés séparément par SHA-256
et avec l’outil de vérification officiel Sparkle.

Sources : [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0),
[sécurité et configuration](https://sparkle-project.org/documentation/customization/),
[publication des mises à jour](https://sparkle-project.org/documentation/publishing/).
