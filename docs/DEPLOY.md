# Deploying pol

One DigitalOcean droplet (`pol-prod`, 68.183.55.31, nyc3, 2GB / $12mo) runs
the entire site via [Kamal](https://kamal-deploy.org): kamal-proxy in front,
the web app (Thruster + Puma), a good_job worker (whose in-process cron is
what runs the hourly feed sweep, the 2-hourly model run and the 7:00 ET
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

## Post-election results

Both production roles use `POST_ELECTION_MODE=true`. The web entrypoint
migrates, verifies the archived run, and imports missing results from retained
civicAPI responses on the shared volume before serving traffic. It can be
retried. A missing or mismatched pin stops startup. The worker then runs
`PostElection::ResultsJob` twice an hour. Old queued polling, forecast and
newsroom jobs skip execution. The election-night preview retains its last
dated estimate.

The downloadable archive comes from production model run **1339**, completed
**November 3, 2026 at 4:32:14 p.m. Eastern**, the last completed run before the
first poll close. Its ID and finish time match the frozen election-night prior.
The 940 race forecasts and four chamber forecasts come from that run. The
924 candidate records come from the November 4 08:15 UTC backup, before the
next candidate sync. Every roster row in that backup predates the final run.
Historical charts end at the pinned run. Later polling runs remain in the
database for audit.

The importer checks each pinned federal contest's identity, non-test flag,
dated report, candidate identities, vote counts and archived raw hash.
civicAPI makes its own projections. A single explicit winner can be displayed
without a published call time. A missing report retains the last good record.
Disputed or conflicting calls remain outstanding. An editor records certification
and links the election authority under **Admin → Races → Election result**.
Selecting **Use civicAPI calls** releases an editorial override. Changes to the
displayed decision are retained in the race's decision history.

Run `bin/rails post_election:refresh` for a due sweep, or
`bin/rails 'post_election:refresh[senate-2026-me]'` for one race, including a
vote correction after certification. The source's report time and the winner's
decision time are recorded independently. To stop collection while preserving
the archive, disable the results cron in GoodJob.

## Election-night preview

The unlisted preview is `https://535.wtf/election-night`. It has no public
navigation link, and both the HTML and snapshot endpoint request no indexing.
Anyone with the URL can open it; it is not authenticated.

During election night the production `job` role enabled `ELECTION_NIGHT_ENABLED=true` and used one
GoodJob worker thread on this 2 GB host. SweepJob caps queued plus running
sweeps at one, skips overlapping manual collection, and waits for a frozen
prior before attempting its first scheduled run. The web role does not
schedule collection. Both roles use `pol_storage:/rails/storage`.

Initialize a new production store once, from the complete polling forecast
that finished before the first poll-close cutoff:

```sh
bin/kamal app exec --reuse --roles job 'bin/rails election_night:freeze'
bin/kamal app exec --reuse --roles job 'bin/rails runner "ElectionNight::SweepJob.perform_later"'
```

Do not copy a development prior or change an existing frozen prior in place.
The page stays in its waiting state until a complete sweep publishes an atomic
snapshot. Check the public snapshot's generation time, source health and actual
nonzero vote coverage; a working HTTP response alone does not prove the provider
has newer counts. Election-night results do not write the polling forecasts or
start newsroom/email publication.

To stop automatic collection, remove the worker's election-night flag and
redeploy that role. Retained snapshots remain visible with their age. The
pre-preview production release `54593ee45f7c96cb19cf3f4136182223b97ee643`
is the rollback target for a failed launch; use `bin/kamal rollback VERSION`
while that image is retained on the server.

## First-boot / rebuild checklist

1. `bin/kamal setup` (installs docker on the host, boots Postgres, deploys).
2. Seed the world: `bin/kamal app exec 'bin/rails pol:seed_races pol:scrape pol:model'`, then
   `bin/kamal app exec 'bin/rails pol:seed_boundaries'`. Boundaries come from the Census
   Bureau and must not block polls and the model on first boot if Census is down.
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

The canonical site is https://535.wtf. Cloudflare has a proxied apex A record
pointing at `68.183.55.31` and `www` aliases the apex. Keep the zone's SSL/TLS
mode at **Full (strict)**: kamal-proxy owns the valid Let's Encrypt origin
certificate, while Cloudflare terminates the public connection. Kamal accepts
`535.wtf`, `www.535.wtf` and the legacy `535.appmakey.com`; Rails permanently
redirects the latter two to the same path on the apex. `assume_ssl`/`force_ssl`
are on, with `/up` excluded so the proxy's internal health check stays valid.

## RailsMind workflow pilot

The native Action Mailer pilot is the subscription-preferences request:
`SubscriptionPreferencesController#create` queues `SubscriberMailer.manage`.
The SDK links the request, enqueue, job start, mail rendering and delivery
attempt by trace and job ID. Attempt completion does not establish recipient
delivery. Mail content, addresses and unsubscribe tokens are excluded.

`test/integration/rails_mind_workflow_test.rb` validates that path with a
synthetic subscriber, memory collector and test-only mail delivery. Use an
isolated PostgreSQL database through `POL_TEST_DATABASE`; no production data or
mail sends are needed. Existing SDK credentials and platform revision detection
remain unchanged.

Dispatch newsletters are different: `SendDispatchEmailJob` renders
`DispatchMailer` and calls the Resend HTTP API directly. SDK render/job events
must not be interpreted as Action Mailer delivery attempts. The pilot test pins
that distinction. Existing signed provider webhooks remain the authority for
newsletter delivery state.

## Dispatch email

Subscribers and per-recipient delivery state live in Postgres. Creating a new
published `Dispatch` queues `DispatchEmailFanoutJob`, which snapshots active
subscribers and queues one idempotent Resend API request per delivery. Existing
dispatches, edits and retractions do not start a mailing. Bounces, complaints,
suppression and delivery state arrive through the signed
`POST /webhooks/resend` endpoint.

Email has its own production kill switch:

```yaml
DISPATCH_EMAILS_ENABLED: "true"
```

This was enabled only after the Resend domain, production API delivery and
signed sent/delivered webhooks passed a live smoke test. Set it back to
`"false"` for an immediate mailing kill switch; this does not affect the
newsroom's separate `agents_enabled` switch.

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

## The poll feed, and the Wikipedia fallback

The NYT poll CSVs are the corpus (see
docs/superpowers/specs/2026-08-31-nyt-poll-feed-design.md). `pol_nyt_sync`
fetches them hourly; the first run in a fresh environment IS the backfill
(`bin/rails pol:nyt_sync` runs one by hand). The Wikipedia sweep survives as
a weekly dry canary — it parses every page and records scrape_runs so
layout-rot alarms stay proven, but writes no polls.

Re-arming the fallback (if the Times moves or stops the files):

1. `scrape.write_enabled: true` in config/model_params.yml.
2. Restore a frequent `pol_scrape` cron in config/initializers/good_job.rb
   (it was `0 */2 * * *` when Wikipedia was the corpus).
3. Decide what `Poll.model_corpus` should read — scraped rows are excluded
   there by design, so a real switch-back also means widening that scope
   deliberately, not just re-enabling writes.
4. Deploy.

## Maps

Every map is drawn at render time from the `boundaries` table, which
`bin/rails pol:seed_boundaries` fills from the Census Bureau's TIGERweb API
(shoreline-clipped state outlines, and the congressional district lines in
effect for the cycle). No boundary data is in the repository or the image.
Until it has run, pages render without maps. Run it once per environment:

    bin/kamal app exec 'bin/rails pol:seed_boundaries'

Re-run it only if the Census corrects the lines (a court-ordered redraw) or
for a new cycle, which moves the derived Congress number. If TIGERweb has not
yet published that Congress's layer, the task fails loudly and the existing
boundaries stay.

## Costs

Droplet $12/mo + droplet backups ~$2.40/mo + registry $0 + Let's Encrypt $0.
OpenRouter spend is usage-based and gated by the newsroom toggle + its
per-race/per-day caps.
