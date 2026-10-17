---
name: fsd-realtime
description: Garder l'UI synchronisée avec des changements faits ailleurs — choisir entre polling, SSE et WebSocket, brancher les événements sur le cache (React Query / RTK Query) plutôt que sur de simples toasts, resynchroniser après une reconnexion, une seule connexion par app, appliquer les événements de façon idempotente. Utiliser quand un projet utilise socket.io / WebSocket / EventSource / setInterval de rafraîchissement, quand une liste reste périmée alors qu'une notification temps réel est arrivée, quand la connexion se perd ou se rouvre en boucle, ou quand l'utilisateur dit « temps réel », « polling », « SSE », « websocket », « fsd-realtime ». Source : Frontend System Design Essentials, ch. 18–19 + étude de cas WebSockets.
---

# fsd-realtime — l'événement met à jour les données, pas seulement un toast

## 1. Choisir le mécanisme (le plus simple qui suffit)

| Besoin | Mécanisme | Outils courants |
|---|---|---|
| quelques écrans, fraîcheur de 10–60 s acceptable, ou suivi d'un traitement qui se termine | **polling** | `refetchInterval` (React Query), `pollingInterval` (RTK Query) |
| le serveur pousse, le client ne fait qu'écouter (notifications, statut, tableau de bord) | **SSE** | NestJS `@Sse()` + `EventSource` |
| échanges dans les deux sens, fréquents (chat, présence, édition collaborative, drag partagé) | **WebSocket** | socket.io (client et `@WebSocketGateway`) |

Le polling n'est pas une honte : un suivi de commande, un traitement batch ou une liste consultée 3 fois par jour n'ont pas besoin d'une connexion permanente. Passer au push quand le trafic de polling devient significatif ou que la latence compte.

## 2. Détecter

```bash
X="--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist --exclude-dir=build"
# rafraîchissement fait main
grep -rnE "setInterval\(" src $X --include='*.ts*' | grep -iE "refetch|fetch|load|refresh"
# connexions temps réel : combien, où ?
grep -rnE "io\(|new WebSocket\(|new EventSource\(" src $X --include='*.ts*'
# événements qui ne touchent pas au cache (toast/console seulement)
grep -rn -A4 "socket\.on(\|addEventListener('message'" src $X --include='*.ts*' | grep -cE "invalidate|setQueryData|updateQueryData|dispatch"
# URL de serveur en dur
grep -rnE "io\(['\"\`]https?://|new WebSocket\(['\"\`]wss?://" src $X --include='*.ts*'
```

## 3. Polling bien fait

```ts
useQuery({
  queryKey: ['runs'],
  queryFn: ({ signal }) => runsApi.list({ signal }),
  refetchInterval: (q) => (q.state.data?.some(isActive) ? 5_000 : false),  // poller seulement tant que c'est utile
  refetchIntervalInBackground: false,      // défaut : pause quand l'onglet est caché
});
```

Remplacer tout `setInterval(() => refetch())` + écouteur `visibilitychange`/`focus` fait main : `refetchInterval` + `refetchOnWindowFocus` (actif par défaut) font la même chose.

## 4. Push (SSE / WebSocket) : les cinq règles

**R1 — Une seule connexion par app**, ouverte dans un provider monté une fois (layout racine). Aucun composant n'appelle `io()` lui-même : ils s'abonnent au provider.

**R2 — La durée de vie suit l'identité, pas les callbacks.** Les dépendances de l'effet de connexion sont `[token]` (ou `[boardId]`), jamais des handlers ou des fonctions de toast. Les handlers passent par une ref :
```ts
const handlerRef = useRef(handler);
useEffect(() => { handlerRef.current = handler; }, [handler]);
useEffect(() => { /* connexion */ socket.on('x', (d) => handlerRef.current?.(d)); return () => socket.disconnect(); }, [token]);
```

**R3 — Un événement met à jour le cache**, et le toast n'est qu'un plus :
```ts
socket.on('mission.updated', (m: Mission) => {
  qc.setQueriesData<Mission[]>({ queryKey: ['missions'] }, (l) => l?.map((x) => (x.id === m.id ? m : x)));
  qc.invalidateQueries({ queryKey: ['missions', 'stats'] });   // ce qu'on ne sait pas patcher : on revalide
});
```
En RTK Query : `dispatch(api.util.invalidateTags(['Mission']))` ou `updateQueryData`. Si l'événement ne transporte qu'un id, `invalidateQueries` suffit. C'est souvent le plus robuste.

**R4 — Appliquer de façon idempotente** (voir `fsd-optimistic` §5). L'émetteur reçoit aussi sa propre diffusion : insérer seulement si l'id est absent, remplacer par id, ignorer un événement plus ancien que l'état local (`updatedAt` ou version).

**R5 — Resynchroniser après une coupure.** Les événements émis pendant la déconnexion sont perdus. À la reconnexion, revalider ce que l'écran affiche :
```ts
socket.io.on('reconnect', () => qc.invalidateQueries());   // socket.io v4 : sur le Manager (socket.io), pas sur le socket
```
Et ne pas plafonner les tentatives : `reconnectionAttempts: Infinity` (défaut) avec backoff, plutôt que 5 essais puis une app muette pour toujours. `EventSource` se reconnecte seul. Revalider aussi dans son `onopen`.

## 5. Côté serveur (NestJS), le minimum

- SSE : `@Sse('events') stream(): Observable<MessageEvent>` à partir d'un `Subject`, et un heartbeat (commentaire toutes les 15–30 s) pour les proxys.
- Le code métier émet un **événement de domaine** (`mission.updated`) sans connaître le transport. Le gateway ou le contrôleur SSE le relaie (pub-sub, ch. 19).
- Diffuser par salle (`board:1`, `tenant:42`), jamais à tout le monde.
- Plusieurs instances de l'API : un adaptateur Redis (`@socket.io/redis-adapter`) ou équivalent. Sinon un client connecté à l'instance B ne voit pas ce qui se passe sur A.

## 6. Vérifier

1. Deux onglets : une action dans A apparaît dans B **sans** rechargement, et pas en double dans A.
2. Couper le réseau 30 s (DevTools → Offline), modifier une donnée depuis un autre client, rétablir : l'écran se met à jour.
3. Onglet Network → WS : **une** connexion, qui ne se rouvre pas quand on navigue ou qu'un toast s'affiche.

## Exemples types

| Symptôme dans le code | Correction |
|---|---|
| `socket.on('item.created', () => toast('Nouvel élément'))` et la liste ne bouge pas | patcher ou invalider le cache dans le handler (R3) |
| `io('https://api.prod…')` en dur dans le provider | URL depuis la configuration d'environnement |
| deux fichiers qui appellent `io()` sur le même namespace | un seul provider, les composants s'abonnent (R1) |
| `useEffect(() => { const s = io(…) }, [token, showToast, handler])` | dépendances `[token]`, handlers via ref (R2) |
| `socket.on('reconnect', …)` en socket.io v4 | `socket.io.on('reconnect', …)` + `invalidateQueries()` (R5) |
| `reconnectionAttempts: 5` | tentatives illimitées avec backoff |
| `setInterval(() => { if (document.visibilityState === 'visible') refetch() }, 30000)` | `refetchInterval: 30_000` (pause automatique onglet caché) |
| bon modèle : `refetchInterval: (q) => (q.state.data?.some(isRunning) ? 5000 : false)` | poller seulement tant qu'un traitement est actif |
