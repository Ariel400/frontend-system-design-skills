---
name: fsd-a11y
description: Faire de l'accessibilité une contrainte du système plutôt qu'une passe de finition — sémantique HTML, action modélisée indépendamment du geste (glisser-déposer, survol, swipe) avec une alternative clavier, focus géré après les changements d'état, changements annoncés via aria-live, et garde-fous automatiques en couches (lint jsx-a11y strict, axe dans Playwright ou les tests unitaires, passe clavier/lecteur d'écran manuelle). Utiliser quand on ajoute une interaction (drag-and-drop, menu, modale, suppression, liste dynamique), quand un projet n'a aucun contrôle d'accessibilité automatisé, quand des div cliquables ou des boutons sans libellé apparaissent, ou quand l'utilisateur dit « accessibilité », « a11y », « WCAG », « clavier », « lecteur d'écran », « fsd-a11y ». Pour un audit visuel/UX d'une interface, voir aussi le skill impeccable. Source : Frontend System Design Essentials, ch. 1 et 22.
---

# fsd-a11y — l'accessibilité est un problème de modélisation

La plupart des défauts d'accessibilité ne viennent pas d'un attribut oublié. Ils viennent d'une interaction qui n'existe que sous forme de geste, d'un composant sans rôle, ou d'un changement d'état visible mais jamais annoncé. On corrige le modèle, puis on fait respecter les règles par l'outillage plutôt que par la mémoire.

## 1. Détecter

```bash
X="--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist"
# éléments non sémantiques rendus cliquables
grep -rnE "<(div|span|li|td|img)[^>]*onClick=" src $X --include='*.tsx' | grep -v 'role='
# boutons icône sans nom accessible (vérifier à la main les résultats sur plusieurs lignes)
grep -rnE "<button[^>]*>\s*<\w+Icon|<button[^>]*>\s*<svg" src $X --include='*.tsx' | grep -v 'aria-label'
# interactions qui n'existent qu'en geste
grep -rlE "onDrag|useDraggable|useSortable|draggable=|onMouseEnter=.*(open|show)|onSwipe" src $X --include='*.tsx'
# annonces et focus
grep -rlE "aria-live|role=\"(status|alert)\"" src $X --include='*.tsx' | wc -l
grep -rnE "outline-none|outline: ?none" src $X --include='*.tsx' --include='*.css' | grep -v "focus-visible" | head
# outillage
grep -E "jsx-a11y|core-web-vitals" eslint.config.* .eslintrc* 2>/dev/null
grep -oE "\"(jest-axe|vitest-axe|@axe-core/playwright|@playwright/test|vitest|@testing-library/react)\"" package.json
```

## 2. Principes de conception

**Sémantique d'abord.** `<button>` pour une action, `<a href>` pour une navigation, `<h1>…<h3>` pour la structure, `<nav>`, `<main>`, `<section aria-labelledby>`, `<article>` pour un élément de liste autonome (carte, publication). Un `<div onClick>` n'a ni focus, ni activation au clavier, ni rôle annoncé. Le remplacer par un `<button type="button">` résout les trois.
- Composants headless (Radix, Ariakit, React Aria) pour les menus, combobox, dialog, tabs, popover : ils gèrent rôles, clavier et focus. Ne pas réécrire un combobox à la main.

**L'action avant le geste (amélioration progressive).** Modéliser l'intention comme une fonction (`moveCard(id, toColumn, index)`, `deleteItem(id)`, `openDetails(id)`), puis l'exposer par plusieurs chemins :
- glisser-déposer pour la souris **et** un menu « Déplacer vers… » avec de vrais boutons (ou les capteurs clavier de dnd-kit) ;
- contenu révélé au survol **et** au focus (`:hover, :focus-within`) ;
- swipe mobile **et** un bouton visible.

La logique n'est écrite qu'une fois, et chaque interaction ne fait que l'appeler.

**Le clavier comme interaction de premier rang.** Tab pour passer d'un contrôle à l'autre. Flèches à l'intérieur d'un composant composite (liste, menu, grille). Entrée/Espace pour activer, Échap pour sortir. Ordre de tabulation = ordre visuel. Focus toujours visible (`focus-visible:ring-…`, jamais `outline-none` seul).

