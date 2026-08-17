# Deploying pol

One DigitalOcean droplet (`pol-prod`, 68.183.55.31, nyc3, 2GB / $12mo) runs
the entire site via [Kamal](https://kamal-deploy.org): kamal-proxy in front,
the web app (Thruster + Puma), a good_job worker (whose in-process cron is
what runs the 2-hourly scrape, the 6:30 ET floor model run and the 7:00 ET
brief — see `config/initializers/good_job.rb`), and Postgres 17 as a Kamal
accessory on a persistent docker directory. Images live in the free Starter
tier of DO's container registry (`registry.digitalocean.com/pol-forecast`).

Secrets are never committed: `.kamal/secrets` reads the macOS keychain
(`pol-do-registry-user`, `pol-do-registry-token`, `pol-db-production`) and
`config/master.key`. The OpenRouter key rides inside Rails credentials.

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

## When there's a domain

Add to `config/deploy.yml`:

```yaml
proxy:
  ssl: true
  host: the-domain.example
```

turn on `config.assume_ssl` and `config.force_ssl` in
`config/environments/production.rb`, point the DNS A record at the droplet,
and `bin/kamal deploy`. Let's Encrypt issuance is automatic.

## Costs

Droplet $12/mo + droplet backups ~$2.40/mo + registry $0 + Let's Encrypt $0.
OpenRouter spend is usage-based and gated by the newsroom toggle + its
per-race/per-day caps.
