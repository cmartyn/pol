# NYT poll feed — source migration, internals toggle, dual-variant forecast

The site's polls have come from 69 Wikipedia pages parsed by a Nokogiri pipeline.
This design replaces that feed with the New York Times polling database — the
continuation of FiveThirtyEight's polls dataset, published as two CSVs
(`https://www.nytimes.com/newsgraphics/polls/senate.csv`, `.../house.csv`) —
and uses the partisan-sponsorship metadata it carries to ship a user-facing
toggle: include or exclude flagged internal polls, across the whole site,
forecast included.

## Why

An August 2026 audit of both sources found the NYT feed a near-superset of the
Wikipedia corpus. Wikipedia's misses are systematic, not random: partisan and
PAC-sponsored polls (the entire gap in six of seven missing House districts),
races pruned or thinly tended by editors (Maine's Senate page carried 6 of 31
known general-election polls), and whole sources we never swept (Maryland).
Wikipedia's failure mode is silent — a poll never appears, or quietly
disappears. The CSV's failure mode is loud — a 404 or a schema break the
fetcher sees immediately. For a forecast whose whole premise is "just polls and
history," the poll feed is the product; it should ride on the loud-failing,
flagged, better-covered source.

What Wikipedia still does better stays on Wikipedia: candidate rosters, race
metadata, 2024 results baselines, presidential leans. Only poll ingestion moves.

## Approved decisions

- **Clean re-import.** The NYT CSVs become the poll corpus for the 2026 cycle.
  Wikipedia-scraped rows stay in the table for provenance but leave the model.
  The single-digit residue of genuinely Wikipedia-only polls re-enters by the
  existing manual mode if wanted.
- **Site-wide internals toggle, default OFF.** Every published number — race
  averages, seat distributions, win probabilities — exists in two variants:
  `excl_internals` (the default everywhere) and `incl_internals`. Flipping the
  toggle opts a reader into the internals view.
- **Internals enter adjusted, not raw.** When included, a flagged poll's margin
  is shifted toward the non-sponsor party by an empirically estimated
  adjustment (prior ~3 points) and its weight is reduced. The "on" view is our
  best estimate including internals, not a naive average.
- **One run, variant as an output dimension (option C).** A single
  `Forecast::RunJob` computes both variants from the same poll snapshot and
  writes both under one `model_run`. The toggle always compares forecasts built
  from identical inputs; there is no half-published state.
- **Newsroom and dispatches narrate the default variant** (`excl_internals`)
  only.

## The source contract (as observed 2026-08-31)

One CSV row per candidate-answer per question; a poll (`poll_id`) asks one or
more questions (`question_id`), each a matchup. Fields we consume: pollster
(+`pollster_id`), `sponsors`, `partisan` (DEM/REP/IND/OTH/blank), `methodology`
(~50% populated), `state`, `seat_number`, `office_type`, `start_date`/`end_date`
(m/d/yy), `sample_size` (~98%), `population` (lv/rv/a), `subpopulation`
(blank = full sample; `d`/`r` = party subsamples), `cycle`, `stage`
(general/primary/…), `party` per answer (DEM/REP/IND/LIB/GRE/…/NONE),
`candidate_name`, `pct`, ranked-choice columns (`ranked_choice_round`,
`ranked_choice_final` — AK/ME), `url`.

Observed invariants the design relies on:

- No `question_id` ever mixes populations → `nyt_question_id` is a sufficient
  unique key for a poll row at our grain.
- `party=NONE` rows are non-candidate answers (Don't know / Someone else /
  Would not vote) — skipped.
- Generic congressional ballot lives in `house.csv` as `state == "US"`.
- Louisiana needs no special case: LA moved to closed congressional primaries
  for 2026, so its `stage=general` rows mean what they mean everywhere else.
- The 538 rating columns (`numeric_grade`, `pollscore`, `transparency_score`)
  are present but 100% empty. Nothing may depend on them.

Risks: the files carry no published license and no API contract. Mitigations:
snapshot every changed fetch (below), keep the Wikipedia scraper warm (below),
attribute the Times on the site's sources/methodology page.

