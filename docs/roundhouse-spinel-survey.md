# Roundhouse + Spinel survey — 2026-10-01

Can 535 be compiled to a native binary with [roundhouse](https://github.com/rubys/roundhouse)
and [Spinel](https://github.com/matz/spinel)? This is the read-only survey:
what each stage of the toolchain did with the app as it stands at `8f86654`.
Nothing in the app, the database or production was changed to produce it.

**Answer: not today.** The app is analyzed and emitted almost completely, but
the emitted project does not compile, and seven columns the site depends on
are dropped on the way through.

## Versions

| Tool | Version | Notes |
|---|---|---|
| roundhouse | 2026.9.18 (`2e286e6f`) | First and only snapshot; prebuilt arm64 binary, checksum verified |
| Spinel | tag `2026.09.12` (`112bae8`) | The version roundhouse's release notes say it was tested against |
| App | `8f86654`, Ruby 4.0.7, Rails 8.1.4 | 12,288 lines of Ruby, 70 templates |

## Stage 1 — analyze (`roundhouse check --continue`)

0.4 seconds. **0 parse errors, 117 errors, 1,004 warnings, 25 survey gaps.**
For scale, roundhouse's release notes put Campfire at 0 errors and Mastodon
at 674.

The 117 errors by cause:

| Count | Cause | Example |
|---:|---|---|
| 27 | Integer-backed `enum` readers typed as Integer; `Model.statuses`-style mappings unknown | `dispatch.kind.humanize`, `Race.offices` |
| 20 | Framework/stdlib methods not modeled | `with_indifferent_access`, `Race.maximum`, `ActiveModel::Type::Boolean.cast`, `Zlib.gzip`, `String#first` |
| 19 | View instance variables with no known type | every `@dispatch` in the dispatch mailer templates; two counts on the methodology page |
| 14 | `PostHog.capture` / `PostHog.identify` | gem not modeled |
| 14 | App value objects not typed | `Admin::KillSwitchStatus#effective?`, a `Result` struct read in a view |
| 10 | Reads of jsonb columns | `margin_percentiles`, `params_snapshot`, `raw_payload`, `cited_poll_ids` |
| 8 | Arithmetic on possibly-nil numbers | `Integer? > Integer` in the polls and subscribers pages |
| 5 | `ENV[...]` / `ENV.fetch` | |

Every error is in `app/views` (72), `app/controllers` (32) or `app/models`
(12). `app/lib` — the forecast engine, ingest and newsroom — reports none,
and no warnings either; it is parsed and emitted but evidently not
type-checked at this stage.

The 25 survey gaps (constructs roundhouse does not ingest):

- `edge_cache` and `without_csrf_token`, the class-level macros from
  `EdgeCacheable` — 14 entries across 7 controllers. These set the Cloudflare
  cache headers and remove the session cookie.
- `prepend_before_action` in `ApplicationController`.
- `mount GoodJob::Engine` — route dropped.
- Argument forwarding (`...`) in three newsroom files; a multiple-assignment
  form in `site/maps/projection.rb`.
- Five fixture fields that are hashes or arrays (the jsonb columns again).

Gems: 31 total — 7 framework, 1 stdlib, 5 modeled, 13 infrastructure,
**5 unknown: `good_job`, `ruby_llm`, `posthog-ruby`, `posthog-rails`,
`rails_mind`.**

## Stage 2 — emit (`roundhouse --target spinel --survey --allow-unsupported`)

Wrote an 899-file project: 363 Ruby files, 53,758 lines including the
runtime. The translation is faithful where it works — the emitted
`Forecast::Simulator` is the same structs, the same seeded `Random`, the same
loop.

What was lost, none of it reported as an error:

- **All 7 app-owned jsonb columns are absent from the emitted schema:**
  `forecasts.margin_percentiles`, `chamber_forecasts.seat_histogram`,
  `boundaries.geometry`, `model_runs.params_snapshot`, `polls.raw_payload`,
  `dispatches.cited_poll_ids`, `scrape_runs.refusal_reasons`. That removes
  the percentile intervals, the seat histograms and the maps. All 25 tables
  are otherwise present, as SQLite.
- **No scheduler.** Active Job is inline: `perform_later` runs the job
  synchronously in the request. `config/initializers/` is not carried over,
  so the five cron entries in `good_job.rb` are gone.
- **Unknown gems pass through by name.** The output still calls `RubyLLM`,
  `Faraday`, `PostHog` and `Rails.application.credentials`; nothing defines
  them. The bundled Nokogiri stand-in answers one XPath shape (Campfire's)
  and raises on anything else.
- Three model declarations are skipped with a warning: `normalizes` on `User`
  and `Subscriber`, and `after_create_commit` on `Dispatch`.
- `format.turbo_stream` in `SubscriptionsController#create` is dropped, so
  subscribing would answer with HTML.

275 further `lower_residue` warnings are mostly "relation chain stays
dynamic", which the Ruby-family targets (Spinel included) execute at runtime.
Those are not blockers for this target.

## Stage 3 — compile (`spin build`)

Failed. Getting as far as possible took four hand-patches to the emitted
tree (not the app):

1. `app/models/dispatch.rb` — a scope's early exit emitted as `next` inside a
   method. Invalid Ruby.
2. `app/views/subscriptions/create.rb` — duplicated parameter names in the
   generated signature.
3. `app/views/home/_corpus_note.rb` — the partial's prose comment
   `<%# locals: note (a visible Site::CorpusNote)…` was read as a strict-locals
   declaration and emitted as parameters `a visible Site`.
4. `app/models/ingest/wikipedia_client.rb` — its `require "erb"` pulls in
   Spinel's `ERB` class, which collides with the runtime's `ERB` module.

Items 1–3 are emitter bugs; 3 and 4 can also be sidestepped in the app. Seven
generated `.rbs` sidecar files also fail to parse, non-fatally.

With those patched, Spinel parsed the program and entered type analysis —
and **did not finish.** After 20 minutes it was still at 100% CPU with
memory flat at 175 MB, and was stopped. Campfire, at 47,000 lines, analyzes
in 11 seconds on comparable hardware (matz/spinel#4847), so this is
non-convergence rather than slowness. The likely cause is the undefined
constants above, but that is not established.

So the survey has no data yet on what Spinel's type checker would reject in
the app's own code.

## What stands between 535 and a binary

**Small, in the app (hours):**
- Reword one partial comment; drop one `require "erb"`.
- Replace `...` forwarding in three files and one multiple assignment.
- Three `define_method` loops, eight nil-guarded comparisons.

**Needs a decision (days to weeks each):**
- **Database.** SQLite only, and jsonb is dropped silently. Seven columns
  need a different representation or the site loses intervals, histograms
  and maps.
- **Jobs and cron.** No queue, no scheduler. The feed sweep, model run and
  daily brief need a replacement.
- **Unknown gems.** `ruby_llm` (the newsroom), PostHog, `rails_mind` (the
  telemetry that found the House N+1) need replacing, stubbing or dropping.
- **Credentials and SMTP.** Neither is modeled.
- **Edge caching.** `EdgeCacheable`'s macros are not understood, so the
  Cloudflare headers and cookie removal would not be emitted.

**Upstream (not ours to fix):**
- The three emitter bugs, the enum-reader typing, the mailer instance
  variables, and whatever stops Spinel's analysis from converging.

## Would another target be easier?

No. The same app was emitted to seven targets. Analysis is shared, so the 117
errors, the dropped jsonb columns, the missing scheduler, the unknown gems
and the three emitter bugs are identical everywhere. What differs is how much
of the app each back end carries:

| Target | Files | Views (of 70) | Forecast engine | Extra unsupported sites |
|---|---:|---:|---|---:|
| spinel | 899 | 68 | emitted | 3 |
| ruby | 849 | 68 | emitted | 3 |
| jruby | 851 | 68 | emitted | 3 |
| typescript | 619 | 65 | emitted | 103 |
| crystal | 229 | 64 | absent | 9 |
| rust | 190 | 25 | absent | 8 |
| go | 187 | 24 | absent | 35 |

The strict targets require every query chain to become SQL at build time;
255 of this app's do not, and nothing from `app/lib` reaches Rust, Go or
Crystal. None of their output was compiled here (no toolchains installed).

The `ruby` target is the Spinel tree without the compile step, running on
CRuby with the real Nokogiri and `net/http`. It was installed and loaded as a
probe. With the three emitter patches it stopped, in order, on:

1. `bigdecimal` missing from the emitted Gemfile (Ruby 4 no longer bundles it).
2. Load order: files are required alphabetically, so
   `Forecast::HouseEffects` reads `Forecast::Runner::MODELLED_OFFICES` before
   it exists. Two such reorders were needed before the next stop.
3. `Rails.root.join("config", "model_params.yml")` — the runtime's `join`
   takes one argument.
4. `config/model_params.yml` and `db/seed_data/*.yml` are not copied into the
   output.
5. `Forecast.variants` undefined — the enum-mapping gap from stage 1, now as
   a runtime error. Stopped here.

`db/seed.sql` also has 7 statements that fail (indexes on dropped columns),
and seeds no rows.

Each failure is an ordinary Ruby exception within a second, against a
20-minute hang under Spinel. That makes the `ruby` target the place to get
the emitted app working before compiling it, not a different destination.

## Reproduce

Tools and output live outside the repo in `~/sites/pol-roundhouse/`.

```bash
R=~/sites/pol-roundhouse/tools/roundhouse-aarch64-apple-darwin/roundhouse
$R check --continue ~/sites/pol
$R --target spinel --survey --allow-unsupported -o ~/sites/pol-roundhouse/out/spinel ~/sites/pol
export PATH=~/sites/pol-roundhouse/tools/spinel/bin:$PATH
cd ~/sites/pol-roundhouse/out/spinel && spin build
```

Logs: `out/check.err`, `out/emit.err`, `out/spin-build*.log`.

To remove everything the survey installed: delete `~/sites/pol-roundhouse/`
and `~/.cache/spin/`, and run `brew uninstall jemalloc`.
