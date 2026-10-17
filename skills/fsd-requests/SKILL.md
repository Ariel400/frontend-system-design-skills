---
name: fsd-requests
description: Fiabiliser la récupération de données côté front — race conditions, annulation (AbortController / signal), debounce des recherches et filtres, chargement géré à la main dans des useEffect. Utiliser quand un composant fait fetch/axios dans un useEffect avec setLoading, quand une recherche ou un filtre déclenche une requête à chaque frappe, quand des résultats périmés écrasent les récents, quand des queryFn ne transmettent pas le signal, ou quand l'utilisateur dit « race condition », « debounce », « annuler la requête », « fsd-requests ». Source : Frontend System Design Essentials, ch. 1 et 11.
---

# fsd-requests — la requête la plus récente gagne, et il y en a peu

Deux problèmes distincts, deux outils :

| Problème | Symptôme | Outil |
|---|---|---|
| **Correction** | une réponse lente (« ins ») arrive après une rapide (« inst ») et écrase l'écran | annulation / ignorer les réponses périmées |
| **Volume** | une requête par frappe | debounce (saisie) ou throttle (scroll, resize, drag) |

Il faut les deux : le debounce réduit les requêtes mais n'empêche pas une réponse lente d'arriver en retard.

## 1. Détecter

```bash
X="--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist --exclude-dir=build"
# chargement fait main (état serveur dans useState)
grep -rlE "setI?s?Loading\(true\)" src $X --include='*.tsx' | xargs grep -lE "axios|fetch\(|Service\.(get|post)"
# React Query : queryFn qui n'utilise pas le signal
grep -rnE "queryFn:" src $X --include='*.ts*' | grep -v signal
# texte saisi envoyé tel quel dans une requête (vérifier l'absence de debounce dans le hook)
grep -rnE "\b(q|query|search|research)\s*:\s*search\w*" src $X --include='*.ts*'
# hook de debounce déjà présent ? le réutiliser
grep -rlE "export (function|const) useDebounce" src $X
```

## 2. Choisir la correction selon la pile du projet

Regarder `package.json` **avant** d'écrire du code. Ne pas ajouter de librairie si le projet en a déjà une.

### A. Le projet a React Query → l'état serveur passe par `useQuery`

```ts
const debounced = useDebounced(search.trim(), 300);   // réutiliser le hook existant
const list = useQuery({
  queryKey: ['requests', { q: debounced, page, status }],
  queryFn: ({ signal }) => api.get('/requests', { params: { q: debounced, page, status }, signal }),
  placeholderData: keepPreviousData,                  // pas de flash vide entre deux filtres
});
```

- React Query ignore déjà les réponses d'une ancienne clé : la correction est acquise.
- Le `signal` ajoute la **vraie annulation** réseau (bande passante, charge serveur). axios et fetch l'acceptent tous les deux. Le passer jusqu'à la fonction d'API : `list(filters, { signal })`.

### B. Le projet a RTK Query → endpoint `createApi`, pas de `useEffect`

- `fetchBaseQuery` transmet le signal tout seul. Un `axiosBaseQuery` maison doit le relayer : `({ url, params }, { signal }) => axios({ url, params, signal })`.
- Le rafraîchissement manuel ou les événements globaux (`window.dispatchEvent('…:refresh')`) deviennent `invalidateTags` / `refetch()`.
- Le cache maison (`dataLoadedRef`, « déjà chargé ? ») disparaît : c'est le travail du cache RTK.

### C. Pas de librairie, ou un cas isolé → `AbortController` dans l'effet

```ts
useEffect(() => {
  const ctrl = new AbortController();
  setLoading(true);
  api.get(url, { signal: ctrl.signal })
    .then((r) => setData(r.data))
    .catch((e) => { if (!ctrl.signal.aborted) setError(e); })   // couvre AbortError (fetch) et CanceledError (axios)
    .finally(() => { if (!ctrl.signal.aborted) setLoading(false); });
  return () => ctrl.abort();
}, [url]);
```

Tester `ctrl.signal.aborted` plutôt que `e.name === 'AbortError'` : axios lève `CanceledError`, pas `AbortError`.

Au-delà de 2–3 effets de ce genre dans un projet, c'est le signe qu'il lui faut une librairie de requêtes (cas A).

## 3. Règles de debounce

- Debouncer **la valeur envoyée**, jamais la valeur affichée : l'input reste contrôlé et instantané.
- Si le projet n'a pas de hook, en créer un seul (`src/hooks/use-debounced.ts`), pas de dépendance pour ça :
  ```ts
  export function useDebounced<T>(value: T, delay = 300) {
    const [v, setV] = useState(value);
    useEffect(() => { const id = setTimeout(() => setV(value), delay); return () => clearTimeout(id); }, [value, delay]);
    return v;
  }
  ```
- 300 ms pour une recherche, 500–800 ms pour une sauvegarde automatique.
- Un filtre qui change remet la page à 1 (sinon page 4 d'une liste qui n'en a plus qu'une → tableau vide).
- Throttle, pas debounce, pour le scroll, le resize et le drag : on veut des mises à jour régulières pendant le geste, pas une seule à la fin.
- Les clics (avatar, onglet, select) n'ont pas besoin de debounce : personne ne clique assez vite.

## 4. Vérifier

1. DevTools → Network, throttling « Slow 3G », taper vite : une seule requête part après la pause. Les précédentes sont marquées `(canceled)`.
2. Le résultat affiché correspond toujours au dernier texte saisi.
3. Relancer les greps de l'étape 1.

## 5. Pièges

- Ne pas mettre un `isFetchingRef` partout « pour éviter les doublons » : c'est utile pour le *load more* d'une pagination (ch. 12), pas pour une recherche, où l'on veut annuler l'ancienne requête, pas bloquer la nouvelle.
- `useCallback` sur une fonction de fetch mise en dépendance d'un `useEffect` = relance à chaque changement de ses propres dépendances. Si la logique en arrive là, c'est le cas A ou B.
- Un abort n'est pas une erreur : ne jamais l'afficher ni l'envoyer au monitoring.

## Exemples types

| Symptôme dans le code | Correction |
|---|---|
| `params: { q: search }` passé à la requête directement depuis l'`onChange` | `const q = useDebounced(search)` puis `q` dans la clé et les paramètres |
| `useEffect` + `axios.get` + `setLoading` + `setData`, sans annulation, dans un projet qui a déjà une librairie de requêtes | endpoint/query de la librairie existante, signal transmis |
| cache maison `dataLoadedRef.current = true` pour « ne pas recharger » | `staleTime` de la librairie de requêtes |
| `queryFn: () => api.list(filters)` | `queryFn: ({ signal }) => api.list(filters, { signal })` |
| `catch (e) { if (e.name !== 'AbortError') setError(e) }` avec axios | tester `controller.signal.aborted` (axios lève `CanceledError`) |
| événement global `window.dispatchEvent('app:refresh')` pour recharger un écran | `invalidateQueries` / `invalidateTags` |
