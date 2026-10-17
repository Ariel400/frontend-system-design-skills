---
name: fsd-perf
description: Rendre le premier affichage et les interactions rapides, puis le prouver — frontière "use client" en Next App Router, hydratation sans contournements (mounted, suppressHydrationWarning), code splitting des librairies lourdes (next/dynamic, React.lazy), préchargement des données sur intention (prefetchQuery au survol/focus), analyse du bundle, budget, Web Vitals mesurés en production. Utiliser quand une page charge lentement, quand des pages entières sont "use client", quand une carte/graphique/PDF/animation est importé statiquement, quand on voit des setMounted(true) pour éviter des erreurs d'hydratation, quand un panneau affiche un spinner à l'ouverture, ou quand l'utilisateur dit « performance », « bundle », « lazy loading », « prefetch », « Web Vitals », « LCP/INP/CLS », « fsd-perf ». Source : Frontend System Design Essentials, ch. 14–16, 23 + étude de cas bundlers.
---

# fsd-perf — moins de JS au départ, les données avant le clic, des mesures réelles

Ordre de travail : **mesurer → réduire le JS initial → précharger sur intention → protéger (budget) → observer (Web Vitals)**. Pas d'optimisation sans mesure avant et après.

## 1. Détecter

```bash
X="--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist"
# pages entières côté client (App Router utilisé comme une SPA)
grep -rlE "^['\"]use client['\"]" src/app $X --include='page.tsx' | wc -l; find src/app -name page.tsx | wc -l
grep -rlE "^['\"]use client['\"]" src/app $X --include='layout.tsx'
# contournements d'hydratation
grep -rnE "set(Is)?(Mounted|Hydrated)\(true\)|suppressHydrationWarning" src $X --include='*.tsx'
# librairies lourdes importées statiquement (vérifier si le fichier est lui-même chargé via dynamic)
grep -rnE "from ['\"](maplibre-gl|leaflet|react-leaflet|recharts|react-apexcharts|chart\.js|xlsx|exceljs|jspdf|html2canvas|pdfjs-dist|react-pdf|@react-pdf/renderer|lottie-react|@tiptap/react|quill)['\"]" src $X --include='*.tsx'
grep -rlE "from ['\"]framer-motion['\"]" src $X --include='*.tsx' | wc -l; grep -rl "LazyMotion" src $X | wc -l
# préchargement et mesure
grep -rnE "prefetchQuery|usePrefetch" src $X --include='*.ts*' | wc -l
grep -rnE "useReportWebVitals|web-vitals" src $X --include='*.ts*'
grep -nE "bundle-analyzer|size-limit|visualizer" package.json
```

## 2. Mesurer d'abord

- `ANALYZE=true next build` avec `@next/bundle-analyzer`, ou `vite build` + `rollup-plugin-visualizer`, si ce n'est pas déjà installé. Repérer les 5 plus gros modules et la route la plus lourde (colonne « First Load JS » de `next build`).
- Lighthouse (mode navigation, mobile, Slow 4G) sur 2–3 pages clés : noter LCP, TBT/INP, CLS **avant** de toucher au code.

## 3. Réduire le JS initial

### 3a. Frontière client (Next App Router)
`"use client"` en haut d'un `page.tsx` ou d'un `layout.tsx` envoie tout le sous-arbre au navigateur et perd le rendu serveur (le gain du ch. 14 : contenu visible avant le JS).
- Garder `page.tsx`/`layout.tsx` **serveur**. Y charger les données initiales (`await` côté serveur) et rendre la structure.
- Descendre `"use client"` jusqu'aux **feuilles interactives** : formulaire, filtre, bouton, carte.
- Passer les données du serveur au client en props sérialisables. Avec React Query : `prefetchQuery` côté serveur + `HydrationBoundary`, et le composant client garde son `useQuery`.

### 3b. Hydratation sans contournement
Le serveur et le client doivent rendre le même HTML. `const [mounted, setMounted] = useState(false)` + `if (!mounted) return null` masque le problème en **désactivant le rendu serveur** du composant (écran vide puis saut).
- Valeurs qui diffèrent serveur/client (`Date.now()`, `Math.random()`, locale, fuseau) : les calculer côté serveur et les passer, ou les formater dans un `useEffect`.
- `window`, `localStorage`, `sessionStorage` : les lire dans un `useEffect`, ou dans un composant chargé avec `dynamic(..., { ssr: false })`. Jamais pendant le rendu.
- `suppressHydrationWarning` : seulement sur un nœud texte précis (horodatage), jamais sur un conteneur.

