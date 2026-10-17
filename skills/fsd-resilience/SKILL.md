---
name: fsd-resilience
description: Empêcher qu'une erreur de rendu React donne un écran blanc — error boundaries par niveau (application, page, widget), error.tsx / global-error.tsx en Next App Router, ErrorBoundary exporté en expo-router, reprise après erreur. Utiliser quand un projet n'a pas de error.tsx, quand une page ou un widget (carte, graphique, contenu tiers) peut planter tout l'écran, quand on veut un bouton « Réessayer » qui marche vraiment, ou quand l'utilisateur dit « error boundary », « écran blanc », « crash », « fsd-resilience ». Source : Frontend System Design Essentials, ch. 21.
---

# fsd-resilience — une panne reste locale

Par défaut, une exception pendant le rendu démonte **tout l'arbre React** : écran blanc.
`try/catch` autour du JSX n'y peut rien, car c'est React qui appelle les composants. Un error boundary isole la panne à la plus petite zone possible.

## 1. Ce que les boundaries attrapent ou pas

| Attrapé | **Pas** attrapé (à gérer autrement) |
|---|---|
| exception pendant le rendu (`user.address.city` sur `undefined`) | handler d'événement (`onClick`) → `try/catch` + toast |
| exception dans un lifecycle / `useEffect` synchrone | code asynchrone (promesse, `setTimeout`) → état d'erreur |
| erreur d'un Server Component (Next) | erreur de requête → état `error` de React Query / RTK Query |
| `useQuery({ throwOnError: true })`, `useSuspenseQuery` | erreur dans le boundary lui-même → boundary parent |

Règle : **erreur de données attendue** (404, réseau) → état d'erreur dans le composant. **Erreur imprévue** (forme de données cassée, bug) → boundary.

## 2. Détecter

```bash
# Next App Router : quels niveaux sont couverts ?
find src -name 'error.tsx' -o -name 'global-error.tsx' -o -name 'not-found.tsx' | grep -v node_modules
find src/app -name 'layout.tsx' | grep -v node_modules     # chaque layout de groupe = candidat error.tsx
# expo-router : un ErrorBoundary exporté ?
grep -rn "export function ErrorBoundary\|export { ErrorBoundary" app src 2>/dev/null
# widgets fragiles (lib tierce, contenu externe) sans protection
grep -rlE "maplibre|leaflet|mapbox|recharts|chart\.js|apexcharts|echarts|react-pdf|dangerouslySetInnerHTML" src --include='*.tsx'
```

## 3. Les trois niveaux

### Niveau 1 — Application (dernier filet)

- **Next** : `src/app/global-error.tsx`. Il remplace le layout racine, donc il doit rendre `<html><body>` et importer `globals.css`. Il n'attrape que ce que rien d'autre n'a attrapé, y compris une erreur **du layout racine**.
- **expo-router** : `export { ErrorBoundary } from 'expo-router'` dans `app/_layout.tsx`, ou un composant maison `ErrorBoundary({ error, retry })`.
- **RN sans router / SPA** : un boundary autour de `<App />`.

### Niveau 2 — Page / section, avec la coquille conservée

- **Next** : un `error.tsx` dans le **groupe de routes** qui porte la navigation, par exemple `app/(admin)/error.tsx`. La sidebar et la topbar restent : l'utilisateur peut aller ailleurs.
- `error.tsx` n'attrape **pas** les erreurs du `layout.tsx` du même dossier, seulement celles de ses enfants. Une erreur de layout remonte au niveau au-dessus.
- C'est un composant client (`"use client"`) qui reçoit `{ error, reset }`.

```tsx
"use client";
export default function PageError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  const router = useRouter();
  const queryReset = useQueryErrorResetBoundary();       // si React Query
  useEffect(() => { reportError(error); }, [error]);
  return (
    <Fallback
      title="Cette page n'a pas pu s'afficher"
      action={<Button onClick={() => startTransition(() => { queryReset.reset(); router.refresh(); reset(); })}>Réessayer</Button>}
    />
  );
}
```

`reset()` seul re-rend le segment avec les **mêmes** données. Si l'erreur vient d'un Server Component, ajouter `router.refresh()`. Si elle vient d'une query, ajouter `queryReset.reset()`. Sinon « Réessayer » replante aussitôt.

### Niveau 3 — Widget

Pour ce qui dépend de données ou de code hors de notre contrôle : carte, graphique, rendu de contenu riche, élément de liste construit à partir de données externes.

```tsx
<WidgetBoundary fallback={<p role="alert">La carte n'a pas pu se charger.</p>} resetKeys={[siteId]}>
  <OpsMap siteId={siteId} />
</WidgetBoundary>
```

- Si `react-error-boundary` est déjà installé, l'utiliser.
- Sinon, une classe d'environ 25 lignes dans `src/components/widget-boundary.tsx` : `getDerivedStateFromError`, `componentDidCatch` → `reportError`, puis `componentDidUpdate` qui se réinitialise quand `resetKeys` change. Pas de dépendance juste pour ça.
- Dans une liste : un boundary **par élément** (`key` sur le boundary), pour qu'un élément cassé n'emporte pas la liste.
- Ne pas envelopper chaque composant : seulement aux frontières de données externes.

## 4. Le fallback

- Même emplacement et à peu près même taille que le contenu (pas de saut de mise en page).
- Dit ce qui a cassé, en langage utilisateur, et propose une sortie : réessayer, ou revenir.
- `role="alert"` au niveau widget, pour que les lecteurs d'écran l'annoncent.
- Ne jamais afficher `error.message` brut en production. Next masque déjà les erreurs serveur derrière un `digest`, à garder pour le support.

## 5. Remonter l'erreur

Une seule fonction `reportError(error, context?)` appelée par tous les boundaries. Aujourd'hui c'est `console.error`. Le jour où un outil de monitoring arrive, c'est le seul endroit à changer. Ne pas installer Sentry ou autre juste pour ce skill.

## 6. Vérifier

1. Dans un composant de la page, temporairement : `if (process.env.NODE_ENV !== 'production') throw new Error('test boundary')`.
2. La coquille (navigation) reste visible, le fallback s'affiche, « Réessayer » fonctionne une fois le `throw` retiré.
3. Même test dans un widget : seul le widget tombe.
4. `next build && next start` : en dev, Next affiche son overlay par-dessus le boundary. Le vrai rendu se voit en production.

## Exemples types

| Situation | Correction |
|---|---|
| aucun `error.tsx` : une erreur de rendu dans une page fait disparaître toute l'interface | `app/(groupe)/error.tsx` au niveau du groupe qui porte la navigation |
| pas de `global-error.tsx` : une erreur du layout racine affiche l'écran par défaut de Next | `app/global-error.tsx` avec `<html><body>` et `globals.css` |
| `global-error.tsx` qui reçoit `error` sans le journaliser | `useEffect(() => reportError(error), [error])` |
| bouton « Réessayer » qui appelle seulement `reset()` et replante aussitôt | `startTransition(() => { queryReset.reset(); router.refresh(); reset(); })` |
| carte, graphique ou rendu de contenu riche utilisé à plusieurs endroits | un boundary **dans** le composant d'enveloppe partagé (ex. `LazyMap`), pas à chaque appel |
| app expo-router sans `ErrorBoundary` exporté | `export { ErrorBoundary } from 'expo-router'` dans `app/_layout.tsx` |
