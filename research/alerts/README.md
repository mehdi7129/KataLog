# Explications des messages — recherche du 15 octobre 2026

**Suite v3 :** [précision et lisibilité](CLARITY-20261015.md), préparée après la 0.8.7. Les résultats ci-dessous décrivent la recherche initiale du catalogue v2 livré dans la 0.8.7. Les codes reconnus sans définition y étaient encore comptés comme fiches spécifiques ; la suite v3 les distingue explicitement.

Travail isolé à partir de KataLog 0.8.6 / `main` `6700f82`. L’app installée, la bibliothèque, les ULogs et les réglages ne sont pas modifiés par cette recherche.

## Critères

- Expliquer les textes réellement présents, tous niveaux compris : l’onglet Alertes affiche aussi les messages informatifs.
- Réserver les définitions documentées aux sources primaires identifiées : code PX4 épinglé, protocoles officiels, manuel constructeur précisément référencé.
- Distinguer une définition upstream de la compatibilité avec le firmware constructeur. Le nom d’une branche ou une version affichée ne prouve pas cette compatibilité.
- Fournir sinon une interprétation limitée au texte, puis un contexte de module si le texte demeure inconnu. Ces deux niveaux ne sont pas comptés comme définitions documentées.
- Conserver le texte, le niveau, le classement, les groupes et les occurrences. Une explication n’établit pas une cause de panne ni le nombre d’incidents.

## Données et reproductibilité

- [Inventaire et méthode](corpus/README.md), extrait en SQLite lecture seule et vérifié contre les messages canoniques.
- Le corpus réel, ses fréquences par message, ses valeurs et sa ventilation par firmware restent localement dans `private-data/alerts-research-20261015/`, ignoré par Git. Une copie intégrale des artefacts de recherche initiaux y est conservée.
- `Tests/fixtures/synthetic/alert-catalogue.json` : exemples artificiels des 388 motifs et des fallbacks ; aucun enregistrement de vol ni fréquence réelle.
- `px4/catalogue.json`, `vendor/catalogue.json`, `marine/catalogue.json` : fiches éditables, motifs complets, explications françaises, contrôles, limites et sources.
- `module-contexts.json` : rôle général des modules, sans diagnostic d’un événement inconnu.
- `coverage.json` : couverture mesurée séparément pour les occurrences et les variantes, alertes et tous niveaux, par niveau de preuve. Le contexte de module n’est jamais assimilé à une explication spécifique.

Génération du catalogue compilé dans l’app et le CLI :

```sh
python3 tools/generate-alert-catalogue.py
python3 tools/generate-alert-catalogue.py --check
```

Le fichier Swift généré ne nécessite ni accès réseau ni bundle de ressources supplémentaire à l’exécution. Les liens de sources sont ouverts seulement à l’initiative de l’utilisateur. La recherche et les textes français constituent les entrées éditables ; ne pas modifier manuellement le Swift généré.

## Point de départ

Bibliothèque observée : 298 logs et 12 906 messages. Le catalogue v1 avait quatre fiches couvrant 797 occurrences, soit **6,18 % de tous les messages** et **14,49 % des 5 500 occurrences classées en alerte**. La couverture des variantes était respectivement 4/1 840 et 4/531. Les répétitions ne représentent pas autant d’incidents indépendants.

