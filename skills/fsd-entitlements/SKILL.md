---
name: fsd-entitlements
description: Sortir les règles métier d'autorisation du front (rôles, plans, profils comparés dans les composants) et les faire renvoyer par l'API sous forme de capacités. Utiliser quand un composant compare un rôle/profil/plan pour décider quoi afficher ou autoriser, quand un commentaire dit « règle de l'API reproduite ici », quand on audite un projet pour la logique métier dupliquée, ou quand l'utilisateur dit « entitlements », « permissions côté API », « fsd-entitlements ». Source : Frontend System Design Essentials, ch. 6–7.
---

# fsd-entitlements — les règles vivent là où vit la connaissance

Le backend possède les règles métier, le front possède la présentation.
Une règle d'autorisation recopiée dans le front finit par diverger de l'API :
bouton affiché puis 403, ou action possible côté API mais cachée dans l'UI.

## 1. Détecter

Lancer depuis la racine du projet front (adapter les noms de champs au projet) :

```bash
X="--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist"
# comparaisons de rôle/profil/plan dans le code UI
grep -rnE "(role|profile|_profile|planType|plan|tier)\s*[!=]==?\s*['\"][A-Z_a-z]+['\"]" src $X --include='*.tsx'
# helpers de rôle appelés depuis les composants
grep -rnE "\bis(Admin|Administrator|SuperAdmin|Premium|Owner)\w*\(" src $X --include='*.tsx'
# aveux explicites de duplication
grep -rniE "reprodui|mirror|same rule as (the )?api|pour ne pas .* 403" src $X
```

## 2. Trier chaque occurrence

| C'est… | Indice | Décision |
|---|---|---|
| **Règle métier** | décide si une action/page/donnée est *permise* ; l'API a un `ForbiddenException`/403 équivalent | → déplacer vers l'API (étape 3) |
| **Présentation** | icône, badge, libellé, couleur, « Nouveau » selon une date | → laisser dans le front |
| **Garde de route** | `if (!isX(user)) return <Forbidden/>` | → remplacer par une capacité nommée (`can.viewAudit`), pas par le rôle |

Règle de tri : *si le product owner change la règle, faut-il redéployer le front ?* Oui → c'est une règle métier mal placée.

## 3. Le modèle cible

Deux niveaux, calculés par **la même fonction de politique** que celle qui lève le 403 côté API (sinon la duplication a juste changé de côté) :

1. **Capacités du viewer** — renvoyées par `GET /auth/me` :
   ```json
   { "id": "u1", "backoffice_profile": "ADMIN",
     "capabilities": { "manageTeam": true, "viewAudit": true, "assignableProfiles": ["ANALYST","ADMIN","FIELD_AGENT"] } }
   ```
2. **Permissions par ressource** — attachées à chaque élément d'une liste/détail :
   ```json
   { "id": "m1", "profile": "SUPER_ADMIN", "permissions": { "canEdit": false, "canChangeStatus": false } }
   ```

Noms de capacités = vocabulaire du domaine (`manageTeam`, `validateSite`), jamais le nom du rôle (`isAdmin`).

### Côté NestJS

Une fonction pure par ressource, utilisée deux fois :

```ts
// team.policy.ts — seule source de vérité
export function memberPermissions(viewer: ConnectedUser, member: { userId: string; profile: Profile }) {
  const isSelf = member.userId === viewer.id;
  const outranked = member.profile === 'SUPER_ADMIN' && viewer.backoffice_profile !== 'SUPER_ADMIN';
  return { canEdit: !outranked, canChangeStatus: !outranked && !isSelf, canChangeProfile: !outranked && !isSelf };
}

// service : l'enforcement appelle la politique…
if (!memberPermissions(viewer, member).canChangeStatus) throw new ForbiddenException('…');
// …et la sérialisation aussi
return items.map((m) => ({ ...toDto(m), permissions: memberPermissions(viewer, m) }));
```

Laisser un test unitaire sur la fonction de politique (cas : soi-même, surclassé, super-admin).

### Côté front

- Lire `member.permissions.canEdit`, `me.capabilities.assignableProfiles`. Plus aucune comparaison de rôle pour décider.
- Supprimer la fonction locale dupliquée et son commentaire « reproduit ici ».
- Typer `permissions`/`capabilities` dans les types de l'API (ou le contrat généré s'il existe).
- Garder la gestion du 403 : les capacités servent l'UX, l'API reste l'arbitre (règle changée entre deux chargements).

## 4. Ordre de livraison

1. API : fonction de politique + test, enforcement branché dessus, champ ajouté aux réponses (additif, rien ne casse).
2. Front : consommer les champs, supprimer la logique locale.
3. Vérifier : relancer les greps de l'étape 1 — il ne doit rester que de la présentation.

## 5. Pièges

- **Ne pas** envoyer toute la matrice rôle → permissions au front « pour qu'il calcule » : c'est la même duplication avec un JSON en plus.
- **Ne pas** créer un service de permissions générique (CASL, RBAC engine) pour 3 règles. Une fonction par ressource suffit ; on généralise quand il y en a beaucoup.
- Les listes paginées : calculer `permissions` côté serveur sur la page renvoyée, pas en N+1 côté client.
- Apps multiples (web + mobile) : c'est le cas où le gain est maximal — elles lisent le même champ.

## Exemples types

| Symptôme dans le code | Correction |
|---|---|
| `const canEdit = member.role !== 'OWNER' \|\| me.role === 'OWNER'` dans un composant, avec un commentaire « même règle que l'API » | fonction `memberPermissions(viewer, member)` côté API, utilisée par le contrôle d'accès **et** sérialisée dans `member.permissions.canEdit` |
| `if (!isAdmin(user)) return <Forbidden />` répété sur chaque page d'administration | capacités nommées dans `/me` (`capabilities.manageTeam`, `capabilities.viewAudit`) et garde sur la capacité |
| liste des rôles attribuables calculée côté front selon le rôle courant | `capabilities.assignableRoles` renvoyé par l'API |
| badge « Admin », icône bouclier, couleur selon le rôle | **à garder côté front** : c'est de la présentation |
| `user.plan === 'premium' && accountAge > 3 ans` pour afficher une fonctionnalité | `features.showAdvancedExport` calculé par le backend |
