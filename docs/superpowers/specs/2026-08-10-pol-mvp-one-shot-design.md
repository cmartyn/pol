# pol MVP — One-Shot Build Prompt

**Status:** Design approved by Chase 2026-08-10; this document is the deliverable.
**How to use:** Start a fresh Claude Code session in `~/sites/pol` and paste everything below the horizontal rule as your first message. The prompt is self-contained — it does not depend on the session that produced it.

---

# Build "pol": an agent-powered 2026 midterms forecast site (MVP)

## Mission and context

You are building the MVP of a political prediction site in the tradition of FiveThirtyEight, Decision Desk HQ, and Nate Cohn's NYT work — but powered by an autonomous agent newsroom with light human editorial oversight.

The editor (Chase) is a former political journalist and high-level political analytics professional. The site's editorial identity is **epistemic humility**: we claim no secret sauce beyond what pollsters and history can tell us. Every number must be traceable to a documented, public methodology; every claim must cite data that exists in our database. Sophistication is welcome; opacity is not.

**Coverage:** the November 3, 2026 midterms — every 2026 Senate race (33 Class 2 seats plus the special elections; verify the exact list) and the House (a generic-ballot-driven national seat model with a page for all 435 districts).

**Centerpiece artifacts:** per-race win probabilities, seat-distribution histograms, chamber-control odds, and autonomously published written dispatches.

**Repo state:** a pristine, uncommitted Rails 8.1.3 skeleton (Ruby per `.ruby-version`, PostgreSQL, importmap, Hotwire, Tailwind via tailwindcss-rails, Propshaft, minitest). Kamal config exists — leave it alone. There are zero commits.

## Non-negotiable decisions (already made — do not relitigate)

1. **All LLM calls go through the `ruby_llm` gem configured for OpenRouter.** Never call a provider SDK directly. Model slugs are config values, not code, so models/providers can be swapped by editing one string.
2. **Secrets live in Rails credentials**, read as `Rails.application.credentials.openrouter_api_key || ENV["OPENROUTER_API_KEY"]`. The key already exists as the top-level credential `openrouter_api_key` — verify its presence (never print it, never run `credentials:edit`).
3. **Background and scheduled jobs use `good_job`** (Postgres-backed, cron built in). No Redis, no Solid Queue, no extra services. Postgres is the only infrastructure.
4. **Charts are a per-chart engineering choice: D3 pinned through importmap (vendored, no Node build step) or hand-rolled server-rendered SVG — whichever genuinely serves that chart.** Wrap any JS charts in Stimulus controllers. Nothing clunky or old either way.
5. **Live data comes from Wikipedia scrapers** with full provenance (source URL stored on every poll). No hand-entered data, no fabricated data, ever.
6. **Agents publish autonomously** — no approval queue. Safety comes from data-grounding validation, publication caps, a kill switch, and admin edit/retract.
7. **Forecasts come from a correlated Monte Carlo simulation** (shared national error + per-race error). Independent per-race probabilities are not acceptable — correlated polling error is the whole story of seat-total uncertainty.
8. **Every model constant lives in `config/model_params.yml`**, and the public methodology page renders from that same file. The methodology can never drift from the code.
9. **Deployment is out of scope.** Don't touch Kamal config, don't add deploy tooling. Keep the app 12-factor clean (works with `DATABASE_URL`, `RAILS_MASTER_KEY`) so DigitalOcean App Platform remains an easy target later.

## How to work

**Phases and commits.** Work in the eight phases below, strictly in order. A phase is done when its tests pass, `bin/rubocop` is clean, and you've made one commit for it. Commit the pristine skeleton first, before any changes.

**Subagents.** Use subagents aggressively for parallelizable work within a phase, and match model to difficulty: Opus-tier for the scraper parsers, the forecast engine, and the newsroom service; Sonnet-tier for scaffolding, views, admin CRUD, and test boilerplate. You (the main loop) are the orchestrator and verifier: brief subagents precisely, then run their tests yourself before accepting anything. Never take a subagent's word that something works.