## Phase A — Data layer

### Schema (one migration)

- `polls`: add `partisan` integer enum (`none: 0, dem: 1, rep: 2, ind: 3,
  oth: 4`, default 0, null false), `methodology` string (nullable),
  `nyt_poll_id` string (indexed, nullable), `nyt_question_id` string (unique
  index, nullable). `entry_mode` enum gains `nyt: 3`.
- `pollsters`: add `nyt_pollster_id` string (unique index, nullable). Once a
  pollster carries the NYT id, lookups go by id first, `canonicalize(name)`
  second — name drift can never split a pollster again.
- `forecasts`: add `variant` integer enum (`excl_internals: 0,
  incl_internals: 1`, default 0, null false). Unique index becomes
  `(model_run_id, race_id, variant)`.
- `chamber_forecasts`: same `variant` column; unique index becomes
  `(model_run_id, chamber, variant)`.
- New table `feed_snapshots`: `source` string (e.g. `senate.csv`), `digest`
  string, `body` binary (gzipped CSV), `fetched_at` datetime; unique on
  `(source, digest)`. Written only when the digest changes.
- Existing rows: all current `forecasts`/`chamber_forecasts` rows are
  `excl_internals` by default — historically true, since the Wikipedia corpus
  carried (almost) no internals.

Deliberately not columns: NYT candidate ids, RCV round detail, sponsor
candidate info — all ride in `raw_payload["nyt"]`.

### Ingestion (`app/lib/ingest/nyt/`)

Mirrors the Wikipedia client's manners: descriptive UA with contact address,
15s timeouts, 3 attempts with exponential backoff, conditional GET (ETag /
If-Modified-Since), and one `scrape_runs` row per file per sync so the
existing `refusal_alarm?` / `dark?` alarm surface carries over unchanged.

- **`Client`** — fetches one CSV; returns body + etag; raises typed errors.
- **`CsvParser`** — CSV → question groups: rows bucketed by `question_id`,
  attached to their shared poll-level fields. Encoding `bom|utf-8`.
- **`Mapper`** — one question group → `RecordPoll` arguments. Rules:
  - Keep only `stage == "general"`, `cycle == 2026` (both from
    `Ingest::Sources.cycle`), blank `subpopulation`.
  - Race lookup: `office_type "U.S. Senate"` → senate race by state. In 2026
    no state carries both a regular and a special race, so state alone
    resolves; if a future cycle breaks that, the mapper disambiguates on the
    feed's `seat_name` and refuses `ambiguous_senate_race` when it cannot.
    `"U.S. House"` + `state != "US"` → house race by state + `seat_number`;
    `state == "US"` → generic ballot (`race_id: nil`). Unknown race → refusal
    `unknown_race`, counted, never guessed.
  - Results: drop `party == "NONE"` rows. Party map: DEM→`dem`, REP→`rep`,
    IND→`ind`, all else (LIB/GRE/PSL/OTH/NPA/CON/WCP/ALL)→`other`. Where a
    party repeats (two Republicans tested), first row wins for the party
    result — same rule as the Wikipedia parser. A question with fewer than two
    parties after filtering is refused (`too_few_parties`).
  - RCV: if a question carries ranked-choice rows, use `ranked_choice_final ==
    TRUE` rows for pcts; plain rows otherwise. Round detail preserved in
    payload.
  - `matchup_key`: built from candidate name + party pairs via
    `Ingest::Matchup.key_from_parties` (new public helper reusing the same
    surname normalisation), so NYT keys agree with legacy Wikipedia keys.
  - `population`: lv/rv/a as-is, anything else `unknown`.
  - `partisan`: DEM/REP/IND→ those; OTH→`oth`; blank→`none`.
  - `sponsor`: `sponsors` field verbatim (pipe-joined already).
  - `raw_payload`: `{"columns" => {"James Talarico (D)" => "45", ...},
    "nyt" => {poll_id:, question_id:, rows: [...]}}`. The `columns` shape is
    synthesized to match the Wikipedia parser's, so `matchup_label`,
    `labels_for_poll`, and every render path work unchanged on NYT rows.
  - `source_url`: the row's `url`; falls back to the poll's NYT race page URL
    pattern, else the CSV URL.
