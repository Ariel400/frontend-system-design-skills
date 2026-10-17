# Frontend System Design — Skills pour Claude Code

> 12 skills qui font de [Claude Code](https://claude.com/claude-code) un relecteur d'architecture front : ils **détectent** les problèmes dans votre code, **choisissent** la correction adaptée à votre pile et **vérifient** le résultat.

Requêtes qui se marchent dessus, écrans blancs, listes périmées, règles d'autorisation dupliquées, scroll infini qui affiche des doublons, App Router utilisé comme une SPA, aucun garde-fou d'accessibilité… Ces problèmes ne sont pas des bugs isolés. Ce sont des **décisions de conception** qui manquent. Ces skills les rendent explicites et applicables à n'importe quel projet React / Next.js / React Native, avec une API NestJS ou autre.

Inspirés du livre *[Frontend System Design Essentials](https://leanpub.com/frontend-system-design-essentials)* de Juntao Qiu, puis adaptés aux outils qu'on utilise vraiment : React Query, RTK Query, Next.js App Router, Expo, NestJS.

---

## Les skills

| Skill | Pour… | Chapitres |
|---|---|---|
| [`fsd-audit`](skills/fsd-audit/SKILL.md) | Dresser l'état d'un ou plusieurs projets : un script produit une grille projet × pratique, puis on vérifie et on priorise | tous |
| [`fsd-ccdao`](skills/fsd-ccdao/SKILL.md) | Concevoir une fonctionnalité **avant** de la coder (Collecter, Composants, Données, API, Optimisations) → note de conception. Inclut un mode entretien | 1–5 |
| [`fsd-entitlements`](skills/fsd-entitlements/SKILL.md) | Sortir les règles d'autorisation du front : l'API renvoie des **capacités**, calculées par la même fonction que le 403 | 6–7 |
| [`fsd-normalize`](skills/fsd-normalize/SKILL.md) | Une seule source de vérité par entité : supprimer les copies, propager les mises à jour, normaliser seulement quand c'est utile | 6, 9–10 |
| [`fsd-requests`](skills/fsd-requests/SKILL.md) | Race conditions, annulation (`signal`), debounce, fin des `useEffect` + `setLoading` faits main | 1, 11 |
| [`fsd-pagination`](skills/fsd-pagination/SKILL.md) | Offset ou curseur selon l'interface, API *keyset*, `useInfiniteQuery`, sentinelle | 4, 12 |
| [`fsd-perf`](skills/fsd-perf/SKILL.md) | Frontière `"use client"`, hydratation propre, code splitting, préchargement sur intention, budget, Web Vitals | 14–16, 23 |
| [`fsd-optimistic`](skills/fsd-optimistic/SKILL.md) | **Quand** être optimiste (et quand ne pas l'être), rollback, idempotence | 17 |
| [`fsd-realtime`](skills/fsd-realtime/SKILL.md) | Polling, SSE ou WebSocket. Les événements mettent à jour le cache, avec resynchronisation après coupure | 18–19 |
| [`fsd-http-cache`](skills/fsd-http-cache/SKILL.md) | `Cache-Control` par catégorie de route, ETag/304, `Vary` sans fuite de données | 20 |
| [`fsd-resilience`](skills/fsd-resilience/SKILL.md) | Error boundaries par niveau (application, page, widget), un « Réessayer » qui marche vraiment | 21 |
| [`fsd-a11y`](skills/fsd-a11y/SKILL.md) | Accessibilité comme contrainte du système : action avant geste, focus, `aria-live`, lint + axe | 1, 22 |

---

## Installation

**Pour tous vos projets** (skills personnels) :

```bash
git clone https://github.com/Ariel400/frontend-system-design-skills.git
cp -r frontend-system-design-skills/skills/* ~/.claude/skills/
chmod +x ~/.claude/skills/fsd-audit/audit.sh
```

**Pour un seul projet** (partagés avec l'équipe via le dépôt) :

```bash
mkdir -p .claude/skills && cp -r frontend-system-design-skills/skills/* .claude/skills/
```

Les skills apparaissent au prochain démarrage de Claude Code.

## Utilisation

Appel direct :

```
/fsd-audit mon-projet
/fsd-ccdao un tableau de bord des commandes avec filtres et export
/fsd-requests
```

Claude les déclenche aussi seul quand la situation correspond : « la recherche envoie une requête à chaque frappe », « l'app fait un écran blanc quand l'API change », « la liste ne se met pas à jour après la notification »…

Un audit complet en ligne de commande, sans Claude :

```bash
~/.claude/skills/fsd-audit/audit.sh ./app-web ./app-admin ./api
```

```
| projet  | pile    | req: queryFn sans signal | err: error.tsx / global | perf: pages use client | … |
|---------|---------|--------------------------|-------------------------|------------------------|---|
| app-web | next RQ | 58                       | 0 / 0                   | 13/20                  | … |
```

---

## Comment ils sont construits

Chaque skill suit la même structure, pour qu'on sache toujours où chercher :

1. **Description** : *quand* le déclencher (c'est ce que lit Claude pour choisir).
2. **Détecter** : des `grep` prêts à lancer.
3. **Trier / choisir** : ce qu'on corrige et ce qu'on laisse (tout ne doit pas devenir optimiste, normalisé ou temps réel).
4. **Modèle cible** : le code de référence **selon la pile du projet** (React Query, RTK Query, sans librairie…).
5. **Vérifier** : comment prouver que la correction marche (DevTools, `curl`, test).
6. **Pièges** et **Exemples types** : symptôme → correction.

Trois principes traversent l'ensemble :

- **Partir de l'existant.** On regarde `package.json` avant d'écrire du code, et on n'ajoute pas de dépendance quand le projet a déjà l'outil ou que vingt lignes suffisent.
- **Un signal n'est pas un constat.** Les détections sont des `grep` : on ouvre le fichier avant d'affirmer quoi que ce soit.
- **Décider, pas seulement appliquer.** Chaque skill dit aussi quand **ne pas** utiliser la technique.

## Écarts assumés avec le livre

Le livre est une excellente base. Quelques points ont été corrigés ou complétés :

- **`Vary`** (ch. 20) : `Vary: X-Search-Query` pour un paramètre d'URL est inutile, la query string fait déjà partie de la clé de cache. `Vary` ne concerne que des **en-têtes**.
- **Curseur** (ch. 12) : un curseur sur `created_at` seul saute ou double des éléments à horodatage égal. Il faut trier sur `(created_at, id)`.
- **Annulation** (ch. 11) : axios lève `CanceledError`, pas `AbortError`. Il faut tester `signal.aborted`.
- **Normalisation** (ch. 9) : avec une librairie de requêtes, le cache *est* déjà le store. Le vrai sujet devient l'absence de copies et la propagation, et on ne normalise à la main que pour un graphe édité localement.
- **Optimiste** (ch. 17) : ajout d'une grille de décision. Les workflows refusables, les données financières et les actions irréversibles restent « serveur d'abord ».

## Crédits

- Contenu dérivé de *Frontend System Design Essentials* de **Juntao Qiu** (Leanpub, 2026), un livre à lire en entier. Ce dépôt n'est pas affilié à l'auteur et ne reproduit pas le texte du livre.
- Format : [Skills de Claude Code](https://docs.claude.com/en/docs/claude-code/skills).

## Licence

[MIT](LICENSE) : utilisez, adaptez, partagez. Les contributions (nouveaux « Exemples types », autres piles comme Vue, SWR, Apollo) sont bienvenues.
