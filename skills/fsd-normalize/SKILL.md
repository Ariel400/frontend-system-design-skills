---
name: fsd-normalize
description: Garantir une seule source de vérité par entité côté front — supprimer les copies de données serveur (useState, Zustand, slices Redux, registres de rafraîchissement maison), propager une mise à jour à toutes les vues via des clés de cache hiérarchiques, et normaliser (byId + listes d'ids) seulement là où l'UI édite un graphe d'entités. Utiliser quand une modification n'apparaît pas partout (nom changé dans le profil mais pas dans la liste), quand la même ressource est chargée à plusieurs endroits, quand des données serveur sont stockées dans un store client, quand on conçoit un état de type board/drag-and-drop, ou quand l'utilisateur dit « normalisation », « source de vérité », « données désynchronisées », « fsd-normalize ». Source : Frontend System Design Essentials, ch. 6, 9 et 10.
---

# fsd-normalize — chaque entité existe une fois

Le livre construit un store normalisé à la main (`usersById`, `cardsById`, `columnOrder`) dans un contexte React. Dans une application qui utilise une librairie de requêtes (React Query, RTK Query, SWR, Apollo…), son cache **est** déjà le store. Le vrai problème n'est donc pas « normaliser », mais **ne pas créer de copies** et **propager les changements**. On normalise explicitement seulement dans les cas du §4.

## 1. Les formes que prend la duplication

| Forme | Symptôme | Correction |
|---|---|---|
| données serveur recopiées dans `useState` / Zustand / slice Redux | la copie ne se met plus à jour après une mutation | lire le cache directement, supprimer la copie |
| même endpoint appelé par deux composants hors cache (axios direct) | deux versions de la même liste à l'écran | une seule query partagée (même clé) |
| même entité dans plusieurs clés (liste, détail, autre liste) | modifié dans le détail, ancien dans la liste | invalidation par préfixe ou `setQueriesData` (§3) |
| registre de rafraîchissement maison au-dessus de React Query | logique de cache réécrite, `isRefreshing` qui ne re-rend pas | `invalidateQueries` / `refetchQueries` avec `queryKey` ou `predicate` |
| état local dérivé stocké (`filtered`, `total`) | dérivé désynchronisé de la source | calculer au rendu (`useMemo`, `select`) |

## 2. Détecter

```bash
X="--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist"
# même endpoint appelé à plusieurs endroits (chemins littéraux, appels sur plusieurs lignes compris)
grep -rhoE "[\`'\"]/(api/)?v?[0-9]*/?[a-z][a-zA-Z0-9/_-]{3,}" src $X --include='*.ts*' | tr -d "\`'\"" | sort | uniq -c | sort -rn | awk '$1>1' | head
# données serveur dans un store client (liste + loading/error = état serveur fait main)
grep -rlnE "createSlice|create\(\(set" src $X --include='*.ts*' | xargs grep -lE "setLoading|setError|createAsyncThunk"
# slices enregistrés dans le store mais jamais lus : clé du reducer sans `state.<clé>` ailleurs
grep -rhoE "^\s+(\w+): \w+Reducer" src $X --include='store.ts' | awk -F: '{gsub(/ /,"",$1); print $1}' | sort -u |
  while read k; do echo "$k $(grep -rE "state\.$k\b" src $X --include='*.ts*' | grep -vc '/slices/')"; done | awk '$2==0'
# copie de la réponse dans un état local
grep -rn -A2 "useEffect(() => {" src $X --include='*.tsx' | grep -E "set[A-Z]\w+\((data|response|result)\b"
```

## 3. Propager une mise à jour (cas le plus courant)

**Clés hiérarchiques**, l'entité en premier :
```ts
['missions']                          // tout ce qui concerne les missions
['missions', 'list', { status, page }]
['missions', 'detail', id]
['missions', 'stats']
```

Après une mutation :
- **Par défaut** : `invalidateQueries({ queryKey: ['missions'] })`, qui revalide toutes les vues de l'entité. Simple et toujours juste.
- **Si on a l'objet à jour et qu'on veut éviter un aller-retour** : écrire dans le détail, et patcher les listes par id :
  ```ts
  qc.setQueryData(['missions', 'detail', m.id], m);
  qc.setQueriesData<Page<Mission>>({ queryKey: ['missions', 'list'] }, (p) =>
    p && { ...p, result: p.result.map((x) => (x.id === m.id ? m : x)) });
  ```
- **Entité imbriquée ailleurs** (l'utilisateur connecté apparaît dans la session, le profil, une liste d'équipe) : lister explicitement les clés qui la contiennent, ou faire renvoyer par l'API un id plutôt qu'une copie (`assigneeId`) et résoudre au rendu.

En RTK Query : `providesTags: [{ type: 'Mission', id }]` sur détail et listes, `invalidatesTags: [{ type: 'Mission', id }]` sur la mutation.

## 4. Quand normaliser vraiment (byId + ids)

Seulement si l'**UI possède et édite** un graphe d'entités en local, avec des mises à jour fréquentes et partielles :
- board / kanban / drag-and-drop : `cardsById`, `columnsById`, `columnOrder`, `column.cardIds`. Déplacer une carte = modifier deux tableaux d'ids, sans réécrire l'arbre.
- éditeur riche, formulaire multi-étapes avec sous-entités, application hors-ligne.
- flux temps réel qui patche beaucoup d'entités (fil avec compteurs, chat).

Outils : `createEntityAdapter` si le projet a Redux Toolkit, sinon une fonction `normalize(payload)` pure à l'entrée et une jointure au rendu (`column.cardIds.map((id) => cardsById[id])`). Hors-ligne mobile : la base locale (SQLite/drizzle) **est** le store normalisé, et les écrans lisent par requête.

Ne pas normaliser une liste en lecture seule « par principe » : c'est de la complexité sans bénéfice.

## 5. Vérifier

1. Modifier une entité depuis l'écran A, puis aller sur toutes les vues qui l'affichent : la nouvelle valeur est partout, sans rechargement.
2. Network : un endpoint n'est appelé qu'une fois quand deux composants l'affichent en même temps (dédoublonnage par clé).
3. Les greps du §2 ne trouvent plus de copie ni de store mort.

## Exemples types

| Symptôme dans le code | Correction |
|---|---|
| une modale rappelle en `axios.get` un endpoint qui existe déjà comme query dans le projet | réutiliser la query existante (même clé = même donnée, un seul appel) |
| la même liste chargée par la page et par un composant enfant, chacun dans son `useState` | une query partagée, l'enfant lit la même clé |
| slice Redux `items + loading + error` enregistré dans le store mais jamais lu | supprimer |
| registre maison `registerRefresh(id, fn)` / `refreshByPattern(regex)` au-dessus de React Query | `invalidateQueries({ queryKey })` / `{ predicate }`, `useIsFetching` |
| `setInterval(() => setData(JSON.parse(localStorage.getItem(k))), 500)` pour partager un état entre composants | source unique (contexte, store ou cache), plus l'événement `storage` pour le multi-onglet. L'intervalle crée un nouvel objet et re-rend en continu |
| profil mis à jour : `setQueryData(['me'], u)` mais l'utilisateur reste ancien dans `['team']` | lister toutes les clés qui contiennent l'entité, ou invalider par préfixe |
| bon modèle : app hors-ligne dont la base locale (SQLite) est le store normalisé | — |