- **`Sync`** — orchestrates: for each of the two files — fetch, snapshot if
  digest changed, parse, map, write each question through
  `Ingest::RecordPoll.call(attrs, results:, entry_mode: :nyt)`; log one
  `ScrapeRun` (`source: "nyt:senate.csv"`); finally
  `Ingest.after_new_polls!(created_ids)` exactly as the Wikipedia path does,
  so the forecast trigger and newsroom flow are untouched.
  - Dedup: `Poll.exists?(nyt_question_id:)` short-circuits before digest
    computation; the digest is computed with a new `salt:` keyword
    (`nyt_question_id`) so two distinct questions can never collide on the
    digest index. `RecordPoll` passes new attrs (`partisan`, `methodology`,
    `nyt_poll_id`, `nyt_question_id`, `salt`) through.
  - Staleness alarm: if fetches succeed but the digest has not changed in
    `feed.staleness_alarm_days` (default 3), the run is recorded `partial`
    with an explanatory message — the "did the Times move the file?" tripwire.
- **`Ingest::NytSyncJob`** — takes over the 2-hourly `pol_scrape` cron slot
  (`feed.cadence_hours`, default 2, same read-at-boot pattern and drift test
  as the scrape cadence).
- **`pol:nyt_sync` rake task** — same output conventions as `pol:scrape`; the
  first run against full files IS the backfill (idempotent thereafter).
- Gemfile: add `gem "csv"` (stdlib gem, not bundled by default since Ruby 3.4).

### Corpus policy

`Poll.model_corpus` scope: `where(entry_mode: [:nyt, :manual])`. Every model
read (averager, house effects, coverage stats) goes through it.
Wikipedia-`scraped` rows remain queryable for provenance and for diffing the
corpora, and render nowhere by default.

## Phase B — Model layer

### Internals adjustment

New forecast stage between averaging inputs and the average:

- A poll is an *internal* iff `partisan != none` (sponsor-party flag from the
  feed; the four IND/OTH-flagged polls adjust toward neither party but still
  take the weight penalty).
- **Adjustment:** shift the poll's margin `internals.prior_shift` points
  (default 3.0) toward the non-sponsor party, blended with an empirical
  estimate once the corpus can support one. The estimator: for every flagged
  poll with at least one unflagged poll of the same race and matchup whose
  field period falls within `internals.pair_window_days` (default 21), take
  (flagged margin − mean unflagged margin), signed toward the sponsor; the
  cycle-wide estimate is the recency-weighted mean of those gaps, shrunk
  toward `prior_shift` by `n / (n + internals.shrinkage_k)` — the same
  shrinkage shape house effects use. Computed once per run on the snapshot,
  recorded in `params_snapshot` for audit.
- **Down-weight:** multiply the poll's weight by
  `internals.weight_factor` (default 0.5).
- Params live in `config/model_params.yml` under two new top-level sections —
  `feed:` (`cadence_hours: 2`, `staleness_alarm_days: 3`) and `internals:`
  (`prior_shift: 3.0`, `weight_factor: 0.5`, `pair_window_days: 21`,
  `shrinkage_k`) — following the file's hard conventions: prose comments
  saying why each number is that number, `# citation:` lines where a number is
  borrowed, section at column 0 / keys at two spaces (the `/methodology`
  citation parser depends on the indentation). Both sections land in
  `params_snapshot` and the admin params diff automatically. Params do not
  vary by variant — the variant is corpus selection plus adjustment
  application, never a params fork — so `Pol::Params`' per-process
  memoisation needs no override seam.
- **House effects are estimated once per run, on the `excl_internals` corpus
  only,** and applied in both variants. Sponsor bias follows the sponsor, not
  the pollster; letting internals into the house-effect estimation would
  launder sponsor lean into a pollster's baseline correction.