Les événements binaires PX4, affichés dans leur onglet propre, sont distincts de ces textes ULog. Leur description exacte nécessite un dictionnaire compatible avec le firmware ; aucune traduction d’identifiant par un dictionnaire upstream arbitraire n’est ajoutée ici. La [documentation officielle PX4 v1.14](https://docs.px4.io/v1.14/en/concept/events_interface) explique ce mécanisme et la différence entre niveaux interne et externe.

## Résultat du catalogue v2

| Indicateur | Catalogue v1 | Catalogue v2 |
|---|---:|---:|
| Fiches | 4 | 321 |
| Motifs de messages complets | 4 | 388 |
| Occurrences avec explication spécifique, tous niveaux | 797 / 12 906 (6,18 %) | 12 904 / 12 906 (99,98 %) |
| Occurrences d’alerte avec explication spécifique | 797 / 5 500 (14,49 %) | 5 500 / 5 500 (100 %) |
| Variantes sources d’alerte avec explication spécifique | 4 / 531 | 531 / 531 |

Le catalogue contient **209 fiches documentées et 112 interprétations**. Sur les messages observés, 6 054 occurrences reçoivent une définition documentée et 6 850 une interprétation ; parmi les alertes, ces nombres sont respectivement 2 866 et 2 634. « Couvert » signifie disposer d’une fiche spécifique, dont le niveau de preuve reste visible : cela ne signifie pas que toutes les définitions sont confirmées dans le firmware constructeur exact.

Les deux occurrences restantes sont des nombres nus émis par `dance`, sans nom de mesure ni unité. Elles reçoivent un contexte de module, sans leur inventer une signification physique. Pour les futurs textes inconnus, ce fallback reste disponible ; un module non identifié conserve le texte et les pistes de recherche.

Les sources comprennent **49 fichiers officiels PX4 épinglés et vérifiés par empreinte**, les protocoles officiels MAVLink/NuttX, le manuel IO Star 3 référencé par titre/page/SHA-256 et les documents officiels Torqeedo. Les deux fiches documentées issues du manuel ont reçu une relecture indépendante. [Contre-audit détaillé](review.md).

## Exemples de sens précisé

| Message | Sens retenu et limite principale |
|---|---|
| `GPS emergency yaw reset` | Réalignement de secours du cap estimé ; ne signifie pas à lui seul une perte du fix GPS. |
| `Gyro … clipping` | Saturation de la plage de mesure ; le texte ne suffit pas à identifier une panne de capteur. |
| `Motor failure detected` | Flag du détecteur de défaillance ; une perte de télémétrie ESC peut aussi y contribuer dans la référence PX4. |
| `Crash dumps present on SD` | Présence de fichiers de crash, qui peuvent être historiques ; chaque répétition ne prouve pas un nouveau crash. |
| `… speed violation` | Critère de vitesse dépassé selon le contrôleur de show ; seuil et cause non attestés par le texte seul. |
| `command number 246 is ok 1` | Le numéro MAVLink désigne reboot/shutdown ; le suffixe constructeur n’est pas assimilé à un accusé de réussite. |
| `XBee link recovered` | Récupération de liaison, même si le firmware enregistre cette annonce au niveau WARNING. |
| `Torqeedo: err:50/54` | Code de périphérique conservé ; correspondance précise non établie pour le matériel et la passerelle observés. |

Les références exactes, les vérifications proposées et les limites sont stockées dans chaque fiche JSON et embarquées dans l’app/CLI. Aucun classement de message, niveau, filtre ou groupement n’est changé.

## Vérification de l’intégration

La validation locale initiale a vérifié le moteur Swift sur le corpus complet. Les tests publics vérifient désormais les 388 exemples synthétiques de tous les catalogues, les cas proches/négatifs, les niveaux de confiance, la conservation des messages et les rapports HTML. Le générateur vérifie la cohérence JSON/Swift/fixture ; cette vérification est ajoutée à la CI. Le [gate de corpus privé](corpus/README.md) est un contrôle local facultatif distinct, absent du gate public.

Le [finding du dictionnaire d’événements](corpus/event-memory-limit.md) est corrigé séparément : la marge mémoire du décodeur passe de 64 à 65 MiB. Les limites de taille, les contrôles de hash et les autres rejets restent actifs. Les tests utilisent notamment un dictionnaire synthétique qui reproduit le défaut. Une validation en mémoire, avec le dictionnaire embarqué exact et les arguments existants, a également traduit **17/17 événements réels** du log ciblé, sans erreur ni réimport : [preuve agrégée](event-translation-validation.md).

**Validation locale initiale : 25 tests Swift ciblés et 31 tests Python réussis**, sans échec ni test ignoré. La contre-relecture a rejeté 3 010 variantes négatives et trouvé zéro chevauchement dans le corpus. Les résultats finaux sont consignés dans [validation.json](validation.json).

## Limites connues

Les codes constructeur sans définition primaire restent explicitement non résolus. Par exemple, les codes Torqeedo 50 et 54 sont conservés sans leur appliquer la table d’un autre modèle. La documentation Travel/Ultralight recoupe le sens de « charging temp error » pour 48, sans attester le modèle matériel ni le mapping de la passerelle UAVCAN du log.

Le catalogue v2 a été distribué dans KataLog 0.8.7. Les changements v3 documentés ci-dessus nécessitent une prochaine release ; cette recherche ne remplace pas l’app installée.
