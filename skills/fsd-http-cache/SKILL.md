---
name: fsd-http-cache
description: Faire travailler le cache HTTP pour le front — choisir Cache-Control par catégorie de route (public stable, privé par utilisateur, jamais), ajouter des validateurs (ETag, Last-Modified) pour des 304 sans corps, poser Vary là où la réponse dépend d'un en-tête, sans casser la sécurité (données d'un utilisateur servies à un autre). Côté NestJS (Fastify ou Express), BFF/proxy Next et rendu serveur Next. Utiliser quand une API renvoie de gros payloads qui changent peu (carte, GeoJSON, référentiels, listes publiques), quand on conçoit une route publique, quand un proxy/BFF réécrit les en-têtes, ou quand l'utilisateur dit « cache HTTP », « ETag », « 304 », « Cache-Control », « CDN », « Vary », « fsd-http-cache ». Source : Frontend System Design Essentials, ch. 20.
---

# fsd-http-cache — les en-têtes font le travail, pas le code React

Deux questions distinctes :
- **Fraîcheur** (`Cache-Control`) : combien de temps peut-on réutiliser une réponse **sans** demander au serveur ?
- **Validation** (`ETag` / `Last-Modified`) : une fois périmée, a-t-elle changé ? Si non, `304 Not Modified` sans corps.

Le cache mémoire de React Query (`staleTime`) et le cache HTTP du navigateur sont **deux couches**. React Query décide *quand* refaire la requête, le cache HTTP rend cette requête presque gratuite (304).

## 1. Classer chaque route GET