**Verify facts at build time — never from memory.** You have web access; use it. Before writing code that depends on them, verify and record in `docs/BUILD_NOTES.md` (with source URLs):

- The exact 2026 Senate race list, including special elections (Florida and Ohio are expected — verify), and each race's incumbent, candidates (post-primary where primaries have happened), and party.
- Current Senate composition and the party split of **holdover seats not up in 2026** (needed for control math).
- The 2024 national House popular-vote margin (expected ≈ R+2.6 — verify), and 2024/2020 presidential national margins (needed for state leans).
- Exact Wikipedia page titles: the 2026 Senate elections overview, per-state race pages ("2026 United States Senate election in {State}" pattern), the generic-ballot polling page ("Nationwide opinion polling for the 2026 United States House of Representatives elections" pattern), and the 2024 House results-by-district source.
- Current OpenRouter model slugs via `GET https://openrouter.ai/api/v1/models` (don't guess slugs).
- Current `ruby_llm` API (OpenRouter provider config, structured-output/schema support), `good_job` cron + timezone syntax, and the importmap pin workflow for D3.

**When something defeats you** (a table format you can't parse, a page that moved): degrade gracefully — log it, build the fixture-based parser for what you can, note it in `docs/BUILD_NOTES.md`, and continue. Never substitute invented data to make a phase "pass."

**House rules:** minitest + fixtures (no RSpec, no FactoryBot); rubocop-rails-omakase as configured; no new services; no Node/esbuild; stub all LLM and HTTP calls in tests (WebMock); keep test runtime sane.

## Phase 0 — Skeleton commit and foundations

- Commit the untouched Rails skeleton before changing anything (a docs-only commit may already exist — that's fine).
- Add gems: `good_job`, `ruby_llm`, `nokogiri` (explicit), `webmock` (test). Uncomment `bcrypt`. Install and configure GoodJob (migrations, `:good_job` adapter, cron enabled in an initializer, dashboard engine mounted later behind admin auth).
- Run the Rails 8.1 authentication generator (single-editor auth; remove/disable any public registration path).
- Create `config/model_params.yml` (full parameter set in the Forecast Model spec below) and a small loader (`Pol::Params`) with typed access.
- Create a `settings` key-value table for runtime toggles; `Setting.agents_enabled?` defaults **true** (the key exists; the editorial posture is tune-in-production), and `ENV["AGENTS_DISABLED"]` forces false regardless.
- `bin/setup` works end to end.

## Phase 1 — Domain model

Tables (add sensible indexes and FK constraints; enums as integer enums with string-y scopes):

- `races` — office enum (`senate`, `house`, `governor` — governor unused but schema-ready), state, district (null for senate), cycle (2026), seat_class/special flag, slug, incumbent name + party, `baseline_margin` (2024 D−R for House districts; null for Senate), `baseline_source_url`, `baseline_imputed` boolean, `lean` (state partisan lean for Senate), uncontested flag + party.
- `candidates` — race, name, party (`dem`, `rep`, `ind`, `other` + caucus_with for independents), incumbent flag.
- `pollsters` — name, canonical slug (dedup key).
- `polls` — pollster, race (nullable; null = generic ballot), field start/end dates, sample_size, population (`lv`, `rv`, `a`, `unknown`), sponsor, `source_url` (required), `dedup_digest` (unique; digest of pollster + dates + race + numbers), `entry_mode` (`scraped`, `manual`, `csv`).
- `poll_results` — poll, candidate (nullable for generic ballot), party, pct.
- `model_runs` — started/finished, status, `params_snapshot` (jsonb), `rng_seed` (persisted so every published run is reproducible), trigger (`ingest`, `manual`, `cron`).
- `forecasts` — model_run, race, win probabilities by party, mean/percentile margins (jsonb), effective poll weight used.
- `chamber_forecasts` — model_run, chamber, control probabilities, seat histogram (jsonb), mean seats.
- `dispatches` — race (nullable for national), kind (`poll_reaction`, `movement_note`, `daily_brief`), headline, dek, body_markdown, `cited_poll_ids` (jsonb), model_run, `model_slug` (which LLM wrote it), status (`published`, `retracted`), published_at, edited_at.
- `scrape_runs` — source, status, counts (fetched/new/duplicate), error text, started/finished (feeds the health dashboard).

Golden model tests for validations, the dedup digest, and settings toggles.

## Phase 2 — Ingestion (Wikipedia, provenance-first)

- Fetch via Wikipedia's REST HTML endpoint (`https://en.wikipedia.org/api/rest_v1/page/html/{title}`), with a descriptive User-Agent including a contact email per Wikimedia policy, timeouts, retry-with-backoff, and polite pacing.
- **Seed task (`bin/rails pol:seed_races`):** scrape the 2026 Senate overview for the race/candidate list (cross-check against your verified list); scrape 2024 House results-by-district for every district's `baseline_margin` + source URL. Districts uncontested in 2024 get an imputed baseline (documented default from `model_params.yml`), flagged `baseline_imputed` — keep imputations ≤ ~15% of districts and list them in BUILD_NOTES.
- **Poll scraper (`bin/rails pol:scrape`):** parse polling tables from each Senate race page and the generic-ballot page. Extract pollster, dates, sample size, population, results, and the page URL + row provenance. Dedup via digest. Unparseable rows → logged and skipped, never guessed; each source's outcome recorded in `scrape_runs`.
- **Parsers are built against saved fixtures:** during the build, save real fetched HTML for at least 4 representative Senate pages + the generic-ballot page into `test/fixtures/files/`, and write parser tests against them (including a malformed-table case).
- Schedule: scrape every 2 hours via GoodJob cron; a model run is enqueued automatically when a scrape lands ≥1 new poll.
- CSV import + manual entry land in Phase 6 (admin), but design the ingestion service so all three entry modes converge on one code path.

## Phase 3 — Forecast engine

Pure-Ruby service objects (no gems needed); every constant below comes from `config/model_params.yml`. Margins are **Democratic minus Republican, in percentage points**, throughout.

**Polling average (per race, and nationally for the generic ballot):**
- Consider polls with field-end within `window_days` (45). If a race has fewer than 2 such polls, widen to `extended_window_days` (120).
- One poll per pollster: the most recent by field-end date.
- Weight = `exp(−ln(2) × age_days / half_life_days)` × `sqrt(min(n, 1500) / 600)`, with `half_life_days: 14`; unknown sample size → n = 400. No population adjustment and no house effects in v1 — the methodology page says so plainly.
- Average margin = weighted mean of (top Dem − top Rep). Effective poll weight `W` = sum of weights (drives the blend below).

**Senate race mean (`mu`):**
- Fundamentals prior = `state_lean_rel + national_env + incumbency_adj × incumbent_direction`, where `state_lean_rel` = mean of (state pres margin − national pres margin) across 2024 and 2020; `national_env` = current generic-ballot average; `incumbency_adj: 1.5`; `incumbent_direction` = +1 when a Democratic incumbent is running, −1 for a Republican incumbent, 0 for open seats.
- Blend: `w = min(1, W / weight_saturation)` with `weight_saturation: 3.0`; `mu = w × polling_avg + (1 − w) × prior`.

**House district mean:** `mu_d = baseline_margin_2024 + national_swing + open_seat_adj`, where `national_swing = national_env − house_national_margin_2024` (that 2024 figure verified and stored in the YAML with its citation), and `open_seat_adj: 1.5` applies against the vacating party (−1.5 when a Dem-held seat is open, +1.5 when a Rep-held seat is open, 0 when the incumbent runs). Where genuine district polls exist, blend them in with the same `w` formula. Uncontested 2026 races: probability 1/0, excluded from noise.

**Simulation (single coherent world per draw):**
- Per sim: draw one shared national error `N ~ Normal(0, sigma_national)`; each Senate race margin = `mu + N + Normal(0, sigma_state)`; each House district margin = `mu_d + N + Normal(0, sigma_district)`. The same `N` hits both chambers — one national environment per simulated world.
- Sigmas (election-day-equivalent, on the margin scale): `sigma_national: 2.5`; `sigma_state_polled: 3.5`; `sigma_state_unpolled: 8.0`; `sigma_district: 6.0`. Time multiplier on all sigmas: `1 + days_to_election / 180`, capped at 1.75. **Sanity-check these against published polling-error research (e.g., FiveThirtyEight's pollster-error analyses) and record citations in the YAML `citation:` fields; tune within reason if the literature clearly disagrees.**
- `n_sims: 10_000`. RNG seeded per run and stored on `model_runs` (tests use a fixed seed; production uses a random stored seed).
- Outputs per run: per-race win probs + margin percentiles (5/25/50/75/95); House seat histogram + `P(D ≥ 218)`; Senate seats-up outcomes combined with verified holdovers → `P(each party controls)`, counting the VP tiebreak for whichever party holds the vice presidency (verify: Republican). Same-party and independent candidates handled explicitly (caucus mapping decides chamber tallies).
- Full run must complete in < 60 seconds. `bin/rails pol:model` triggers manually.

**Engine tests:** averaging and blend math verified against hand-computed golden values; a fixed-seed full simulation asserting stable win probabilities and seat histograms (so any future formula change shows up as a diff, not a mystery).

**Methodology page:** renders every parameter, formula description, and citation directly from `model_params.yml` + a prose partial. If a param isn't on the page, it doesn't exist.

## Phase 4 — Public site

Hotwire + Tailwind, server-rendered, fragment-cached where hot. No SPA. Charts are a per-chart choice on merit: D3 (importmap-pinned, vendored) inside Stimulus controllers reading inline `<script type="application/json">` payloads, or server-rendered SVG partials.

- `/` — national dashboard: both chambers' control odds, seat histograms, biggest probability movers this week, latest dispatches.
- `/senate` — sortable table of all races: win prob, average margin, poll count, sparkline.
- `/house` — seat model summary + histogram; searchable/sortable 435-district table (prob, baseline, imputed flag).
- `/races/:slug` — probability timeline chart (from forecast history), polls scatter with average overlay, full poll table (every row links to its source URL), dispatch feed.
- `/dispatches` — reverse-chron feed; each shows its byline: "Written autonomously by {model_slug}" plus "Updated by the editor" when `edited_at` is set.
- `/methodology`, `/about`.
- Design: clean, typographically confident, data-forward; sensible empty states everywhere (races with no polls say so honestly). Light mode only.

## Phase 5 — Agent newsroom

- `RubyLLM` configured for OpenRouter in an initializer; API key from `Rails.application.credentials.openrouter_api_key` with ENV fallback (`OPENROUTER_API_KEY`). **If the key is somehow absent, every agent job logs a skip and exits cleanly — the site must still build, test, and run.**
- Model slugs in `model_params.yml` (`writer_model`, `brief_model`) — default both to the current Anthropic Sonnet-tier slug you verified from the OpenRouter models list; they're one-string swappable by design.
- One `Newsroom::Writer` service: input is a structured JSON context assembled **only from the database** — race + candidates, the new polls (ids, pollster, dates, n, results, source URLs), current and prior forecast numbers, national context, recent dispatch headlines (to avoid repetition), and a style guide (sober, numerate, AP-adjacent; uncertainty stated plainly; every number attributed; no predictions beyond model outputs; no invented quotes or reporting).
- Output via ruby_llm's structured-output/schema mechanism: `{headline ≤90 chars, dek ≤200, body_markdown ≤450 words, cited_poll_ids}`. Validation: `cited_poll_ids ⊆ provided poll ids`, length caps enforced. One retry with the validation error appended; a second failure logs and skips — **nothing invalid ever publishes.**
- Triggers: (a) ingest lands new polls on a race → `poll_reaction`, capped at `max_dispatches_per_race_per_day: 3`; (b) win prob moves ≥ `movement_threshold: 0.08` within 7 days → `movement_note`, max 1/race/week; (c) `daily_brief` at 7:00 America/New_York via GoodJob cron (national picture: control odds, movers, notable polls). Global cap `max_dispatches_per_day: 40`.
- Every publish records `model_slug` and `model_run_id`. Kill switch honored at job start (`Setting.agents_enabled?`).
- Tests stub ruby_llm/HTTP (WebMock fixtures for valid, invalid-schema, and over-cite responses).

## Phase 6 — Admin

`/admin` (auth required; seed one editor: email from credentials `admin.email` or `cmartyn@gmail.com`, password from credentials/`ADMIN_PASSWORD` or generated-and-printed once at seed time):

- Polls: CRUD, CSV import (same ingestion path as the scraper), per-poll provenance display.
- Scraper health: `scrape_runs` list with errors and counts.
- Model runs: history, params snapshot diffs, manual "run model now."
- Dispatches: edit (sets `edited_at`), retract, view validation logs of skipped generations.
- Race metadata: edit candidates, leans, baselines, uncontested flags.
- Agents kill switch toggle; GoodJob dashboard mounted here behind the same auth.

## Phase 7 — Hardening and acceptance

- End-to-end system test: fixture poll ingested → model run → (stubbed) agent publishes a dispatch → homepage shows the new numbers and dispatch.
- Run the full acceptance checklist below; fix anything failing.
- Rewrite `README.md`: what this is, setup, the three rake tasks, credentials needed, where the methodology lives.
- `brakeman` and `bundle audit` clean (no high-confidence findings); final commit; clean working tree.

## Acceptance criteria (the contract)

1. `bin/setup` succeeds on a machine with Postgres running; `bin/dev` boots the site.
2. Full test suite green; `bin/rubocop` clean; LLM/HTTP fully stubbed in tests.
3. `pol:seed_races` produces every 2026 Senate race (incl. verified specials) and 435 House districts with sourced or explicitly-flagged-imputed baselines (imputed ≤ ~15%).
4. `pol:scrape` (live) ingests ≥ 10 real, distinct 2026 Senate polls and ≥ 5 generic-ballot polls, each with a working `source_url` — if reality genuinely offers fewer as of run date, document the evidence in BUILD_NOTES instead of inventing.
5. `pol:model` finishes < 60s; every race has a forecast; probabilities are sane (sum ≈ 1 per race; Senate seat tallies + holdovers = 100; House histogram sums to n_sims).
6. With no OpenRouter key configured, agent jobs skip gracefully and everything else works.
7. All public pages render without error (spot-check ≥ 5 race pages including an unpolled one); admin is auth-gated.
8. The methodology page displays every `model_params.yml` parameter with its citation.
9. One commit per phase, descriptive messages, clean tree at the end.
10. `docs/BUILD_NOTES.md` records every verified fact (with URLs), every deviation, and every known limitation.

## Out of scope — do not build

Governor races (schema supports them; nothing else), pollster ratings/house effects, dark mode, a congressional district map (a D3 Senate state map is an optional stretch **only after** all acceptance criteria pass), district-level poll scrapers beyond what the race pages already provide, backtesting, comments, newsletters, RSS, SEO/social cards, multi-user roles, and any deployment work.

## When you finish

Print a handoff summary for Chase: (1) confirmation the existing `openrouter_api_key` credential was detected (plus the optional `admin` credentials block Chase can add later), (2) how to flip the agents kill switch, (3) the three rake tasks and the cron cadence now active, (4) anything in BUILD_NOTES that needs an editorial decision — e.g., baseline imputations or candidate-list judgment calls.
