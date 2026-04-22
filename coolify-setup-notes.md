# Coolify UI Setup (Per App)

Everything you actually click through for each app after the host is provisioned and the repo has `Dockerfile.coolify` + `docker-compose.yaml` committed.

## 0. Pre-flight

- [ ] `provision-host.sh` ran on the VPS. `/opt/<client>-apps/<app>/storage/` exists and is owned by the client user.
- [ ] `.env`, SQLite file, and any uploads synced from old host into `/opt/<client>-apps/<app>/storage/` (see `cutover-runbook.md` for rsync commands).
- [ ] DNS for the staging subdomain (`stg.<domain>`) points at the VPS — do this BEFORE clicking Deploy, otherwise Let's Encrypt rate-limits your cert requests.

## 1. Create the app

**Dashboard → Project → + New Resource → Docker Compose Empty → From Git**

- **Git Source:** your existing account-level GitHub App / SSH key (the one already wired into Coolify for other apps). *Don't* generate a per-repo deploy key.
- **Repository + branch:** pick the app's repo and whichever branch is production.
- **Base Directory:** `/`
- **Docker Compose Location:** `docker-compose.yaml`

Coolify reads `docker-compose.yaml`, sees the `app` service with `expose: [80]`, and auto-wires Traefik.

## 2. Set the Domain

**Application → General (or Domains) → set FQDN**

Examples: `stg.yourdomain.com` for staging rehearsal, `yourdomain.com` on cutover day.

⚠️ **Do NOT skip this step.** An empty Domain field means no Traefik labels get rendered, which means the reverse proxy has no route to the container and every request returns 503 from Coolify's proxy. (Symptom: `curl -I https://your.domain/` → 503, but `docker exec <container> wget -qSO- http://127.0.0.1/` → 200.)

## 3. Ports Exposes

**Application → Network / Advanced → Ports Exposes**

Change from default `3000` → **`80`**. Our nginx listens on 80; Coolify's default 3000 is for Node-style apps.

## 4. Environment variables

**Application → Environment Variables → paste**

Start with `docker-templates/.env.example` as a template — fill in values from the old host's `.env`.

⚠️ **Mark every variable "Runtime only"** (i.e. uncheck "Is Build Time"). If anything stays build-time, Coolify injects it as `--build-arg` at the top of every build — any value change busts the Docker layer cache and forces a 15-minute full rebuild.

If you already pasted vars and they show as build-time, flip them all at once via SQL in the Coolify DB:

```sql
-- Find your app's id first:
SELECT id, name FROM applications WHERE name LIKE '%yourdomain%';

-- Then:
UPDATE environment_variables
  SET is_buildtime = false
  WHERE resourceable_id = <app_id>
    AND resourceable_type LIKE '%Application%';
```

Run from the coolify-db container:
```bash
docker exec -i coolify-db psql -U coolify -d coolify
```

### Critical vars to get right

| Key | Notes |
|---|---|
| `APP_KEY` | Copy VERBATIM from old host. New key = every session + encrypted cookie invalidated. |
| `APP_URL` | Use the staging URL during rehearsal, flip on cutover. |
| `DB_CONNECTION=sqlite` | |
| `DB_DATABASE` or `DB_SQLITE_DATABASE` | **Container-absolute path**, e.g. `/var/www/html/storage/database.sqlite` or `/var/www/html/database/database.sqlite`. NOT `/home/olduser/webapps/...` (that path does not exist inside the container). |
| `AUTO_MIGRATE=false` | Flip to `true` for exactly one deploy to apply pending migrations, then back to `false`. |

### Importing env vars programmatically

For apps with 50+ vars, pasting is painful. Quicker: set via tinker in the coolify container (values get encrypted with Coolify's APP_KEY automatically):

```bash
ssh root@<vps> "docker exec -i coolify php /var/www/html/artisan tinker --no-interaction" <<'PHP'
$appId = 11; // your app id
$vars = [
  ['APP_KEY', 'base64:...'],
  ['DB_SQLITE_DATABASE', '/var/www/html/storage/database.sqlite'],
  // ...
];
foreach ($vars as [$k, $v]) {
    \App\Models\EnvironmentVariable::updateOrCreate(
        ['resourceable_id' => $appId, 'resourceable_type' => 'App\\Models\\Application', 'key' => $k],
        ['value' => $v, 'is_buildtime' => false, 'is_runtime' => true]
    );
}
PHP
```

## 5. Healthcheck

Declared in `docker-compose.yaml` — no UI action needed.

Note: we use `http://127.0.0.1/healthz` not `http://localhost/healthz`. Alpine's busybox `wget` prefers IPv6 `::1`, but nginx binds only IPv4 `0.0.0.0:80`, so `localhost` returns "connection refused" and the container stays in `unhealthy` forever.

## 6. Auto-deploy

**Application → Webhooks / Source → Automatic Deployment on Git Push**

Enable it. Push-to-deploy is the whole point. (Optionally disable at first and deploy manually until you trust the build.)

⚠️ If you have multiple apps sharing a project, don't push to all of them simultaneously — parallel deploys can clobber each other's build-helper containers. Push one, let it finish, then push the next.

## 7. Deploy

**Deploy button.** What happens:

1. Coolify pulls the branch.
2. Writes Dockerfile adjustments + build args → `docker build -f Dockerfile.coolify`.
3. First build: ~5-8 min (apk add, docker-php-ext-install, composer install, npm ci — all uncached). Subsequent: ~60-90s if env vars are runtime-only and source has only incremental changes.
4. Container starts, entrypoint.sh runs Laravel warmup (artisan config:cache, etc.).
5. Supervisor brings up php-fpm + nginx + scheduler + (optional) queue worker.
6. Healthcheck goes green → Traefik routes traffic.

## 8. Validate

```bash
# Internal (bypass Traefik, go straight to nginx)
ssh root@<vps> 'docker exec $(docker ps --format "{{.Names}}" | grep <app_uuid>) wget -qSO- http://127.0.0.1/healthz'

# External (through Traefik + Let's Encrypt)
curl -sI https://stg.yourdomain.com/
curl -sI https://stg.yourdomain.com/healthz  # 200

# Supervisor state (if you included the socket sections in supervisord.conf):
docker exec <container> supervisorctl -c /etc/supervisor/conf.d/supervisord.conf status
```

Log in as a real user → session must persist across requests (validates APP_KEY).

## Troubleshooting quick-ref

| Symptom | Cause | Fix |
|---|---|---|
| Build takes 15+ min every time | Env vars flagged build-time | SQL update to flip `is_buildtime=false` |
| 503 from `https://yourdomain/` | Empty `fqdn` column | Set Domain in UI |
| 502 from Traefik | php-fpm not ready / not listening | Check Coolify logs for fpm errors |
| Container `unhealthy` despite logs showing nginx up | Healthcheck uses `localhost` | Already fixed in template — but verify |
| 500 on all pages, "Database file does not exist" | Stale absolute path in DB_SQLITE_DATABASE | Edit env var to `/var/www/html/storage/database.sqlite` |
| "Could not open input file: artisan" | Wrong entrypoint for non-Laravel app | Swap to `variants/entrypoint.custom.sh` |
| Sessions drop on every request | APP_KEY regenerated instead of copied | Paste APP_KEY from old host's .env verbatim |
| Let's Encrypt "too many certs" | Repeatedly deploying against prod domain without DNS ready | Use staging subdomain for rehearsal |