### Dual-variant run

`Forecast::RunJob` unchanged in trigger and cadence. Inside
`Forecast::Runner#forecast!`:

1. One poll snapshot (`Poll.model_corpus`), one `HouseEffects.call` — computed
   from the internals-excluded polls, applied in both variants.
2. The `excl_internals` variant computes **exactly as the run computes today**
   — same averager, same race-model build in `Race…order(:id)`, same seeded
   draw order. This is a hard constraint, not an aspiration: the golden tests
   in `test/lib/forecast/runner_test.rb` pin exact values
   (`assert_in_delta … 1e-7`), and they must keep passing untouched. Variant
   machinery wraps the existing path; it does not reorder it.
3. The `incl_internals` variant then runs as a second pass — averager over the
   full corpus with internals adjusted and down-weighted, its own
   `Simulator` instance **seeded with the same `rng_seed`**. Same seed means
   identical shared-error draws, so the toggle's delta is pure input signal,
   never resampling noise — a paired comparison by construction.
4. Both variants' `forecasts` and `chamber_forecasts` rows are written under
   the one `model_run` inside the run's existing single transaction — both
   variants publish atomically or not at all. `house_effects` rows stay
   variant-less (there is one estimate per run, by design).

Cost: averaging and simulation run twice; house effects, fundamentals and the
race board load once. The run floor is 30 minutes behind the sweep, so 2× the
cheap half fits. If wall-clock says otherwise, halve the `incl_internals`
draw count — its bands are a comparison view, not the headline.

### Reading paths

