# Cutover Runbook

DNS flip day. Works the same whether you're cutting one app or several — do each serially.

## T-24 hours: Lower TTL

For every production A record you'll flip, lower TTL to **300s**. Record the current values first so you can restore after cutover stabilizes.

## T-1 hour: Staging smoke test

Prereq: staging subdomain resolves to the VPS, the app's been deployed and is green.

- [ ] Load the staging URL in an incognito window → homepage renders, no 500s
- [ ] Log in → session persists across 3 page loads (validates APP_KEY)
- [ ] Trigger an email action (password reset, contact form) → email arrives
- [ ] Trigger a queue job if the app has one → processes within expected window
- [ ] `docker exec <container> supervisorctl -c /etc/supervisor/conf.d/supervisord.conf status` → all programs RUNNING
- [ ] SFTP upload a test file into `/opt/<client>-apps/<app>/storage/app/public/test.txt` (or wherever your public uploads live) → fetch it at the public URL
- [ ] Tail `storage/logs/laravel*.log` on the VPS during 5 test pageloads → no unexpected errors

If anything fails: do NOT proceed. Fix, redeploy, re-test.

## T-0: Cutover window

### 1. Freeze the old host (2 min)

SSH to the old host, for each app:

```bash
cd /path/to/app
php artisan down --secret="bypass-$(openssl rand -hex 8)"
# note the secret — lets you bypass maintenance mode for a final smoke test
```

Old host now returns 503 to visitors. In-flight sessions continue in the users' browsers harmlessly.

### 2. Final sync (5-10 min)

Pull the absolute freshest `.env` + SQLite + uploads from the old host, in case anything drifted since the initial sync.

From your laptop (with ssh-agent forwarding so the VPS can hop to the old host):

```bash
# Per app
ssh -A root@<vps> "sudo -u <client> rsync -avP --delete \
  olduser@<old-host>:/path/to/app/.env \
  /opt/<client>-apps/<app>/.env"

ssh -A root@<vps> "sudo -u <client> rsync -avP --delete \
  olduser@<old-host>:/path/to/app/storage/ \
  /opt/<client>-apps/<app>/storage/"

# If the app keeps SQLite in database/ (not storage/):
ssh -A root@<vps> "sudo -u <client> rsync -avP \
  olduser@<old-host>:/path/to/app/database/database.sqlite \
  /opt/<client>-apps/<app>/database/database.sqlite"
```

Then on the VPS:

```bash
ssh <client>@<vps>
# fix any .env paths that still point at the old host filesystem (DB_DATABASE, LOG_*, etc.)
# restart each app in Coolify UI to pick up fresh env + DB
```

### 3. DNS flip (1 min)

In your DNS provider, update all production A records to the VPS IP. Timestamp the flip for the propagation check.

### 4. Watch Let's Encrypt (1-3 min)

Coolify's Traefik issues certs as soon as DNS points at the VPS:

```bash
ssh root@<vps> 'docker logs -f coolify-proxy 2>&1 | grep -iE "cert|acme"'
```

Expect `certificate obtained successfully` within 30-120 seconds.

### 5. External validation (5 min)

From **outside** your network (phone hotspot, cloudshell, a friend's laptop):

```bash
dig +short yourdomain.com    # should return VPS IP
curl -sI https://yourdomain.com/  # expect HTTP/2 200
```

Hit it from at least one additional vantage point — propagation is uneven.

### 6. Functional smoke (live)

Log in as a real user. Click through 5 pages. Trigger an email. Watch the logs on the VPS:

```bash
ssh <client>@<vps>
tail -f /opt/<client>-apps/<app>/storage/logs/laravel-*.log
```

### 7. Leave old host in maintenance mode

Don't `php artisan up` on the old host yet. If Coolify breaks in the next 30 min, your rollback path is:
1. Flip DNS back (300s TTL means fast propagation)
2. `php artisan up` on old host
3. Investigate on the VPS at leisure

If you `artisan up` and DNS is also pointing to the new host, writes can happen on both backends for the brief propagation window — painful to reconcile.

Wait 30 min of clean VPS traffic, then `php artisan up` on the old host so it's warm-but-idle.

## T+15 min: disable old host's background jobs

⚠️ **Do NOT skip this.** The old host still has its scheduler + cron + queue workers active. If you leave them, they keep running against the old DB copy → duplicate emails sent, duplicate SMS, stale queued jobs reprocessed on rollback.

Per app on the old host:
- [ ] RunCloud / Plesk / cPanel: disable the `* * * * * php artisan schedule:run` cron entry
- [ ] Stop any supervisor-managed queue workers (RunCloud: Supervisor panel → stop + disable)
- [ ] Disable any app-specific cron entries (cache warming, sitemap regeneration, etc.)
- [ ] Confirm with `crontab -u <user> -l` and/or `supervisorctl status`

These are now running inside the container via our supervisord config — duplicate running = bad.

## T+24h

- [ ] Review `laravel-*.log` for 24h of error trends. Anything new vs. the old host baseline?
- [ ] `docker stats` — container CPU/memory under real traffic looks sane?
- [ ] `df -h` — disk growth rate under real uploads is what you expected?
- [ ] Scheduled tasks that should have fired in the last 24h — did they produce their expected side effects (email sent, report generated, etc.)?
- [ ] Restore original DNS TTL values if cutover was clean.

## T+7 days: decommission old host

Only after a full week of no surprises. Things that surface late:

- A cron firing once a week that isn't in the new supervisord
- A hardcoded absolute path (`/home/olduser/...`) in app code someone forgot about
- A queued job in the old host's Redis that never got drained
- A file someone uploaded to the old host AFTER your final sync
- An IP allowlist on a third-party API still pointing at the old IP

Last audit before tearing down:

```bash
# On the old host
crontab -u <user> -l                          # app cron entries
ls /etc/cron.*/                                # system cron
# Files modified in the last 7 days (post-cutover surprise uploads, etc.)
find /path/to/app -mtime -7 -type f \
  -not -path "*/storage/logs/*" \
  -not -path "*/storage/framework/*"
```

If clean: tear down. Keep a SQLite snapshot + a tarball of the app dir in cold storage for 90 days as insurance.

## T+7 days: credential rotation

If any production credentials got pasted into chat logs / tickets / scratch files during the migration, rotate them now. Usual suspects:

- [ ] `APP_KEY` — if you're rotating anyway, do it during a deploy window (all sessions invalidated)
- [ ] Mail provider (Mailgun, SendGrid, SMTP2GO) API keys
- [ ] Twilio Account SID + Auth Token
- [ ] Stripe keys (restricted keys can be cycled without re-integrating)
- [ ] Google OAuth client secret (bumps all users' tokens; plan for the re-auth flow)
- [ ] Any third-party API key logged in the migration chat

Update each in Coolify → Environment Variables → redeploy.

## Rollback plan

If the cutover breaks within the first hour:

1. DNS: flip A records back to the old host. TTL 300s = fast propagation.
2. Old host: `php artisan up`
3. VPS: no action — leave Coolify apps running, they're just not receiving traffic. Debug at leisure.

⚠️ **Do not** let writes happen on the VPS (real user traffic) and then roll back — any writes to the VPS-side SQLite during that window are lost when DNS flips back. This is why maintenance mode goes on the old host *before* the DNS flip.
