# Coolify Migration Kit

Templates + runbook for migrating a PHP 8.3 + SQLite Laravel-style app from a traditional host (RunCloud, cPanel, shared hosting) to a VPS running [Coolify](https://coolify.io/).

Battle-tested on two apps (austinselite + austinselite-next) — final deploy time ~60-90s per app after first build.

## Files

| Path | Purpose |
|---|---|
| `provision-host.sh` | One-time VPS setup: creates the unified user, SSH key, shared apps dir |
| `docker-templates/` | Per-app container config (Dockerfile + compose + supervisor + entrypoint) |
| `coolify-setup-notes.md` | Per-app Coolify UI click-through with all known gotchas |
| `cutover-runbook.md` | DNS flip day + post-cutover cleanup (disable old cron, rotate creds) |

## Quickstart

### 1. Prepare the VPS (once per host)

On the VPS as root:

```bash
CLIENT_NAME=yourclient CLIENT_UID=1000 \
SSH_PUBKEY="ssh-rsa AAAA... you@laptop" \
./provision-host.sh
```

Creates a `yourclient` user (uid=1000) with SSH/SFTP via your key, and `/opt/yourclient-apps/` as the bind-mount parent for all apps. Idempotent — safe to re-run.

### 2. Drop templates into each app repo

```bash
cp -r docker-templates/Dockerfile.coolify \
      docker-templates/docker-compose.yaml \
      docker-templates/.dockerignore \
      docker-templates/.env.example \
      docker-templates/docker \
      /path/to/your-app-repo/
```

Edit `docker-compose.yaml`:
- Replace both `<client>` and `<app>` in the volume paths.
- Add the `database:/var/www/html/database` mount only if your app keeps SQLite under `database/` (the Laravel default). Apps keeping SQLite under `storage/` don't need it.

**Non-Laravel apps** (no `artisan`): swap in the custom variants:
```bash
cp docker/variants/entrypoint.custom.sh docker/entrypoint.sh
cp docker/variants/supervisord.custom.conf docker/supervisord.conf
rm -rf docker/variants
```

Commit + push to the app's GitHub repo.

### 3. Sync data from old host

From your laptop (ssh-agent forwarded so the VPS can hop to the old host):

```bash
# .env (trim stale absolute paths after copy)
ssh -A root@<vps> "sudo -u yourclient rsync -avP \
  olduser@<old-host>:/path/to/app/.env \
  /opt/yourclient-apps/<app>/.env"

# SQLite + storage
ssh -A root@<vps> "sudo -u yourclient rsync -avP \
  olduser@<old-host>:/path/to/app/storage/ \
  /opt/yourclient-apps/<app>/storage/"
```

Then edit the .env on the VPS:
- Fix any `DB_SQLITE_DATABASE` / `DB_DATABASE` path to be **container-absolute** (e.g. `/var/www/html/storage/database.sqlite`), not the old host path.
- Drop any vestigial MySQL / Redis credentials that aren't actually used.

### 4. Configure in Coolify UI

Follow `coolify-setup-notes.md`. The non-default settings that matter:
- **Source:** your existing GitHub App integration (no per-repo deploy keys)
- **Build Pack:** Docker Compose, `docker-compose.yaml`
- **Domain:** FILL IT IN. Empty `fqdn` → no Traefik labels → 503.
- **Ports Exposes:** `80` (not Coolify's default `3000`)
- **Env vars:** paste `.env.example` template filled in. **Mark every var "Runtime only"** (is_buildtime=false).

### 5. Rehearse, then cutover

- Point `stg.yourdomain.com` at the VPS, deploy, smoke-test.
- Follow `cutover-runbook.md` for the DNS flip + post-cutover cleanup.

## Pitfalls we hit (and fixed)

### Slow builds

1. **Env vars flagged `is_buildtime=true`** → injected as `--build-arg` → any value change invalidates layer 1 → full rebuild every time (~15 min). Flip all to runtime-only:
   ```sql
   UPDATE environment_variables SET is_buildtime = false
   WHERE resourceable_id = <app_id> AND resourceable_type LIKE '%Application%';
   ```
2. **`chown -R www-data:www-data /var/www/html`** on 40k+ files = overlayfs copy-up hell (~9 min). Only `bootstrap/cache` needs www-data ownership; everything else is either bind-mounted or read-only.
3. **Second `composer dump-autoload --optimize`** rebuilds classmap for 40k+ classes (~2 min). Skip it — pure PSR-4 composer.json resolves at runtime.
4. **`composer install` without `--no-scripts`** runs Laravel's `package:discover` hook, which fails at build time (no APP_KEY). Use `--no-scripts`; the entrypoint runs discovery at boot.
5. **Parallel deploys** (pushing both repos at once) clobber each other's build-helper containers. Push + deploy serially.

### Runtime / config

6. **Healthcheck against `localhost`** fails on alpine because busybox `wget` prefers IPv6 `::1` but nginx binds only IPv4. Use `127.0.0.1`.
7. **Empty Coolify Domain field** → empty `fqdn` in DB → Traefik has no routing labels → 503 from the proxy.
8. **Stale SQLite path in .env** (`/home/olduser/webapps/...`) → app crashes on first DB query. Always rewrite `DB_SQLITE_DATABASE` / `DB_DATABASE` to the container-absolute path.
9. **Missing `[unix_http_server]` + `[supervisorctl]` sections** in supervisord.conf don't break the running container but prevent `supervisorctl status` from introspecting. Our template includes them.
10. **Custom framework without `artisan`** needs a different entrypoint + supervisord (no `schedule:work`, no `queue:work`). Use `docker/variants/*`.

### Ops hygiene

11. **Per-repo GitHub deploy keys are unnecessary.** Use the account-level GitHub App / SSH key already wired into Coolify.
12. **Old host's supervisor + cron jobs keep running after cutover.** Disable them at cutover or both sides run schedulers / queue workers against stale DB copies → duplicate emails, duplicate SMS, corrupted state.
13. **Everything you pasted into the Coolify UI while debugging is in Coolify's DB.** Rotate credentials post-cutover (Twilio, Mailgun, Stripe, Google OAuth, anything else) if the migration chat touched production secrets.

## Re-running this kit

`provision-host.sh` is parameterized for reuse. Second client on the same VPS:
```bash
CLIENT_NAME=client2 CLIENT_UID=1001 SSH_PUBKEY="..." ./provision-host.sh
```
UID 1001 means you also need to change the `addgroup -g 1000` / `adduser -u 1000` in the Dockerfile to match. Keep each client's UID consistent between host user and container `www-data` or bind-mount permissions break.

## Prod-grade tweaks (post-cutover)

The templates are tuned for fast staging deploys. Once stable on prod, consider:

- Re-enable `composer dump-autoload --optimize --no-scripts` in the build RUN (costs ~2 min at build, gives ~5% class-resolution speedup at runtime).
- Raise healthcheck `start_period: 10s` → `30s` if the app ever takes longer to warm than 10s.
- Add `composer cache` + `npm cache` BuildKit mounts (`--mount=type=cache,target=/root/.composer/cache`) — no current-build benefit (those layers are CACHED), but speeds up rebuilds when deps change.