There is no published flag today — display is `ModelRun.succeeded.latest` plus
the unique `(model_run_id, race_id)` lookup. That stays; a run is still one
row. Every forecast reader gains a `variant:` argument defaulting to
`:excl_internals`, so untouched call sites keep today's behaviour by
construction. The full set to thread (from the audit): `Forecast.latest_for_races`,
`Race#latest_forecast`, `Site::Movers`, `Site::SenateTable` / `Site::HouseTable`,
the chamber-card partial, `Newsroom::Context` (its `chamber_forecast` and
`Forecast.find_by` reads), and the two **live** `Forecast::Averager` call
sites (`HomeController#index`'s national environment, `Newsroom::Context`) —
which additionally must read `Poll.model_corpus` and exclude internals, since
they average polls directly rather than reading forecast rows.

## Phase C — Presentation

### Delivery

Race pages and the homepage embed chart data as inline JSON read by Stimulus
controllers (`timeline`, `polls_scatter`) — no JSON endpoints exist and none
are added. Those payload builders (`Site::Charts::*`) emit both variants under
`excl_internals` / `incl_internals` keys; the controllers select by toggle
state and keep the existing contract that the payload carries the words and
the JS only the geometry. The seat histogram is different — its SVG rects are
computed in ERB, not JS — so the partial renders **both** variants' SVGs and
the toggle swaps visibility.

No cache changes anywhere: the HTML is byte-identical for every reader
regardless of toggle state, so the fragment cache keys (all keyed on
`@latest_run`), the `CDN-Cache-Control` policy, the no-`Set-Cookie`
constraint, and the zone-wide Cloudflare rule are untouched. This is the
design's load-bearing simplification and the reason the toggle is
client-side.

### Toggle

- One site-wide control (header, near the timestamp): "Partisan internals:
  off / on", default off.
- A Stimulus controller swaps which variant feeds the D3 charts, the topline
  numbers, and the poll tables (internal polls render greyed/badged when off —
  visible but explicitly out of the math; full rows with sponsor + flag when
  on). Marked-up values carry `data-variant-*` attributes; the controller
  never recomputes statistics client-side, only swaps precomputed values.
- Persistence: `localStorage` (wrapped in try/catch), plus a `#internals=on`
  URL fragment for shareable links. A fragment, not a query param — a query
  string would double the edge cache's working set, and a cookie would break
  edge caching outright (`Set-Cookie` is what `without_csrf_token` exists to
  prevent).
- No-JS readers see the `excl_internals` markup — the server-rendered default
  state is the editorial default, by construction.
- Every internals-on view shows a one-line provenance note: what adjustment
  and weight the flagged polls carried, linking the methodology page.

### Newsroom & dispatch

Newsroom prompts and dispatch deliveries read `excl_internals` only, via the
defaulted reader path through `Newsroom::Context` — no prompt or template
changes, and the `dispatches` table needs no variant column (its
`model_run_id` FK plus the default-variant readers fully determine what a
dispatch described). `Site::Movers` and the newsroom's movement notes keep
sharing `ModelRun.comparison_run`, both on the default variant, so the site
and the newsroom still cannot disagree about "last week." A later enhancement
(newsroom noting a divergence between variants) is out of scope.

## Wikipedia fallback posture

- `Ingest::Scraper` gains `dry_run:` (parse, log `scrape_runs`, write no
  polls). The `pol_scrape` cron entry becomes weekly, dry-run — a canary that
  notices page-shape rot while the fallback stays proven.
- Re-arming the scraper is a params flip (`scrape.write_enabled`) plus
  restoring the cadence — documented in DEPLOY.md.
- Candidate roster sync (`pol_house_candidates`), `seed_races`, baselines,
  leans: unchanged, still Wikipedia.

## Testing

- **Fixtures:** trimmed real slices of both CSVs (`test/fixtures/files/
  nyt_senate_sample.csv`, `nyt_house_sample.csv`) covering: a plain general
  question, a multi-question poll, a partisan-flagged poll, an AK RCV question
  with final-round rows, subpopulation rows, `NONE` answers, third parties, a
  primary-stage poll, generic-ballot US rows, an unknown-district row.
  `pol:refresh_fixtures` learns to regenerate them from the live files.
- **Unit:** Mapper rules (stage/cycle/subpopulation filters, party mapping,
  RCV final preference, matchup-key parity with the legacy path for the same
  candidates, partisan enum, race resolution incl. specials and US rows).
  Parser grouping. Digest salting (two questions, same toplines, distinct
  digests).
- **Integration:** Sync against webmock'd CSVs — created/duplicate/refused
  counts, snapshot-on-change only, staleness alarm, `after_new_polls!` fired
  with created ids, idempotent second run.
- **Forecast:** the existing golden tests (`runner_test.rb`'s pinned exact
  values and seed-reproducibility assertions) pass **unmodified** — the proof
  that the `excl_internals` path is numerically untouched. The fixture world
  contains no partisan polls, so a new golden asserts the two variants are
  exactly equal there; a `create_poll(partisan: :dem)` factory extension then
  drives the divergence tests: one run writes 2× race forecasts + 2× chamber
  rows atomically, variants differ only where internals exist, house effects
  identical across variants, defaulted readers return `excl_internals`, params
  snapshot records the estimated shift.
- **System:** toggle flips numbers on a race page; localStorage + fragment
  persistence; internals rows badge correctly in both states.
- The existing cadence-drift test pattern extends to `feed.cadence_hours`.

## Rollout

1. **Spike (local):** migration + ingester + backfill against the real CSVs on
   a production-shaped local DB; verify corpus deltas (Maine 6→31,
   partisan counts, MD-01 appears, generic parity) before any forecast work.
2. Model layer (adjustment + dual variant) behind the defaulted readers —
   site renders identically until the toggle ships.
3. Toggle UI + methodology page note.
4. Production: deploy, run backfill task, watch one 2-hourly cycle's
   `scrape_runs`, then flip `pol_scrape` to weekly dry-run.
5. Wikipedia sweep decommission review after two clean weeks.

## Non-goals

- Governor races, primary polling, 2028 — the feed carries them; we don't.
- Pollster ratings/weights by grade (the columns are empty; nothing to use).
- Auto-failover to the Wikipedia scraper (a differently-shaped corpus swapping
  in silently mid-cycle is scarier than a loud stale-feed alarm and a manual
  flip).
- Replacing Wikipedia candidate rosters with feed-derived rosters.
