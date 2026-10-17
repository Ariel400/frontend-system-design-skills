---
name: fsd-audit
description: Dresser l'état d'un ou plusieurs projets front (et de leur API NestJS) au regard des pratiques « Frontend System Design » — une grille projet × pratique (requêtes, error boundaries, frontière client/hydratation, Web Vitals, accessibilité, temps réel, pagination, règles d'autorisation dans l'UI, cache HTTP) produite par un script, puis une liste priorisée de chantiers vérifiés, chacun renvoyant vers le skill fsd-* qui le traite. Utiliser quand l'utilisateur demande un audit, un état des lieux, « où appliquer les bonnes pratiques », « par quoi commencer » sur un ou plusieurs projets, ou dit « fsd-audit ». Source : Frontend System Design Essentials (tout le livre).
---

# fsd-audit — signaux automatiques, conclusions vérifiées

## 1. Lancer la grille

```bash
~/.claude/skills/fsd-audit/audit.sh <projet> [<projet> ...]
# sans argument : chaque sous-dossier du répertoire courant qui contient un package.json
```
Environ 1–2 s par projet. Le script sort un tableau Markdown. Monorepos (apps/*, packages/*) et API NestJS sont pris en charge : pour une API, seule la colonne cache est remplie.

## 2. Lire les colonnes

| Colonne | Signal | Lecture | Skill |
|---|---|---|---|
| `req: queryFn sans signal` | `queryFn` React Query qui ne passe pas `signal` | requêtes jamais annulées réseau (`n/a` pour RTK Query, qui le fait seul) | `fsd-requests` |
| `err: error.tsx / global` | segments couverts / boundary racine | `0 / 0` = une erreur de rendu donne l'écran par défaut de Next | `fsd-resilience` |
| `perf: pages use client` | pages `"use client"` / pages totales | ratio élevé = App Router utilisé comme une SPA, pas de rendu serveur | `fsd-perf` §3a |
| `perf: mounted` | fichiers avec `setMounted(true)` & co | contournements d'hydratation | `fsd-perf` §3b |
| `perf: vitals` | Web Vitals collectés | `0` = aucune mesure réelle | `fsd-perf` §6 |
| `a11y: axe / lint` | axe dans les tests / plugin jsx-a11y | `- / -` = aucun garde-fou automatique | `fsd-a11y` §3 |
| `a11y: div onClick` | `div`/`span` cliquables sans rôle (hors `stopPropagation`) | actions inaccessibles au clavier | `fsd-a11y` §2 |
| `rt: setInterval refetch` | rafraîchissement fait main | à remplacer par `refetchInterval` | `fsd-realtime` §3 |
| `rt: sockets` | fichiers ouvrant socket.io / WebSocket / EventSource | > 1 = vérifier qu'il n'y a qu'une connexion | `fsd-realtime` §4 |
| `pag: infini sur page` | `useInfiniteQuery` piloté par numéro de page (+ accumulations faites main) | doublons/trous possibles dans un flux | `fsd-pagination` |
| `ent: rôle comparé en UI` | comparaisons de rôle/profil dans les `.tsx` (+ appels `isAdmin()`…) | règles d'autorisation dupliquées côté front | `fsd-entitlements` |
| `cache` (API) | plugin ETag / occurrences de `Cache-Control` | `- / 0` = aucun cache HTTP | `fsd-http-cache` |

Ce sont des **signaux de grep** : ils ont des faux positifs (un `role === "user"` de chat n'est pas une autorisation) et des angles morts (un appel multi-lignes). **Ne jamais présenter un chiffre de la grille comme un constat** sans avoir ouvert au moins un fichier concerné.

## 3. Vérifier puis prioriser

Pour chaque cellule qui ressort :
1. Ouvrir 1 à 3 occurrences et confirmer (ou écarter) le problème. Lancer les greps plus fins du skill concerné (§ « Détecter »).
2. Classer :
   - **Correction / sécurité** d'abord : données d'un utilisateur visibles par un autre (cache), règle d'autorisation divergente, écran blanc (aucun boundary), résultats périmés qui écrasent les récents.
   - **Gain large pour un effort faible** ensuite : `error.tsx` de groupe, `global-error.tsx`, axe dans un Playwright existant, `refetchInterval` à la place d'un `setInterval`, debounce manquant.
   - **Chantiers structurants** en dernier, à planifier : descendre la frontière `"use client"`, passer une API en curseur, remplacer un état serveur fait main par une librairie de requêtes.
3. Tenir compte de l'activité : un projet sans commit depuis des mois passe après un projet actif (`git -C <projet> log -1 --format=%cs`).

## 4. Livrable

```markdown
# Audit FSD — <date>
<grille du script>

## Constats vérifiés (par priorité)
1. <projet> — <constat> — `chemin:ligne` — skill : fsd-xxx — effort : S/M/L
...
## Écartés après vérification
- <signal> : faux positif parce que …
## Points forts à reproduire ailleurs
- <projet> `chemin` : <bon modèle>
```

La section « Écartés » évite de relancer les mêmes fausses pistes au prochain audit. « Points forts » donne aux skills des modèles internes à citer.

## Après l'audit

- Les constats propres au projet (chemins, lignes) restent **dans le rapport d'audit**, pas dans les skills.
- Si l'audit révèle un **motif nouveau et généralisable** (anti-pattern ou bon modèle), l'ajouter à la table « Exemples types » du skill concerné, formulé sans nom de projet ni chemin, pour qu'il serve à tout projet.
