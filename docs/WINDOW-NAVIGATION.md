# Navigation par fenêtre

`LibraryStore` reste l'unique propriétaire du writer lease, des imports, des
clients, de la maintenance, des préférences partagées et du raccordement GCS.
Créer une fenêtre n'instancie pas une deuxième bibliothèque.

Chaque `Workspace06View` possède un `LibraryNavigationStore` : pages lues,
curseurs confirmés, résultats courants, tri temporaire de la vue d'ensemble,
cache de huit requêtes, erreurs et annulation. Le filtre de bibliothèque et le
tri enregistré restent partagés comme auparavant. Le filtre possède également
sa propre session transitoire pour son catalogue et son registre de drones.

La façade de lecture de `LibraryStore` délègue à une session par défaut pour le
shell historique et les appelants existants. Seule cette session alimente son
snapshot de compatibilité ; les fenêtres modernes lisent leur propre snapshot.

Les sessions sont enregistrées faiblement dans la bibliothèque. Leur activité
est agrégée pour les mutations et la fermeture de l'app ; une annulation ou la
fermeture d'une fenêtre conserve cette activité jusqu'à l'arrêt réel du helper.
Une fenêtre peut continuer à lire pendant qu'une autre attend sa page.

La préparation initiale de l'index est une seule opération partagée. Un lecteur
annulé ne l'interrompt pas si un autre lecteur l'attend encore ; l'annulation du
dernier lecteur l'arrête. La préparation facultative des trajectoires pour une
carte ne prend le writer que si aucune autre session ne lit.

Après une mutation ou un changement de filtre partagé, les caches sont invalidés
et les sessions ouvertes rechargent leur historique à la première page. Chaque
fenêtre conserve son onglet et son tri temporaire. Aucun format persistant,
schéma SQLite ou protocole de requête ne change.

Les tests utilisent des bibliothèques synthétiques, deux `NSWindow` réelles et
des helpers pouvant ignorer SIGTERM. Ils contrôlent pages, tri, curseurs,
annulation indépendante, libération du processus, maintenance et invalidation.
Les captures sont produites par AppKit avec `KATALOG_UI_ARTIFACTS` ; elles ne
constituent pas une qualification de clics Accessibility ni d'un GCS réel.