| Catégorie | Exemples | `Cache-Control` | Validateur | `Vary` |
|---|---|---|---|---|
| **A. Public, identique pour tous, change peu** | carte publique, référentiels, offres, GeoJSON | `public, max-age=60, s-maxage=300, stale-while-revalidate=600` | ETag | selon les en-têtes qui changent la réponse (`Accept-Language`), sinon rien |
| **B. Privé (dépend de l'utilisateur)** | `/me`, mes dossiers, tableaux du backoffice | `private, no-cache` (réutilisable seulement après revalidation) | ETag | `Authorization` ou `Cookie` |
| **C. Jamais en cache** | jetons, OTP, téléchargements signés, export ponctuel, réponses avec secret | `no-store` | — | — |
| **Fichiers statiques versionnés** (hash dans le nom) | `/_next/static/*`, `assets/*-a1b2.js` | `public, max-age=31536000, immutable` | — | — |

Règles :
- **Par défaut, privé.** Une route n'est « publique » que si la réponse est **strictement identique** quel que soit l'appelant. Un champ dépendant de l'utilisateur (`isFavorite`, `permissions`) la rend privée.
- `public` + `s-maxage` sur une réponse authentifiée = un CDN peut servir les données d'un utilisateur à un autre. C'est la faute grave de ce chapitre.
- `stale-while-revalidate` est surtout respecté par les CDN et proxys. Ne pas compter dessus côté navigateur.

## 2. Vary : uniquement des en-têtes

`Vary` liste les **en-têtes de requête** dont dépend la réponse : `Authorization`, `Cookie`, `Accept-Language`, `Accept-Encoding`, `Origin` (CORS avec liste d'origines). Les paramètres d'URL (`?q=`, `?page=`) font **déjà** partie de la clé de cache, il ne faut pas les mettre dans `Vary`. L'exemple `Vary: X-Search-Query` du livre est faux.

## 3. Détecter

```bash
X="--exclude-dir=node_modules --exclude-dir=dist"
grep -oE "\"@nestjs/platform-(express|fastify)\"|\"@fastify/etag\"|\"@fastify/compress\"|\"compression\"" package.json
grep -rnE "Cache-Control|ETag|If-None-Match|Last-Modified|Vary|@Header\(" src $X --include='*.ts' | grep -v spec
# routes publiques (décorateur ou mention dans la doc Swagger)
grep -rnE "@Public\(|Route publique|isPublic" src $X --include='*.controller.ts'
# gros GET : listes complètes, géométries
grep -rnE "all: true|geojson|geometry|perimeter" src $X --include='*.ts' | grep -vE "spec|dto" | head
# côté front : proxy/BFF qui réécrit les en-têtes, fetch serveur Next
grep -rnE "Cache-Control|no-store|if-none-match|etag" src/app/api src/server src/lib $X -i --include='*.ts' 2>/dev/null
```

## 4. Implémenter (NestJS)

**Validation (ETag)**
- **Fastify** : `await app.register(require('@fastify/etag'))` (ou import ESM) dans `main.ts`. Il calcule un ETag sur le corps et répond `304` tout seul quand `If-None-Match` correspond.
- **Express** : ETag faible déjà actif par défaut (`app.set('etag', …)`). Vérifier qu'il n'a pas été désactivé.
- L'ETag par hachage économise la **bande passante**, pas le calcul : le serveur produit encore la réponse. Pour une ressource coûteuse, calculer un ETag de version **avant** de charger (`max(updated_at)` + `count(*)`), et renvoyer 304 sans requête lourde.

**Fraîcheur, par route**
```ts
@Get()
@Header('Cache-Control', 'public, max-age=60, s-maxage=300, stale-while-revalidate=600')
findAll() { … }
```
Pour les routes authentifiées, un intercepteur global qui pose `private, no-cache` + `Vary: Authorization` quand le handler n'a rien défini, et `no-store` sur les routes de la catégorie C.

**Après une écriture** : avec un ETag par hachage, rien à faire, le nouveau corps donne un nouvel ETag. Avec un ETag de version, l'`updated_at` doit bouger à chaque mutation qui change la réponse (y compris suppression/archivage).

## 5. Côté front

- **Ne pas casser le cache** : pas de `?_t=${Date.now()}`, pas de `Cache-Control: no-cache` en en-tête de requête « par habitude ». Les garder pour les vrais cas (vérification de version de l'app).
- **BFF / proxy Next** (route `app/api/.../route.ts`) : relayer `If-None-Match` vers l'amont, et en retour `ETag` + le statut `304`. Remplacer la directive amont par une directive **privée** propre à l'origine du front (`private, no-cache`), jamais l'amont tel quel.
- **Next serveur** : `fetch(url, { next: { revalidate: 300, tags: ['sites'] } })` pour les données de catégorie A rendues côté serveur, et `revalidateTag('sites')` après une publication.
- React Query : `staleTime` aligné sur le `max-age` des données A (au-delà, React Query refait la requête et le navigateur la résout souvent en 304).

## 6. Vérifier

```bash
curl -sI https://api/…/sites | grep -iE "cache-control|etag|vary"
curl -sI -H 'If-None-Match: "<etag reçu>"' https://api/…/sites | head -1     # attendu : HTTP/1.1 304
```
DevTools → Network : colonne « Size » à `(disk cache)` dans la fenêtre `max-age`, puis requêtes `304` de quelques centaines d'octets. Avec deux comptes différents : une route privée ne renvoie jamais les données de l'autre, même derrière le CDN.

## Exemples types

| Situation | Correction |
|---|---|
| route publique `GET /sites?all=true` (identique pour tous, gros payload), sans en-tête de cache | catégorie A : `public, max-age=60, s-maxage=300, stale-while-revalidate=600` + ETag |
| API NestJS sur Fastify sans plugin ETag | `@fastify/etag` dans `main.ts` |
| `GET /me/…` sans directive | catégorie B : `private, no-cache` + ETag + `Vary: Authorization` |
| réponse authentifiée en `public, s-maxage=…` | **faille** : passer en `private` |
| proxy/BFF qui force `no-store` et supprime tous les en-têtes amont | garder la protection, mais relayer `If-None-Match` / `ETag` / 304 et poser `private, no-cache` |
| `Vary: X-Search-Query` pour un paramètre d'URL | supprimer : l'URL fait déjà partie de la clé de cache |
| `fetch(url + '?_t=' + Date.now())` | supprimer le contournement, régler `Cache-Control` côté serveur |
| `cache: 'no-store'` sur la vérification de version de l'application | **correct** |
