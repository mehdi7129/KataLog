# Plan USB, file de collecte et Mac Intel — 0.9.0

## Base et périmètre

Partir de `main` 1f7c84d (0.8.8, build 27) dans une copie de travail séparée.
Préserver les clients, notes, favoris, imports et mécanismes de reprise existants.
Préparer 0.9.0, build 28 ; revérifier le build public avant publication.

1. Porter la collecte USB serial PX4 et sa file persistante. Vérifier l'identité
   du contrôleur, les métadonnées du log et tous les octets avant l'import.
   Autoriser l'ajout de logs d'autres appareils pendant un téléchargement GCS.
   Un appareil USB absent reste en attente ; aucun basculement implicite de cible.
2. Valider le protocole face aux sources PX4 et QGroundControl, avec de vrais
   encodeurs MAVLink 1/2 indépendants. Négocier MAVLink 2 pour stabiliser UID2.
   Simuler pertes, doublons, trames corrompues, bruit, changement d'identité,
   déconnexion, annulation et reprise sur un pseudo-terminal serial macOS.
3. Produire deux apps natives autonomes : `arm64` et `x86_64`. Même version,
   build, bundle ID et format de bibliothèque ; ZIP/DMG explicitement suffixés.
   Épingler CPython et les wheels de chaque architecture. Refuser tout mélange
   Swift/helper/Python ou dépendance native incompatible. Conserver macOS 15 minimum.
4. Exécuter les suites et le moteur embarqué sur runners natifs Apple Silicon
   et Intel. Vérifier l'architecture effective et l'absence de traduction Rosetta.
   Conserver les preuves et archives liées au commit exact. Tester le bundle final
   signé sur Intel, pas seulement les sources ou un cross-build ARM.
5. Conserver le flux Sparkle ARM existant. Ajouter un flux Intel séparé : Sparkle
   2.10 reconnaît `hardwareRequirements=arm64`, pas un filtre Intel équivalent.
   Vérifier l'accord architecture/URL/archive et signer chaque ZIP et chaque feed.
6. Réécrire le README, les instructions de collecte/installation/distribution et
   le changelog. Documenter l'essai USB simulé et la qualification matérielle restant
   à faire ; ne promettre aucun débit réel sans mesure sur l'autopilote.
7. Après réussite des contrôles : signature Developer ID et notarisation locales
   des deux architectures, recette des DMG, checksums, commit/tag exacts et release
   GitHub autorisée. Publier les feeds après vérification des assets publics.
   Ne remplacer aucun asset déjà publié.

## Double vérification du plan

- Deux relectures indépendantes convergent vers des builds natifs séparés et
  des feeds distincts. Un faux bundle universal ou un filtre Sparkle `x86_64`
  ne suffirait pas.
- L'audit protocolaire a identifié puis corrigé le changement d'identité entre
  démarrage MAVLink 1 et connexion après QGroundControl. Les tests utilisent les
  vrais dialectes v1/v2, sans extension v2 artificiellement incluse dans une trame v1.
- Ne pas envoyer `LOG_REQUEST_END` entre la liste et les données : PX4 quitte
  son état de transfert et refuse ensuite les données. Nettoyer à la fin/annulation.
- Le runner Intel doit réellement lancer l'app/helper et non seulement inspecter
  leurs en-têtes. La signature peut être faite sur ARM ; l'exécution Intel reste
  qualifiée sur Intel.
- La simulation qualifie le logiciel et les erreurs injectées. Elle ne qualifie
  pas le câble USB, les pilotes, le firmware Aqua installé ni les débits réels.

## Sources vérifiées

- [Runners GitHub natifs](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Contraintes matérielles Sparkle](https://sparkle-project.org/documentation/publishing/#minimum-system-version-requirements)
- [Packaging multi-architecture PyInstaller](https://pyinstaller.org/en/stable/feature-notes.html#macos-multi-arch-support)
