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

Les utilisateurs de **0.5.x et 0.6.x** installent directement la dernière
release une première fois par DMG : leurs builds n’activent pas le flux public.
Ensuite les mises à jour se font depuis l’app. KataLog Preview reste une app de
review indépendante.

## Passage à 0.8.3

La version **0.8.3 (build 22)** apporte des corrections de fiabilité et de
réactivité sans modifier les fonctions ni les parcours. Elle conserve le
parseur **1.4.0** et la projection SQLite **8** ; depuis 0.8.2, aucun réimport,
nouveau téléchargement GCS ni nouvelle migration n’est nécessaire. Les données,
attributions, identités, dossiers et réglages restent conservés.

La [recette 0.8.3](RELEASE-0.8.3.md) consigne la qualification du package et ses
limites. Le [DMG 0.8.3](https://github.com/mehdi7129/KataLog/releases/download/v0.8.3/KataLog-0.8.3-macOS-arm64.dmg)
est disponible. Le XML stable versionné propose le build 22 ; ses signatures
et celles du ZIP public sont vérifiées localement avec l’outil officiel Sparkle.

## Passage à 0.8.2

Le correctif **0.8.2 (build 21)** rétablit la consultation de l’historique lorsque
les informations sur les sources rendent une page trop volumineuse. Il permet
également de charger et de réessayer la lecture des clients indépendamment de
l’historique. La qualification de l’app est consignée dans
[RELEASE-0.8.2.md](RELEASE-0.8.2.md). La version est distribuée par DMG et par le
flux stable signé depuis le **7 octobre 2026**. Depuis 0.7.0, elle peut être
installée avec **Réglages → Mises à jour → Rechercher une mise à jour**.

Depuis 0.8.1, le parseur et la projection SQLite restent inchangés. Les analyses,
clients, attributions, identités et réglages sont conservés. Aucun réimport,
nouveau téléchargement GCS ni réinitialisation n’est nécessaire pour appliquer
ce correctif. La préparation d’un index ou une restauration attend désormais
l’arrêt de la lecture des clients avant de remplacer ou modifier la bibliothèque.

## Changements introduits en 0.8.1

Les changements de **0.8.1 (build 20)** sont inclus lors d’une mise à jour directe
vers 0.8.3. Le [suivi de qualification 0.8.1](RELEASE-0.8.1.md) conserve les
résultats de la Preview approuvée et des contrôles de ce package stable.

La bibliothèque stable, les identités, les clients, les réglages et les dossiers
choisis sont conservés. La projection SQLite passe de 7 à 8, avec conservation
des résumés canoniques et sauvegarde de migration. Les anciennes analyses restent
consultables ; une réanalyse reste explicite et aucun nouveau téléchargement GCS
n’est requis. La bibliothèque de KataLog Preview reste indépendante et n’est pas
transférée automatiquement à KataLog stable.

La carte peut désormais représenter tous les logs géolocalisés du périmètre,
y compris ceux qui dépassaient l’ancienne limite d’affichage de 80 logs.

## Passage depuis une version antérieure à 0.8.0

Les changements introduits en 0.8.0 sont également inclus lors d’une mise à jour
directe vers 0.8.3. La [recette 0.8.0](RELEASE-0.8.0.md) conserve les résultats
de cette release.

La mise à jour conserve la bibliothèque stable, les identifications et les dossiers
choisis. Les logs existants apparaissent dans **Sans client** : ils ne sont pas
attribués automatiquement à une organisation. Créez vos clients dans le sélecteur
**Tous les clients**, puis attribuez les logs voulus en lot. Un log déjà connu
conserve son attribution lors d’un réimport ou d’une nouvelle collecte.

La première recherche géographique peut lire les sources accessibles pour mettre
en cache les trajectoires complètes. Les trajectoires non vérifiables sont
signalées ; elles ne sont pas assimilées à des logs hors de la zone recherchée.
Aucun nouveau téléchargement GCS n’est nécessaire pour cette migration.

Le vidage de bibliothèque et la réinitialisation sont des actions séparées,
confirmées dans les réglages ; une mise à jour ne les déclenche pas. Elles
conservent les fichiers `.ulg`. Voir [les effets précis](CLIENTS-BENTO.md#nettoyage).

## Installation manuelle

Téléchargez le nouveau DMG depuis la page Releases officielle, ouvrez-le, puis
glissez **KataLog.app** dans **Applications** et acceptez le remplacement de
l’ancienne app. Fermez KataLog avant ce remplacement. La bibliothèque, les
numéros de drones, les profils clients, les filtres et le dossier de collecte restent dans
Application Support et ne sont pas contenus dans l’app.

Les versions **0.5.x et 0.6.x** utilisent cette procédure. Leurs flux de mise
à jour étaient désactivés ; elles n’imposent pas d’installer les versions
intermédiaires une par une.

### Package de review indépendant

**KataLog Preview.app** s’installe à côté de KataLog. Les nouvelles Previews
utilisent un dossier `KataLogPreview-VERSION` distinct sous Application Support ;
les anciennes variantes gardent leur dossier dédié. La bibliothèque de la Preview
n’est pas transférée automatiquement à la version stable. Glisser cette Preview
dans Applications ne met pas à jour KataLog. Son flux de mise à jour est désactivé.

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
par [GitHub Raw](https://raw.githubusercontent.com/mehdi7129/KataLog/main/updates/stable/appcast.xml). Un éventuel flux
de staging doit être créé et vérifié séparément avant activation.

Configurer un build de staging :

```bash
KATALOG_VERSION=0.8.3 KATALOG_BUILD_NUMBER=22 \
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
  --archive dist/KataLog-0.8.3-macOS-arm64.zip \
  --archive-url https://updates.example.org/KataLog-0.8.3-macOS-arm64.zip \
  --output /private/tmp/katalog-update-draft \
  --release-notes /private/tmp/katalog-release-notes.txt \
  --channel staging --previous-build 21 --draft
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
[publication](PUBLICATION.md) et de [distribution](RELEASING.md#recette-finale).

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

Pour la 0.8.3, le [banc SDK du candidat](https://github.com/mehdi7129/KataLog/actions/runs/37923450954)
réussit à nouveau ces cinq recettes sur macOS 15.7.9 et 27.0.1 : remplacement et
relancement, feed modifié, archive modifiée, téléchargement interrompu et asset
absent. Les six fichiers synthétiques restent inchangés dans chaque essai.
Ce banc utilise des apps ad hoc jetables et une clé éphémère sur HTTP loopback ;
il ne remplace pas un cycle réel 0.8.2 → 0.8.3 dans KataLog. Les cas de payload
altéré constatent une erreur SDK et l’absence d’installation, sans asserter un
code d’erreur de signature précis. Les JSON sont conservés dans les logs du run ;
ce workflow ne téléverse pas d’artifacts séparés.

Sources : [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0),
[sécurité et configuration](https://sparkle-project.org/documentation/customization/),
[publication des mises à jour](https://sparkle-project.org/documentation/publishing/).
