> **Document historique.** Les résultats et statuts ci-dessous décrivent leur
> version à la date de la recette. Pour la version actuelle :
> [KataLog 0.8.1](RELEASE-0.8.1.md) et [guide utilisateur](README.md).

# KataLog 0.6.0 — recette de livraison

Version **0.6.0 (14)**, 30 septembre 2026. Livraison hors App Store pour Mac Apple
Silicon. Le dépôt reste privé ; sa visibilité est indépendante de cette release.

## Parcours livré

- Télécharger le DMG, glisser **KataLog.app** dans Applications, éjecter et lancer.
- Depuis 0.5.1/0.5.2 : quitter l’app avant remplacement. La bibliothèque conserve
  son emplacement, ses identités, annotations, sources et réglages de collecte.
  Les projections SQLite sont reconstruites sans imposer de réanalyse des ULogs.
- La **Preview** reste une app séparée avec une bibliothèque séparée. Ses imports
  ne sont pas fusionnés automatiquement dans la stable ; réimporter leur dossier
  dans KataLog permet de les retrouver sans multiplier les contenus identiques.
- Le flux Sparkle reste désactivé : cette release se met à jour manuellement par
  DMG. Aucun compte App Store, Python, Homebrew ou Terminal n’est nécessaire.

## Collecte et identité

**Tout collecter** inclut les drones éligibles découverts sur la GCS connectée,
enregistre les nouveaux UUID puis inventorie et collecte les fichiers. Le numéro
de stock est facultatif et peut être renseigné plus tard. Les drones sans aucun
log restent enregistrés. Aucun numéro n’est deviné à partir de la télémétrie.

Les UUID invalides, les appareils hors ligne et ceux explicitement armés sont
exclus. L’état d’armement absent reste inconnu. La découverte seule n’inscrit pas
un drone. Un échec de sauvegarde bloque le départ ; le registre précédent est
restauré si l’écriture des réglages échoue.

Deux drones au maximum peuvent transférer en parallèle, un fichier par drone.
Pause, arrêt local, relance et cache vérifié restent disponibles. Le dossier choisi
persiste ; la collecte ne crée pas une archive supplémentaire. Fermer l’onglet web
GCS évite son propre téléchargement parallèle dans Téléchargements.

Les fichiers retirés localement par iCloud sont détectés avant leur ouverture.
La collecte explique comment télécharger le dossier dans Finder puis relancer,
sans transformer une preuve indisponible en téléchargement supplémentaire.
Les analyses déjà en cache restent conservées si leur ULog est dans le cloud.

## Design et lisibilité

La référence reste le bento monochrome précédent : cartes, contours discrets,
sidebar compacte, touches de couleur pour les signaux, thèmes clair/sombre/système.
Les dix rubriques restent visibles à 900×620. Alertes donne immédiatement accès
aux messages ; le profil reste dépliable. Stockage réunit ses indicateurs et ses
actions ; Rapports sépare composition et aperçu avec son bouton Générer visible.
Événements et Mises à jour reprennent les mêmes cartes et couleurs.

Les aides au survol/clic explicitent sources, temps enregistré, temps en vol,
couverture et badges. Les mêmes distinctions figurent dans les rapports HTML/JSON.
Si une lecture attend un fichier ou un accord macOS, une aide apparaît après
12 secondes avec **Annuler la lecture**. La reprise conserve les analyses ; aucun
délai maximal n’interrompt automatiquement le traitement d’une grande bibliothèque.

## Validation

Les preuves détaillées, captures et données de flotte restent hors Git.

- App Swift : **247 tests réussis**, zéro échec ni skip.
- Moteur Python : **344 réussis sur 345 cas**, zéro échec/erreur/skip inattendu.
  Le seul test absent dépend d’un corpus privé de neuf ULogs, déclaré séparément.
- Rapports JavaScript : **18 réussis**, zéro échec ni skip.
- Total : **609 tests réussis** ; le corpus privé absent n’est pas compté comme réussi.
- Distribution finale : **9 contrôles sur 9 réussis**, dont moteur embarqué sans
  Python externe, signatures strictes, licences, confidentialité du bundle,
  installation depuis le DMG, tickets de notarisation et Gatekeeper.
- ZIP final extrait à nouveau : signature stricte, tickets app/helper et
  Gatekeeper valides ; exécutable identique au package installé.
- Migration sur une copie de la bibliothèque installée : **4 logs / 178 messages**
  conservés ; fichiers d’identités, annotations, réglages et état historique
  inchangés. La bibliothèque active n’est pas utilisée pour cet essai.
- Recette native installée : rapport HTML/JSON généré depuis l’interface,
  redémarrage, thème sombre, sources, destination de collecte et registre conservés.
- Recette radio de cette livraison : un drone, deux logs reconnus en cache,
  **100 % / 2 fichiers vérifiés sur 2** dans l’interface. Contenu SHA256, inode et
  taille des ULogs inchangés ; aucune copie supplémentaire dans la destination.
  L’admission d’un appareil non enregistré a aussi été exercée sur ce drone.
- Cas iCloud réel : deux manifestes non téléchargés détectés immédiatement,
  puis reconnaissance du cache après leur téléchargement normal dans Finder.
- Captures natives synthétiques : 1 et 120 logs, clair/sombre, 900×620 et
  1440×980 ; appareils GCS nouveaux puis enregistrés, avant/après collecte ;
  attente prolongée et reprise après annulation.
- Export Git de 209 fichiers : garde de publication et scanner de secrets sans
  signalement. Le bundle est aussi vérifié : 178 fichiers et 474 contenus
  embarqués inspectés, aucun signalement.

## Paquets vérifiés

App et DMG : notarisation Apple **Accepted** et tickets agrafés.

| Fichier | SHA256 |
|---|---|
| `KataLog-0.6.0-macOS-arm64.dmg` | `4f63e22c74aa4b3ae1b7ffaf7802f14563a227836bb1557c3616ecb077fc169f` |
| `KataLog-0.6.0-macOS-arm64.zip` | `0a0922a6ced4dfc3006f0b2455a34d4c11566f30daf8fab176801cab5af84f7a` |

## Périmètre des preuves

La recette locale porte sur **macOS 27.0.1**. macOS 15 reste le minimum déclaré
et vérifié dans les composants natifs ; une recette physique sur macOS 15 n’est
pas disponible sur ce poste. Les tests GitHub Actions sont volontairement
ignorés tant que le dépôt est privé ; ils ne sont pas comptés comme réussis.

Le banc historique de 50 000 logs / 5 millions de messages / 500 identités est
synthétique : p95 maximal 350,1 ms sur les huit requêtes retenues, RSS 169 Mio.
Il ne représente ni le parsing de 50 000 ULogs ni 500 drones radio simultanés.
La collecte réelle à grande échelle, la recette VoiceOver complète, les autres
navigateurs et le futur flux de mise à jour public restent des qualifications
séparées. Les scénarios simulés ne sont pas présentés comme des essais matériels.

Les événements PX4 exigent le dictionnaire du firmware exact pour être traduits.
Les messages conservés et badges sont des observations, pas un diagnostic matériel.

## Sources et licence

GPL-3.0-only. Le tag `v0.6.0` identifie les sources et scripts de build correspondant
aux binaires. L’archive des sources et les notices des dépendances accompagnent
la release. Aucune bibliothèque, ULog, identité de flotte ni preuve privée n’est
incluse dans le dépôt ou les assets. Voir [les licences](DEPENDENCIES-LICENSES.md).
