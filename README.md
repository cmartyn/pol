# pol

**pol** is a forecast of the 2026 U.S. midterms — all 35 Senate races and all
435 House districts — that writes about itself. Polls are scraped from
Wikipedia every two hours, a correlated Monte Carlo model turns them into win
probabilities and seat distributions, and an agent newsroom publishes short
pieces about what changed: a reaction when new polls land on a race, a note
when a race moves, a national brief every morning. Nothing waits in an
editorial queue. What keeps that safe is not the model's good manners but the
code around it — a context payload built only from our own tables, validation
of every draft on our side, per-race and per-day caps, a kill switch, and a
recorded reason for every piece the newsroom decided against.

The thesis is that there is **no secret sauce**. Every constant the model uses
lives in one file, `config/model_params.yml`, and every one of them is on the
public [`/methodology`](#the-site) page next to the source that justified it.
The polling is public. The historical baselines are public. The simulation is
a few hundred lines. What is actually hard is doing the boring parts honestly:
deduplicating polls, keeping the House caveat attached to the House number
wherever it is printed, refusing to publish a sentence the payload cannot
support. Where this model is worse than a professional one, the limitation is
written down — on the methodology page, in `docs/BUILD_NOTES.md`, and in the
prose the newsroom is instructed to write.

## Quickstart

Requires **Ruby 4.0.2** (see `.ruby-version`) and a running **PostgreSQL**.
Nothing else — no Redis, no Node.

```bash
bin/setup      # bundle, db:prepare, clear logs/tmp, then start the dev server
bin/dev        # or just this, if setup has already run
```

`bin/setup` is non-destructive: it uses `db:prepare`, which creates the
database only if it is missing and otherwise just runs pending migrations. It
resets nothing unless you pass `--reset` explicitly. `bin/setup --skip-server`
does everything except start the server.

`bin/dev` runs Puma and the Tailwind watcher through `Procfile.dev`, and in
development the job worker runs in-process, so there is nothing else to start.

An empty database gives you an empty site. To fill it:

```bash
bin/rails pol:seed_races   # the race board
bin/rails pol:scrape       # polls
bin/rails pol:model        # a forecast
```

Run the tests with `bin/rails test` (fast, no network at all), the end-to-end
browser test with `bin/rails test:system` (needs Chrome), and everything —
setup, style, three security scanners, both suites — with `bin/ci`.

## Rake tasks

| Task | What it does |
|---|---|
| `bin/rails pol:seed_races` | Builds the board: 35 Senate races from a verified list (33 regular + 2 specials), 435 House districts with their 2024 margins, and each state's presidential lean. Idempotent — **re-run it after primaries settle** to pick up nominees. Prints a summary, including which districts got an imputed baseline. |
| `bin/rails pol:scrape` | One polite sweep of all 36 Wikipedia sources (35 Senate pages + the generic ballot), ingesting anything new. Prints a per-source table of rows seen / new / duplicate / skipped. New polls queue a forecast run, which in turn wakes the newsroom. |
| `bin/rails pol:model` | Runs the model once and prints the headline numbers: the generic-ballot average, both chambers' control probabilities and mean seats, the House caveat, and the biggest movers against the previous run. Takes about two seconds. |
| `bin/rails pol:brief` | Writes today's national brief immediately — the same code path the 07:00 cron uses. Prints the piece, or the reason nothing was written. **Spends money** (one OpenRouter call). |
| `bin/rails pol:refresh_fixtures` | Build-time only: re-downloads the trimmed Wikipedia HTML the parser tests run against. |

## Background jobs

[GoodJob](https://github.com/bensheldon/good_job) on Postgres — no Redis, no
separate queue service. In development the executor runs inside the web
process. In production, run a worker of your own:

```bash
bundle exec good_job start
```

Three cron entries, defined in `config/initializers/good_job.rb`:

| Job | Schedule | Why |
|---|---|---|
| `Ingest::ScrapeAllJob` | every 2 hours (`0 */2 * * *`, server time) | The cadence is read from `scrape.cadence_hours` in `config/model_params.yml`. |
| `Forecast::RunJob` | **06:30 America/New_York** | New polls already trigger a run; this is the floor, so a day with no polling still gets fresh numbers instead of an ageing "as of". |
| `Newsroom::DailyBriefJob` | **07:00 America/New_York** | Half an hour after the model run, so the morning brief always has same-day numbers. |

Both daily entries carry an explicit timezone (fugit's sixth cron field), so a
deploy to a UTC box does not move the morning brief to the middle of the night.
The queue dashboard is at `/admin/good_job`.

## Credentials

| Key | Required? | Fallback |
|---|---|---|
| `openrouter_api_key` | Only for the newsroom | `ENV["OPENROUTER_API_KEY"]` |
| `admin.email` | No | `ENV` is not consulted; defaults to the maintainer's address in `db/seeds.rb` |
| `admin.password` | No | `ENV["ADMIN_PASSWORD"]`, else a generated one printed once |

Edit them with `bin/rails credentials:edit`.

**The app boots without any of this.** A checkout with no `config/master.key`
starts normally, serves every public page, scrapes, and runs the model; the
credentials store simply reads as empty. Only the newsroom notices: with no key
it publishes nothing, makes no HTTP request, and records a `no_api_key` row in
the skip log for each piece it would have written. That is why the ENV fallback
exists — a container with no master key is a supported way to run this.

## The admin

`/admin`, gated by the same session for every page under it, including the job
dashboard. There is no sign-up: `db/seeds.rb` creates exactly one editor
account, and if any user already exists it does nothing at all. On the run that
creates the account it prints a generated password **once** unless you supplied
one.

Inside: the dashboard, polls (manual entry, CSV import, edit, delete), scrape
runs and model runs (each with a *Run … now* button), dispatches (edit, and
**retract** — the lever for pulling a published piece), the newsroom skip log
(why the newsroom stayed quiet), races and candidates, settings, and jobs.

Settings holds the **kill switch**. `agents_enabled` defaults to on; turning it
off stops the newsroom writing anything, per piece, with a skip row recorded so
the silence is visible. Setting `AGENTS_DISABLED` in the environment forces it
off regardless of the stored value, and the admin page says so rather than
offering a toggle that would not work.

## The site

- `/` — both chambers, the national environment, movers, the latest dispatches
- `/senate`, `/house` — every race, sortable and searchable
- `/races/:slug` — one race: forecast, probability over time, every poll, and
  what the newsroom has said about it
- `/dispatches` — everything the newsroom has published
- `/methodology` — every parameter with its citation, the formulas in prose,
  and a list of what this model gets wrong
- `/about` — the thesis and how to get in touch

## Methodology and build notes

The short version is `/methodology`. The parameters themselves are
`config/model_params.yml` — if a number is not in that file, it is not in the
model. The long version is [`docs/BUILD_NOTES.md`](docs/BUILD_NOTES.md): a
section per build phase recording every real-world fact with the URL it was
verified against, every decision where the design admitted more than one
reading, and the live runs that proved each phase worked.

## Current limitations

The one that matters most: the simulation draws correlated error at three
levels — national, census division, and state — plus each race's own, which is
four of the five components 538's published House model uses. The one missing
is their demographic-cluster term, which correlates districts that resemble
each other regardless of where they are and needs a clustering of all 435 that
we have no data for; our correlated total is 4.12 against their 4.58. Measured
on the live board, adding a fifth component of 2 points moves House control
from 93% to somewhere between 93% and 90% depending on how broadly it is
assumed to correlate, so both control figures are a point or two firmer than a
fuller model's, in whichever direction they lean. That note travels with the
number everywhere it is printed, including into the newsroom's prompt. Beyond
it: there are no pollster quality weights, district baselines are 2024 results
and go stale where a state has since redistricted, 37 districts have imputed
baselines because a major party did not field a candidate in 2024, about ten
Senate nominations were unsettled when the board was seeded, and the model has
no idea which party currently controls either chamber — which is why the
newsroom writes about *winning* control and never about holding it.

## Deploy posture

Nothing is deployed, and deployment is deliberately out of scope for this
build. The app is 12-factor-ready: Postgres via `DATABASE_URL`, secrets via
credentials or environment, one web process plus one `good_job` worker, no
local state, `/up` as a health check. DigitalOcean's App Platform is the likely
target. The `Dockerfile`, `.kamal/` and `config/deploy.yml` are Rails
generator output, present and unused — treat them as a starting point rather
than as a tested configuration.
