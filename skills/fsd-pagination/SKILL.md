---
name: fsd-pagination
description: Choisir et implémenter la pagination selon l'interface — offset (pages numérotées, tableaux d'admin) ou curseur (fil, scroll infini, « charger plus », historique) — côté NestJS et côté client (useInfiniteQuery, RTK Query infiniteQuery, sentinelle IntersectionObserver). Utiliser quand une liste charge tout d'un coup, quand un scroll infini affiche des doublons ou saute des éléments, quand un composant accumule des pages à la main dans un useState, quand on conçoit un endpoint de liste, ou quand l'utilisateur dit « pagination », « infinite scroll », « curseur », « load more », « fsd-pagination ». Source : Frontend System Design Essentials, ch. 4 et 12.
---

# fsd-pagination — la stratégie suit le parcours de l'utilisateur

## 1. Choisir

| UI | Stratégie | Pourquoi |
|---|---|---|
| tableau avec pages « 1 2 3 … », aller à la page N, total affiché | **offset** (`page`, `limit`) | on saute n'importe où ; une page qui bouge un peu est acceptable |
| fil, timeline, notifications, chat, historique, scroll infini, « charger plus », select qui charge au scroll | **curseur** (`after`, `limit`) | reprend exactement après le dernier élément vu, même si des éléments arrivent en tête |

Le défaut de l'offset dans un scroll infini : un élément ajouté en tête pendant que l'utilisateur descend décale tout d'un cran. Le dernier élément de la page 1 revient en tête de la page 2 (doublon, clé React en double). Une suppression fait l'inverse : un élément n'est jamais affiché. Et `OFFSET 10000` oblige la base à parcourir 10 000 lignes.

## 2. Détecter

```bash
X="--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist"
# scroll infini branché sur des numéros de page → candidat curseur
grep -rn -A6 "useInfiniteQuery" src $X --include='*.ts*' | grep -E "nextPage|page \+ 1|pageParam \+ 1"
# accumulation de pages faite main (useState + concat + dédoublonnage = symptôme d'offset en infini)
grep -rnE "setAccumulated|\[\.\.\.prev, \.\.\.(new|data|incoming)" src $X --include='*.ts*'
grep -rnE "existingIds|new Set\(prev\.map" src $X --include='*.ts*'
# listes chargées en entier
grep -rnE "(all|limit)\s*[:=]\s*(true|9999|1000|-1)" src $X --include='*.ts*'
```

## 3. API NestJS

### Offset (tableaux)
Garder l'existant `page`/`limit` → `{ result, totalCount, nextPage }`. Plafonner `limit` côté serveur (ex. 100).

### Curseur (fils)
- Tri **total** : `ORDER BY created_at DESC, id DESC`. Un `created_at` seul ne suffit pas (le livre l'utilise seul) : deux lignes à la même seconde → éléments sautés ou doublés à la frontière.
- Condition de keyset : `WHERE (created_at, id) < (:createdAt, :id)`, avec un index sur `(created_at, id)`.
- Curseur **opaque** : `base64url(JSON.stringify({ c: createdAt, i: id }))`. Le client le renvoie tel quel, il ne le construit jamais.
- Réponse : `{ items, nextCursor: string | null }`. Pas de `totalCount`, qui coûte cher et n'a pas de sens dans un flux.
- Demander `limit + 1` lignes pour savoir s'il y a une suite sans requête de comptage.

## 4. Client

### React Query
```ts
useInfiniteQuery({
  queryKey: ['feed', { type }],
  queryFn: ({ pageParam, signal }) => feedApi.list({ after: pageParam, limit: 20 }, { signal }),
  initialPageParam: null as string | null,
  getNextPageParam: (last) => last.nextCursor ?? undefined,
  select: (d) => uniqueById(d.pages.flatMap((p) => p.items)),   // filet de sécurité tant que l'API est en offset
  maxPages: 10,                                                  // borne la mémoire sur les très longues sessions
});
```

### RTK Query
`build.infiniteQuery` (RTK ≥ 2.6) avec `getNextPageParam`. Pas d'accumulation dans un `useState` à côté du hook : le cache garde les pages, les invalide ensemble et gère le refetch.

### Déclencheur
- Sentinelle `IntersectionObserver` avec `rootMargin` ≈ un écran : la page suivante arrive avant que le bas soit atteint.
- Garde : `if (hasNextPage && !isFetchingNextPage) fetchNextPage()`. Pas besoin d'un `isFetchingRef` maison avec React Query.
- Taille de page ≈ deux écrans (15–30 éléments). Une page de 3 éléments provoque une rafale de requêtes au premier scroll.
- Accessibilité : garder aussi un bouton « Charger plus » focalisable (le scroll infini seul piège les utilisateurs au clavier, et empêche d'atteindre le pied de page). Annoncer « 20 éléments ajoutés » dans une zone `aria-live="polite"`.
- Changement de filtre = nouvelle `queryKey`. Les pages repartent de zéro sans `setAccumulated([])` manuel.

## 5. Vérifier

1. Pendant qu'on scrolle, créer un élément en tête depuis un autre onglet : ni doublon (console sans warning de clé), ni trou.
2. Network : une requête par page, pas de rafale au chargement.
3. Changer un filtre : la liste repart de la page 1, sans éléments de l'ancien filtre.

## Exemples types

| Symptôme dans le code | Correction |
|---|---|
| fil en scroll infini avec `getNextPageParam: (last) => last.pagination.nextPage` (offset) | API à curseur `after`/`nextCursor`. En attendant, `uniqueById` dans `select` |
| `limit = 3` sur un fil | 15–30 éléments, environ deux écrans |
| pages accumulées dans un `useState` avec un filtre `existingIds` | `useInfiniteQuery` / `build.infiniteQuery`, le cache garde les pages |
| paramètre `load_previous_pages` (recharger `page × limit` lignes) côté API | endpoint à curseur pour les écrans « charger plus » |
| curseur `WHERE created_at < :c ORDER BY created_at DESC` | tri total `(created_at, id)` |
| tableau d'administration paginé « 1 2 3 … » en offset | **à garder** : l'offset est adapté |
| bon modèle : sentinelle `IntersectionObserver` avec `rootMargin: "100% 0px"`, callback via ref | — |
