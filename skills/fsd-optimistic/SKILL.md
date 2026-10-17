---
name: fsd-optimistic
description: Décider quand une mutation doit mettre à jour l'UI avant la réponse du serveur, et l'implémenter correctement — onMutate/rollback en React Query, onQueryStarted/patch.undo en RTK Query, id temporaire à la création, idempotence des mises à jour d'état et des requêtes rejouées. Utiliser quand une action simple (cocher, marquer lu, publier, archiver, renommer, réordonner) fait attendre l'utilisateur, quand un élément apparaît en double après une création, quand une file d'envoi hors-ligne rejoue des requêtes, ou quand l'utilisateur dit « optimistic update », « rollback », « idempotent », « fsd-optimistic ». Source : Frontend System Design Essentials, ch. 17 + étude de cas WebSockets.
---

# fsd-optimistic — afficher tout de suite, savoir revenir en arrière

Une mise à jour optimiste inverse l'ordre : l'UI change d'abord, la requête part ensuite, et on revient en arrière si elle échoue. C'est un pari. Il ne se prend que là où il est presque toujours gagné et peu coûteux à perdre.

## 1. Trier : optimiste ou serveur d'abord ?

| Optimiste ✅ | Serveur d'abord ⛔ |
|---|---|
| échoue rarement (pas de validation métier côté serveur) | transition de workflow que l'API peut refuser (403, 400) |
| résultat prévisible côté client | résultat calculé par le serveur (numéro, montant, statut dérivé) |
| réversible, peu d'enjeu | financier, juridique, irréversible, envoie un e-mail/SMS |
| fréquent, l'attente se remarque | rare, l'utilisateur accepte d'attendre et veut une confirmation |
| ex. marquer lu, favori, publier/dépublier, renommer, réordonner, cocher | ex. valider un dossier, payer, supprimer un chèque, changer un rôle |

En cas de doute : serveur d'abord, avec un état `isPending` sur le bouton. Pour une suppression peu grave, une variante souvent meilleure que l'optimiste pur : retirer l'élément avec un toast « Annuler » pendant 5 s, et n'envoyer la requête qu'à l'expiration.

## 2. Détecter

```bash
X="--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist"
# mutations simples qui attendent le serveur puis rechargent tout
grep -rnE "useMutation\(\{ ?mutationFn: \w+, onSuccess: \w+ ?\}\)" src $X --include='*.ts*'
grep -rniE "mutationFn:.*(publi|toggle|favori|markAs|read|archive|rename|order|pin)" src $X --include='*.ts*'
# faux optimiste : onMutate qui ne touche pas au cache
grep -rn -A3 "onMutate" src $X --include='*.ts*' | grep -E "setLoading|setError"
# optimiste réel déjà présent (modèle à réutiliser)
grep -rlnE "cancelQueries|updateQueryData|patch\.undo" src $X --include='*.ts*'
```

## 3. React Query

```ts
const qc = useQueryClient();
useMutation({
  mutationFn: (p: { id: string; published: boolean }) => photosApi.setPublished(p.id, p.published),
  onMutate: async ({ id, published }) => {
    await qc.cancelQueries({ queryKey: ['photos'] });          // sinon un refetch en vol écrase l'optimiste
    const previous = qc.getQueriesData<Photo[]>({ queryKey: ['photos'] });
    qc.setQueriesData<Photo[]>({ queryKey: ['photos'] }, (list) =>
      list?.map((p) => (p.id === id ? { ...p, published } : p)));
    return { previous };
  },
  onError: (_e, _v, ctx) => {
    ctx?.previous.forEach(([key, data]) => qc.setQueryData(key, data));   // rollback
    toast.error("La photo n'a pas pu être publiée.");
  },
  onSettled: () => qc.invalidateQueries({ queryKey: ['photos'] }),        // revalider dans tous les cas
});
```

- `getQueriesData` / `setQueriesData` (au pluriel) : la même entité vit souvent dans plusieurs caches (liste paginée, filtres, détail). Les mettre tous à jour, sinon l'UI se contredit.
- **Création** : insérer avec un id temporaire (`temp-${crypto.randomUUID()}`), puis remplacer par l'élément du serveur dans `onSuccess`. Désactiver les actions sur un élément `temp-` tant qu'il n'est pas confirmé.
- Variante légère sans toucher au cache : `useMutation().variables` + `isPending` pour afficher l'élément en attente directement dans le rendu. Pratique quand un seul composant affiche la donnée.

## 4. RTK Query

```ts
async onQueryStarted(id, { dispatch, queryFulfilled }) {
  const patch = dispatch(api.util.updateQueryData('getNotifications', undefined, (draft) => {
    const n = draft.items.find((x) => x.id === id); if (n) n.read = true;
  }));
  try { await queryFulfilled; } catch { patch.undo(); toast.error('…'); }
},
invalidatesTags: ['UnreadCount'],
```

## 5. Idempotence — le même événement arrive deux fois

Une même création peut arriver par trois chemins : l'insertion optimiste, la réponse du serveur, et l'écho temps réel (WebSocket/SSE, l'émetteur reçoit aussi sa propre diffusion). Plus les rejeux d'une file hors-ligne.

- **État** : chaque écriture dans le cache est idempotente. On insère seulement si l'id est absent, on remplace par id, jamais de `push` aveugle :
  ```ts
  (list) => (list?.some((x) => x.id === item.id) ? list.map((x) => (x.id === item.id ? item : x)) : [...(list ?? []), item])
  ```
- **Requête** : un envoi rejoué ne doit pas créer de doublon côté serveur. Soit l'id est généré par le client et l'API fait `PUT /ressource/:id` en upsert, soit un en-tête `Idempotency-Key` sur le `POST`.

## 6. Pièges

- Oublier `cancelQueries` : un refetch lancé juste avant revient avec l'ancien état et efface le changement optimiste.
- Deux mutations rapides sur le même élément : le rollback de la première restaure un instantané qui écrase la seconde. `onSettled → invalidateQueries` remet tout d'aplomb. Si c'est fréquent (bouton cliqué en rafale), sérialiser avec `scope: { id: 'photo-' + id }` (React Query v5).
- Un toast de succès avant la réponse du serveur ment. Optimiste = pas de toast de succès, seulement un toast d'échec.
- L'échec doit être visible et compréhensible (toast, `role="alert"`), sinon l'élément « disparaît » sans explication.

## 7. Vérifier

1. DevTools → Network → bloquer l'URL de la mutation (« Block request URL ») : l'UI change, puis revient en arrière avec un message.
2. Throttling « Slow 3G » : le changement est instantané, la requête part ensuite.
3. Cliquer cinq fois vite sur un toggle : l'état final correspond au serveur après `onSettled`.

## Exemples types

| Situation | Décision |
|---|---|
| publier / dépublier / archiver un élément avec `onSuccess: () => refetch()` | **optimiste** : `onMutate` + rollback + `onSettled` invalidation |
| marquer une notification comme lue | **optimiste** (RTK : `updateQueryData` + `patch.undo()`) |
| valider un dossier dans un workflow que l'API peut refuser, avec commentaire | **serveur d'abord**, bouton en `isPending` |
| supprimer une écriture financière | **serveur d'abord**, avec confirmation |
| `onMutate: () => setLoading(true)` | ce n'est pas de l'optimiste : utiliser `isPending` |
| file d'envoi hors-ligne qui rejoue des `POST` après un timeout | id généré par le client + `PUT /ressource/:id` en upsert, ou `Idempotency-Key` |
| élément ajouté deux fois après une création (réponse + écho WebSocket) | écriture du cache idempotente (insérer seulement si l'id est absent) |
