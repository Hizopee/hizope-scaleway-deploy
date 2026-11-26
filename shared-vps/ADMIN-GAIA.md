# Administration de Gaïa (gaia-app.fr/admin)

Le site d'administration (Vue) est construit **dans l'image `gaia-api`** (voir le `Dockerfile` de Gaia-backend) et servi par l'API
sous `/admin`. Il n'y a donc rien de plus à construire ni à copier sur le VPS : une nouvelle image, c'est un nouveau site.

## Ce que fait le Caddyfile

- `gaia-app.fr/admin` et `gaia-app.fr/api/admin/*` sont relayés vers `gaia-api` : même origine, donc le cookie de session
  (`HttpOnly`, `Secure`, `SameSite=Strict`) et l'en-tête de protection CSRF fonctionnent sans CORS.
- `api.gaia-app.fr` répond **404** sur `/admin` et `/api/admin` : l'administration n'est pas joignable depuis l'adresse que
  l'application mobile connaît.
- Le reste de `gaia-app.fr` (site vitrine, page de suppression de compte) est inchangé.

Aucun nouvel enregistrement DNS : `gaia-app.fr` pointe déjà sur ce VPS.

## Créer le premier compte (une seule fois)

1. Sur ta machine, dans `Gaia-backend` :
   ```powershell
   dotnet run --project GaiaWebApi -- hash-password
   ```
   Saisis le mot de passe (12 caractères au moins, varié) : la commande écrit une empreinte `pbkdf2-sha256$600000$…`.
   Le mot de passe ne quitte jamais ta machine.
2. Dans `shared-vps/.env` sur le VPS, renseigne (**valeur entre apostrophes simples**, elle contient des `$`) :
   ```
   GAIA_ADMIN_USERNAME=joyce@gaia-app.fr
   GAIA_ADMIN_DISPLAY_NAME=Joyce
   GAIA_ADMIN_PASSWORD_HASH='pbkdf2-sha256$600000$…'
   ```
3. `docker compose up -d gaia-api` : le compte est créé au démarrage (journal : « Compte d'administration … créé »).
4. **Retire ensuite ces trois lignes du `.env`** : elles sont sans effet si le compte existe, et un mot de passe changé depuis
   l'administration n'est jamais remplacé par celui du `.env`.

Si l'empreinte n'est pas valide (un mot de passe en clair mis par erreur), l'API ne crée rien et le dit dans son journal.

## Vérifier après un déploiement

```bash
curl -sI https://gaia-app.fr/admin/ | head -5          # 200, Content-Security-Policy, Cache-Control: no-store
curl -s -o /dev/null -w '%{http_code}\n' https://api.gaia-app.fr/api/admin/auth/me   # 404 : fermé sur l'API
curl -s -o /dev/null -w '%{http_code}\n' https://gaia-app.fr/api/admin/auth/me       # 401 : joignable, mais sans session
```

Puis ouvrir `https://gaia-app.fr/admin/`, se connecter, vérifier le tableau de bord et l'onglet Fonctionnalités.

## Ordre de mise en production

1. Fusionner la configuration Caddy (cette branche) **et** la version de Gaia-backend qui contient le site, sur `main`.
2. Le déploiement reconstruit l'image `gaia-api` : le site arrive avec.
3. Sur le VPS : `git pull`, ajouter les variables ci-dessus, puis :
   ```bash
   cd ~/hizope-scaleway-deploy/shared-vps
   docker compose -f docker-compose.prod.yml up -d gaia-api
   docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate caddy
   ```
   Caddy se **recrée** (et ne se recharge pas) : le `Caddyfile` est monté comme fichier unique, un `git pull` en change
   l'inode et `caddy reload` répondrait « config is unchanged » (voir `LAZULITTERAIRE.md`). Vérifier :
   `docker compose -f docker-compose.prod.yml exec caddy grep -c "api/admin" /etc/caddy/Caddyfile` doit afficher un nombre non nul.
4. Retirer les variables du compte du `.env`.
5. **Ensuite seulement**, retirer l'onglet Gaia du Pilotage : la modération se fait désormais ici.
