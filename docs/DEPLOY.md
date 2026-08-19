# Deploying pol

One DigitalOcean droplet (`pol-prod`, 68.183.55.31, nyc3, 2GB / $12mo) runs
the entire site via [Kamal](https://kamal-deploy.org): kamal-proxy in front,
the web app (Thruster + Puma), a good_job worker (whose in-process cron is
what runs the 2-hourly scrape, the 2-hourly model run and the 7:00 ET
brief — see `config/initializers/good_job.rb`), and Postgres 17 as a Kamal
accessory on a persistent docker directory. Images live in the free Starter
tier of DO's container registry (`registry.digitalocean.com/pol-forecast`).

Secrets are never committed: `.kamal/secrets` reads the macOS keychain
(`pol-do-registry-user`, `pol-do-registry-token`, `pol-db-production`) and
`config/master.key`. The OpenRouter and Resend values ride inside encrypted
Rails credentials.

## Day to day

```bash
bin/kamal deploy          # ship HEAD (build → push → health-checked swap)
bin/kamal logs            # tail web logs;  -r job for the worker
bin/kamal console         # rails console in the running container
bin/kamal app exec 'bin/rails pol:model'   # any one-off task
```

Kamal builds from git HEAD — commit before deploying.

## First-boot / rebuild checklist

1. `bin/kamal setup` (installs docker on the host, boots Postgres, deploys).
2. Seed the world: `bin/kamal app exec 'bin/rails pol:seed_races pol:scrape pol:model'`.
3. The editor account: on a fresh boot the entrypoint's `db:prepare`
   CREATES the database and therefore runs `db/seeds.rb` — so the account
   already exists and its generated password was printed once into the web
   container's boot log. Recover it before the next deploy replaces that
   container:
   `ssh root@<host> 'docker logs $(docker ps -q --filter label=role=web) 2>&1 | grep -A4 "GENERATED password"'`
   then rotate it from `bin/kamal console`
   (`User.sole.update!(password: ...)`) — it has, after all, been sitting
   in a docker log. Sign in at `/session/new`, ideally only once SSL is up.
4. The newsroom: a fresh production database arms it by default
   (`Setting.agents_enabled?`). This deploy set the stored toggle to
   disarmed so an unattended box doesn't publish or spend; arm it from
   `/admin/settings` when you're ready.
5. Backups: `bin/pg-backup` is installed as a root cron on the droplet
   (nightly at 08:15 UTC / 4:15 ET, after the morning brief), keeping 14
   days of gzipped dumps in `/root/backups`. Restore:
   `gunzip -c dump.sql.gz | docker exec -i pol-db psql -U pol -d pol_production`.

## The domain

The canonical site is https://535.wtf. Cloudflare has an apex A record
pointing at `68.183.55.31` and `www` aliases the apex. Both are DNS-only
(gray cloud) so kamal-proxy can issue and renew its own Let's Encrypt
certificate directly. Kamal accepts `535.wtf`, `www.535.wtf` and the legacy
`535.appmakey.com`; Rails permanently redirects the latter two to the same
path on the apex. `assume_ssl`/`force_ssl` are on, with `/up` excluded so the
proxy's internal health check stays valid.

If Cloudflare proxying is enabled later, set SSL/TLS to **Full (strict)** and
enable trusted forwarded headers in the Kamal proxy configuration before the
change.

## Dispatch email

Subscribers and per-recipient delivery state live in Postgres. Creating a new
published `Dispatch` queues `DispatchEmailFanoutJob`, which snapshots active
subscribers and queues one idempotent Resend API request per delivery. Existing
dispatches, edits and retractions do not start a mailing. Bounces, complaints,
suppression and delivery state arrive through the signed
`POST /webhooks/resend` endpoint.

Email has its own production kill switch:

```yaml
DISPATCH_EMAILS_ENABLED: "false"
```

Keep it false until the Resend domain is verified and a live subscription,
delivery and unsubscribe smoke test passes; then change it to `"true"` and
deploy. This does not affect the newsroom's separate `agents_enabled` switch.

The Resend sending domain is `535.wtf`, the sender is
`535.wtf <robot@535.wtf>`, and replies go to `cmartyn@gmail.com`. The Cloudflare
zone must contain the exact SPF/MX, DKIM and tracking records shown by Resend,
plus a DMARC record at `_dmarc`. Store the one-time values in encrypted Rails
credentials:

```bash
bin/rails credentials:edit

# resend_api_key: re_...
# resend_webhook_secret: whsec_...
```

The encrypted `config/credentials.yml.enc` file is committed; its master key is
not. `RESEND_API_KEY` and `RESEND_WEBHOOK_SECRET` remain supported as runtime
overrides.

## Costs

Droplet $12/mo + droplet backups ~$2.40/mo + registry $0 + Let's Encrypt $0.
OpenRouter spend is usage-based and gated by the newsroom toggle + its
per-race/per-day caps.
