---
name: fsd-ccdao
description: Concevoir une fonctionnalité front avant de la coder, en cinq étapes CCDAO — Collecter l'information (vocabulaire du domaine, règles, contraintes), Composants (découpage, propriétaire de l'état), Données (modèle, normalisation, pagination), API (contrat orienté intention), Optimisations (perf, résilience, accessibilité, temps réel) — et produire une note de conception courte qui renvoie vers les skills fsd-* pour l'implémentation. Utiliser avant de démarrer une fonctionnalité non triviale (liste, fil, tableau de bord, recherche, formulaire multi-étapes, board, carte), pour relire une PR d'architecture, ou pour préparer un entretien de system design front ; ou quand l'utilisateur dit « conçois », « design », « CCDAO », « system design », « fsd-ccdao ». Source : Frontend System Design Essentials, ch. 1–5.
---

# fsd-ccdao — la forme avant les détails

Un ticket « simple » (« un dropdown pour assigner un utilisateur ») cache presque toujours du chargement, des erreurs, du volume, de la recherche, des race conditions, de l'accessibilité, de l'i18n et des effets sur d'autres écrans. CCDAO force à les voir **avant** d'écrire du code, en une demi-heure, pas en une semaine.

## Déroulé

Lire d'abord le code existant autour de la fonctionnalité (écrans voisins, hooks d'API, types, conventions du projet), puis répondre à chaque étape. Si une question bloque la conception et que ni le code ni le ticket n'y répondent, la poser à l'utilisateur. Sinon, prendre l'hypothèse raisonnable et l'écrire comme telle.

### 1. Collecter l'information
- **Parcours minimal** (« steel thread ») : la plus petite suite d'actions qui apporte la valeur, de bout en bout.
- **Vocabulaire du domaine** : relever les mots exacts du métier (« commande », « facture », « abonnement », « intervention ») et les réutiliser tels quels dans les noms de composants, de types et d'endpoints.
- **Règles métier et qui les possède** : qui peut faire quoi, dans quel état. Toute règle d'autorisation vit dans l'API (→ `fsd-entitlements`).
- **Contraintes** : volume (10, 1 000, 100 000 éléments ?), fréquence de changement des données, multi-utilisateur simultané, temps réel attendu, hors-ligne, mobile / réseau lent, langues, accessibilité, SEO.

### 2. Composants
- Esquisser l'arbre : conteneur (orchestration, chargement, erreurs) → sections → éléments → contrôles.
- **Propriétaire de chaque état** : état serveur (cache de requêtes) / état d'URL (filtres, page, onglet → `searchParams`) / état local d'UI (ouvert/fermé) / état global client (rare : session, préférences).
- **Transitions** autant que les états : quand ça s'ouvre, se ferme, se recharge ; que se passe-t-il si une réponse arrive après fermeture ?
- Frontière serveur/client (Next) : quels morceaux sont interactifs (→ `fsd-perf` §3a).
- Où placer les error boundaries : page, widget (→ `fsd-resilience`).

### 3. Données
- Entités et relations (diagramme en 3 lignes suffit). Quels écrans affichent la même entité ?
- Forme côté client : cache par requête suffit-il, ou l'UI édite-t-elle un graphe (→ `fsd-normalize` §4) ?
- Volume → pagination et stratégie (→ `fsd-pagination`).
- Ce qui est dérivé (calculé au rendu) vs stocké.

### 4. API
- Liste des endpoints avec forme de requête et de réponse (exemple JSON court).
- **Mutations orientées intention** : `POST /cards/:id/move { toColumnId, index }`, pas « renvoyer tout le board ».
- La réponse sert l'UI : capacités/permissions incluses (→ `fsd-entitlements`), pas de champ calculé à refaire côté front.
- Pagination (`after`/`limit` ou `page`/`limit`), filtres, tri.
- Temps réel : polling, SSE ou WebSocket, et événements émis (→ `fsd-realtime`).
- Cache HTTP par route (→ `fsd-http-cache`). Idempotence des écritures rejouables (→ `fsd-optimistic` §5).

### 5. Optimisations (seulement celles que les contraintes justifient)
- Requêtes : debounce, annulation, `keepPreviousData` (→ `fsd-requests`).
- Mutations : optimiste ou serveur d'abord (→ `fsd-optimistic` §1).
- Rendu : virtualisation au-delà de ~200 éléments visibles, lazy loading des parties lourdes, préchargement sur intention (→ `fsd-perf`).
- Résilience : états vide / chargement / erreur / partiel, réessai.
- Accessibilité : clavier, focus, annonces, alternative aux gestes (→ `fsd-a11y`).

## Livrable : note de conception

Écrire la note dans `docs/design/<fonctionnalite>.md` si le projet a un dossier `docs/`, sinon la donner dans la réponse. Une à deux pages, pas plus :

```markdown
# <Fonctionnalité>
## Parcours minimal
## Vocabulaire et règles (qui possède quoi)
## Hypothèses (à valider)
## Composants (arbre + propriétaire de chaque état)
## Données (entités, forme côté client, pagination)
## API (endpoints, exemples, temps réel, cache)
## Optimisations retenues — et écartées (avec la raison)
## Risques / questions ouvertes
## Plan de livraison (tranches verticales, chacune utilisable)
```

« Écartées, avec la raison » compte autant que « retenues » : ne pas virtualiser une liste de 30 éléments est une décision, pas un oubli.

## Mode entretien (45 min)

Même ordre, à voix haute : ~5 min pour clarifier (poser les questions de l'étape 1, annoncer ses hypothèses), ~10 min composants + données, ~10 min API, ~15 min optimisations et compromis, le reste pour les questions. Un bon déroulé ressemble à une conversation guidée par le cadre, pas à une liste récitée. Exercices classiques : typeahead, fil d'actualité, board kanban, chat, notifications, carte avec filtres.

## Exemple appliqué (abrégé) : fil d'actualités d'un intranet

1. **Collecter** : contenus de plusieurs types (actualité, magazine, alerte, revue de presse), lecture + réactions, publications pendant la lecture, volume illimité dans le temps, mobile fréquent.
2. **Composants** : `NewsFeed` (orchestration, sentinelle de fin) → `FeedItem` par type → `Reactions`. Filtre de type dans l'URL. Boundary par `FeedItem` (contenu riche venu d'un CMS).
3. **Données** : `useInfiniteQuery`, éléments identifiés par id. Une publication peut apparaître dans le fil et dans sa rubrique.
4. **API** : `GET /feed?type=&after=&limit=20` → `{ items, nextCursor }` (curseur, pas numéro de page). `POST /posts/:id/reactions` idempotent.
5. **Optimisations retenues** : préchargement du détail au survol, réactions optimistes avec rollback, bandeau `aria-live` « N nouvelles publications » plutôt qu'une insertion qui fait sauter la lecture. **Écartées** : virtualisation (moins de 200 éléments visibles en pratique), WebSocket (un polling de 60 s suffit pour un intranet).