### 3c. Code splitting des librairies lourdes
Carte, graphique, PDF, export Excel, éditeur riche, animation Lottie : chargés **quand on en a besoin**.
```tsx
const SiteMap = dynamic(() => import('./site-map'), { ssr: false, loading: () => <MapSkeleton /> });
```
- Le fallback a la taille du composant final (pas de CLS).
- Une action ponctuelle (export Excel/PDF) : `const XLSX = await import('xlsx')` dans le handler du clic, pas en haut du fichier.
- Rappel du ch. bundlers : le tree shaking s'arrête aux `import()` dynamiques. Un module dynamique arrive **entier**. Garder les modules splittés petits et ciblés.
- framer-motion dans beaucoup de fichiers : `LazyMotion` + `m.div` (charge les features à la demande), ou des transitions CSS pour les effets simples.
- Vues alternatives (onglet liste/carte, modale, drawer) : chargées au premier affichage.

## 4. Précharger sur intention (ch. 16)

Le code est prêt, mais le panneau affiche encore un spinner le temps de la requête. Lancer la requête quand l'utilisateur **montre son intention** :
```tsx
const qc = useQueryClient();
const prefetch = () => qc.prefetchQuery({ queryKey: ['site', id], queryFn: () => sitesApi.get(id), staleTime: 60_000 });
<Link href={`/sites/${id}`} onMouseEnter={prefetch} onFocus={prefetch}>…</Link>
```
- **Même `queryKey`** que le `useQuery` de la destination, sinon le préchargement ne sert à rien.
- `staleTime` > 0, sinon la destination refait la requête.
- Seulement pour des données petites et probables : détail au survol d'une ligne, page suivante d'un tableau, premier onglet d'un drawer. Pas « tout au cas où ».
- `onFocus` en plus d'`onMouseEnter` : le clavier et le tactile n'ont pas de survol.
- Next `<Link>` précharge déjà le **code** de la route. Ici on précharge les **données**.

## 5. Protéger : budget

Une optimisation sans garde-fou régresse au prochain import. Après avoir mesuré (§2), fixer des limites un peu au-dessus de l'état actuel, puis les faire échouer en CI :
- `size-limit` si l'équipe accepte une dépendance de dev, sinon un script Node d'une vingtaine de lignes qui gzippe les chunks de `.next/static/chunks` (ou `dist/assets`) et compare à un JSON de limites (`process.exit(1)` si dépassé).
- Cibles de départ raisonnables : JS initial par route < 200 kB gzip ; LCP < 2,5 s ; INP < 200 ms ; CLS < 0,1.

## 6. Observer : Web Vitals en production

Next :
```tsx
'use client';
import { useReportWebVitals } from 'next/web-vitals';
export function WebVitals() {
  useReportWebVitals((m) => {
    if (process.env.NODE_ENV !== 'production') return console.debug(m.name, Math.round(m.value), m.rating);
    navigator.sendBeacon?.('/api/vitals', JSON.stringify({ name: m.name, value: m.value, rating: m.rating, page: location.pathname }));
  });
  return null;
}
```
Monté une fois dans le layout racine. Vite/SPA : le paquet `web-vitals` (`onLCP`, `onINP`, `onCLS`, `onFCP`, `onTTFB`). Côté réception : une route qui journalise suffit au début, l'outil d'analyse viendra plus tard. Regarder le **75e percentile** par page, pas la moyenne.

## 7. Vérifier

1. Relancer l'analyse du bundle et Lighthouse : comparer aux chiffres du §2 et les noter dans la PR.
2. Network : le chunk de la carte/du graphique ne part qu'à l'affichage du composant. Survoler un lien préchargé, puis cliquer : pas de spinner.
3. Désactiver JavaScript sur une page serveur : le contenu principal s'affiche quand même.

## Exemples types

| Symptôme dans le code | Correction |
|---|---|
| `app/layout.tsx` racine en `"use client"`, donc toutes les pages côté client | layout serveur + `providers.tsx` client pour Redux/Query/toasts |
| `<Head>` de `next/head` dans un layout App Router (sans effet) | `export const metadata` / `export const viewport` dans un layout serveur |
| `viewport` avec `maximum-scale=1, user-scalable=no` | les retirer : ils empêchent le zoom (WCAG 1.4.4) |
| `const [mounted, setMounted] = useState(false)` + `if (!mounted) return null` pour lire `sessionStorage` | lecture dans un `useEffect`, ou composant `dynamic(…, { ssr: false })` limité à la partie concernée |
| `framer-motion` importé dans des dizaines de fichiers et dans un layout | `LazyMotion` + `m.*`, ou CSS pour les effets simples |
| `import * as XLSX from 'xlsx'` en haut d'un fichier pour un bouton « Exporter » | `const XLSX = await import('xlsx')` dans le handler |
| panneau de détail qui affiche un spinner à chaque ouverture | `prefetchQuery` sur `onMouseEnter`/`onFocus`, même `queryKey`, `staleTime` > 0 |
| bon modèle : carte en `dynamic(() => import('./map'), { ssr: false, loading: () => <MapSkeleton /> })` | — |