**Le focus suit l'état.**
- Ouverture d'une modale : focus sur le premier champ ou le titre. Fermeture : retour à l'élément déclencheur.
- Suppression d'un élément : focus sur l'élément suivant (ou précédent, ou le titre de la liste si elle est vide), sinon le focus tombe sur `<body>`.
- Changement de route (SPA) : focus sur le `<h1>` de la nouvelle page.

**Ce qui change visiblement est annoncé.** Une seule région par zone, montée dès le départ (une région créée en même temps que son contenu n'est pas lue) :
```tsx
<div role="status" aria-live="polite" aria-atomic="true" className="sr-only">{announcement}</div>
```
Annoncer : « Carte déplacée vers En cours », « 20 résultats », « 12 éléments ajoutés », « Enregistré ». `role="alert"` (assertif) seulement pour les erreurs.

**Formulaires.** Chaque champ a un `<label>` associé. Les erreurs sont liées par `aria-describedby` et `aria-invalid`. À la soumission en erreur : focus sur le premier champ invalide.

## 3. Garde-fous en couches (du moins cher au plus complet)

| Couche | Rôle | Mise en place |
|---|---|---|
| **1. Lint** | bloque les erreurs courantes avant l'exécution | `eslint-plugin-jsx-a11y`, config **`recommended`** ou `strict`. `next/core-web-vitals` n'en active qu'une poignée de règles, en avertissement. |
| **2. axe automatisé** | vérifie le rendu réel (contraste, rôles, libellés, ARIA invalide) | **Playwright déjà présent** → `@axe-core/playwright` sur les pages clés et dans leurs états ouverts (modale, menu). **Vitest + Testing Library présents** → `vitest-axe`/`jest-axe` sur les composants partagés. **Aucun test** → commencer par Playwright sur 3–5 parcours plutôt que monter une infra de tests unitaires juste pour axe. |
| **3. Lighthouse / DevTools** | retour rapide pendant le dev | contrôle de cohérence, pas une preuve |
| **4. Manuel** | ce qu'aucun outil ne voit : ordre du focus, annonces compréhensibles, parcours complets | clavier seul + VoiceOver/NVDA, après chaque nouvelle interaction ou refonte d'un parcours |

Test axe Playwright type :
```ts
test('dashboard sans violation WCAG A/AA', async ({ page }) => {
  await page.goto('/');
  const r = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(r.violations).toEqual([]);
});
```
Scanner aussi après avoir **ouvert** les états interactifs (modale, menu, drawer) : axe ne voit que ce qui est dans le DOM.

**Mobile (React Native / Expo)** : `accessibilityRole`, `accessibilityLabel`, `accessibilityState` sur les `Pressable`, `accessibilityLiveRegion` (Android) / `AccessibilityInfo.announceForAccessibility`, cibles tactiles ≥ 44 pt. Lint : `eslint-plugin-react-native-a11y`.

## 4. Vérifier

1. Débrancher la souris : tout le parcours principal se fait au clavier, avec le focus toujours visible.
2. Lecteur d'écran : les actions, les changements (déplacement, ajout, suppression) et les erreurs sont annoncés.
3. Le lint et le test axe échouent si on réintroduit un `<div onClick>` ou un bouton sans libellé (le vérifier une fois en le faisant exprès).

## Exemples types

| Symptôme dans le code | Correction |
|---|---|
| `<div onClick={toggle} className="cursor-pointer">` qui ouvre un menu | `<button type="button" aria-expanded aria-haspopup="menu">`, ou un DropdownMenu headless |
| `<button><TrashIcon /></button>` | `aria-label="Supprimer <nom de l'élément>"` |
| glisser-déposer seul pour déplacer une carte | menu « Déplacer vers… » qui appelle la même fonction `moveCard`, ou les capteurs clavier de la librairie |
| suppression d'un élément de liste : le focus tombe sur `<body>` | focus sur l'élément suivant, ou sur le titre de la liste |
| `className="outline-none"` sur des éléments focusables | `focus-visible:ring-2 …` |
| ESLint limité à `next/core-web-vitals` | `plugin:jsx-a11y/recommended` |
| Playwright présent mais aucun test axe | `@axe-core/playwright` dans les specs des parcours clés |
| fond de modale `<div onClick={onClose}>` alors que la modale a `role="dialog"`, `aria-modal` et Échap | **acceptable** : le clic sur le fond est un raccourci en plus |
