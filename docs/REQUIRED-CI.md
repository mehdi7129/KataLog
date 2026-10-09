# Contrôles requis sur main

La configuration versionnée dans [main-branch-protection.json](../.github/main-branch-protection.json)
a été appliquée le 8 octobre 2026 à `mehdi7129/KataLog`, puis relue via l’API GitHub.
Elle impose une PR et les quatre checks GitHub Actions au commit à intégrer,
avec mise à jour par rapport à `main` :

- `tests (macos-15)`
- `tests (macos-26)`
- `Package ARM64 / macos-15`
- `Package ARM64 / xcode-27`

Les checks sont liés à l’application GitHub Actions (`app_id: 15368`). Ils
s’appliquent aussi à l’administrateur ; aucune exception de bypass n’est configurée.
Aucune seconde approbation humaine n’est exigée, pour permettre la maintenance
par une seule personne. Force-push et suppression de `main` sont interdits.

Cette politique utilise l’[API officielle de protection des branches](https://docs.github.com/en/rest/branches/branch-protection).
La présence du fichier dans Git ne change pas à elle seule le réglage distant.
Après toute modification volontaire, vérifier à nouveau le réglage effectif :

```sh
gh api repos/mehdi7129/KataLog/branches/main/protection
```

Vérification observée après application : la PR #9, au commit `577d477`, est
`BLOCKED` avec trois checks verts et le check macOS 26 annulé sans exécution faute
de runner. Elle ne peut donc pas emprunter le chemin normal de fusion sans ce
check. Aucune fusion ni tentative de pousser du code en échec sur `main` n’a
été effectuée pour cette vérification.

Les branches de travail des PR empilées restent libres d’être recalées avec
`--force-with-lease`. Après fusion d’un parent, recaler l’enfant sur `main` et
attendre les quatre checks de son nouveau commit avant son intégration.
