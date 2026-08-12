# Build notes

Every real-world fact this project bakes into code or config is verified against a
source at build time and recorded here with its URL. Organised by phase.

---

# Phase 0 — Foundations

No real-world facts are baked in by this phase; what follows is the decision
record. Everything here was verified by running it, not by recalling it.

## A. What was added

| Piece | Where | Note |
|---|---|---|
| Rails 8.1 skeleton | whole tree | `rails new` output, committed unmodified first so every later diff is ours |
| Postgres | `config/database.yml` | `pol_development` / `pol_test`; no other service (no Redis) |
| `good_job` 4.19.2 | `config/initializers/good_job.rb` | Postgres-backed Active Job; cron enabled, entries added in Phases 2 and 5 |
| `ruby_llm` 1.16.0 | `config/initializers/ruby_llm.rb` | the only outbound AI dependency, pointed at OpenRouter |
| `nokogiri` 1.19.4 | — | Wikipedia parsing (Phase 2) |
| `webmock` 3.26.2 | `test/test_helper.rb` | `WebMock.disable_net_connect!(allow_localhost: true)` — the suite cannot reach the network |
| `bcrypt` 3.1.22 | `app/models/user.rb` | uncommented from the generated Gemfile, for `has_secure_password` |
| Auth | `app/controllers/concerns/authentication.rb` | `bin/rails generate authentication` — sessions and password reset only |

`bundle install` resolved cleanly on Ruby 4.0.2 and the `Gemfile.lock` diff was
purely additive.

## B. Decisions worth keeping

- **Authentication is deny-by-default.** The generator's concern adds
  `before_action :require_authentication` in its `included do`, so
  `ApplicationController` requires a session and it is `PublicController`
  (Phase 4) that opts out with `allow_unauthenticated_access`. Phase 6's
  `Admin::BaseController` therefore gates the whole admin by doing *nothing* —
  the safe posture is inherited, not re-asserted per controller.
- **No sign-up.** The generator produces `SessionsController` and
  `PasswordsController` and no `UsersController`; nothing was added. This is a
  single-editor site and the account comes from `db/seeds.rb`.
- **Every model/newsroom constant lives in `config/model_params.yml`.**
  `Pol::Params.fetch!(*keys)` raises a `KeyError` naming the path and the file
  on a missing key or a nil value, so a typo is a loud failure rather than a
  silent `nil` propagating into a probability. `reload!` re-reads from disk,
  which is what lets tests prove a number is genuinely read from the file.
- **The kill switch is a database row with an environment override.**
  `Setting.agents_enabled?` is true when unset, respects a stored
  `"true"`/`"false"`, and is forced false whenever `ENV["AGENTS_DISABLED"]` is
  *present* (any value) — so an operator can stop the newsroom without a
  database write, and the admin toggle (Phase 6) writes the same key,
  `Setting::AGENTS_ENABLED_KEY`.
- **GoodJob runs `execution_mode: :async` in development only**, so `bin/dev`
  needs no second process; production runs a dedicated worker. The test
  environment sets `config.active_job.queue_adapter = :test` explicitly,
  because naming an adapter in `config/application.rb` disables Rails'
  automatic test-adapter swap — see
  https://github.com/rails/rails/issues/37270.

## C. Process incident — credential exposure (local only)

The OpenRouter API key was printed to a local terminal twice during this build:
once by a `credentials:show` invocation, and once when a review diff was
rendered through git's `rails_credentials` textconv filter, which decrypts.
Neither value left the machine or entered a commit; the tainted diff file was
deleted and a repo-local `git config diff.rails_credentials.textconv cat` was
set so review diffs no longer decrypt. **Rotating the key is still recommended**
— it is on the Phase 7 handoff list below.

---

# Phase 1 — Domain model

Eleven application tables plus GoodJob's five. Schema version
`2026_08_11_050001`. Again no external facts — this section records the
judgment calls, because several of them are load-bearing later.

## A. The tables

`races`, `candidates`, `pollsters`, `polls`, `poll_results`, `model_runs`,
`forecasts`, `chamber_forecasts`, `dispatches`, `scrape_runs`, plus Phase 0's
`users`/`sessions`/`settings` and Phase 5's `newsroom_skips`.

## B. Decisions where the design admitted more than one reading

1. **`model_runs.started_at`/`finished_at` are both nullable; `scrape_runs`'
   are both `null: false`.** A model run has a `running` status — a live row
   with a start and no finish is a legitimate state. A scrape run has no
   `running` status (`succeeded`/`failed`/`partial`), so the row is written
   once, after the fact, with both timestamps known.
2. **`polls.dedup_digest`: presence validated in the model, uniqueness enforced
   only by the database.** A duplicate raises `ActiveRecord::RecordNotUnique`
   rather than failing `valid?`, which is what `Ingest::RecordPoll` wants: it
   checks `Poll.exists?(dedup_digest:)` first for a clean answer and rescues
   the index violation as the real guarantee. Both paths are tested.
3. **`poll_results.party` is always set, even when a candidate is attached.**
   Party is how every downstream reader (averager, charts, poll table) groups
   results; a candidate is a nicety that may be absent.
4. **`dependent: :destroy` only from `Poll → poll_results` and
   `ModelRun → forecasts`/`chamber_forecasts`.** Destroying a `Race` with polls
   or dispatches raises `ActiveRecord::InvalidForeignKey` instead of silently
   deleting history — the safer default for the data the site's premise rests
   on.
5. **`Dispatch` validates headline presence and the headline cap only.** The
   dek and body caps are the writer's business (Phase 5's
   `Newsroom::Validation`), and the headline cap is read from `Pol::Params` on
   every validation rather than frozen into a constant, so editing the YAML
   takes effect without a restart.

## C. Fixtures

`test/fixtures/` carries one small coherent world used by every later phase:
two Senate races (Maine, polled; a Florida special, unpolled), one House
district with a 2024 baseline (NY-17), three candidates in Maine including an
independent who caucuses with the Democrats, two Maine polls and one
generic-ballot poll, one succeeded model run with a Maine forecast, and one
published poll-reaction dispatch citing both Maine polls. The independent and
the unpolled race are there on purpose: they are the two shapes that break
naive dem-vs-rep code, and they have caught real bugs in Phases 3, 4 and 7.

---

# Phase 2 — Wikipedia ingestion + seeds

Research date: **August 11, 2026** (all "as of today" statements below mean that
date). Everything in this section was checked against a live page on that date;
nothing is from model memory.

## A. Verified facts

### A1. The 2026 U.S. Senate map — 35 seats

Source (overview, incumbents, statuses, primary/filing dates):
<https://en.wikipedia.org/wiki/2026_United_States_Senate_elections>

Cross-check on the Class 2 membership and its party split:
<https://www.senate.gov/senators/Class_II.htm> — 20 Republicans, 13 Democrats,
matching Wikipedia exactly, including the two 2026 appointees (Armstrong, Graham).

33 Class 2 seats plus **two** Class 3 special elections (Florida and Ohio) = 35.
No other specials exist: the two 2026 vacancies (Oklahoma, South Carolina) both
fell in seats *already* regularly scheduled for 2026, so they are filled by the
regular election, not by a special. That is stated explicitly on the South
Carolina page ("South Carolina is one of two states, along with Oklahoma, that
had vacancies in Senate elections already regularly scheduled for 2026").

Two developments postdate common knowledge and were each cross-checked against
non-Wikipedia sources:

- **Oklahoma.** Markwayne Mullin resigned in March 2026 to become Secretary of
  Homeland Security; Gov. Kevin Stitt appointed energy executive **Alan S.
  Armstrong** (R), who took office March 24, 2026 and is ineligible under
  Oklahoma law to run in 2026. Cross-checks:
  <https://rollcall.com/2026/03/24/energy-executive-armstrong-tapped-to-replace-mullin-in-senate/>,
  <https://www.nbcnews.com/politics/congress/oklahoma-energy-executive-alan-armstrong-fill-senate-markwayne-mullin-rcna264913>
- **South Carolina.** Lindsey Graham won renomination on June 9, 2026 and then
  died on July 11, 2026 (aortic dissection). Gov. Henry McMaster appointed his
  sister **Darline Graham** (R) on July 13; she was sworn in July 14 and is
  running for the full term. Cross-checks:
  <https://www.npr.org/2026/07/12/nx-s1-5890790/us-sen-lindsey-graham-dies>,
  <https://governor.sc.gov/news/2026-07/gov-mcmaster-appoints-darline-graham-us-senate>,
  <https://www.cbsnews.com/news/lindsey-graham-replacement-senate-south-carolina-governor/>

Per-race detail is carried in `db/seed_data/senate_2026.yml`; each entry cites
its own Wikipedia page. `open_seat` is true exactly when the sitting senator is
not on the November ballot (retirement, lost renomination, or ineligible).

| State | Sp. | Incumbent (party) | Status | Open | D candidate | R candidate | Other |
|---|---|---|---|---|---|---|---|
| AL | | Tommy Tuberville (R) | retiring (running for gov.) | yes | Everett Wess | Barry Moore | |
| AK | | Dan Sullivan (R) | running | no | Mary Peltola* | Dan Sullivan* | |
| AR | | Tom Cotton (R) | renominated | no | Hallie Shoffner | Tom Cotton | |
| CO | | John Hickenlooper (D) | renominated | no | John Hickenlooper | Mark Baisley | |
| DE | | Chris Coons (D) | running | no | Chris Coons* | — (unsettled) | |
| FL | ✓ | Ashley Moody (R, appt. 2025) | running | no | — (unsettled) | Ashley Moody* | |
| GA | | Jon Ossoff (D) | renominated | no | Jon Ossoff | Mike Collins | |
| ID | | Jim Risch (R) | renominated | no | — | Jim Risch | Todd Achilles (I) |
| IL | | Dick Durbin (D) | retiring | yes | Juliana Stratton | Don Tracy | |
| IA | | Joni Ernst (R) | retiring | yes | Josh Turek | Ashley Hinson | |
| KS | | Roger Marshall (R) | renominated | no | Adam Hamilton | Roger Marshall | |
| KY | | Mitch McConnell (R) | retiring | yes | Charles Booker | Andy Barr | |
| LA | | Bill Cassidy (R) | lost renomination | yes | Jamie Davis | Julia Letlow | |
| ME | | Susan Collins (R) | renominated | no | Troy Jackson | Susan Collins | |
| MA | | Ed Markey (D) | running | no | Ed Markey* | John Deaton* | |
| MI | | Gary Peters (D) | retiring | yes | Abdul El-Sayed | Mike Rogers | |
| MN | | Tina Smith (DFL) | retiring | yes | — (unsettled) | — (unsettled) | |
| MS | | Cindy Hyde-Smith (R) | renominated | no | Scott Colom | Cindy Hyde-Smith | Ty Pinkins (I) |
| MT | | Steve Daines (R) | retiring | yes | Alani Bankhead | Kurt Alme | Seth Bodnar (I) |
| NE | | Pete Ricketts (R) | renominated | no | — | Pete Ricketts | Dan Osborn (I) |
| NH | | Jeanne Shaheen (D) | retiring | yes | Chris Pappas* | Scott Brown* | |
| NJ | | Cory Booker (D) | renominated | no | Cory Booker | Justin Murphy | |
| NM | | Ben Ray Luján (D) | renominated | no | Ben Ray Luján | Larry Marker | |
| NC | | Thom Tillis (R) | retiring | yes | Roy Cooper | Michael Whatley | |
| OH | ✓ | Jon Husted (R, appt. 2025) | nominated | no | Sherrod Brown | Jon Husted | |
| OK | | Alan S. Armstrong (R, appt. 2026) | ineligible to run | yes | — (unsettled) | Kevin Hern | |
| OR | | Jeff Merkley (D) | renominated | no | Jeff Merkley | David Brock Smith | |
| RI | | Jack Reed (D) | running | no | Jack Reed* | Raymond McKay* | |
| SC | | Darline Graham (R, appt. 2026) | running | no | Annie Andrews | — (unsettled) | |
| SD | | Mike Rounds (R) | renominated | no | — | Mike Rounds | Brian Bengs (I) |
| TN | | Bill Hagerty (R) | renominated | no | Marquita Bradshaw | Bill Hagerty | |
| TX | | John Cornyn (R) | lost renomination in runoff | yes | James Talarico | Ken Paxton | |
| VA | | Mark Warner (D) | renominated | no | Mark Warner | Bert Mizusawa | |
| WV | | Shelley Moore Capito (R) | renominated | no | Rachel Fetty Anderson | Shelley Moore Capito | |
| WY | | Cynthia Lummis (R) | retiring | yes | James Byrd* | Harriet Hageman* | |

`*` = **unsettled**: the primary has not happened yet (or has not been called),
so the name is the declared front-runner rather than a nominee. Unsettled races
and why, as of August 11, 2026:

- **AK** (top-four primary Aug 18) — Sullivan and Peltola are the two declared
  major candidates; Alaska's system means the November field is not final.
- **DE** (primary Sep 15) — Coons is the incumbent seeking renomination; the
  Republican field (Michael Katz, John Shulli, Alec Coppola) has no front-runner,
  so no Republican is seeded.
- **FL special** (primary Aug 18) — Moody is the incumbent; the Democratic
  primary (Alexander Vindman, Angie Nixon, Alan Grayson) is genuinely contested,
  so no Democrat is seeded.
- **MA** (primary Sep 1) — Markey faces Seth Moulton; Deaton is described by the
  page as the presumptive Republican.
- **MN** (DFL and R primaries **today**, Aug 11) — the DFL race is Peggy Flanagan
  vs. Angie Craig with no clear front-runner; no candidates seeded.
- **NH** (primary Sep 8) — Chris Pappas (D) and Scott Brown (R) are the clear
  front-runners in their fields.
- **OK** — Hern is the Republican nominee; the Democratic nominee is listed as
  TBD on the page.
- **RI** (primary Sep 8) — Reed is the incumbent; Raymond McKay leads a two-name
  Republican field.
- **SC** (special Republican primary **today**, Aug 11) — Annie Andrews is the
  Democratic nominee; the Republican nominee (Darline Graham, Russell Fry, and
  others) is undecided, so no Republican is seeded even though the seat's
  appointed incumbent is running.
- **WY** (primary Aug 18) — Hageman (R) and Byrd (D) lead their fields.

Where a party has no seeded candidate the poll parser falls back to matching
poll columns by party, so those races still ingest polls (see D3 below).

### A2. Senate composition and the 65 holdover seats

Source: <https://en.wikipedia.org/wiki/2026_United_States_Senate_elections>
(infobox `seats_before`, plus the "Partisan composition" section).

Current Senate: **53 R, 45 D, 2 I** (Bernie Sanders of Vermont and Angus King of
Maine, both caucusing with the Democrats) = 100.

Seats up in 2026 = 35:

- Class 2: 20 R + 13 D = 33 (confirmed against senate.gov's Class II list)
- Class 3 specials: Florida (R) + Ohio (R) = 2 R

So 22 R and 13 D are up. Arithmetic for the holdovers (seats **not** on the 2026
ballot):

```
Republican holdovers      = 53 − 22 = 31
Democratic holdovers      = 45 − 13 = 32
Independent holdovers     =  2 −  0 =  2   (Sanders and King are both Class 1)
Democratic-caucus holdovers = 32 + 2 = 34
Total holdovers           = 31 + 34 = 65    (65 + 35 = 100 ✓)
```

Phase 3 will need these two numbers: **31 Republican / 34 Democratic-caucusing
holdovers.** Also verified for Phase 3's tiebreak rule: the vice presidency is
**Republican** — JD Vance, whose resignation from the Senate in 2025 is what
created the Ohio special election.

### A3. 2024 national U.S. House popular vote

Source: <https://en.wikipedia.org/wiki/2024_United_States_House_of_Representatives_elections>
(infobox, citing the Clerk of the House's *Statistics of the Congressional
Election of November 8, 2024*).

- Republicans 74,390,864 = **49.8%**
- Democrats 70,571,330 = **47.2%**
- **D − R = −2.6 pct pts** (the article's own prose: Republicans won the House
  popular vote "by 4 million votes and a narrow margin of 2.6%")

→ `fundamentals.house_national_margin_2024: -2.6`

### A4. 2024 and 2020 national presidential popular vote

- 2024: <https://en.wikipedia.org/wiki/2024_United_States_presidential_election>
  — Trump 77,302,580 (49.80%), Harris 75,017,613 (48.32%) of 155,238,302 total
  (FEC certified). **D − R = −1.5 pct pts.**
- 2020: <https://en.wikipedia.org/wiki/2020_United_States_presidential_election>
  — Biden 81,283,501 (51.31%), Trump 74,223,975 (46.85%) of 158,429,631 (FEC).
  **D − R = +4.5 pct pts.**

→ `fundamentals.pres_national_margin_2024: -1.5`,
  `fundamentals.pres_national_margin_2020: 4.5`

These same two pages supply the per-state margins used for Senate `lean`
(section C3).

### A5. Exact Wikipedia page titles scraped

| Purpose | Title |
|---|---|
| Senate overview (facts only, not scraped at runtime) | `2026 United States Senate elections` |
| Per-state Senate race (33) | `2026 United States Senate election in {State}` |
| Special Senate races (2) | `2026 United States Senate special election in Florida` / `... in Ohio` |
| Generic congressional ballot | `2026 United States elections` (§ Polling) |
| 2024 House results, per district | `2024 United States House of Representatives elections` |
| 2024 presidential results by state | `2024 United States presidential election` (§ Results by state) |
| 2020 presidential results by state | `2020 United States presidential election` (§ Results by state) |

Note on the generic ballot: the obvious candidates
(`Nationwide opinion polling for the 2026 United States House of Representatives elections`,
`Generic ballot`) do **not** exist, and
`2026 United States House of Representatives elections` § Opinion polling holds
only *aggregator averages*, not individual polls. The individual generic-ballot
polls live on `2026 United States elections` § Polling, which is what the
scraper reads.

## B. Fetcher notes

`Ingest::WikipediaClient` GETs
`https://en.wikipedia.org/api/rest_v1/page/html/{title}` as specified. That
endpoint now answers **301** with a same-host `Location:` of
`/w/rest.php/v1/page/{title}/html`, so the client follows same-host redirects
(max 3 hops) rather than hard-coding the new path — the documented URL keeps
working and a future move is absorbed too. Off-host redirects are refused. The
User-Agent is descriptive and carries the contact address from
`model_params.yml`; timeouts are 15 s open and read; a request is attempted 3
times with exponential backoff on 5xx and transport errors and **never** on
404; and each client instance paces itself to one request per second, measured
from the end of the previous request.

Pacing and backoff default to zero under `Rails.env.test?` — the suite never
reaches a live server (WebMock forbids it), so there is nothing to be polite
to. The tests that are *about* pacing pass their own values and a fake sleeper.

## C. Seed notes

`bin/rails pol:seed_races` is idempotent: every race is upserted by slug
(`senate-2026-ga`, `senate-2026-oh-special`, `house-2026-al-01`), so re-running
after a primary resolves updates in place. A candidate dropped from the
verified list is deleted unless a poll result already points at them, in which
case the historical link wins and the task warns.

**Senate `lean`** = mean over 2024 and 2020 of (state margin − national
margin), D−R points, from the two presidential pages' "Results by state"
tables. Maine's and Nebraska's statewide rows are flagged with a dagger because
those states also have per-district rows; the dagger is stripped and the
district rows ignored. 2020's table includes DC and 2024's does not — no
consequence here, since DC has neither a Senate seat nor a House district.

**Uncontested in 2026** is left `false` for every race. Nothing in the sources
reliably establishes a 2026 one-major-party ballot this far from the election;
Phase 6's admin can set it where it becomes true.

**The House parse has a floor.** `Ingest::SeedRaces` refuses to write a single
district unless the parser returned exactly `HOUSE_DISTRICTS` (435), raising
`Ingest::SeedRaces::IncompleteSource` with the per-state counts it did find.
Wikipedia can restructure a page at any time, and a seeder that quietly filled
in 300 districts would leave the forecast silently wrong rather than visibly
broken. Tests against the trimmed fixture pass their own `expected_districts:`
(the fixture legitimately holds six states), and one test drives the default to
prove the guard fires and writes nothing.

## D. Parser design decisions

1. **Grid normalisation first.** `Ingest::TableGrid` expands `rowspan`/`colspan`
   into a dense 2-D grid before anything else. Wikipedia's polling tables lean on
   both heavily (one pollster cell spanning four result rows is routine), and the
   presidential results tables use two stacked header rows. Cell text drops
   `<style>` and `<sup>` (reference and footnote markers) and turns `<br>` into a
   space, so `Jon<br>Husted (R)` reads as `Jon Husted (R)` rather than
   `JonHusted (R)`.
2. **Aggregator tables are skipped**, detected by a "source of poll aggregation"
   or "dates updated" header. They are averages of other people's polls, not
   polls.
3. **A table is only ingested when its party columns cover at least two distinct
   parties, and — for any party where the race has seeded candidates — the column
   surname matches one of them.** This is what separates real general-election
   matchups from the two other kinds of table that sit in the same "Polling"
   section: primary polls (columns are `Buddy Carter` / `Mike Collins` /
   `Derek Dooley`, no party marker at all → zero party columns → skipped) and
   hypothetical matchups against non-candidates (`Jon Ossoff (D)` vs
   `Brad Raffensperger (R)` in Georgia, where the Republican nominee is Mike
   Collins → skipped). On the Georgia fixture this is the difference between 39
   rows and the 10 polls of the race that is actually happening. Races with no
   seeded candidate for a party (the unsettled ones in A1) fall back to
   party-only matching, which is the best available. The same rule quietly
   handles "Generic Democrat" columns (Montana and Mississippi both have one):
   the label names no real candidate, so the table is refused — a poll against
   a hypothetical generic opponent is not a poll of the race.
4. **Dates.** Four shapes occur in the wild and all are handled:
   `April 16, 2025`; `February 10–12, 2025`; `May 15 – June 21, 2026`;
   `December 29, 2025 – January 4, 2026`. The separator is always U+2013 in
   practice; ASCII `-` and em dash are accepted too. Anything else is skipped and
   counted, never guessed.
5. **Sample size / population.** `600 (LV)` → 600 + `lv`. The population codes
   actually present are LV, RV, A and V; `V` maps to `unknown` because "voters"
   is not one of the model's three defined populations, and v1 does not adjust
   for population anyway.
6. **A dashed cell is "not tested", not zero — but only for minor parties.**
   Montana's page is the case that settled this: its main table carries a
   Libertarian column that most pollsters left out, dashed row after row.
   Treating those dashes as unparseable threw away 13 of that page's 22 real
   polls (and 2 of Mississippi's 3); treating them as 0% would be inventing
   data. So an `ind` or `other` column that is dashed simply contributes no
   result, while a dashed Democratic or Republican column still kills the row —
   a matchup missing a major party is not a matchup. A row must end up with at
   least two results across at least two parties.
7. **Sponsor.** The parser reads a `Sponsor`/`Client` column when a table has
   one, but no page in this corpus does — Wikipedia writes the sponsor into the
   poll-source cell instead. So `polls.sponsor` is null across the live run,
   correctly, rather than for want of trying.
8. **Pollster names.** Standalone partisan tags are stripped before
   canonicalisation, so `Tulchin Research (D)` and `Tulchin Research` are the
   same pollster. The unmodified cell text is preserved in `raw_payload`.
9. **Provenance.** `source_url` is the article URL plus the enclosing section's
   anchor (`...#Polling_3`). Those anchors were checked against the *rendered*
   page, not just Parsoid — `id="Polling_3"` exists on both, so the links land
   on the right table. `raw_payload` keeps every cell of the row, keyed by
   column label.
10. **House baselines.** `2024 United States House of Representatives elections`
   carries one table per state with a Candidates cell like
   `▌Y Barry Moore (Republican) 78.5% ▌Tom Holmes (Democratic) 21.5%`.
   Percentages are summed *by party*, which is what makes Louisiana's jungle
   primary (three Republicans on one line) come out right. Where a cell spells
   out ranked-choice rounds, only the deciding round is counted — summing
   Alaska's first round *and* its instant runoff put that district's two-party
   total at 195.8%.

    **Party labels are not uniform.** The page carries 28 distinct party labels,
    and two of the Democratic ones do not contain the word "Democrat":
    Minnesota's **DFL** (8 districts) and North Dakota's **Democratic-NPL** (1).
    Missing DFL is not a small error — it makes all eight Minnesota districts
    look as though no Democrat ran, so each gets an imputed baseline signed
    toward the Republican, turning MN-5's real **+50.4** into **−35.0**. The
    match is `/democrat|\bDFL\b/i`, and the House fixture now includes both
    states so the suite can catch a regression. Every other label on the page
    is a genuine third party (Libertarian, Green, Working Class, Independence,
    Progressive, and so on) and is correctly excluded from both totals.
11. **Structural rows.** Blank separator rows and the "Primary elections are
    held" dividers (one cell stretched across most of the table) are recognised
    as structure and passed over silently rather than counted as failures.

### Known caveats

- Several states redistricted mid-decade for 2026. A district's
  `baseline_margin` is its **2024** result on the **2024** lines, which is what
  the brief specifies and what `baseline_source_url` points at, but for
  redrawn districts the 2024 number describes different territory. Phase 6's
  admin can override.
- Phase 2 seeds no 2026 House incumbency, so Phase 3's `open_seat_adj` has no
  input for the House yet. Deliberately out of scope here; it needs the 2026
  House page, not the 2024 one.
- Independents (Osborn, Achilles, Bodnar, Bengs, Pinkins) are seeded with no
  `caucus_with`. Osborn has said publicly he would caucus with neither party,
  and the rest have not said. Phase 3 needs an explicit rule for tallying an
  independent win rather than a guess made here.
- Where a page publishes both a three-way and a two-way version of the same
  matchup (Montana does), both are ingested. They are different published
  matchups with different digests; Phase 3 keeps one poll per pollster, so this
  does not double-count.

## E. Fixtures

Real Parsoid HTML, trimmed to the sections the parsers care about. Regenerate
with:

```
bin/rails pol:refresh_fixtures
```

The task fetches each page live and writes the trimmed file, printing its size.
The trim keeps the `<section>` elements whose heading matches and drops
everything else — infoboxes, navboxes, references, images — which is what gets
a 2.8 MB Parsoid document down to tens of kilobytes. Two fixtures are also
row-capped because they would otherwise dominate: the generic ballot (561 rows)
keeps 45 rows per table, and the House page keeps four states rather than
fifty. Total committed fixture weight is about 1.0 MB.

| Fixture | What it is there for |
|---|---|
| `senate_georgia.html` | the heavy case: an aggregator table, five primary tables and eight hypothetical matchups around one real one |
| `senate_ohio_special.html` | a special election, party columns in R-then-D order, a "Primary elections are held" divider row |
| `senate_iowa.html` | a middling race |
| `senate_rhode_island.html` | a sparse race (2 polls) |
| `generic_ballot.html` | party-named columns and heavy rowspan (one pollster over several subsamples) |
| `house_results_2024.html` | Alabama (rowspan + safe seats), Alaska (ranked choice), Louisiana (jungle primary), Washington (top-two, incl. a race with no Republican), Minnesota (DFL) and North Dakota (Democratic-NPL) — the only two states whose Democrats carry a non-standard label |
| `presidential_2024.html`, `presidential_2020.html` | two stacked header rows; Maine/Nebraska daggers |
| `poll_table_malformed.html` | hand-mangled copy of the Rhode Island fixture — gibberish dates, a missing pollster, a non-numeric percentage, a row that stops early, a header-less table and a body-less one. **Not** regenerated by the task. |

No test in the suite touches the network: `WebMock.disable_net_connect!(allow_localhost: true)` is set in `test/test_helper.rb`, and every Wikipedia fetch goes through `WikipediaStubHelper`.

## F. Live run

Run once against live Wikipedia on August 11, 2026 (then a second sweep after
the parser change described in D6 — see below).

### `bin/rails pol:seed_races`

| | |
|---|---|
| Senate races | **35** (33 Class 2 + 2 specials) |
| Senate races with a presidential lean | 35 |
| House districts | **435** |
| Imputed baselines | **37 (8.5%)** — comfortably under the 15% ceiling |
| Candidates seeded | 66 |
| Warnings | none |

The 37 imputed districts: AL-3, AL-4, AL-5, CA-12, CA-16, CA-20, CA-34, CA-37,
FL-20, IL-15, IL-16, KY-4, KY-5, LA-4, MA-1, MA-2, MA-3, MA-4, MA-5, MA-6,
MA-7, MS-3, NV-2, NC-3, NC-6, OK-3, PA-3, TX-1, TX-9, TX-11, TX-13, TX-19,
TX-20, TX-25, TX-30, WA-4, WA-9.
Every one is a district where a major party did not field a candidate in 2024 —
safe seats, plus the California and Washington top-two races that ended with two
candidates of the same party.

> **Correction.** The first seed run reported 45 imputed districts (10%), and
> the sentence above was false for eight of them: Minnesota's whole delegation
> was imputed because the parser did not recognise "DFL" as a Democratic label
> (see D10). Those eight districts are genuinely two-way contested and now
> carry their real 2024 margins — MN-5 **+50.4** rather than the fabricated
> **−35.0**, and MN-2 +13.5, MN-3 +17.0, MN-4 +34.8 had the wrong *sign* as
> well as the wrong magnitude. After the fix and a re-seed the count is 37 and
> the list above is accurate. Two non-imputed districts (OH-5 at −35.0 and VA-4
> at +35.0) sit at exactly the imputed magnitude by coincidence — VA-4's 2024
> result really was 67.5–32.5 — so `baseline_imputed`, not the number, is the
> flag to read.

Lean extremes, as a sanity check: WY −46.1, WV −41.9, OK −35.2 at one end;
MA +27.8, RI +15.8, DE +15.3 at the other.

### `bin/rails pol:scrape`

36 sources (35 Senate pages + the generic ballot). **No source 404'd and none
failed.**

| Sweep | Rows seen | New | Duplicate | Skipped |
|---|---|---|---|---|
| First | 804 | 785 | 4 | 15 |
| Second (after the D6 fix) | 804 | 15 | 789 | 0 |

Resulting database: **800 polls — 241 Senate and 559 generic ballot** — with
1,620 poll results across 133 pollsters, comfortably past the targets of ≥10
Senate and ≥5 generic-ballot polls. Every poll has a
`https://en.wikipedia.org/wiki/...#Polling...` source URL; 437 Senate results
are linked to a specific candidate (the rest are the party-fallback races from
A1 and minor-party columns).

**24 of the 35 Senate races have at least one poll.** The eleven with none —
CO, DE, IL, LA, NJ, NM, OK, OR, TN, WV, WY — have no polling section content on
their pages at all, which is what you would expect for uncompetitive or
late-primary races; nothing was invented to fill them. Best-polled races: NC 26,
TX 24, MT 22, MI 21, FL-special 21, AK 15, OH-special 15, NH 13.

> **Correction (Phase 8).** "No polling section content at all" was true of six
> of the eleven and wrong about five. Colorado, Illinois, Louisiana, New Mexico
> and Oklahoma all carry polling sections — 104 rows across the four re-fetched
> in Phase 8, plus Colorado's — and every table in them is a primary field,
> correctly refused. The sentence above could
> not tell the two cases apart because at the time neither could the code. It
> can now: see Phase 8 §D for the page-by-page audit and §C for what the
> scrape run records instead.

The 4 duplicates in the first sweep were genuine within-page repeats (the same
poll listed in two matchup tables on the Minnesota, South Carolina and generic-
ballot pages). The 15 skips were all the Montana/Mississippi dashed-column rows
that D6 then recovered — hence the second sweep, which also served as a
789-row demonstration that the dedup contract holds at scale.

Spot-check against the live rendered page (not the Parsoid copy the scraper
reads): the newest North Carolina poll is stored as Change Research,
2026-08-03 → 2026-08-06, n=915 LV, Whatley (R) 43.0, Cooper (D) 50.0, and the
page's row reads `Change Research (D) | August 3–6, 2026 | 915 (LV) | ± 3.5% |
43% | 50% | – | 7%`. The partisan tag is stripped from the pollster name; the
numbers match exactly.

---

# Phase 3 — Forecast engine

Research date: **August 11, 2026.** The sigma anchors below were checked against
live pages on that date; nothing is from model memory. Margins throughout are
**side A minus side B in percentage points**, which for all but three races is
Democrat minus Republican.

## A. Error-model constants

Phase 0 wrote four sigmas and a time multiplier into `config/model_params.yml`
marked `VERIFY-PHASE-3`. Each is now cited in that file. The reasoning, and the
one value that moved, are here.

A note on units, because it decides everything: these are standard deviations
of the **election-day-equivalent error on the margin**. Published research
usually reports *mean absolute error*, and often on a candidate's *share*
rather than the margin. Margin error is about twice share error, and for a
normal distribution `sigma ≈ 1.25 × MAE`. Both conversions are applied below.
A second caveat: most headline "average error" figures describe *individual
polls*, which carry sampling noise and house effects that partly wash out in an
average — so they are upper bounds on what an average's error should be.

### A1. `sigma_national: 2.5` — kept

The right target is the standard deviation of the **signed** national error,
because that is the thing a shared national shock represents.

- AAPOR's 2024 task force gives the signed national error across all offices in
  the final two weeks: 2016 +3.1, 2018 +0.1, 2020 +4.6, 2022 −0.6, 2024 +2.7.
  Root-mean-square about zero = **2.8**; sample SD = 2.2.
  <https://aapor.org/wp-content/uploads/2025/10/Task-Force-on-2024-Pre-Election-Polling-Report-Executive-Summary.pdf>
- AAPOR's 2020 task force (Table 3) gives the presidential series back to 2000:
  −1.1, +1.4, +0.7, −2.4, +1.3, +3.9. RMS about zero = **2.1**.
  <https://aapor.org/wp-content/uploads/2022/11/AAPOR-Task-Force-on-2020-Pre-Election-Polling_Report-FNL.pdf>
- 538's 2024 House model uses "about 3 points of error at the national level".
  <https://abcnews.com/538/538s-2024-house-election-forecast-works/story?id=114446291>

2.5 sits in the middle of 2.1–2.8 and just under 538's 3.0. **Kept unchanged.**

### A2. `sigma_state_polled: 3.5 → 4.0` — the one value that moved

Two independent anchors put a polled state's *total* error higher than 3.5
implied:

- 538's 2024 presidential model: "the average polling miss for each party's
  vote share in a competitive state is a hair over 2 points, or around 3.8
  points on the margin between the candidates". MAE 3.8 → **sigma ≈ 4.75**.
  <https://abcnews.com/538/538s-2024-presidential-election-forecast-works/story?id=113068753>
- Shirani-Mehr, Rothschild, Goel & Gelman (2018, *JASA*), Table 1: average
  election-level absolute bias for Senate races on election day is 2.0% of
  two-party *share* — about 4.0 points of margin MAE → **sigma ≈ 5.0**. This is
  the decisive number, because election-level bias is precisely the component
  that does **not** average away over more polls: "shared election-level poll
  bias persists unchanged, even when averaging over a large number of surveys."
  <https://sites.stat.columbia.edu/gelman/research/published/polling-errors.pdf>

A race's total error here is `sqrt(sigma_national² + sigma_state²)`. At 3.5 that
is **4.30**, below every anchor found. At 4.0 it is **4.72**, matching 538's
4.75 and near Shirani-Mehr's 5.0. Keeping 3.5 would have been a bet that a
modern house-effect-corrected average beats the 1998–2014 record; 2024 supports
that bet (Silver Bulletin: "The 4.1-point average polling error in Senate races
this cycle is the lowest in our records"), 2020 does not (AAPOR: Senate and
governor absolute error 6.7). **Raised to 4.0** as the robust choice. This is
the only constant Phase 3 changed.

### A3. `sigma_state_unpolled: 8.0` — kept

An unpolled race is a fundamentals estimate, and 538 published the error of
theirs: "we would expect our fundamentals model to miss the vote margin in the
average state by about 6.5 points". MAE 6.5 → **sigma ≈ 8.15**, against our
total of `sqrt(2.5² + 8.0²) = 8.38`. Their Senate model reaches the same place
from the other direction, inflating state error for seats with no polls above
its ~7-point baseline.
<https://abcnews.com/538/538s-2024-presidential-election-forecast-works/story?id=113068753>,
<https://abcnews.com/538/538s-2024-senate-election-forecast-works/story?id=114997770>

### A4. `sigma_district: 6.0` — kept, with a structural caveat recorded

538's 2024 House model states the number outright: "There are about 3 points of
error at the national level, 2 each at the regional and state levels, 2 at the
demographic-cluster level, and 6 at the district level," combined in quadrature
("These numbers don't add up to 8 points because uncorrelated errors are not
additive"). Same scale, same construction, same value.
<https://abcnews.com/538/538s-2024-house-election-forecast-works/story?id=114446291>

**The caveat is not about this constant, it is about the ones next to it.**
538's *correlated* error outside the district is `sqrt(3² + 2² + 2² + 2²) =
4.58`; ours is a single national term of 2.5. Per district that barely matters
(our 6.50 against their 7.55), but the missing 4-odd points are *correlated
across districts* and therefore do not wash out over 435 seats. **Our House
seat-count distribution is narrower than it should be, and the House control
probability is correspondingly more confident than it should be.** Inflating
`sigma_district` would not fix this — it would add the variance as independent
noise, which is exactly what does wash out. The fix is a regional or state-level
shared term, which is a change to the model's structure rather than to a
number, and is left for a later phase. Recorded here so the number is read with
its limits known.

**How much it matters, measured.** Standing `sigma_national` up to 538's full
correlated total is not the right fix, but it does bound the size of the effect,
because it is the same variance arriving through the only correlated channel
this model has. Re-running the live board at three values, same seed, same
inputs:

| `sigma_national` | House D control | seat SD | seat range | Senate D control |
|---|---|---|---|---|
| **2.5** (ours) | **96.3%** | 13.6 | 186–303 | **31.1%** |
| 3.5 | 90.2% | 19.0 | 167–333 | 35.1% |
| 4.58 (538's correlated total) | 83.9% | 25.4 | 137–360 | 38.0% |

So the honest reading of the live House number is **"around 85–95%, and nearer
the bottom of that"**, not 96%. The Senate is less exposed but moves too, by
about 7 points. Neither figure is wrong for the model as specified; both are
narrower than the evidence supports.

> **Corrected 2026-08-12 by Phase 10 — read the conclusion above with this.**
> The three measurements in the table are still true and still reproduce (Phase
> 10 §C re-ran the 3.5 and 4.58 rows and got 91.2% and 84.9% on a later date and
> a grown corpus). **The sentence drawing a conclusion from them is not.**
>
> Every row here raises `sigma_national` alone, so all of the correlated
> variance travels through the one channel common to all 435 districts. That is
> the *upper bound* this section said it was — but the paragraph above then
> printed the bound as the honest reading, and the site repeated it for two
> phases. A correlated total of 4.58 spread across national, regional, state and
> cluster scopes is a different object from a national term of 4.58: only the
> 3.0 is common to every district, and the rest partly averages away across a
> chamber. Measured on the same board with the correlation put where the
> literature puts it, the same variance moves the House number by about 3.5
> points, not 12 (96.6% → 93.1%). **The honest reading was nearer "around 90–96%"
> than "85–95%, nearer the bottom".** The same over-reading applies to the
> Senate line: it moves by one to two points across these configurations, not
> seven.
>
> The closing line of the paragraph before the table — "The fix is a regional or
> state-level shared term... left for a later phase" — is also stale. That is
> Phase 10, and it shipped: `sigma_regional` over census divisions and
> `sigma_state` over a state's Senate race and all its districts, at 538's own
> values. See Phase 10 §A for the components and §C for the measurement that
> corrects this paragraph.

### A5. Time inflation `t = min(1.75, 1 + days/180)` — kept

No published source states a 1.75 cap or a 180-day scale; what the literature
supports is the shape.

- Shirani-Mehr et al. Figure 2 (7,040 polls, final 100 days) shows Senate poll
  error running about **1.7×** its election-day level three months out, once the
  sampling floor is netted out — close to the 1.75 cap. (Read off the published
  figure; the paper prints no table for it.)
- The same paper on the flat region this formula produces near the end: "Average
  error... appears to stabilize in the final weeks, with little difference in
  RMSE one month before the election versus one week before." AAPOR 2020 agrees:
  "The polling error for the presidential election was stable throughout the
  campaign." Our formula gives 1.12× at three weeks.
- The one source that argues for more is 538's presidential drift estimate ("the
  polling margin in the average state tends to move by 12 points over the entire
  course of the election... From 75 days out... closer to 6 points"), which
  implies roughly 1.9× at 75 days where ours gives 1.42×. Down-ballot races
  anchored on partisan lean move far less than a presidential topline, and 2024
  had a mid-race candidate swap inflating that figure.

**Kept.** If a later phase wants to hedge toward the presidential evidence, the
lever is shortening `time_scale_days` to 120, not raising the cap.

### A6. `chambers:` — new in Phase 3

`senate_holdover_dem_caucus: 34`, `senate_holdover_rep: 31`, `vp_party: "rep"`
and `house_majority_seats: 218`, all from the Phase 2 arithmetic in §A2 above
(31 + 34 + 35 = 100). The VP's party is what makes the two Senate thresholds
asymmetric: Republicans control at 50, Democrats need 51.

## B. What the engine computes

Four objects, each with one job.

**`Forecast::Averager`** — a weighted mean margin for a race or the generic
ballot, as of a date. Polls inside `window_days` (45), widening to
`extended_window_days` (120) when fewer than two qualify; one poll per pollster
(latest `field_end`, then latest `field_start`, then highest id); weight
`exp(-ln2 × age_days / 14) × sqrt(min(n, 1500) / 600)`, with a missing sample
size treated as 400. Returns the mean, `W` (the sum of weights), the poll count,
the window used, and the number of polls skipped.

**`Forecast::RaceModel`** — the central estimate.
Senate prior `lean + national_env + 1.5 × incumbent_direction`;
House prior `baseline_margin + (national_env − house_national_margin_2024) +
open_seat_term`; blended with the poll average at `w = min(1, W / 3.0)`,
`mu = w × average + (1 − w) × prior`.

**`Forecast::Simulator`** — 10,000 worlds. One national error per world, shared
by every race in both chambers, plus one independent error per race, every sigma
multiplied by `t`. Winner is side A when the margin is ≥ 0.

**`Forecast::Runner`** — opens the `ModelRun`, records `Pol::Params.to_h` and the
seed on it, writes 470 forecasts and two chamber rows in a single transaction,
closes the run. A run can be reproduced exactly from its own row.

## C. Decisions this phase had to make

1. **Polls that do not measure the modelled matchup are dropped before the
   one-per-pollster cut, not after.** The specification listed the window and
   the per-pollster rule first, but the live data settles the order. Wikipedia
   pages publish several matchup tables per race, so Tavern Research has four
   Nebraska rows fielded on the same days, of which exactly one is the
   Osborn-vs-Ricketts contest the model is forecasting; Montana's page carries
   both a three-way and a two-way version of the same poll. Deduplicating first
   keeps whichever row has the highest id and then discards that pollster for
   "missing a side" — losing the poll that actually measures the race. The
   widening test counts usable polls for the same reason. `skipped_count`
   reports the dropped rows rather than hiding them (Nebraska: 3 skipped, 1
   kept).

2. **Incumbency is read from `open_seat`, not from the candidate flag.** Phase 2
   defines `open_seat` as true exactly when the sitting senator is not on the
   November ballot, which is the only signal that covers **South Carolina**:
   the appointed incumbent (Darline Graham) is running, but the Republican
   nomination is unsettled, so no candidate row carries the incumbent flag. Read
   from candidates alone, South Carolina would silently lose its −1.5. An
   appointed incumbent seeking the seat counts as an incumbent (FL, OH, SC); an
   appointee who cannot run does not (OK, where `open_seat` is true).

3. **The House open-seat term is written out and inert.** Phase 2 seeds no 2026
   House incumbency or retirements — it read the 2024 results page, which
   carries neither — so `race.open_seat` is false for all 435 districts and
   `open_seat_term` is 0 everywhere today. It is implemented in full
   (`−open_seat_adj × incumbent_party_direction`, so an open seat docks the
   retiring party's advantage) so the formula self-activates the day a Phase 6
   admin or a later scraper marks a district open. Both halves are tested.
   Senate open seats never come through this path: they are already handled by
   `incumbent_direction` going to zero.

4. **A race with no Democrat is modelled on the same prior as one with a
   Democrat.** Idaho, Nebraska and South Dakota each field a Republican and an
   independent with no Democrat on the ballot. Side A becomes the independent
   and the margin scale becomes side A minus side B, but the prior is still
   `lean + national_env + incumbency` — the state's Democratic lean standing in
   as a proxy for the anti-Republican vote. This is an approximation and is
   flagged as one in the code. An independent-specific prior would be a number
   with nothing behind it, and the alternative (no forecast for those three
   seats) is worse.

5. **Party and caucus are different questions, deliberately.** `p_dem_win` is
   the probability a **Democratic-party** candidate wins, so an independent's
   chances land in `p_other_win` however they intend to caucus. Chamber control
   reads the **caucus** instead: dem/rep by party, an independent's declared
   `caucus_with` where there is one, and `uncommitted` where there is not. All
   five 2026 independents are uncommitted (Phase 2 §D, known caveats).

6. **Worlds where an uncommitted independent holds the balance count for
   neither party.** With `vp_party: rep`, Democrats control at 51 and
   Republicans at 50; a simulation where neither threshold is met is counted for
   neither, so `p_dem_control + p_rep_control` sums to **less than 1** by design.
   In the live run that remainder is 0.07% of Senate simulations. It is small
   because Osborn wins Nebraska in only 0.9% of worlds and is pivotal in fewer
   still — but it is the honest number, and the test suite constructs the case
   where it is 50.7%.

7. **Uncontested races are certain and take no noise**, contributing a fixed
   seat rather than 10,000 identical draws. `uncontested` is false for every
   race today (Phase 2 §C). A race flagged uncontested with **no**
   `uncontested_party` recorded is treated as contested: an incomplete flag is
   not a certainty, and inventing the winner would be worse than simulating it.

8. **With no generic-ballot polls at all, the national environment falls back to
   `house_national_margin_2024` (−2.6), not to zero.** Zero would assume a tied
   national vote and shove every district 2.6 points toward the Democrats for
   want of data; the 2024 result leaves every district exactly at its baseline,
   which is the genuinely neutral starting point. Logged as a warning when it
   happens; it does not happen with 559 generic-ballot polls in hand.

9. **Percentiles are nearest-rank, not interpolated** — the reported 5th
   percentile is a margin the simulation actually produced. **A margin of
   exactly zero goes to side A**; it is a measure-zero event on a continuous
   distribution and the rule exists only so the code has no undefined case.
   **The time multiplier is floored at 1.0** on and after election day, so a
   back-dated or late run cannot shrink the error below its election-day value
   or invert it.

10. **A recorded sample size of zero is an unknown sample size**, not a poll of
    nobody, and falls back to the default 400. The scraper already normalises
    zero to nil (Phase 2 §D5); manual and CSV entry can still produce one.
    Relatedly, "polled" means *there is an average to blend*, not *rows exist*:
    a race whose polls carry no weight sits on its prior, which is also what
    stops the blend ever multiplying by a missing mean.

11. **One run at a time, enforced by the database.** `model_runs` carries a
    partial unique index over `status = running`, so two workers inserting in
    the same instant cannot both open a run — the check and the insert are one
    operation, and every path in is covered rather than only the ones that
    remember to ask. A run left `running` by a killed worker would otherwise
    block every later run forever while the site served stale numbers, so the
    next run fails anything older than `simulation.stale_run_minutes` (30 —
    about a thousand times the 1.6 s a run takes, and well inside the 2-hour
    scrape cadence) and takes over, leaving the abandoned row its own
    `error_message` rather than sweeping it away.

12. **Race order is part of the seed.** Draws come off one Box–Muller stream, so
    the runner always orders races by id; the same seed with the races in a
    different order is a different (still valid, still reproducible) run.

## D. Performance

The budget was 60 seconds for a full run. Measured on the live board (470 races
× 10,000 simulations = 4.71 million race draws plus 10,000 national draws):

| | |
|---|---|
| Full `bin/rails pol:model` | **1.6 s** (2.2 s including Rails boot) |
| Simulation only, mean of 5 | **1.41 s** |
| Everything else (queries, averaging, 472 inserts) | ~0.2 s |

No optimisation was needed and no dependency was added. Three things keep it
cheap: the per-sim national errors are drawn once into an array and reused by
every race; each race loops over simulations rather than the other way round, so
its `mu` and sigma are read once; and Box–Muller's second normal is kept rather
than discarded, halving the transcendental work.

There is roughly 35× headroom against the budget, which is worth knowing because
**10,000 simulations is not free of noise**. Across five seeds on identical
inputs, the Senate control probability ranged 30.0%–31.5% (spread 1.4 points)
and the House 95.9%–96.2% (spread 0.4 points). The Senate is noisier because
control is a threshold statistic. Two consequences: run-to-run "movement" below
about 1.5 points is simulation noise, not news — comfortably below Phase 5's
`movement_threshold` of 8 points — and if a later phase wants tighter headline
numbers, `simulation.n_sims` is the lever and the budget can afford it.

## E. Live run

`bin/rails pol:model`, August 11, 2026, against the full seeded board (35 Senate
races, 435 districts, 800 polls). Run 4, seed 2426173658350254384, 1.56 s.

| | |
|---|---|
| Generic ballot (D−R) | **+6.43** from 30 polls (W = 14.68, 45-day window) |
| Implied House swing since 2024 | +9.03 |
| Error inflation `t` | 1.4667 (84 days out) |
| **Senate** | **D 30.6% / R 69.3% / neither 0.1%**, mean 49.3 D-caucus seats (range 40–59, mode 49) |
| **House** | **D 96.1% / R 3.9%**, mean 240.5 D seats (range 189–307, mode 240) |

Senate detail: 22 of 35 races polled, 13 unpolled (carrying `sigma_state_unpolled`);
19 races between 5% and 95%; 15 Democratic favourites, 20 Republican. The
closest are MI (D 45.4%), TX (D 66.4%), IA (D 25.8%), NC (D 79.2%), OH-special
(D 20.7%) and FL-special (D 20.2%). In the House, 236 seats are Democratic
favourites and 114 are between 5% and 95%.

The three independent-side races behave as designed: Nebraska is
`p_dem_win 0.0000 / p_rep_win 0.9909 / p_other_win 0.0091` — no Democrat is on
the ballot, so the Democratic probability is a true zero rather than a missing
value, and Osborn's 0.9% sits in `p_other_win` while his caucus stays
uncommitted for the chamber count. Idaho and South Dakota are the same shape at
longer odds.

**Read the House number with §A4 in mind.** A 96% probability is more confident
than this model has earned: with one correlated error term instead of four, the
seat distribution is too narrow. The Senate figure is less exposed, because 35
races cannot average away as much as 435.

## F. Tests

112 new tests (the suite goes 191 → 303), all off fixtures and hand arithmetic;
nothing touches the network. The load-bearing ones:

- **Averager** — every weighted mean is a literal worked out from the published
  formula and written into the test with its derivation, so the implementation
  cannot move the goalposts. Window widening, the boundary day, one-per-pollster
  and its two tie-breaks, the default sample size, the sample-size cap, the
  top-result-per-party rule, and the independent-sides case.
- **RaceModel** — the four incumbency signs including the South Carolina case
  with no candidate row; House swing arithmetic in both directions; the
  open-seat term inert and active; blend goldens at w = 0, 0.5 and 1 (built from
  polls whose weights are exactly 1.0 and 1.5); sigma selection; six
  side-resolution cases; four uncontested cases.
- **Simulator** — a fixed-seed golden (2 races, 100 sims) asserting exact win
  counts, percentiles and seat histogram, **plus** a 200,000-draw run checked
  against the closed-form normal, so the golden is a record of correct behaviour
  and not of a bug. Determinism, seed sensitivity, order sensitivity. The shared
  national error demonstrated two ways: near-zero independent error makes the
  seat histogram bimodal, huge independent error makes it centred. The
  uncommitted-independent rule as a matched pair — the same race and the same
  draws, differing only in the caucus flag, gives `p_dem + p_rep = 0.493` or
  exactly 1.0. Sigmas shown to scale exactly with `t`.
- **Runner** — a full-scenario fixed-seed golden over the fixture world, with
  Maine's `mu` cross-checked by hand; reproducibility; the 2024 fallback; the
  governor exclusion; and three failure paths, including one that proves a
  half-written run rolls back and leaves the previous succeeded run showing.
- **Concurrency** — the unique index proven by a second `create!` raising, with
  the enum-to-index literal pinned alongside it so the two cannot drift; a run
  abandoned past the cutoff failed and succeeded by its replacement, through
  both the job and the runner; a run inside the cutoff still blocking.
- **Parameter linkage** — the constants that decide chamber control and window
  widening are tested by *moving* them: flipping `vp_party` turns 50 Democratic
  seats from no control into control, and raising `min_polls_in_window` widens
  a window that two polls had held.

---

# Phase 4 — Public site

Eight routes, all unauthenticated, all served by subclasses of
`PublicController` (which is the one place `allow_unauthenticated_access` is
called). No external facts; the numbers below are measurements.

## A. The routes

| Route | What it shows |
|---|---|
| `GET /` | Two chamber cards with compact seat histograms and the House caveat, the generic-ballot environment, Movers, the five latest dispatches |
| `GET /senate` | All 35 races, sortable by state / rating / probability / margin / poll count / last poll, both directions |
| `GET /house` | Chamber summary, full seat histogram, caveat, all 435 districts, client-side search |
| `GET /races/:slug` | Header and candidates, lead sentence, forecast detail with percentile interval, win-probability timeline, polls scatter and table, this race's dispatches; 404 on an unknown slug |
| `GET /dispatches` | Every published dispatch, reverse chronological |
| `GET /methodology` | Every `config/model_params.yml` value with its citation, the formulas in prose, known limitations |
| `GET /about` | The no-secret-sauce thesis, the editor model, contact |

## B. `site:` params added

`movers_window_days: 7`, `movers_count: 6` and `tossup_band_pp: 65.0` are
editorial choices with no external source, and the methodology page correctly
shows them with no citation. `movers_floor_pp: 1.5` is the one with a source,
and the source is our own engine: Phase 3 measured ~1.4pp of run-to-run Monte
Carlo noise on Senate control at `n_sims = 10,000`, so the floor sits just
above the model's own noise rather than being picked from nowhere.

## C. Charts — one decision per chart

- **Seat histograms (dashboard, `/house`)** — server-rendered SVG. A static bar
  chart over a few dozen known bins, needed at two sizes, with no interaction:
  a fixed-`viewBox` SVG does that with zero JavaScript. Bins are shaded on one
  axis only (meets the Democratic-control threshold or does not) because the
  histogram counts Democratic-caucus seats per simulated world, and for the
  Senate that single number cannot distinguish "Republicans control" from "an
  independent holds the balance". The exact `p_dem_control` / `p_rep_control`
  are printed as text beside the chart, not read off it.
- **Win-probability timeline and polls scatter (race pages)** — D3 in Stimulus
  controllers, reading a sibling `<script type="application/json">` payload
  built server-side. The timeline handles 0, 1 and many runs without template
  branching (one run renders as two dots and no line, which is the common case
  today). The scatter's reference line is the *live* weighted average from
  `Forecast::Averager`, deliberately not the forecast's stored `mean_margin` —
  that is the simulator's blended output, a different number by design.
- **Senate-table trend cell** — a plain diverging CSS bar, capped at ±30pp. 35
  D3 initialisations for a decorative cell is the clunkiness this site is
  trying to avoid.

D3 is vendored through importmap as six used modules plus their direct
dependencies (12 files, ~160KB) rather than the `d3` meta-package (37 files,
~830KB). `bin/importmap audit` is clean.

## D. Performance — bounded queries and real fragment caching

Query counts are asserted at the *controller* level, with extra ad-hoc rows
added, so the test fails if the count starts scaling with the number of races:

| Page | Queries, warm |
|---|---|
| `GET /house` (435 districts) | 5 |
| `GET /senate` (35 races) | 5 |
| `GET /` | 8 |

That test exists because a real N+1 got through the builder-level test: the
first `/house` template called `formatted_margin`, which routes through
`Site::RaceSides.for(race.candidates)` and lazy-loaded candidates once per row
(6 queries at 1 district, 11 at 6). House races structurally have no candidates
seeded, so the fix was House-specific `house_margin` helpers that never ask.

Every heavy surface is wrapped in a `cache` block keyed on the run its numbers
come from, plus whatever else can change it (sort order, the race, the race's
latest dispatch, a collection-freshness key). The suite runs with
`:null_store`, so a dedicated test (`test/controllers/fragment_caching_test.rb`)
swaps in a real `MemoryStore` on the controller class to prove reuse and
invalidation actually happen rather than assuming the key is right.

---

# Phase 5 — Agent newsroom

Research date: **August 11, 2026**. The model slugs, the ruby_llm API and the
cron timezone syntax below were each checked against a live source or the
installed gem on that date; nothing here is from model memory.

This is the phase where the site starts publishing on its own. There is no
approval queue and there is not going to be one. What stands in its place:

- a context payload built only from our own tables, and a system prompt that
  says the payload is the whole world (§B1);
- validation on **our** side of every draft, applied regardless of what the
  model returned, with one retry and then silence (§B2);
- caps per race per day, per day overall, and per race per week for movement
  notes, all counted against what is actually published (§B3);
- a kill switch checked at the top of every job;
- a `newsroom_skips` row for every piece that did not get written (§B4).

## A. Verified facts

### A1. The OpenRouter model slugs

`GET https://openrouter.ai/api/v1/models` (public, no key), retrieved
2026-08-11: 402 models, 28 of them Anthropic. The current Sonnet-tier entry:

| field | value |
| --- | --- |
| id | `anthropic/claude-sonnet-5` |
| canonical_slug | `anthropic/claude-sonnet-5-20260630` |
| context / max completion | 1,000,000 / 128,000 |
| pricing | $2.00 per M input, $10.00 per M output |
| supported_parameters | includes `response_format`, `structured_outputs`, `max_tokens` |

Those three parameters are exactly what `Newsroom::Client` depends on, which is
why the check was worth making rather than assuming. Both `newsroom.writer_model`
and `newsroom.brief_model` are set to it. Note what is **not** in that list:
`temperature`. ruby_llm only sends the field if asked, and we do not ask.

`anthropic/claude-sonnet-4.6` is still listed (and cheaper per token than it
was) but is the previous generation; the two slugs are interchangeable in
`config/model_params.yml` with no code change, which is the point of keeping
them there.

citation: https://openrouter.ai/api/v1/models (retrieved 2026-08-11)

### A2. ruby_llm 1.16.0 — the API this actually uses

Read out of the installed gem at
`~/.gem/ruby/4.0.0/gems/ruby_llm-1.16.0`, not from memory. The mechanisms
`Newsroom::Client` relies on, with where each one lives:

- **`RubyLLM.chat(model:, provider: :openrouter, assume_model_exists: true)`** —
  `Models.resolve` (lib/ruby_llm/models.rb:154) skips the bundled registry when
  `assume_exists` is set and builds a `Model::Info.default`. Necessary: the
  bundled `models.json` does not carry OpenRouter's catalogue, so resolving
  `anthropic/claude-sonnet-5` without it raises `ModelNotFoundError`.
- **`#with_schema(hash)`** — `Chat#normalize_schema_payload` (chat.rb:182) takes
  `{name:, strict:, schema:}`, and `Providers::OpenRouter::Chat#render_payload`
  turns it into `response_format: {type: "json_schema", json_schema: {...}}`.
  On the way back, `Chat#normalize_schema_response` JSON-parses the reply, so
  `message.content` arrives as a Hash with **string** keys.
- **`#with_params(max_tokens:)`** — `Provider#complete` (provider.rb:48)
  deep-merges `params` into the rendered payload. This is how the output bound
  is applied; there is no first-class max-tokens setter.
- **`message.model_id`** — OpenRouter's own `model` field from the response
  body (openrouter/chat.rb:77), i.e. the model that actually served the
  request. That is what the byline says, falling back to the configured slug.
- **`message.input_tokens` / `#output_tokens`** — from the response `usage`.
- **Errors** — `ErrorMiddleware.parse_error` maps status codes to
  `RubyLLM::UnauthorizedError` (401), `PaymentRequiredError` (402),
  `RateLimitError` (429), `ServerError` (500), `ServiceUnavailableError`
  (502–504), `OverloadedError` (529). `Connection#setup_retry` retries 429s,
  5xxs, timeouts and connection failures `config.max_retries` (3) times with
  backoff **including on POST**, so a transient failure has already been
  retried three times before `Newsroom::Client` ever sees it.
- **`config.openai_use_system_role`** — found by asserting on the request in a
  test: without it, ruby_llm's OpenAI-compatible providers send the system
  prompt with `role: "developer"` (openrouter/chat.rb:125), OpenAI's newer
  name for it. We talk to an Anthropic model through OpenRouter, where
  `"system"` is the role every hop understands, so the initializer sets it.

### A3. Cron with a timezone

good_job 4.19.2 parses cron strings with fugit (README §"Cron-style
repeating/recurring jobs"), and fugit 1.13.0 reads a **sixth field** as a
timezone name:

```
Fugit.parse_cron("0 7 * * * America/New_York").zone  # => "America/New_York"
```

Verified against the installed gems, and asserted in the suite on both sides
of a DST boundary: the 07:00 brief resolves to 11:00 UTC in July and 12:00 UTC
in December. A schedule without the zone would follow the server's clock, and
"07:00" on a UTC box is 3am Eastern for half the year — a bug that appears
only after a deploy, in production, to readers.

## B. How the newsroom works

### B1. The payload is the world

`Newsroom::Context` builds one hash per piece, entirely from our tables: the
race and its candidates, the current forecast and the prior one, the new polls
(pollster, field dates, sample size, population, source domain, per-candidate
results), the national picture, recent headlines to avoid repeating, today's
date and the days to the election. Probabilities and margins are pre-formatted
through `Site::Format`, so a dispatch and the race page it links to cannot
disagree about what the same number is called.

It also carries `citable_poll_ids` — the exact set a citation may name, which
is what the validator holds the model to.

### B2. Validation is ours, not the model's

`Newsroom::Validation` runs against the parsed reply and assumes nothing about
the schema having been honoured: the headline, dek and body caps from
`config/model_params.yml`; no markdown structure the site cannot render
(headings, bullet or numbered lists, block quotes, code fences, tables — the
view uses `simple_format`, so a heading would publish as a literal `## `); and
strictly no cited id outside `citable_poll_ids`. A poll reaction that cites
none of the polls it is reacting to is also rejected: nothing in it could be
traced to a source.

A rejected draft gets exactly one more turn, in the same conversation, with the
validator's own messages appended. A second failure publishes nothing and
writes a `validation_failed` skip. Nothing invalid reaches the page.

### B3. Caps

Counted immediately before each piece, against rows in `dispatches` rather than
an in-process counter, on **America/New_York** days — the clock the readers and
the 07:00 brief are on. `max_dispatches_per_race_per_day` counts every
published dispatch for that race today, not only the kind being written: the
parameter is a budget for how much this site may say about one race in a day,
and three poll reactions plus a movement note is four pieces about the same
race whatever they are called.

The duplicate guard is a jsonb containment query (`cited_poll_ids @> '[42]'`,
OR'd per id — the tidier `?|` only matches *string* elements, and these are
stored as JSON numbers), so a poll that any published dispatch already cites is
not news twice.

### B4. Every silence is recorded

`newsroom_skips` — kind, race, reason (`validation_failed`, `cap_reached`,
`duplicate`, `agents_disabled`, `no_api_key`, `llm_error`), detail, and a
SHA256 digest of the payload. `NewsroomSkip.record!` is the only way one gets
written and it always logs. The API key cannot travel into a detail:
`Newsroom::Client.sanitize` strips it and truncates, and a test proves it with
a 401 whose message contains the key.

## C. Decisions this phase had to make

### C1. Poll ids travel with the run

`Ingest.after_new_polls!` used to take a count. It now takes ids, because by
the time a reaction is written, a poll created two minutes ago and one created
two hours ago are indistinguishable in the table — only the sweep knows which
ones it created. They flow scrape → `Forecast::RunJob` → `Newsroom.after_model_run!`,
and reactions are only queued after the run those polls caused has **succeeded**,
so the piece can quote a forecast that includes them.

**Known cost:** a run refused by the concurrency guard (`AlreadyRunning`) drops
its poll ids. The run that won will publish the numbers, but nothing reacts to
those particular polls. Two sweeps would have to overlap for it to happen, and
the alternative — reacting against a run that may not have included them — is
worse than a missing piece.

### C2. `movement_note_cooldown_days` is a new parameter

"Max one movement note per race per rolling seven days" needed a seven from
somewhere. Reusing `site.movers_window_days` would conflate two different
questions — how far back movement is measured, and how often the same race may
be written up — so it is its own parameter. House rule: if a constant is not in
`config/model_params.yml`, it does not exist.

### C3. Comparison-run selection is now shared

`Site::Movers#comparison_run` moved to `ModelRun.comparison_run`, so the
dashboard's movers module and the newsroom's movement notes answer "what did
this look like last week" with the same run. The newsroom's threshold
(`newsroom.movement_threshold`, 0.08 of win probability) is deliberately far
above the dashboard's noise floor of 1.5 points: a table can afford to show a
small shift, a paragraph of prose about one cannot.

The comparison rounds the delta to four decimal places before testing it
(`Movement::PROBABILITY_PLACES`). Win probabilities are counts over
`simulation.n_sims` draws, so at 10,000 sims four places is all the resolution
there is — and `0.62 - 0.54` is `0.07999999999999996` in binary floating point,
which would otherwise make a race that moved exactly eight points a
non-mover.

### C4. The 06:30 model run

`pol_daily_model` closes a gap that was real before this phase and easy to miss:
the only thing that ran the model was ingestion finding new polls. On a quiet
day nothing re-ran it, so the numbers sat still while the "as of" timestamp on
every page aged. Now the floor is one run every morning at 06:30 Eastern, half
an hour before the brief, which also means the brief is always written from
same-day numbers.

Both daily times are literals in the initializer rather than parameters: they
are publication times, not model constants. Tests pin them.

### C5. What the payload deliberately does not say — and what that cost

See §D. The payload does not carry which party currently controls either
chamber, because that fact is not in our tables and this project does not
publish facts it has not verified. The first live brief filled the gap by
itself and got it wrong. The fix was two-sided: give the model the thresholds
we **do** have verified (`chambers.house_majority_seats`,
`senate_total_seats`, `vp_party`, derived exactly as
`Forecast::Simulator#senate_outcome` derives them), and tell it plainly that
current control is not something it knows.

## D. Live run

One live daily brief was the acceptance test for the whole phase:
`bin/rails pol:brief`, real credential, real OpenRouter, real publication.
It ran twice — once as the proof, and once more after the proof found a defect.

### D1. First call — published, and wrong in one sentence

`anthropic/claude-sonnet-5`, 4,245 input / 1,139 output tokens, about **2.0
cents** at the published $2/$10 per M. Headline: *"Generic ballot sits at D+6.4
as House and Senate outlooks diverge."* Every poll number in it was correct,
every one attributed to a pollster with field dates and sample frame, and the
House caveat was carried in full.

Two sentences were not defensible:

> "Our model gives Democrats a **96 in 100 chance of holding the House**" —
> the payload never said who holds the House, and Democrats do not.

> "a mean of 49.2 seats — **short of the 50 needed** with the chamber's
> tiebreak structure" — 50 is the Republicans' number. The vice president is a
> Republican, so a tie goes to them and Democrats need 51. The payload gave
> neither figure, so the model supplied its own.

Both are the same failure: a gap in the payload filled from outside it. That is
the exact failure mode the whole design is meant to prevent, and it took a live
call to find, because a stubbed test can only assert what we thought to stub.

### D2. The fix

- `Newsroom::Context` now puts the control thresholds in the payload —
  `dem_seats_needed: 51`, `rep_seats_needed: 50`, and the tiebreak in words —
  derived from the same parameters the simulator counts against, plus the
  House's 218.
- The system prompt gained a "WHAT THE PAYLOAD DOES NOT TELL YOU" section:
  current control is not known, so write about *winning* control, never
  holding, keeping, defending, losing or flipping it; and use no seat
  thresholds but the ones given.
- Two context tests and one writer test pin both.

### D3. Second call — the one on the page

`anthropic/claude-sonnet-5`, 4,453 input / 1,415 output tokens, about **2.3
cents**. Total live spend for the phase: **4.3 cents**.

> **Democrats hold generic ballot edge as Senate battle stays close**
> *Our average puts Democrats up 6.4 points nationally, but the Senate math and
> a cluster of new state polls show a tighter contest underneath.*

349 words, four paragraphs, 12 polls cited, all 12 in the payload. Checked line
by line against the rows: Quantus 1,048 LV Aug 3-4 D+49-43; Reuters/Ipsos
July 29–Aug 3 at 36-30 among 4,505 adults and 42-37 among 3,542 RV;
Economist/YouGov July 31–Aug 3 at 41-33 among 1,607 adults and 46-42 among
1,472 RV; Morning Consult 24,000 RV 46-42; Change Research Aug 3-6 Cooper 50
Whatley 43; Hart Research Jackson 49 Collins 45; YouGov Blue and Wedgewood in
Texas; Emerson in Iowa. Every figure, sample size, population and field window
matches the database exactly. The Senate arithmetic reads correctly now: "a 31
in 100 chance of winning Senate control … 49.2 seats against the 51 needed;
Republicans need only 50 because the vice president, a Republican, breaks a
50-50 tie." The House caveat is in the model's own words, with the 84% figure.

It renders on `/dispatches` under "Written autonomously by
anthropic/claude-sonnet-5". The first brief was retracted rather than deleted —
it is the honest record of what the system did before the fix, and retracting
it is what the Phase 6 admin would do.

### D4. Rough edges seen live

- **Output budget.** 1,415 output tokens for a 349-word brief; the cap is
  2,000. A model that ran long would be truncated mid-JSON, which is a
  validation failure and a retry rather than a bad publication — but the margin
  is only about 1.4x, and `newsroom.max_output_tokens` is the dial if briefs
  start getting cut off.
- **Cost at the cap.** 40 dispatches a day at ~2.3 cents is under a dollar a
  day. The caps bound spend as well as volume.
- **Prompt weight.** ~4.3k input tokens per call, of which the payload is about
  1.8k. Nothing to fix yet; worth watching if the brief's poll list grows.

## E. Tests

136 new tests (the suite goes 412 → 548). Every LLM call in the suite is
WebMock-stubbed against `https://openrouter.ai/api/v1/chat/completions`;
nothing reaches the network, and the API key is forced to a literal for the
duration of each test so the suite behaves identically on a machine with the
real credential and one without. The load-bearing ones:

- **Client** — the request shape as OpenRouter receives it: the slug from
  params (and a params override proving a model swap needs nothing else), the
  max-tokens bound, a strict `json_schema` response format, the system message
  under the `system` role, and an `Authorization` header asserted **present**,
  never compared. Parsed structured output, the served model id and its
  fallback, a non-JSON reply becoming nil data rather than an exception, the
  conversation surviving a second `ask`, and 401/429/500/503/timeout all
  arriving as one `Client::Error`.
- **Validation** — every cap moved through `with_params` to prove it is read
  and not hardcoded; six kinds of markdown structure rejected, and a
  hyphenated aside *not* mistaken for a bullet list; an excess cited id
  rejected; a numeric-string id accepted; and all four problems with a badly
  broken draft reported at once, because the retry gets one turn to fix them.
- **Writer** — a valid draft published with the served model as its byline; an
  over-cited draft producing a second request whose body contains the
  validator's complaint, then publishing; two bad drafts publishing nothing and
  leaving one `validation_failed` skip with a payload digest; a 401 whose
  message contains the key proving the key cannot reach the skip log.
- **Caps** — the Eastern day boundary tested with two dispatches an hour apart
  across 04:00 UTC, one inside the cap and one outside it; the duplicate guard;
  the movement cooldown on both sides.
- **Triggers** — the kill switch (stored and `AGENTS_DISABLED`) and the missing
  key each producing a skip row and *no* HTTP request; the pipeline handoff
  asserted end to end (sweep → poll ids → run → the reaction job's arguments);
  a failed run and a run that stepped aside queueing nothing.
- **Cron** — both new entries, and their parsed fugit schedules, including that
  the model run comes before the brief and that 07:00 Eastern is 11:00 UTC in
  July and 12:00 UTC in December.

## F. Known gaps

- **Current chamber control is not in the data model** (§C5). The newsroom now
  writes around it. Adding it properly — a verified fact with a citation, the
  way Phase 2 added the holdover counts — would let a brief say "flip" and
  "defend", which is how these races are actually discussed.
- **Poll ids are dropped by a refused run** (§C1).
- **The daily brief does not know about races it is not shown.** It sees the 12
  most recent polls and the movers; a race that is quietly extraordinary but
  unpolled this week is invisible to it.
- **One retry, one model.** If the writer model is down, the piece is skipped
  rather than tried on a second model. `newsroom.writer_model` is a one-string
  swap, but nothing does it automatically.
- **The caps are read-then-write, not atomic.** Two newsroom jobs running
  concurrently could each see room under a cap and both publish. The database
  guard that makes forecast runs safe (a partial unique index) has no clean
  equivalent here, because "three a day" is a count and not a uniqueness
  constraint. In practice the window is the length of one LLM call and needs
  two model runs to finish inside it, which the 2-hour scrape cadence makes
  unlikely; the damage is bounded by the caps themselves — a duplicate piece,
  not an unbounded one. If it ever happens, good_job's concurrency extension
  (`perform_limit: 1` keyed on the newsroom) would serialise the jobs.

---

# Phase 6 — Admin

The editor's cockpit at `/admin`: eleven controllers, the GoodJob dashboard,
and the two levers a human has over an autonomous newsroom (retract, and the
kill switch). No external facts; two environment facts were verified by
running them, and both are recorded below.

## A. Gating

`Admin::BaseController < ApplicationController` is empty. That is the point:
`ApplicationController` requires authentication by default (Phase 0 §B), so an
admin controller is gated by *not* opting out, and a new action added later is
covered without anyone remembering to add a filter.

The proof asks the router rather than a hand-written list.
`Admin::AuthenticationTest` walks `Rails.application.routes.routes`, filters to
controllers under `admin/`, asserts there are at least 25 of them (so the test
itself fails loudly if `routes.rb` changes shape), fills in dynamic segments,
issues each route with its real verb, and asserts a redirect to sign-in.

The GoodJob dashboard is a mounted engine whose controller is not in this app's
hierarchy, so it is gated through the extension point GoodJob's README
documents for exactly this — `ActiveSupport.on_load(:good_job_application_controller)`
(see https://github.com/bensheldon/good_job#authentication) — using
`Session.from_signed_cookie(cookies)`, the same lookup
`Authentication#find_session_by_cookie` uses, extracted so there are not two
independent definitions of "signed in" to drift apart. An unauthenticated
request gets a plain 404, matching GoodJob's own suggested behaviour; a forged
cookie value gets the same, which is a separate test (the gate verifies the
signature, not the presence of a cookie).

## B. CSV import, and why there is a hand-rolled parser

**Verified, not assumed:** `bundle exec ruby -e 'require "csv"'` fails with
`LoadError` on this Ruby. As of Ruby 3.4 `csv` is a *bundled* gem rather than a
default one — installed with Ruby but off the load path unless it is in the
Gemfile — and it is not in `Gemfile.lock`. Adding it would be a new dependency,
which the house rules rule out.

So `Admin::SimpleCsv` is a character-by-character parser covering the RFC 4180
subset a spreadsheet export actually produces: commas, quoted fields containing
commas or newlines, CRLF or LF, blank lines skipped, short rows filled with
`nil`. Documented gap: `""` as an escaped literal quote inside a quoted field is
not supported — the outcome is a garbled-but-contained field, not an exception.
Swapping in the real gem later is a one-line Gemfile change plus deleting the
file: `Admin::PollCsvImport` only calls `Admin::SimpleCsv.parse(text)`.

Two guards the import needs that the poll recorder cannot provide:
`population` is checked against `Poll.populations.keys` before assignment
(Rails enums raise `ArgumentError` on an unknown value, which is not something
`Ingest::RecordPoll` could turn into a graceful `:invalid` row), and a
non-numeric percentage is passed through as the original string rather than
`to_f`'s silent `0.0`, so `RecordPoll` rejects the row instead of recording a
fake zero.

A UTF-8 byte-order mark was found (in review) to make the first header cell
`"﻿race_slug"`, which silently filed every imported poll under the generic
ballot. The strip is now at the byte level, before decoding.

## C. One door in, two doors out

All three entry modes go through `Ingest::RecordPoll` — the scraper with
`entry_mode: :scraped`, the manual form with `:manual`, the importer with
`:csv`. **Editing** does not, deliberately: `RecordPoll` is create-or-report-
duplicate and its dedup check assumes it is comparing against *other* rows.
`Admin::UpdatePoll` recomputes the digest with the same public functions
(`Pollster.canonicalize`, `Poll.compute_digest`) and excludes the row being
edited from the collision check.

Poll create, edit and destroy call `race.touch`, which is what keeps Phase 4's
fragment caches honest — a poll edit that did not touch the race would leave
the race page's cached fragment showing the old poll table. An edit that moves
a poll between races touches both.

---

# Phase 7 — Hardening + acceptance

Closing phase: the end-to-end proof, the acceptance run, the README, and the
handoff. Executed **August 11, 2026**; every number below is from a command run
that day against this checkout and the live development database.

## A. The end-to-end test

`test/system/full_pipeline_test.rb` — one Capybara/headless-Chrome test that
drives the whole loop with no network:

1. The race page is read *before*: Maine Senate at Tossup, `D 62%`, "62 in 100".
2. A poll is recorded through `Ingest::RecordPoll` — the same door the scraper
   uses for a parsed row — at D 62.0 / R 33.0, n=1,500 LV.
3. `Ingest.after_new_polls!` is called, exactly as the end of a sweep calls it,
   inside `perform_enqueued_jobs`. `Forecast::RunJob` re-runs the model;
   `Newsroom::PollReactionsJob` writes a reaction citing that poll;
   `Newsroom::MovementNotesJob` writes up the swing it caused.
4. The race page is read *again*: Favors Dem, `D 99%`, "99 in 100", the mean
   margin, the new run's "as of" timestamp, the poll's own row at `D+29.0`, and
   both new dispatch cards. Then the dashboard, then the Senate table — a
   different query object (`Site::SenateTable`) over the same forecast.

OpenRouter is WebMock-stubbed with a reply shaped like the live API's, keyed on
the assignment line in the system prompt and echoing back the payload's own
`citable_poll_ids`, so `Newsroom::Validation` genuinely decides whether the
drafts publish rather than being bypassed. The RNG seed (`20260811`) and
`n_sims` (2,000) are pinned, so the page shows the same numbers every run:
`p_dem_win` 0.62 → **0.9935**, mean margin 3.2 → **16.58**. 34 assertions,
1.5s, run four times with identical results.

Rails excludes `test/system` from `bin/rails test` by design, so the previously
commented-out system-test step in `config/ci.rb` is now enabled;
`.github/workflows/ci.yml` already ran `test:system` as its own job.

## B. Acceptance — commands and what they printed

### 1. `bin/setup` runs clean and non-destructively

`bin/setup` uses `bin/rails db:prepare`, and reaches `db:reset` only behind an
explicit `--reset` flag it was not given. Verified before running.

```
$ bin/setup --skip-server        # 1.57s
== Installing dependencies ==      The Gemfile's dependencies are satisfied
== Preparing database ==           (no output — 16/16 migrations already up)
== Removing old logs and tempfiles ==
```

Development database before and after, unchanged: **800 polls, 470 races, 470
forecasts, 2 model runs, 2 dispatches, 1 user, 72 scrape runs**, 16/16
migrations up. `--skip-server` is used because the bare command `exec`s into
`bin/dev`, which never returns.

### 2. Suite, style, and the security scans

| Command | Result |
|---|---|
| `bin/rails test` | **713 runs, 2,406 assertions, 0 failures, 0 errors, 0 skips** (1.9s, 16 parallel workers) |
| `bin/rails test:system` | **1 run, 34 assertions, 0 failures** |
| `bin/rubocop` | 216 files inspected, no offenses |
| `bin/bundler-audit` | No vulnerabilities found |
| `bin/importmap audit` | No vulnerable packages found |
| `bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error` | **Errors 0, Security Warnings 0** — exit 0 |

Suite by area: models 92, jobs 55, lib 427, controllers 139, system 1.

**The one brakeman warning, and why it is gone.** Phase 5 left a medium-
confidence SQL Injection warning on `app/models/dispatch.rb:25`, the
`citing_any` scope — the newsroom's duplicate guard. It was a false positive:
the scope joined the frozen literal `"cited_poll_ids @> ?"` *n* times and bound
`to_i`'d values, so nothing but literal text ever reached the SQL string.
Brakeman cannot see that a string assembled at runtime holds only literal text,
and reports the assembly itself.

It could have been suppressed with a written justification. It was rewritten
instead, because a suppression has to be re-argued by every future reader while
a structural fix argues itself: the OR is now built by Active Record
(`ids.map { |id| where("cited_poll_ids @> ?", [ id ].to_json) }.reduce(:or)`),
which leaves no runtime-assembled fragment to flag. The generated SQL is
identical, including under chaining — Active Record factors the shared
conditions out, so `Dispatch.published.poll_reaction.citing_any([7,9]).where(race_id: 3)`
still produces `status = 0 AND kind = 0 AND ((cited_poll_ids @> '[7]') OR
(cited_poll_ids @> '[9]')) AND race_id = 3`. A regression test pins exactly
that: the scope must *narrow* the relation it is chained onto, which is how
`Newsroom::Caps#duplicate` uses it.

### 3. Database integrity

`bin/rails runner` against the development database, read-only:

| Check | Expected | Observed |
|---|---|---|
| Senate races | 35 | **35** (33 regular + **2** specials) |
| Senate races missing a presidential lean | 0 | **0** |
| House districts | 435 | **435** (435 distinct state+district) |
| Districts missing a 2024 baseline | 0 | **0** (and 0 missing a baseline source URL) |
| `baseline_imputed` districts | 37 | **37** |
| Senate polls / generic-ballot polls | ≥10 / ≥5 | **241 / 559** (800 total, 0 House) |
| Senate races with at least one poll | — | 24 of 35 |
| Poll results | — | 1,620 across 134 pollsters; 437 linked to a candidate |
| Orphan `poll_results` | 0 | **0** |
| Duplicate `dedup_digest`s | 0 | **0** (and 0 polls missing a digest or source URL) |
| Orphan forecasts | 0 | **0** |
| Races with no forecast on the latest run | 0 | **0** (470 of 470) |

134 pollsters, not the 133 recorded in Phase 2 §F: one more arrived with a
later poll. Nothing else moved.

### 4. A live scrape sweep

```
$ bin/rails pol:scrape        # 79.9s wall, ~2.2s per source
TOTAL (36 sources)   Rows 804   New 0   Dup 804   Skip 0
0 source(s) failed outright
```

Every one of the 35 Senate pages and the generic-ballot page fetched and parsed;
nothing 404'd, nothing failed, nothing was skipped. Pacing is ~2.2s per request,
against a 2-hour cadence and a sweep six hours after the last one.

Because the sweep created **no** new polls, `Ingest.after_new_polls!` was not
called and nothing downstream fired — no model run, no reaction, no LLM call,
no spend. That is the correct behaviour and it also re-demonstrates the dedup
contract at 804 rows. The ingest→forecast→newsroom chain under live conditions
is evidenced instead by Phase 5 §D (two real dispatches, one retracted) and,
deterministically, by the system test in §A. `scrape_runs` went 72 → 108.

### 5. A model run

```
$ bin/rails pol:model         # 2.0s wall including boot
Model run 11 — succeeded in 1.5s (seed 4541931192453565572)
Generic ballot (D−R)   +6.43   from 30 polls, W = 14.68, 45-day window
Races forecast         470 (35 senate, 435 house)
Error inflation (t)    1.4667
Senate   D 31.4%  R 68.4%  neither 0.1%   mean D seats  49.3
House    D 96.1%  R  3.9%                 mean D seats 240.6
```

Well inside the 60-second bar. The House caveat printed with the number, as it
must. Sanity checks on the run's own rows:

- **`p_dem_win + p_rep_win + p_other_win`** — exactly 1.0 for all 470 forecasts
  (0 rows differing by more than 1e-9).
- **Senate seats** — histogram sums to `n_sims` (10,000) over support 40..59,
  which lies inside the only possible range, 34..69 (34 Democratic-caucus
  holdovers, 35 seats up). The holdover arithmetic in `config/model_params.yml`
  is 34 + 31 + 35 = 100. `p_dem_control + p_rep_control` = 0.9987; the missing
  0.13% is the documented "neither" case, worlds where an independent holds the
  balance (Phase 3 §6, `Forecast::Simulator`).
- **House seats** — histogram sums to 10,000 over support 190..302, all inside
  0..435, and `p_dem_control + p_rep_control` = 1.0.

### 6. No API key — graceful, not fatal

Covered by tests: `Newsroom::ClientTest` "configured? follows the OpenRouter
key" and "a missing key fails as a Client::Error rather than taking the job
down"; `Newsroom::PollReactionsJobTest` and `MovementNotesJobTest` both assert
that a keyless run publishes nothing, makes no HTTP request, and leaves a
single `no_api_key` skip row.

Verified live without touching the real credentials, by adding a detached git
worktree of this commit — `config/master.key` is gitignored, so a worktree
genuinely has no key, which is the same situation as a container without one:

```
booted:                        true          # the app starts
master.key present:            false
credentials readable:          false
openrouter credential nil:     true
Newsroom::Client.configured?:  false
Newsroom.blocked:              [:no_api_key, "no OpenRouter API key is configured"]
```

With `OPENROUTER_API_KEY` set in the environment and still no key file,
`configured?` is `true` and `Newsroom.blocked` is `[nil, nil]` — the ENV
fallback in `config/initializers/ruby_llm.rb` is a real path, not a comment.
With `AGENTS_DISABLED=1`, `Newsroom.blocked` is
`[:agents_disabled, ...]` regardless. The worktree was removed afterwards.

### 7. Every public page renders

The integration suite covers this first: `bin/rails test test/controllers` —
**139 runs, 668 assertions, 0 failures**, of which the five public-page files
(`home`, `races`, `pages`, `dispatches`, `fragment_caching`) are 44 runs / 158
assertions.

Then a curl pass against a transiently booted development server on port 3111
(started with `AGENTS_DISABLED=1`, killed afterwards, port confirmed closed):

| Path | Status | Time | Bytes | Marker found |
|---|---|---|---|---|
| `/` | 200 | 0.157s | 33,789 | "Latest dispatches" |
| `/senate` | 200 | 0.028s | 53,385 | "All 35 seats" |
| `/house` | 200 | 0.049s | 400,777 | `data-testid="house-table"` |
| `/dispatches` | 200 | 0.008s | 10,245 | `data-testid="dispatch-card"` |
| `/methodology` | 200 | 0.007s | 40,784 | `sigma_state_polled` |
| `/about` | 200 | 0.005s | 8,334 | `<h1>` |
| `/up` | 200 | 0.004s | 73 | — |
| `/races/senate-2026-nc` (best-polled, 26 polls) | 200 | 0.038s | 50,340 | poll table |
| `/races/senate-2026-fl-special` (special, 21 polls) | 200 | 0.027s | 42,884 | "Special election" |
| `/races/senate-2026-wy` (unpolled) | 200 | 0.011s | 11,084 | unpolled empty state |
| `/races/house-2026-al-03` (imputed baseline) | 200 | 0.011s | 10,800 | forecast detail |
| `/races/house-2026-ak-01` (real baseline) | 200 | 0.010s | 10,811 | forecast detail |
| `/races/house-2026-ny-17` | 200 | 0.011s | 10,806 | forecast detail |
| `/races/no-such-race-2026` | **404** | 0.006s | 7,477 | "Not found · Pol" |
| `/admin` | **302** → `/session/new` | | | |
| `/admin/good_job` | **404** (unauthenticated) | | | |
| `/session/new` | 200 | | | |

Two substitutions from the checklist's wish list, both because the live data
has no such row: there is **no unpolled Senate special** (both specials, FL and
OH, are polled — 21 and 15 polls), so an unpolled regular Senate race stands in
alongside a polled special; and there are **no House district polls at all**
(0 in 800), so no House race page can show a poll table. The server log for the
whole pass contains no exception other than the deliberate `RecordNotFound`,
which rendered `errors/not_found.html.erb` as designed.

### 8. Methodology page — every parameter, every citation

Covered by `PagesControllerTest` ("methodology renders every params section
with a spot-checked value and its citation", plus the `site.*` and Known-
limitations tests) and `Site::ParamCitationsTest`.

Spot-checked against the rendered page: all **46** leaf keys in
`config/model_params.yml` appear on `/methodology`; `sigma_state_polled` renders
its value `4` next to both of its citations (538's presidential-model
explainer and Shirani-Mehr et al.), as live links.

**One defect found and fixed here.** `newsroom.writer_model`'s citation is a URL
followed by a retrieval date, and `citation_link` linked the entire string —
producing `href="https://openrouter.ai/api/v1/models (retrieved 2026-08-11)"`,
which a browser percent-encodes into a 404. A dead source link on the page
whose whole promise is that every number can be checked. `citation_link` now
links only the first whitespace-delimited token and renders the rest as text
beside it; a test asserts the href and that no link on the page has whitespace
in its address.

### 9. Git history

35 commits on `build/mvp` from `main` (this phase's four included), working
tree clean at the end of the phase. The history is
organised by phase but is **not** one commit per phase: each phase landed as
two to six commits (a build, sometimes split into readable stages, then a
reviewed fix commit), e.g. Phase 3 as `1bd98f0 → b21afa9 → b17fb7d → aa69f6d`
followed by `967a742 Phase 3 fix: atomic run guard, stale recovery, params
purity, House caveat`. Every commit subject names its phase and the fix commits
name what the review found. This is read as satisfying "logical commits per
phase": the intent is a history that can be read phase by phase, and squashing
the fix commits into their builds would *lose* the record of what review caught.
History was not rewritten.

### 10. These build notes

Now carry a section per phase, 0 through 7. Phases 0, 1, 4, 6 and 7 were
written in this phase; 2, 3 and 5 are as their phases left them. Every
real-world fact still carries its URL — the Senate map and holdover arithmetic
(§Phase 2 A1–A5), the sigma anchors (§Phase 3 A), the OpenRouter model slugs
(§Phase 5 A1) — and the known-limitations lists in Phase 3 §C, Phase 5 §F and
`/methodology` are current as of this run.

## C. Handoff — what the editor should know

1. **Re-run `bin/rails pol:seed_races` after the remaining primaries.** About
   ten Senate nominations were still unsettled when the board was seeded, so
   some races carry no candidate or a placeholder. The task is idempotent and
   re-running it is the intended way to pick them up. Candidate names matter to
   more than the header: they set which side is "A" in three no-Democrat races
   (Phase 3 §C4) and they are what a poll result gets attributed to.
2. **Current chamber control is not in the data model.** Nothing anywhere knows
   which party holds the Senate or the House today, which is why the newsroom
   prompt forbids "hold", "keep", "defend", "flip" and "lose" — the model would
   have to invent the premise. The proper fix is a verified fact with a
   citation, the way Phase 2 added the holdover counts, not a prompt tweak.
   Until then a brief can say who is *likely to win control* and nothing about
   who has it.
3. **The regional error term is the top modelling item.** v1 correlates every
   race through one national error where fuller models use several, so the
   House seat distribution is too narrow and its control probability too
   confident in whichever direction it leans (~96% here reads ~84% at a
   correlated total; the Senate is off by roughly 7 points). It is a structural
   change, not a constant, and it is what would let the caveat come off the
   page. See Phase 3 §A4.
4. **`n_sims` is tunable, and the noise floor moves with it.**
   `simulation.n_sims` is 10,000, where run-to-run Monte Carlo noise on Senate
   control measures ~1.4pp. Raising it costs run time roughly linearly (a full
   470-race run is ~1.5s today) and shrinks the noise as 1/√n. Anything that
   reads a *difference* between runs has to stay above that floor:
   `site.movers_floor_pp` (1.5) does, and `newsroom.movement_threshold` (0.08 =
   8 points) does comfortably. The mover list printed by `bin/rails pol:model`
   does not — its 0.05pp cutoff reports noise as news, which is cosmetic but
   misleading if read as signal.
5. **Rotate the OpenRouter API key.** It was printed in plaintext twice on this
   machine during the build (Phase 0 §C). Nothing left the machine and nothing
   is in the repository, but the cheap, correct response to a key that has been
   on a terminal is to rotate it. `newsroom.writer_model` and the credential are
   the only two places the newsroom is configured; a rotated key goes in
   `bin/rails credentials:edit` (or `OPENROUTER_API_KEY`) and needs no code
   change.
6. **Deployment is deliberately not done.** The app is 12-factor-ready and the
   generated Kamal config is present but unused; nothing has been deployed and
   no production database exists. See the README's "Deploy posture".

---

# Phase 8 — Data coverage (ingestion)

The House side of the model had no polls in it. All 435 district forecasts ran
on fundamentals alone, and a parser refusal was indistinguishable from a page
with nothing on it, so a race could stop being polled — or stop being *read* —
without anything saying so. This phase went looking for district polling, found
more of it than expected, and made every refusal say why.

## A. Where 2026 House district polling actually lives

Checked live on 2026-08-11 through the project's own client (descriptive UA,
~1 request/second), one pass over every candidate page.

### A1. The three places it is not

| Page | URL | What it carries |
|---|---|---|
| 2026 United States House of Representatives elections | <https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections> | 58 wikitables. Exactly one polling table, and it is the generic-ballot **aggregator** average ("Source of poll aggregation" — 270toWin, RCP and friends). The other 57 are per-state candidate rosters. **No district polls.** |
| Nationwide opinion polling for the 2026 United States House of Representatives elections | <https://en.wikipedia.org/wiki/Nationwide_opinion_polling_for_the_2026_United_States_House_of_Representatives_elections> | **404.** No such article. The sibling we already scrape for individual generic-ballot polls is [2026 United States elections](https://en.wikipedia.org/wiki/2026_United_States_elections), unchanged. |
| Per-district articles | e.g. <https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_election_in_New_York%27s_17th_congressional_district> | **404**, as is the Pennsylvania-10 equivalent. Searching Wikipedia for 2026 House district articles returns state pages, the main article and a [ratings article](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_election_ratings) — never a district one. 2026 House districts do not get their own articles the way Senate races do; the state page is the unit. |

### A2. The place it is

`2026 United States House of Representatives elections in {State}` — one page
per state, each district a section, polling nested inside it:

```
District 17
  Democratic primary
    Polling          ← a primary field
  General election
    Polling          ← the matchup we want
```

**All fifty state pages were read.** Six states with a single at-large district
use the singular title (`…House of Representatives election in Alaska`); the
plural 404s for them, and only for them.

Thirty-three states carry at least one general-election district poll. The
counts below are what the parser as committed takes off each page.

| State | Page | Poll rows | Districts | Tables refused |
|---|---|---:|---|---|
| AL | [Alabama](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Alabama) | **1** | 2 | primary ×3 |
| AK | [Alaska](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_election_in_Alaska) | **7** | at-large | primary ×1, placeholder ×2 |
| AZ | [Arizona](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Arizona) | **4** | 2, 6 | primary ×5, placeholder ×1 |
| AR | [Arkansas](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Arkansas) | **2** | 2 | — |
| CA | [California](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_California) | **8** | 3, 6, 22, 40, 48 | primary ×10, results ×1, same-party ×1, placeholder ×1, no party columns ×1 |
| CO | [Colorado](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Colorado) | **5** | 3, 5 | primary ×2, placeholder ×1 |
| FL | [Florida](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Florida) | **21** | 2, 7, 8, 11, 12, 13, 14, 22, 25, 27, 28 | primary ×18, placeholder ×1 |
| ID | [Idaho](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Idaho) | **3** | 1 | — |
| IL | [Illinois](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Illinois) | **1** | 4 | primary ×4 |
| IN | [Indiana](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Indiana) | **1** | 5 | — |
| IA | [Iowa](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Iowa) | **6** | 1, 2, 3 | placeholder ×1 |
| KY | [Kentucky](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Kentucky) | **6** | 6 | primary ×5 |
| ME | [Maine](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Maine) | **14** | 2 | primary ×2, placeholder ×1 |
| MI | [Michigan](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Michigan) | **13** | 4, 7, 10 | primary ×5, placeholder ×1 |
| MN | [Minnesota](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Minnesota) | **5** | 1, 2 | primary ×1, placeholder ×1 |
| MO | [Missouri](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Missouri) | **1** | 2 | primary ×1, placeholder ×2 |
| MT | [Montana](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Montana) | **6** | 1 | primary ×1 |
| NE | [Nebraska](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Nebraska) | **3** | 1 | primary ×1 |
| NV | [Nevada](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Nevada) | **1** | 2 | — |
| NH | [New Hampshire](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_New_Hampshire) | **6** | 2 | primary ×4 |
| NJ | [New Jersey](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_New_Jersey) | **2** | 7 | primary ×3, placeholder ×1 |
| NM | [New Mexico](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_New_Mexico) | **1** | 2 | placeholder ×1 |
| NY | [New York](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_New_York) | **4** | 1, 17, 21 | primary ×9 |
| NC | [North Carolina](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_North_Carolina) | **6** | 1, 10, 11, 14 | primary ×1, placeholder ×3, no district ×1 |
| OH | [Ohio](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Ohio) | **9** | 7, 9, 10, 15 | placeholder ×3, no party columns ×1 |
| PA | [Pennsylvania](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Pennsylvania) | **9** | 1, 7, 8, 10 | primary ×3 |
| SC | [South Carolina](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_South_Carolina) | **4** | 1, 7 | primary ×2 |
| TN | [Tennessee](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Tennessee) | **1** | 5 | primary ×2 |
| TX | [Texas](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Texas) | **8** | 15, 23, 28, 34 | primary ×17, placeholder ×3, no district ×1 |
| VT | [Vermont](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_election_in_Vermont) | **4** | at-large | primary ×1 |
| VA | [Virginia](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Virginia) | **2** | 1, 2 | primary ×1 |
| WA | [Washington](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Washington) | **6** | 3, 5 | same-party ×3, placeholder ×2 |
| WI | [Wisconsin](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Wisconsin) | **8** | 1, 3, 6 | primary ×2, placeholder ×3 |

| State | Page | Poll rows | Why none |
|---|---|---:|---|
| CT | [Connecticut](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Connecticut) | 0 | primary ×1 |
| DE | [Delaware](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_election_in_Delaware) | 0 | no polling section |
| GA | [Georgia](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Georgia) | 0 | primary ×1 |
| HI | [Hawaii](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Hawaii) | 0 | primary ×2 |
| KS | [Kansas](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Kansas) | 0 | no polling section |
| LA | [Louisiana](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Louisiana) | 0 | no party columns ×1 |
| MD | [Maryland](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Maryland) | 0 | primary ×2 |
| MA | [Massachusetts](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Massachusetts) | 0 | primary ×3 |
| MS | [Mississippi](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Mississippi) | 0 | no polling section |
| ND | [North Dakota](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_election_in_North_Dakota) | 0 | no polling section |
| OK | [Oklahoma](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Oklahoma) | 0 | no polling section |
| OR | [Oregon](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Oregon) | 0 | no polling section |
| RI | [Rhode Island](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Rhode_Island) | 0 | no polling section |
| SD | [South Dakota](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_election_in_South_Dakota) | 0 | primary ×3 |
| UT | [Utah](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_Utah) | 0 | primary ×2 |
| WV | [West Virginia](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_elections_in_West_Virginia) | 0 | no polling section |
| WY | [Wyoming](https://en.wikipedia.org/wiki/2026_United_States_House_of_Representatives_election_in_Wyoming) | 0 | primary ×2 |

**178 general-election poll rows across 73 districts in 33 states** — against
zero district polls before this phase. It is thin next to the Senate's 241 and
the generic ballot's 559, and it is aimed where it matters: 28 of the 73
districts have a 2024 baseline margin inside ten points and 16 inside five,
against 17 sitting at 20 points or wider. Pollsters are polling the close ones.

### A3. The nine states that were closest

These carry congressional polling today but only of primaries, so they are not
in `Ingest::Sources::DISTRICT_POLL_STATES` and are not fetched: **CT, GA, HI,
LA, MD, MA, SD, UT, WY**. Each is one resolved nomination away from qualifying.
The eight with no polling section of any kind — **DE, KS, MS, ND, OK, OR, RI,
WV** — are further off.

### A4. The list is a snapshot, and stales in one direction

`DISTRICT_POLL_STATES` is 33 hand-recorded state codes. A state that gains its
first district poll after today will not be picked up until the list is
refreshed. Refreshing it means re-running the survey: fetch all 50 state pages,
run `Ingest::PollTableParser` over each in district scope, and take the states
with a non-zero row count. Scraping all 50 unconditionally was the alternative
and was rejected on weight, not on principle — the 33 are 46 MB a sweep, the
full 50 about 70 MB, twelve times a day, for seventeen pages we know are empty.
`scrape.max_district_sources` (40) is the ceiling on how far the list can grow
before someone has to look at that trade again; anything past it is skipped and
named in the log.

## B. What a district page asks of the parser that a Senate page does not

### B1. The district comes from the section, not the row

Nothing in a poll row says which district it is. The district is the section the
table sits inside, so `PollTableParser` in district scope walks the table's
**ancestor `<section>` elements, nearest first**, and takes the first heading
matching `District N` (or an at-large heading, which resolves to district 1).
This is DOM containment, not "the last heading above it on the page" — a table
cannot be captured by a district it is not inside. A polling table with no
district ancestor is refused as `district_unresolved` rather than attached to
anything: North Carolina and Texas both poll their congressional vote
*statewide*, seventeen rows between them under a "Statewide polling" heading,
and those rows belong to no district.

A state with one at-large district is the one case with no heading to read,
because there is only one district to mean. The scraper passes
`default_district` there, and only there, derived from holding exactly one House
race for the state.

Rows whose district resolves to a district we hold no race for are skipped and
counted (`Ingest::Scraper#ingest_districts`), never reassigned.

### B2. Three refusals a Senate page never needed

| Refusal | The case | Where it bites |
|---|---|---|
| `multiple_same_party_columns` | Two columns tagged with the same *major* party. A general election has one Democrat and one Republican; a field of five has to be a primary. | Washington's top-two primary tables carry party tags and pass every other test — WA-4 is four Republicans and a Democrat. Same for California and Louisiana. |
| `generic_candidate_column` | A column headed "Generic Democrat", "Generic Republican", "Another Democratic candidate". A real number, but not against an opponent. | 44 tables in the live sweep: 28 on state House pages, 16 on Senate pages. On the Senate side the seeded candidate list already rejected most of them; where a race had a seeded Democrat and no seeded Republican, it did not — which is how the four historical rows in §F got in. |
| `results_table` | A column headed "Votes". | California's 22nd files its primary *result* under the Polling heading. Without this it would be refused as `layout_unrecognized`, which is meant to mean "the page changed shape under us" and would mark California `partial` on every sweep for a table that is doing nothing wrong. |

Section headings do the rest: a table under a heading matching `primary` and
not `general election` is `primary_only_table`, which is what catches a jungle
primary whose columns are perfectly well-formed. That check now runs on Senate
pages too, so Colorado's Democratic-primary-only page stops reporting as a
clean empty sweep.

### B3. What ingestion cannot tell apart, and where that is dealt with

No House race has candidates seeded (`Ingest::SeedRaces` seeds candidates for
Senate races only), so every district column matches on party alone. The
consequence: a **pre-primary hypothetical general-election matchup is
indistinguishable from the real one**. California's 22nd carries both
"Valadao vs Villegas" — Villegas took 32.4% of the primary vote and advanced —
and an August 2025 "Valadao vs Bains", Bains having finished third on 26.9%.
Both are ingested. On the Senate side the seeded candidate list is exactly what
rejects those; here there is nothing to reject them with.

Ingestion stays permissive, because refusing a table on suspicion would throw
away real polling; the judgement is made downstream instead, where the polls
that actually count towards a forecast are known. See §G.

## C. Refusal observability

### C1. Ten reasons, all of them things the code can actually tell apart

`Ingest::PollTableParser::REFUSAL_REASONS`, in the order the parser tries them:
`layout_unrecognized` (no columns at all), `aggregator_table`, `results_table`,
`layout_unrecognized` again (no pollster or date column), `primary_only_table`,
`district_unresolved`, `generic_candidate_column`, `no_party_columns`,
`multiple_same_party_columns`, `no_candidate_column_match` — plus the
page-level `no_polling_section`. A test asserts that every reason on that list
is produced by a real fixture, so a reason cannot be added without a page that
emits it.

Refusals are only counted for tables **under a Polling heading**, or tables that
carry a poll table's own header shape wherever they sit. A wikitable elsewhere
on the page — endorsements, fundraising, results by county, of which California
has 265 — is not a poll table and is passed over in silence. Without that scope
the counts would be noise.

### C2. Which refusals make a source `partial`

Not all of them, and this is the judgement call of the phase.

Refusing a table is *routine*. The Georgia Senate page refuses eighteen every
sweep — four aggregator averages, seven hypothetical matchups, five primary
fields, one "Generic Republican", one table with no party columns — and yields
ten real polls. Treating any
refusal as trouble would make `partial` the permanent status of nearly every
source, and a status that is always amber says nothing.

Two things are trouble:

1. **`layout_unrecognized`** — a table under a Polling heading whose shape we
   could not account for at all. That is what a page restructured under us looks
   like, and it marks the source `partial` on its own even if the page yielded
   polls.
2. **Refusing everything and reading nothing** — `refused_count > 0` with
   `fetched_count == 0`. The race is dark and we declined the only tables
   offered. Colorado's Senate page is exactly this.

A page with **no polling section** refused nothing — there was no table to turn
down — so `refused_count` stays 0, the reason `no_polling_section` is recorded
anyway, and the status is a clean `succeeded`. "succeeded, fetched 0, refused 0,
no_polling_section" and "partial, fetched 0, refused 1, primary_only_table" are
the two cases that used to be the same row.

The policy lives on `ScrapeRun` (`UNREADABLE_REASONS`, `EMPTY_PAGE_REASON`,
`#dark?`, `#refusal_alarm?`) because that is the record both the scraper writes
and the admin reads; `Ingest::Scraper` reads it rather than restating it.

### C3. Where it shows

* **`scrape_runs`** gains `refused_count` (integer) and `refusal_reasons`
  (jsonb, reason → count). `refused_count == refusal_reasons.values.sum` except
  for the documented `no_polling_section` case.
* **Admin scrape health** leads with a panel naming the sources that need
  looking at — the dark ones and the unreadable ones, by name and reason —
  and a one-line count of the sources that refused only routine tables and
  still read polls, so the panel stays small as the sweep grows. Every row gets
  a Refused column with reason chips in plain English (`primary field ×4`)
  carrying the machine name in `data-reason` and `title`. A page with no polling
  section renders as "no polling section" instead of a number, which is the
  visual distinction the phase was asked for. The page is now also **windowed**
  to the most recent 150 runs (`Admin::ScrapeRunsController::WINDOW`): at 69
  sources every two hours it would otherwise grow by 828 rows a day, with the
  refusal summary computed over all of them.
* **`bin/rails pol:scrape`** gains a `Ref` column, a per-source `refused:` line
  naming the reasons, and a sweep-wide "Refusals by reason" total.

## D. Dark-race audit — the seven unverified Senate races

Four were hand-checked during the MVP build (NJ, OR, TN: no polling section;
CO: a Democratic primary table, correctly refused). These are the other seven,
fetched live on 2026-08-11 and run through the parser with the candidates we
actually hold for each race.

| Race | Polling section | What is on the page | Parser | Verdict |
|---|---|---|---|---|
| **DE** | none | No heading matching "poll" anywhere. Fundraising and ratings tables only. | `no_polling_section`, succeeded | Correct. Candidates, fundraising and ratings, and no poll of any kind. |
| **IL** | yes | Three primary tables, 28 rows: two Democratic (Kelly / Krishnamoorthi / Stratton) and one Republican. **No general-election table.** | `primary_only_table ×3`, fetched 0 → **partial** | Correct. Was invisible before; now reads as a dark race. |
| **LA** | yes | Eight tables, 72 poll rows, every one a Republican primary — first round *and* runoff (Letlow / Fleming / Cassidy) — plus one aggregator average. **No general-election table.** | `primary_only_table ×7`, `aggregator_table ×1`, fetched 0 → **partial** | Correct. Louisiana runs closed congressional primaries from 2026, so a runoff poll is still a primary poll. |
| **NM** | yes | One Democratic primary table, 1 row (Luján 69, Dodson 9). **No general-election table.** | `primary_only_table ×1`, fetched 0 → **partial** | Correct. |
| **OK** | yes | Two Republican primary tables, 3 rows (Hern / Stitt / Bice). **No general-election table.** | `primary_only_table ×2`, fetched 0 → **partial** | Correct. |
| **WV** | none | No heading matching "poll". | `no_polling_section`, succeeded | Correct. |
| **WY** | none | No heading matching "poll". | `no_polling_section`, succeeded | Correct. |

**No parser bug was found.** All seven are genuinely unpolled at the general
level, and all seven now say which kind of unpolled they are. Five of the eleven
dark Senate races — CO, IL, LA, NM, OK — will report `partial` on every sweep
from here until somebody polls their general election. That is the intended
signal, not a fault: those five have polling on the page and none of it is ours
to use, which is a different thing from Delaware having no polling at all.

## E. Tests

Thirty-four new tests — the suite goes 722 → 756, plus the end-to-end system
test — and nothing in any of them touches the network. The review round added
twenty-three more (779; see §G).

| File | What it pins |
|---|---|
| `test/lib/ingest/poll_table_parser_test.rb` | District attribution from the enclosing section, per-district candidate matching, at-large default, and one case per refusal reason — including a test that **every** reason in `REFUSAL_REASONS` is emitted by a real fixture |
| `test/lib/ingest/scraper_test.rb` | A state page becomes polls against the right races; an unmappable district is skipped and counted with **no Poll created and nothing reassigned**; the `max_district_sources` cap; refusal counts surviving parser → scraper → row; the four status outcomes (routine refusals stay `succeeded`, no polling section stays `succeeded`, dark is `partial`, unreadable is `partial`) |
| `test/models/scrape_run_test.rb` | `#refusals` ordering and labels, `#dark?`, `#refusal_alarm?`, and that every parser reason has a label |
| `test/controllers/admin/scrape_runs_controller_test.rb` | Reason chips by machine name, the empty-page distinction, the summary panel listing only what needs looking at |
| `test/lib/ingest/date_range_test.rb` | The optional comma, and that a month with no day still returns nil |
| `test/fixtures/scrape_runs.yml` | Four fixture rows, one per refusal shape |

Six new fixtures, all real trimmed Parsoid HTML from `bin/rails
pol:refresh_fixtures` (which grew a district trimmer that keeps the
`District 7 > General election > Polling` nesting, and an `ONLY=` filter so one
fixture can be refreshed without touching the rest):

| Fixture | Chosen for |
|---|---|
| `house_michigan.html` | Three districts with clean general-election tables — the happy path |
| `house_washington.html` | Top-two primary fields with party tags, and the missing-comma date |
| `house_alaska.html` | At-large, plus two placeholder-opponent tables |
| `house_california.html` | A primary results table under the Polling heading, and a Democrat-versus-Democrat general |
| `house_north_carolina.html` | Statewide congressional polling under no district |
| `house_delaware.html` | A page with tables but no polling section |

## F. Live run — one sweep, 2026-08-11

`bin/rails pol:scrape`, once, against live Wikipedia. **69 sources** (35 Senate
pages + the generic ballot + 33 state House pages), 61 succeeded, 8 partial,
none failed, no page 404'd.

| | Rows seen | New | Duplicate | Skipped | Refused |
|---|---:|---:|---:|---:|---:|
| 35 Senate pages | 240 | 1 | 239 | 0 | 182 |
| Generic ballot | 561 | 0 | 561 | 0 | 1 |
| 33 state House pages | 188 | 174 | 4 | 10 | 141 |
| **Total** | **989** | **175** | **804** | **10** | **324** |

Refusals by reason, sweep-wide: `primary_only_table ×172`,
`no_candidate_column_match ×67`, `generic_candidate_column ×44`,
`aggregator_table ×29`, `no_polling_section ×6`, `no_party_columns ×5`,
`multiple_same_party_columns ×4`, `district_unresolved ×2`, `results_table ×1`.
No `layout_unrecognized` anywhere in 69 sources — every table under a Polling
heading was accounted for.

**Database after: 975 polls — 242 Senate, 559 generic ballot, and 174 House
district polls where there were none.** 73 of 435 districts now hold at least
one poll. The Senate side gained exactly one new poll (Alaska) and recognised
the other 232 rows as duplicates, which is the dedup contract holding across a
sweep that also added a third of a chamber's worth of new sources.

Four polls already in the database were read from placeholder-opponent tables
before `generic_candidate_column` existed — polls 105 and 106 (Minnesota,
"Generic Republican" against Craig and against Flanagan), 150 (Nebraska,
Ricketts against a "Generic Democrat") and 190 (South Carolina, Andrews against
a "Generic Republican"). No new ones can arrive. These four are **left in the
table and left off the average** (§G3): a poll fought against a placeholder
measured the party, not the nominee, so its margin is not a reading of that
contest. They stay on their race pages, grouped under a heading that says so.
Deleting them is still an editorial call nobody has had to make.

### F1. Per state page

| State page | Status | Rows | New | Dup | Skipped | Refused | Reasons |
|---|---|---:|---:|---:|---:|---:|---|
| Alabama | succeeded | 1 | **1** | 0 | 0 | 3 | primary_only_table ×3 |
| Alaska | succeeded | 7 | **7** | 0 | 0 | 3 | generic_candidate_column ×2, primary_only_table ×1 |
| Arizona | succeeded | 4 | **4** | 0 | 0 | 6 | generic_candidate_column ×1, primary_only_table ×5 |
| Arkansas | succeeded | 2 | **2** | 0 | 0 | 0 | — |
| California | succeeded | 8 | **8** | 0 | 0 | 14 | generic_candidate_column ×1, multiple_same_party_columns ×1, no_party_columns ×1, primary_only_table ×10, results_table ×1 |
| Colorado | succeeded | 5 | **5** | 0 | 0 | 3 | generic_candidate_column ×1, primary_only_table ×2 |
| Florida | partial | 26 | **21** | 0 | 5 | 19 | generic_candidate_column ×1, primary_only_table ×18 |
| Idaho | succeeded | 3 | **3** | 0 | 0 | 0 | — |
| Illinois | succeeded | 1 | **1** | 0 | 0 | 4 | primary_only_table ×4 |
| Indiana | succeeded | 1 | **1** | 0 | 0 | 0 | — |
| Iowa | succeeded | 6 | **6** | 0 | 0 | 1 | generic_candidate_column ×1 |
| Kentucky | succeeded | 6 | **5** | 1 | 0 | 5 | primary_only_table ×5 |
| Maine | succeeded | 14 | **13** | 1 | 0 | 3 | generic_candidate_column ×1, primary_only_table ×2 |
| Michigan | succeeded | 13 | **13** | 0 | 0 | 6 | generic_candidate_column ×1, primary_only_table ×5 |
| Minnesota | succeeded | 5 | **5** | 0 | 0 | 2 | generic_candidate_column ×1, primary_only_table ×1 |
| Missouri | succeeded | 1 | **1** | 0 | 0 | 3 | generic_candidate_column ×2, primary_only_table ×1 |
| Montana | succeeded | 6 | **6** | 0 | 0 | 1 | primary_only_table ×1 |
| Nebraska | partial | 5 | **3** | 0 | 2 | 1 | primary_only_table ×1 |
| Nevada | succeeded | 1 | **1** | 0 | 0 | 0 | — |
| New Hampshire | succeeded | 6 | **6** | 0 | 0 | 4 | primary_only_table ×4 |
| New Jersey | succeeded | 2 | **2** | 0 | 0 | 4 | generic_candidate_column ×1, primary_only_table ×3 |
| New Mexico | succeeded | 1 | **1** | 0 | 0 | 1 | generic_candidate_column ×1 |
| New York | succeeded | 4 | **4** | 0 | 0 | 9 | primary_only_table ×9 |
| North Carolina | succeeded | 6 | **6** | 0 | 0 | 5 | district_unresolved ×1, generic_candidate_column ×3, primary_only_table ×1 |
| Ohio | succeeded | 9 | **9** | 0 | 0 | 4 | generic_candidate_column ×3, no_party_columns ×1 |
| Pennsylvania | succeeded | 9 | **9** | 0 | 0 | 3 | primary_only_table ×3 |
| South Carolina | succeeded | 4 | **4** | 0 | 0 | 2 | primary_only_table ×2 |
| Tennessee | succeeded | 1 | **1** | 0 | 0 | 2 | primary_only_table ×2 |
| Texas | succeeded | 8 | **8** | 0 | 0 | 21 | district_unresolved ×1, generic_candidate_column ×3, primary_only_table ×17 |
| Vermont | succeeded | 4 | **3** | 1 | 0 | 1 | primary_only_table ×1 |
| Virginia | succeeded | 2 | **2** | 0 | 0 | 1 | primary_only_table ×1 |
| Washington | partial | 9 | **5** | 1 | 3 | 5 | generic_candidate_column ×2, multiple_same_party_columns ×3 |
| Wisconsin | succeeded | 8 | **8** | 0 | 0 | 5 | generic_candidate_column ×3, primary_only_table ×2 |
| **33 state pages** | | **188** | **174** | 4 | 10 | 141 | |

Florida, Nebraska and Washington are `partial` for skipped rows, not refusals:
five and three of those rows carry a month with no day ("Late July 2025"), and
Nebraska's two are cells with no percentage in them. Ten rows out of 188.

### F2. The eleven dark Senate races, as the sweep now reports them

| Senate source | Status | Refused | Reason |
|---|---|---:|---|
| Colorado | partial | 1 | primary_only_table ×1 |
| Delaware | succeeded | 0 | no_polling_section ×1 |
| Illinois | partial | 3 | primary_only_table ×3 |
| Louisiana | partial | 8 | aggregator_table ×1, primary_only_table ×7 |
| New Jersey | succeeded | 0 | no_polling_section ×1 |
| New Mexico | partial | 1 | primary_only_table ×1 |
| Oklahoma | partial | 2 | primary_only_table ×2 |
| Oregon | succeeded | 0 | no_polling_section ×1 |
| Tennessee | succeeded | 0 | no_polling_section ×1 |
| West Virginia | succeeded | 0 | no_polling_section ×1 |
| Wyoming | succeeded | 0 | no_polling_section ×1 |

Six say "there is no polling section here". Five say "there is polling here and
none of it is a general-election matchup", and they are `partial` rather than a
clean zero. Before this phase all eleven read `succeeded, fetched 0`.

### F3. The sweep queued a model run

`Ingest.after_new_polls!` fired once with all 175 new poll ids and enqueued a
single `Forecast::RunJob(trigger: :ingest)`. It is sitting in GoodJob's queue
because no worker runs on this machine outside `bin/dev`; the seam behaved
exactly as it does for a Senate-only sweep. The first run to pick it up will be
the first forecast in this project's history with House district polling in it.

### F4. Weight of the sweep

The 33 state pages are ~46 MB of Parsoid HTML — Alaska is 0.4 MB, California
5.6 MB — against ~15 MB for the 36 Senate-and-generic sources. At
`scrape.cadence_hours: 2` that is 69 requests and ~61 MB twelve times a day,
all of it paced at one request per second behind the project's descriptive
user agent. The request rate is trivial; the bytes are the part worth watching,
and `scrape.max_district_sources` is where the ceiling is set.

## G. Review fixes — matchup ambiguity and refusal-panel accuracy

### G1. Half the district corpus was blending mutually exclusive matchups

Measured after the phase's live sweep: **85 of the 174 district polls (49%) sit
in 22 of the 73 polled districts, and those 22 carry more than one distinct
matchup.** Maine's 2nd has thirteen polls across four different Democrats
against Paul LePage; Florida's 25th has four polls and four matchups. Averaged
together they would publish a margin between people who cannot all be on the
ballot — the same thing the Senate side refuses seven times on the Georgia page
alone, except that a district has no candidate list to refuse it with.

**The rule: a race whose qualifying polls span more than one matchup is
treated as unpolled.** The forecast falls back to fundamentals with a reason
the page can read, and the polls stay stored and published, grouped by the
contest they measured.

`polls.matchup_key` is what makes it computable — a normalised,
order-independent rendering of the candidate columns a row named
(`Ingest::Matchup`): surnames only, accents folded, generational suffixes
dropped, downcased, **keyed by party slot**, sorted, joined.
`"dem:conley|rep:lawler"`. Kept readable rather than hashed so a page can group
on it and a person can read it in a console. Null for the generic ballot (its
columns name nobody) and for polls entered by hand.

**Per party slot rather than as a flat list of names**, and Montana is why. Its
page polls Alani Bankhead against Kurt Alme both two-way and three-way with
Seth Bodnar. A flat list calls those two different matchups; they are one
contest between the same two people with a third option offered, and the gap
between the two-way and three-way numbers is a third-party effect, not evidence
that we cannot tell who is running. `Forecast::Averager#contested_pairs` reads
only the two sides it is about to compare, so Montana resolves to one contest
and Maine's four Democrats against LePage stay four.

The test runs **inside the averaging window and before the one-per-pollster
cut** — see §G6 for why that order, and what it cost to get wrong. A race
resolves itself as its old hypotheticals age out of the window; nothing has to
be re-run when a primary settles and no migration is owed.

**Result on the live board: 47 of the 73 polled districts average cleanly, 10
fall back to fundamentals, and 16 have no poll recent enough to qualify** (the
last of those was already true before this rule and is not caused by it). The
ten: FL-2, FL-14, FL-25, ME-2, MI-7, MN-2, MT-1, NJ-7, VT-1, WA-5. The other
twelve multi-matchup districts resolve themselves once the window has run.

**The rule applies to every race, not only districts.** It reads on the polls:
if the ones that survive the window and the per-pollster cut name two different
pairs on the sides being compared, there is no single contest to average. The
generic ballot is untouched — its columns name nobody, so its polls carry no
key and this can never fire on them. §G1a is what that does to the Senate.

On the race page: a race in this state gets a note saying polling exists and
measures several matchups so the forecast rests on fundamentals, and its poll
table is grouped under a heading per matchup, labelled as the source page wrote
it ("Matt Dunlap (D) vs Paul LePage (R)"). The note names the right
fundamentals for the office — a district's 2024 result, a state's partisan
lean. Nothing is hidden.

### G1a. What the rule does to the Senate

**Two of the 24 polled Senate races fall back: Florida and South Carolina.**
Twenty average cleanly and 2 have no poll recent enough to qualify.

(An earlier draft of this section said zero. That was measured with the
ambiguity test running *after* the one-per-pollster cut, which is a bug in its
own right — see §G6 — and hid both of these.)

The mechanism that contaminates a Senate race is not the obvious one. No 2026
Senate race has two candidates of one party seeded, so a hypothetical against a
*different* person of a party we hold is refused at ingest — that is Georgia's
`no_candidate_column_match ×7`. What gets through is a party slot with **no**
seeded candidate at all, where `match_candidates` falls back to party alone and
every hypothetical for that slot is accepted. South Carolina has no Republican
nominee and its page polls Annie Andrews against eight different Republicans;
Florida's page carries four pairs, Minnesota's two.

Back-dating the averager to each of the **194** field-end dates in the corpus,
three Senate races fall back on **192 race-days** between them: Minnesota 98,
Florida 75, South Carolina 19. Florida and South Carolina were both ambiguous
as recently as **2026-08-06** — five days before this was written — which is
why they are ambiguous today. (Not to be confused with 2026-07-17, the field
date of the seven-row Public Policy Polling battery in §G6: one is when a poll
was taken, the other is a day on which the average would have stood down.) Phase 9 estimates pollster house effects from
race-level residuals, and a residual measured on any of those days would have
carried the blend into every pollster's estimated lean.

Montana, South Dakota, Idaho and Nebraska — four of the seven races the first
audit flagged — are not mutual exclusivity at all. Each polls one pair both
two-way and three-way (Bodnar in Montana, Beaudion in South Dakota, Roth in
Idaho, and Nebraska's Democrats against Ricketts alongside the Osborn contest
the model actually reads), and the flat-list key was counting a third name as a
different contest. The per-party key tells them apart; all four are clean under
it. Correcting that was necessary to extend the rule at all — left as it was,
extending it would have declared three Senate races unpolled for a reason that
is not true.

A fallen-back Senate race takes the same path as a district: `polled?` false,
`mu` the prior alone, `blend_weight` zero. Its **sigma moves too** — from
`sigma_state_polled` (4.0) to `sigma_state_unpolled` (8.0) — which is right,
because a race whose polls cannot be read is an unpolled race and claiming the
polled precision would be claiming something the data does not support. Pinned
by test rather than by live data, since nothing is in that state today.

### G2. The admin refusal panel counted runs, not sources

The panel selected over the 150-run window — a little over two sweeps — so from
the second sweep on it would have read "124 sources refused a table" against 69
that exist, listing Colorado, Illinois, Louisiana, New Mexico and Oklahoma two
or three times each. It now groups by source first and judges each on its most
recent run. Same defect, same fix, in the "other sources refused only routine
tables" count.

### G3. Smaller things

* **A real same-party general now says so.** California's 11th is a genuine
  top-two general between two Democrats; it was being refused as
  `no_party_columns`, which reads like a parser failure. The duplicate-major-
  party test now runs first, so it is refused as `multiple_same_party_columns`
  — still refused, because there is no two-party margin in it, but for the
  accurate reason.
* **`pol:scrape` explains its own arithmetic.** The Ref column totalled 324
  while the by-reason line totalled 330; the six-count gap was
  `no_polling_section`, which is a page with no table to refuse. It is now
  reported on its own line instead of left for an operator to spot.
* **An at-large heading takes the caller's district** rather than the literal 1
  the parser used to invent. No live page carries such a heading — the branch
  exists for the day one does — and with no caller district it now refuses as
  `district_unresolved` instead of guessing.
* **A poll against a placeholder opponent no longer enters an average.** The
  four rows in §F carry no matchup key — a placeholder is not a name — so the
  ambiguity rule cannot see them, and they were still feeding named-candidate
  races. `Forecast::Averager` drops them (counted in `skipped_count`, which is
  exactly what it means) and the race page heads their group "Against a generic
  opponent — not in the average".
* **A generational suffix is not a surname.** "Nick Begich III" was a man
  called "iii", and "Mike Bouchard Jr." and "Tom Kean Jr." were the same
  person. Audited against the corpus before and after: no seeded candidate
  anywhere carries a suffix, no race had two candidates colliding under the old
  rule, all **439** attributed poll-result columns resolve to the same
  candidate either way, and not one Senate column in the corpus (or in the four
  Senate fixtures and seven cached pages) carries a suffix at all. The bug was
  latent on the Senate side and bit only where columns like "Nick Begich III"
  exist and no candidate list is consulted — the House, and only the matchup
  keys this phase introduced.

### G4. A fixture that passed for the wrong reason

`trim_sections` lifted a matched "Polling" section out of its parent, so the
Georgia fixture's five Republican-primary tables reached the parser with no
primary heading above them and were refused as `no_party_columns`. The total
matched live (18) and the reasons did not. The trimmer now keeps enclosing
sections, stripped to their headings, and the regenerated Georgia fixture
reproduces the live page exactly: `aggregator_table ×4,
no_candidate_column_match ×7, primary_only_table ×5, generic_candidate_column
×1, no_party_columns ×1`. Iowa, Ohio, Rhode Island and the generic ballot were
regenerated with it; every count they pin is unchanged.

Two fixtures were added for the matchup rule, both real trimmed Parsoid HTML:
`house_maine.html` (District 2 — fourteen rows, four matchups) and
`house_florida.html` (District 25 — four rows, four matchups).

### G5. Correction to §F

The Phase 8 report said 55 of the 69 sources refused at least one table. The
sweep's rows say **57**.

### G6. The ambiguity test runs before the one-per-pollster cut

Shipped the other way round at first, and it was wrong in a way worth writing
down. `one_per_pollster` keeps the latest poll per house and breaks ties on id.
Run the ambiguity test after it and an **insertion order decides which
hypothetical the site publishes**: Public Policy Polling fielded seven South
Carolina rows to 2026-07-17, against seven different Republicans, and the cut
kept whichever happened to land with the highest id. Forty-four
(race, pollster, field_end) groups in the corpus span more than one matchup in
a single field period — that is the count, independently reproduced.

A pollster testing seven opponents in one field period is not a race to pick a
winner from — it is the plainest evidence there is that nobody knows who is
running. The test now runs on everything inside the window, before the cut. The
per-pollster cut keeps doing its own job (not letting one house weigh twice) on
races that are not ambiguous, and the test can only ever get more conservative
this way, never less.

What it cost, measured before shipping:

| | After the cut | **Before the cut** |
|---|---:|---:|
| Senate races falling back (of 24 polled) | 0 | **2** — FL, SC |
| House districts falling back (of 73 polled) | 3 | **10** |
| Combined | 3 of 97 (3%) | **12 of 97 (12%)** |
| Races ever ambiguous in the 194-date back-test | 7 | **17** |
| Race-days ambiguous | 308 | **1,153** |

Twelve per cent of polled races resting on fundamentals is a real cost and it
is the honest one; the stop-condition agreed beforehand was a third, and this
is well inside it. Sixty-seven of the 97 polled races still publish a
poll-based average.

### G7. `matchup_key` is computed once, at ingest

It is never re-derived on read. That is deliberate — the key is provenance,
recording what a page said at the moment it was read — but it has a
consequence worth knowing before Phase 9 touches this: **if the normalisation
ever changes, old rows keep old-format keys and new rows get new ones, and a
race holding both would be declared ambiguous for no reason other than the
format change.** The remedy is the backfill the migration already contains
(`Ingest::Matchup.for_poll` over every poll), and it should be run in the same
commit as any change to how the key is built. This has already happened twice
during Phase 8 — once for the name-suffix fix, once when the key became
party-keyed — and both times the whole table was recomputed.

## H. What this leaves for later

1. **Seed candidates for the slots that have none.** Seeding House candidates
   is what would let the parser tell a district's real matchup from a
   pre-primary hypothetical (§B3) and turn the three districts now resting on
   fundamentals back into polled races. The same gap exists on the Senate side
   wherever a *party* has no nominee yet — South Carolina's Republican slot is
   the worst of them, eight hypotheticals deep (§G1a) — and closing it is the
   same piece of work.
2. **Refresh `DISTRICT_POLL_STATES` after the remaining primaries.** Nine
   states are one nomination away from carrying general-election district polls
   (§A3) and will not be fetched until the list is re-surveyed.
3. **The four placeholder-opponent polls** are excluded from averaging and
   still displayed (§F, §G3). Whether to delete them outright is an editorial
   call nobody now has to make in a hurry.
4. **Watch the bandwidth, not the request rate.** 69 sources is 61 MB a sweep
   and 12 sweeps a day. If that becomes a problem the lever is a separate,
   slower cadence for district sources rather than a shorter list — the list is
   already only the pages that carry polls.

---

# Phase 9 — Pollster house effects (averaging)

The averaging layer now estimates each pollster's systematic lean, removes it
from every average, and publishes every number that went into the decision on
a public `/pollsters` page. The estimate is a leave-one-out residual: how far
a firm's polls sit from what everyone *else* found on the same question at the
same time. It is not a measure of accuracy — no election has happened — and
the page says so.

## A. Params, and the two the brief did not ask for

### A1. What the literature actually supports

Four URLs, each fetched and read during this phase rather than recalled:

| Source | What it establishes |
|---|---|
| [538, "How our polling averages work"](https://abcnews.com/538/polling-averages-work/story?id=103232260) (Morris, 2023-10-09) | The definition we use — a firm's tendency to lean one way relative to the average poll. Bayesian shrinkage toward a zero-mean prior whose SD "usually it's around 3 points". Aggregation run **three separate times**. |
| [538, "How 538's pollster ratings work"](https://abcnews.com/538/538s-pollster-ratings-work/story?id=105398138) (Morris, 2024-01-25) | The shrinkage **form**, verbatim: `Adjusted Error × (n / (n + n_shrinkage)) + group_error_prior × (n_shrinkage / (n + n_shrinkage))`. `n_shrinkage` is described as the effective number of polls' worth of weight to put on the prior. **The value is not published.** |
| [Silver Bulletin, polling-average methodology](https://www.natesilver.net/p/silver-bulletin-polling-average-methodology) | House effects and the average solved **iteratively**, looping "until there are no further gains to be had". Shrinkage keyed to how often a firm polls. |
| [Silver Bulletin, "Which polls are biased toward Harris or Trump?"](https://www.natesilver.net/p/which-polls-are-biased-toward-harris) (2024-09-27) | Magnitudes, **on the margin scale**: the most Republican-leaning majors were Trafalgar −2.7 and Rasmussen −2.6; the most Democratic about +1.9. Firms with a handful of polls "discounted heavily toward the mean". The write-up's own cutoff was five polls of the race. |

Dead ends, recorded so nobody re-runs the search: every `fivethirtyeight.com`
permalink for the 2010–2012 Silver-era house-effect posts now 301s to an ABC
politics index, and `web.archive.org` was unreachable from the build
environment. Those are the pieces most likely to carry a plain "a typical
house effect is X points" sentence, and their absence is the biggest hole in
the citation set. `abcnews.com/538/<slug>/story?id=<n>` — the pattern Phase 3
already used — is confirmed working across six methodology pieces.

So: **the functional form is 538's, the cap is anchored to two published
magnitudes, and `shrinkage_k` is ours.** Said plainly in the YAML rather than
dressed up as inherited.

### A2. `min_polls_to_apply: 3`, and the tension in it

Kept at the brief's value, but it is the weakest-supported number here and the
comment says so. **No published model uses a hard gate at all** — both 538 and
Silver Bulletin rely on continuous shrinkage that approaches zero smoothly.
Where those methodologies do state hard minimums they cluster at five, never
three: 538 needs five polls from three pollsters before publishing a race
average, and Silver's own house-effect table used firms with five or more.

Three is kept because the gate is belt-and-braces behind the shrinkage, which
has already cut an n=3 effect by 62% before the gate sees it; what the gate
actually catches is n=1 and n=2, where an "effect" is one poll's sampling
error. What raising it would cost, measured on the live board: **44 applied at
3, 24 at 5** — twenty firms, two of them in the top ten by magnitude (Marist
University and Public Opinion Strategies, both estimated on three residuals).
That is a large enough cut to be a real decision rather than a tidy-up, and it
is the reason this is flagged as the weakest-evidenced constant on the page
rather than quietly changed to match the literature's adjacent thresholds.

### A3. `residual_half_life_days: 180` — a param the brief did not list

The approved design says residuals are "time-decayed on the same half-life as
the averager". Implemented literally that is 14 days, and on a 20-month corpus
it breaks the estimator. Effective sample size (Kish, `(Σw)²/Σw²`) per
pollster, measured on the live generic-ballot corpus:

| Pollster | Polls | ESS at 14d | ESS at 180d |
|---|---:|---:|---:|
| The Economist/YouGov | 81 | 8.4 | 71.4 |
| Morning Consult | 49 | 6.3 | 42.7 |
| Big Data Poll | 33 | 6.2 | 29.3 |
| Reuters/Ipsos | 30 | 5.0 | 27.7 |
| **RMG Research** | **24** | **1.4** | **19.1** |
| Quantus Insights | 23 | 1.8 | 17.8 |
| Cygnal | 21 | 1.8 | 15.8 |

At 14 days, RMG Research's estimate rests on 1.4 polls of information while
the shrinkage term — which counts polls — sees 24 and shrinks by only 17%. A
single poll's margin carries roughly ±3.5 points of sampling error at n=800,
so the cap would routinely bind on noise, and the page would publish "R+2.8
from 24 polls" when the truth is "R+2.8 from last month's poll". That is the
confident-looking adjustment built on noise this phase was told not to ship.

A house effect is a slow-moving property of a firm's methodology; the 14-day
half-life is tuned for a fast-moving race. Separating them is what makes the
count-based shrinkage coherent with the weighting. **180 days** keeps the
design's requirement (recent behaviour outweighs old) while leaving ESS
tracking the count closely.

### A4. `min_comparison_pollsters: 3` — implementing a clause the brief dropped

The approved design asks for race-level residuals only "where a race has
enough distinct pollsters to define a meaningful average". The brief omitted
that clause, and the first live run showed exactly why it exists:

```
The Bullfinch Group   +7.43 raw  → +3.00 (capped), n=9, applied
Peak Insights        -44.00 raw  → -3.00 (capped), n=1
```

Both traced to **one pairing in Idaho** — two polls a week apart, 44 points
between them, each firm's residual being nothing but the other firm's lean
with the sign flipped. That single pairing was the largest input to two
different published effects, and it dragged Bullfinch to the top of the table
on the strength of it.

Against one other house a residual is not a distance from the field. The rule
is applied to the generic ballot too, so there is one standard for what counts
as a field; the generic ballot clears it on nearly every date, so it costs
almost nothing there. The threshold sweep, live:

| `min_comparison_pollsters` | Estimated | Applied | At the cap | Top three |
|---:|---:|---:|---:|---|
| 1 | 129 | 56 | 3 | Bullfinch, Peak Insights, AtlasIntel — two of them Idaho artefacts |
| **2** | 113 | 48 | 1 | AtlasIntel, RMG, McLaughlin |
| **3** | **111** | **44** | **1** | AtlasIntel, RMG, McLaughlin |
| 4 | 105 | 42 | 1 | unchanged |
| 5 | 101 | 40 | 1 | unchanged |

The answer is stable from 2 upward — the top of the table does not move again
— so this is a cliff, not a dial, and 3 sits just past it. Three is chosen
over two because a "field" of two houses is still 50% one house.

## B. How the estimator works

`Forecast::HouseEffects`, one pass, in the runner before any averaging.

**The residual.** For poll `p` by pollster `P` measuring quantity `Q` at
`field_end t`: build the weighted mean margin of every OTHER house's polls of
`Q` within ±`residual_window_days` of `t`, using the averager's own weight
function on the **absolute** distance from `t`. `residual = margin_p − that`.

Three details that are decisions, not mechanics:

1. **The window is symmetric.** A backward-only window would sit two to three
   weeks behind each poll on average and charge every pollster for whatever
   the race did in between. Centring on the poll removes the first-order
   trend bias.
2. **One poll per house in the comparison.** The Economist/YouGov alone has 81
   of the 559 generic-ballot polls; without this, a good part of every other
   firm's "lean" would be a measurement of its distance from The
   Economist/YouGov. The one kept is the nearest in time to `t` — the window
   runs both ways, so "latest" is not the question being asked.
3. **One residual per house per field period.** A release publishing a two-way
   and a three-way version of the same question is one poll. Tavern Research's
   four Montana rows to 2026-07-27 were producing four residuals — two of them
   numerically identical — inflating the very count the shrinkage reads as
   evidence. Deduplicating those cut `ambiguous_matchup` skips from 80 to 40
   and Tavern's residual count from 11 to 3.

**Eligibility is the averager's own, shared not copied.** `Forecast::Averager`
gained two public methods (`#measurement`, `#distinct_matchups`) for this. A
poll the average would refuse contributes no residual: a placeholder opponent,
a missing side, or a race whose polls *in that window* disagree about who is
running. Phase 8's rule reaching in here is the whole point — a residual
measured against a blend of mutually exclusive matchups would put that
contamination inside every pollster's estimated lean, and from there into
every average the model takes. The ambiguity test runs over everything in the
window **including the subject's own polls and before the field-period
dedup**, the same order and for the same reason as §G6 of Phase 8.

**The effect.** Weighted mean of the firm's residuals pooled across every
quantity — the generic ballot and each race are all D−R margins against a
contemporaneous average of the same thing — weighted by each residual's own
poll weight, decayed toward the run date on `residual_half_life_days`. Then
`clamp(raw × n/(n+k), ±max_effect_pp)`.

**A row is written only for a firm with at least one residual.** "No estimate"
and "an estimate of zero" are different claims, and 42 of the 153 firms in the
corpus are the first. A run of zeroes on the page would say the second.

**Single pass, and it is a simplification.** Both published models iterate;
we do not. The bias it leaves is one-directional and worth naming: where
several firms polling the same thing lean the same way, each is measured
partly against the others' lean, so all their estimated effects come out a
little too close to zero. The correction is therefore conservative rather than
overcooked. On the methodology page in those words.

## C. What it does to the board

Same seed (20260811), same corpus, effects off then on — runs 13 and 14, so
the difference is the adjustment and not the RNG.

| | Effects off | Effects on | Δ |
|---|---:|---:|---:|
| Generic ballot (D−R) | +6.4272 | +6.6799 | **+0.2527** |
| Senate D control | 37.08% | 37.95% | +0.87pp |
| Senate mean D seats | 49.64 | 49.73 | +0.09 |
| House D control | 96.15% | 96.61% | +0.46pp |
| House mean D seats | 240.76 | 241.65 | +0.89 |

Every one of those deltas is **deterministic**, not sampling scatter — same
seed means the simulator draws the identical numbers, so the only thing that
changed is each race's `mu`. But deterministic is not the same as meaningful:
both chamber moves are **smaller than the Monte Carlo uncertainty in the
reported probability itself** (~1.4pp on Senate control at n_sims=10,000,
Phase 3 §8.2), so neither should be read as the forecast having changed. Race
by race, `mean |Δ margin| = 0.251` and **1 of 470 races moved by 1.5pp or
more** on the site's own movers floor (OH-07, +2.5pp).
The correction is a small, almost entirely national shift — the generic-ballot
move flowing into every district's prior — not a re-ranking of the board.

That is the honest headline: **this phase buys inspectability and a quarter
point on the national environment, not a different forecast.**

### C1. A property worth knowing

In a field where every house polls equally often, removing house effects
**does not move the average at all**. Residuals are measured against the other
houses, so the effects net out; what changes is which firms carry the weight.
Pinned as a regression test, because a correction that shifted a balanced
average would be measuring something other than the gap between houses. Where
it bites is a race one firm has to itself — there the whole effect comes off.

## D. The ten largest effects, live (run 14, 2026-08-11)

| Pollster | Raw | Shrunk | Residuals | Polls | Applied |
|---|---:|---:|---:|---:|:--|
| AtlasIntel | +8.48 | **+3.00** (capped) | 5 | 5 | yes |
| RMG Research | −3.68 | −2.84 | 17 | 24 | yes |
| McLaughlin & Associates | −3.59 | −2.69 | 15 | 18 | yes |
| Harvard/Harris Poll/HarrisX | −4.04 | −2.20 | 6 | 12 | yes |
| Glengariff Group | −7.12 | −2.03 | 2 | 7 | **no** |
| Marist University | +5.15 | +1.93 | 3 | 3 | yes |
| Public Opinion Strategies | −5.12 | −1.92 | 3 | 4 | yes |
| Morning Consult | −1.99 | −1.81 | 49 | 49 | yes |
| Catawba College/YouGov | +6.14 | +1.75 | 2 | 2 | **no** |
| Strength In Numbers/Verasight | +2.43 | +1.75 | 13 | 22 | yes |

**111 of 153 firms estimated, 44 applied, exactly 1 at the cap.** Applied
effects: mean −0.093, median −0.029, 19 above 1 point, 4 above 2. A
leave-one-out system should centre near zero by construction, and it does —
that is the estimator checking its own arithmetic.

**AtlasIntel is the surprise and it is not an artefact.** Its five
generic-ballot polls read D+9, D+8, D+8, D+16, D+15 against field medians of
D+0, D+3, D+3, D+4 and D+6 in the same months — a consistent gap across twelve
months, not one stray release. A firm with a public reputation for
Republican-leaning US presidential numbers is the most Democratic-leaning
generic-ballot house in this corpus by a wide margin, and it is the only firm
the cap binds on. Reported as found. On five residuals the shrinkage keeps
half of it and the cap takes the rest, which is the machinery behaving
correctly around an outlier rather than being fooled by one.

Two firms in the top ten are shown and **not** applied (Glengariff, Catawba)
— which is the `/pollsters` page doing its job.

## E. Publication

* **`/pollsters`** — all 153 firms with a poll, sorted by |shrunk effect|,
  not-applied rows visually muted. The sign convention is stated in words at
  the top, because it is the one thing a reader cannot derive and inverting it
  would double every lean instead of removing it. Three queries however many
  firms there are, pinned by test. Honest empty states for "no polls at all"
  and "no run has estimated effects yet".
* **Race pages** — a "House adj." column showing the adjusted margin over the
  lean that was removed. Deliberately *not* rendered as "−R+1.6": a minus sign
  in front of an already-signed party label is two conventions in one token
  and a reader cannot tell which way the margin moved. Caught by looking at
  the rendered live page, not by a test.
* **The scatter's reference line** is now drawn from the *adjusted* average,
  so the line on the chart is the one the model used. The plotted points stay
  raw — they are what the pollster published.
* **Methodology** — a five-step plain-language section, plus the single-pass
  note. The old "no pollster house-effect correction" limitation is gone,
  replaced by the accurate narrower one about the single pass.

## F. Tests

69 new tests (792 → 861), plus the system test. Highlights: a hand-computed
residual golden to 7dp; shrinkage arithmetic at n = 1, 5 and 50 against a
constructed flat field where every residual is exactly 2.0, so the arithmetic
is isolated from the weighting; the cap in both directions; window boundary at
exactly 45 and 46 days; symmetry; leave-one-out proven by a firm that polls a
quantity alone getting no residual; ambiguous matchups and placeholder
opponents excluded; `min_polls_to_apply` gating `applied` without gating
display; `enabled: false` estimating everything and applying nothing.

**The Phase 3 averaging goldens are byte-for-byte unchanged**, pinned three
ways: the whole pre-existing averager suite still passes untouched, a new test
asserts that a nil/empty/absent lookup all reproduce the same Result fields,
and a runner test asserts the fixture world applies zero effects — so a future
change that started adjusting the fixture world fails by name rather than as a
wall of moved goldens.

## G. What this leaves for later

1. **Iterate.** One extra pass would be cheap (the estimator runs in 0.5s) and
   would recover the conservative bias in §B. Two or three passes is what both
   published models do.
2. **Shrink on aggregate sample size, not poll count.** Silver Bulletin keys
   its shrinkage to total respondents. A firm with three 3,000-person polls
   and one with three 400-person polls are treated identically here.
3. **`min_polls_to_apply` is the weakest-evidenced constant on the page**
   (§A2). Five is the better-precedented value and costs seven firms.
4. **Residuals within a firm are correlated** — a run of polls in one short
   span is close to one observation, so `n` overstates the independent
   evidence and the shrinkage is correspondingly too gentle for a firm that
   polls in bursts.
5. **42 firms have polls and no estimate.** Mostly single polls of races
   nobody else polled. More district polling closes this on its own.

## H. Operational note — 23 dispatches the build published by accident

Smoke-testing the new pages against the real corpus meant starting a
development server, and `config/initializers/good_job.rb` registers the
newsroom cron in development too. It fired: **model run 15 (trigger `ingest`)
and 23 published `poll_reaction` dispatches**, written by real OpenRouter
calls to `anthropic/claude-sonnet-5`. Dispatch ids 4–26.

Nothing was scraped and no poll was added or changed — the corpus is still 975
polls and 559 generic-ballot polls, and run 15 is a clean run of the new code
(111 effects estimated, 44 applied), so the live board is correct. **The
dispatches were left in place.** They are published editorial content and
deleting or retracting them is the editor's call, not the build's; the
standing rule for this database is that nothing gets destroyed.

Worth a guard before the next phase does the same thing: either a
`GOOD_JOB_ENABLE_CRON=false` in the smoke-test path, or gate the cron
registration on something other than "not test". Curling a page should not be
able to spend API credit and publish to the site.

---

# Phase 10 — Correlated error structure (simulation)

The last model-v2 phase, and the one the site's own pages apologised for.
Until now every race was correlated to every other through exactly one shared
national error; this replaces it with four components, three of them shared at
different geographic scopes. Research and live runs dated **2026-08-12**.

## A. The four components, and the back-solve

538's 2024 House model publishes the decomposition outright: "There are about
3 points of error at the national level, 2 each at the regional and state
levels, 2 at the demographic-cluster level, and 6 at the district level,"
combined in quadrature.
<https://abcnews.com/538/538s-2024-house-election-forecast-works/story?id=114446291>

We now carry four of those five, at their values:

| Component | Shared by | σ |
|---|---|---|
| National | every race, both chambers | 3.0 |
| Regional | every race in a census division | 2.0 |
| **State** | **a state's Senate race and all its districts** | **2.0** |
| Idiosyncratic — Senate polled | one race | 2.2913 |
| Idiosyncratic — Senate unpolled | one race | 7.2973 |
| Idiosyncratic — House district | one district | 6.0 |

**`sigma_national` 2.5 → 3.0 is not a re-reading of the evidence; it is a
refusal to mix decompositions.** The AAPOR series Phase 3 used still says what
it said (RMS 2.8 across offices 2016–2024, 2.1 for the presidential series
back to 2000, so 2.5 "in the middle"). But a decomposition only means anything
taken whole: our national term paired with 538's regional and state terms
would give a correlated total neither source stands behind. What the AAPOR
anchors actually constrain is a race's *total* error, and the back-solve below
holds both Senate totals exactly where Phase 3 put them.

**The arithmetic, to four decimals:**

```
correlated total          sqrt(3² + 2² + 2²)   = sqrt(17)    = 4.1231
Senate polled, total      sqrt(2.5² + 4.0²)    = sqrt(22.25) = 4.7170   (unchanged)
  → idiosyncratic         sqrt(22.25 − 17)     = sqrt(5.25)  = 2.2913
Senate unpolled, total    sqrt(2.5² + 8.0²)    = sqrt(70.25) = 8.3815   (unchanged)
  → idiosyncratic         sqrt(70.25 − 17)     = sqrt(53.25) = 7.2973
House district, total     sqrt(17 + 6²)        = sqrt(53)    = 7.2801   (was 6.5000)
538's correlated total    sqrt(3² + 2² + 2² + 2²) = sqrt(21) = 4.5826
538's district total      sqrt(21 + 36)        = sqrt(57)    = 7.5498
```

The stored idiosyncratic terms are the back-solve rounded to four decimals,
which puts the unpolled total back at 8.3816 against 8.3815 — a ten-thousandth
of a point on a quantity whose anchors are quoted to one. `test/lib/pol/
params_test.rb` pins all six totals against this arithmetic, so anyone
retuning a correlated component is told to re-solve rather than left to
discover it.

**The House district total rises on purpose.** 6.0 is 538's own cited
district-level value; our old 6.5000 total was never independently calibrated
— it was an artifact of having a single correlated term. 7.2801 is nearer
538's 7.5498 than 6.5000 was.

**`sigma_state_polled` / `sigma_state_unpolled` are renamed
`sigma_senate_polled` / `sigma_senate_unpolled`.** With a genuine state-level
term now above them, a name saying "state" for one race's idiosyncratic noise
was actively misleading.

**Omitted, and said out loud:** the demographic-cluster term. It correlates
districts that resemble each other regardless of where they are, and building
it needs a clustering of all 435 districts we have no data for. Inventing a
clustering would be inventing the correlation it is supposed to measure. What
that omission costs is measured in §C, not guessed.

## B. Census divisions — the mapping and its source

`Pol::CensusDivisions` maps all 50 states plus DC to one of the nine Census
divisions. Transcribed at build time from two census.gov sources that agree
exactly, one prose and one machine-readable:

- <https://www.census.gov/programs-surveys/economic-census/guidance-geographies/levels.html>
  ("Regions and Divisions" section, read from the page's own HTML rather than
  a summary of it)
- <https://www2.census.gov/programs-surveys/popest/geographies/2023/state-geocodes-v2023.xlsx>
  — "Census Bureau Region and Division Codes and Federal Information
  Processing System (FIPS) Codes for States", Population Division, internet
  release date May 2024. Its 51 state rows were joined to `Race::STATE_NAMES`
  to get the two-letter codes.

Counts: New England 6, Middle Atlantic 3, East North Central 5, West North
Central 7, South Atlantic 9 (including DC), East South Central 4, West South
Central 4, Mountain 8, Pacific 5 — 51 rows, 9 divisions, every state exactly
once. The test asserts those counts and that the code set equals
`Race::STATE_NAMES`, so the two lists cannot drift.

**Divisions, not the four Census regions.** 538 says "the regional level" and
does not publish which grouping it means. Four regions would put one shared
shock over the entire South — 16 states and 164 districts. Nine divisions is
the finest standard grouping published, which is the conservative reading. It
is also very nearly free: measured on the live board, running the same four
components over four regions instead of nine divisions moves House control
from 93.1% to 92.5% and seat SD from 17.4 to 17.8. The choice is documented
rather than defended as decisive, because it isn't.

**DC** is in the table because the Census puts it in the South Atlantic and a
table that disagreed with its source would be the kind of small silent edit
the file exists to prevent. It never draws: no Senate seat, no voting
district, and the live board has races in exactly 50 states. A state outside
the table raises rather than resolving to nothing — a race with no division
would take no regional or state error and quietly fall out of the correlated
structure, narrowing the seat distribution exactly where this phase widened
it.

## C. Controlled before/after — and where it did not land

**This section is a controlled experiment, not the live board.** Runs 16 and
17, same seed (20260811), same date, **same 975 polls** — nothing re-scraped
and nothing re-seeded, so the delta is attributable to the change and to
nothing else. Both run with `AGENTS_DISABLED=1`. Nothing here is restated
against later data; the current board is §H, and every figure in this section
keeps its run number so the two can never be confused. (As it happens the two
sit on identical polls — the refresh in §H added none — so the difference
between run 17 and the current run 19 is the RNG seed and nothing else.)

| | before (run 16) | after (run 17) |
|---|---|---|
| House D control | **96.61%** | **93.12%** |
| House seat SD | 13.62 | **17.44** |
| House seat range | 187–310 | 180–314 |
| Senate D control | **37.95%** | **39.71%** |
| Senate seat SD | 2.62 | **3.00** |
| mean D seats (H / S) | 241.65 / 49.73 | 242.26 / 49.68 |
| runtime | 2.04s | 2.12s |

**Individual races barely moved — the signature of reallocation rather than
inflation.** Not one of the 470 races moved as much as the newsroom's 8-point
movement threshold; the largest single move was 3.77 points and the mean was
0.86.

| race | before | after |
|---|---|---|
| Michigan Senate | 48.06% | 48.04% |
| Texas Senate | 65.05% | 64.77% |
| Alaska Senate | 26.69% | 26.75% |
| AZ-2 | 51.37% | 51.34% |
| WI-1 | 45.50% | 46.11% |
| AL-1 | 0.00% | 0.00% |

### The result did not land where the design predicted, and the reason is the
### design's arithmetic, not the model's

The design expected House control near **85–88%**, interpolating the Phase 3
measurement table (2.5 → 96.3%, 3.5 → 90.2%, 4.58 → 83.9%). It landed at
**93.1%**. That table raised `sigma_national` alone, so every one of its rows
routes the whole correlated variance through the *national* channel — and a
correlated total of 4.1231 spread over national, division and state is not
interchangeable with a national term of 4.1231. Only the 3.0 is common to all
435 districts; the regional and state parts partly average away across a
chamber, which is precisely what a national term cannot do.

Measured on the live board, same seed, same polls, error model varied:

| configuration | correlated | House D | seat SD | Senate D | seat SD |
|---|---|---|---|---|---|
| Phase 9 (N 2.5 only) | 2.5000 | 96.8% | 13.6 | 38.2% | 2.62 |
| **Phase 10 (3.0 / 2.0 / 2.0)** | **4.1231** | **93.1%** | **17.4** | **39.7%** | **3.00** |
| same per-race totals, all correlation national | 4.1231 | 87.6% | 22.6 | 41.4% | 3.73 |
| Phase 3 table row: N 3.5 | 3.5000 | 91.2% | 19.0 | 40.2% | 3.31 |
| Phase 3 table row: N 4.58 | 4.5800 | 84.9% | 25.3 | 42.1% | 4.07 |
| + a 5th component of 2, at state scope | 4.5826 | 92.8% | 17.8 | 39.1% | 3.01 |
| + a 5th component of 2, at region scope | 4.5826 | 92.2% | 18.2 | 40.1% | 3.06 |
| + a 5th component of 2, at national scope | 4.5826 | 89.7% | 20.7 | 40.9% | 3.43 |

(The two Phase 3 rows reproduce that table to about a point — 91.2 against
90.2, 84.9 against 83.9 — on a different date, a different seed and a corpus
that has grown since, which is as close as reproduction gets here. The Phase 9
row reads 96.8% against run 16's 96.61% for the same reason plus one more: the
new code draws the regional and state series even when their sigma is zero, so
the per-race draws differ. Both sit inside the 1.4pp run-to-run noise floor
measured in Phase 3 §8.2.)

**Provenance, because the first reviewer of this table reconstructed one row
differently and got different Senate numbers.** Every row above is
`as_of 2026-08-12`, seed 20260811, 10,000 sims, the 975-poll corpus, and — this
is the part that has to be said out loud — **each row carries the full parameter
set of the model it names, not just its correlated terms**. The Phase 9 row
therefore uses Phase 9's `sigma_state_polled: 4.0` / `unpolled: 8.0`, giving a
polled Senate race a total of 4.7170; it is the Phase 9 *model*, not Phase 10
with `sigma_national` turned down. Reconstructing it the other way — varying
`sigma_national` to 2.5 and leaving Phase 10's back-solved 2.2913 in place —
gives a polled Senate total of 3.3912, below every anchor Phase 3 calibrated
against, and reads **S 37.49% / sd 2.47** instead of 38.20 / 2.62 (verified: it
reproduces to the digit, 37.01 / 2.47 at `as_of` 08-11). The House cells are
identical either way, since `sigma_district` does not move between the two.
Both figures are correct arithmetic; only the first is a Phase 9 baseline.

**Two things follow, and the second is the more important.**

1. **The Phase 3 caveat overstated the problem it described.** "96% here reads
   84%" was measured by routing all correlated variance through the
   maximally-correlating channel. That is an upper bound on the effect — Phase
   3 said as much ("not the right fix, but it does bound the size of the
   effect") — and the site then printed the bound as the honest reading. With
   the correlation put where the literature puts it, the same variance moves
   the House number by 3.5 points, not 12.
2. **538's own House model is therefore narrower than a 4.58 national term
   would imply, for exactly the same reason.** Their 4.5826 is a quadrature
   sum across four scopes; only 3.0 of it is common to all 435 districts.
   Comparing our correlated total to theirs in quadrature is the right way to
   size the omission, but converting either into a chamber probability
   requires the geography, not just the total.

**The cost of the missing cluster term, measured rather than guessed:** adding
a fifth component of 2.0 points moves House control from 93.12% to 92.77% at
state scope, 92.16% at region scope and 89.68% at national scope — **0.35 to
3.44 points**, against the six to twelve the retired caveat claimed.

Where in that range is a question about the component, not about the model. A
demographic clustering *partitions* the 435 districts into groups, so a cluster
shock hits a subset and the rest of the chamber absorbs it; the 3.44-point end
assumes the term correlates every district at once, which is the one thing a
partition cannot do. It is an upper bound by construction. The truth sits
nearer the region row, because a cluster spans states but not the country.

The Senate moves by under a point across the same three placements — 39.11%,
40.08%, 40.89% against a 39.71% baseline — and in both directions. At 10,000
simulations the standard error on a control probability near 40% is 0.49
points, so **that spread is not resolved from sampling noise** and nothing here
should be read as a Senate effect with a sign.

No constant was tuned to close the gap to the design's prediction. The
structure is 538's, at 538's values, applied to the geographies they name; the
number is what that produces.

## D. What came off the site, and what replaced it

The blanket caveat's factual claim — "correlates races through a single
national error term where fuller models use several" — is false as of this
phase, and its magnitude claim was an overstatement even when it was written.
It is gone from all five surfaces:

- **`app/views/shared/_house_caveat.html.erb` → `_house_error_note.html.erb`**
  (`data-testid` renamed with it). A marker is still warranted — the residual
  gap is one-directional and larger than the 1.5pp noise floor the site
  already treats as meaningful — but it now names the real remaining gap: four
  of five components, the fifth omitted for want of data. **No number in it**,
  for the reason Phase 5 learned: a figure printed beside a probability goes
  stale the run after it is written. The measured range lives on the
  methodology page, where it carries a date.
- **`Newsroom::Prompts::HOUSE_CAVEAT` → `HOUSE_ERROR_NOTE`.** The mandate that
  every sentence carrying a House probability say the model overstates
  certainty is gone. What is left describes the four levels and the omitted
  fifth, invites the writer to say so where it is relevant, and keeps the two
  prohibitions that were always the useful part: no figure on the difference,
  no corrected probability. "A probability is not a prediction" was never part
  of this string and is untouched in the UNCERTAINTY block above it.
- **The payload key `must_say` → `error_model_note`.** The text still travels
  with the House numbers; nothing now requires it to appear in the copy.
- **`lib/tasks/pol.rake`.** The summary prints the three correlated sigmas and
  their total, read from the params rather than hardcoded, then names the
  omitted component.
- **`/methodology`.** "How the forecast works" step 4 describes all four
  levels and why a state's Senate race and its districts move together. Known
  limitations replaces "The House control probability is overconfident" with
  "One correlated error component is missing", carrying 4.12-against-4.58 and
  the measured 93.1% → 92.8–89.7% range. The six sigmas render in the params
  table with their citations, including the census.gov spreadsheet beside
  `sigma_regional`.

`Forecast::Runner#write_chamber_forecasts` and the README's Current
limitations carried the same claim in prose and were rewritten to match. (The
README also still said there were no pollster house effects, which Phase 9
made untrue; fixed in the same paragraph rather than left standing.)

## E. Tests

880 tests, 3,075 assertions, plus the system test. Rubocop clean.

- **Goldens re-pinned with their independent checks.** Both the simulator's
  fixed-seed golden and the runner's fixture-world golden moved, and both keep
  a paired check. The simulator gains a stronger one than it had: the golden's
  two races are now **rebuilt draw for draw** from the design — national
  series, then one per census division in Census order, then one per state
  alphabetically, then each race's own noise in entry order — and composed by
  hand, so a change to the composition rule fails saying what broke instead of
  leaving five moved numbers to be re-pinned on faith. The 200,000-draw
  closed-form check stands alongside it and now reads its correlated terms
  from the params. The runner's golden keeps every hand-computed `mu` it had
  (none of them moved — the central estimates are untouched by this phase) and
  adds two width checks that recover 4.7170 × t and sqrt(53) × t from the
  published percentiles.
- **The correlation ladder, against a closed form.** For two mean-zero races
  with correlation ρ, the share of simulated worlds where exactly one goes to
  side A is 1/2 − arcsin(ρ)/π, and the seat histogram's middle bucket counts
  it directly. Same state ρ = 17/17, same division 13/17, different divisions
  9/17 — each asserted against its own value, so the ordering is a consequence
  of the arithmetic rather than the claim being tested.
- **Cross-chamber sharing, extended.** The Phase 3 regression (a refactor
  drawing the shared series once per chamber loop) is kept, isolated by
  switching the regional and state terms off so only the national series can
  be doing the work. Added beside it: a state's Senate race and its two
  districts win the identical set of worlds, and their seat histogram has no
  bucket for "one district each way".
- **Reallocation, not inflation.** A Senate race's margin distribution keeps
  its width — 4.7170 × t, read back off the percentiles — while a 35-race
  chamber's seat SD widens by a fifth. Both seat SDs are checked against an
  analytic form (n/4 plus every pair's arcsin(ρ)/π) rather than recorded, so
  the widening is verified rather than observed.
- **The shared draws cost one series each, not one per race**, asserted by
  counting Gaussian draws: 1 national + 2 divisions + 3 states + 4 contested
  races = 10 series, with the certain race taking nothing. That is the
  performance guarantee as arithmetic instead of a stopwatch; the wall clock
  is in §C (2.12s for 470 races × 10,000 sims against a 60-second budget).
- **End to end through real Race rows**, because `to_entry` passing the state
  is what makes any of the above reach the live board: two House districts in
  Maine alongside Maine's Senate race co-move, and an Oregon district does
  not.
- **Division mapping completeness**: 51 codes, 9 non-empty divisions, equality
  with `Race::STATE_NAMES`, DC in the South Atlantic with no race, every state
  on the live board resolvable, and territories/typos/nil raising.

## F. Operational note — the guard Phase 9 asked for earned its keep

Phase 9 §H recorded 23 dispatches published by accident from a smoke-test
development server, and asked for a guard before the next phase did the same
thing. This phase ran every live model run and the one dev server with
`AGENTS_DISABLED=1`, and it mattered: the server booted GoodJob's async
executor with cron enabled ("GoodJob started cron with 3 jobs"), which picked
up **one `Newsroom::PollReactionsJob` left queued from before this session**
and drained it. It recorded **74 `agents_disabled` skips and published
nothing** — 74 Opus-written poll reactions that a server booted without the
flag would have paid for.

Confirmed for the whole phase, counting from the first live run: 0 dispatches,
0 scrape runs, 0 new GoodJob rows, no OpenRouter call in the server log, and
the corpus still at 975 polls. The three model runs it did create (16, 17, 18)
are the before, the after and the rake-summary check.

The standing recommendation stands and is now evidence-backed rather than
hypothetical: the cron registration in `config/initializers/good_job.rb`
should be gated on something narrower than "not test", so that starting a dev
server cannot spend API credit. `AGENTS_DISABLED=1` is a discipline, and
disciplines are the thing that fails.

## G. What this leaves for later

1. **The demographic-cluster term**, the fifth component, needing a clustering
   of all 435 districts. §C prices the omission at one to three points of
   House control.
2. **The regional term's geography is a judgement call.** Nine divisions, not
   four regions, and 538 does not say which it means. Worth 0.6 points either
   way (§B), so it is a note rather than a risk.
3. **Correlated error is symmetric and mean-zero here.** Nothing in this
   structure expresses a *directional* prior — that polling misses have leaned
   one way in recent cycles is in the sigma, not in a bias term, and adding one
   would be a different kind of claim than this phase makes.
4. **The Senate's idiosyncratic terms are back-solved from Phase 3's totals.**
   If a later phase re-derives those totals from newer evidence, both numbers
   have to be re-solved; `params_test.rb` fails loudly if they are not.

## H. Data refresh, 2026-08-12 — and what it did not change

Run after the phase was reviewed, on instruction, with the no-re-scraping rule
lifted. All three steps under `AGENTS_DISABLED=1`. **The headline is that the
board was already current**, which is worth recording as carefully as a change
would have been: a refresh that finds nothing is only reassuring if you can
show it looked.

### 1. `bin/rails pol:seed_races` — no change, and a structural reason why

35 Senate races (2 specials, 35 leans), 435 House districts, 37 imputed
baselines (9%) — identical to the previous seed. Diffed properly rather than
eyeballed: a before/after snapshot of all 470 races across candidates, lean,
baseline, imputed flag, uncontested, open-seat and incumbent fields showed
**0 races added, 0 removed, 0 fields changed, 0 candidate lists changed.**

The reason is structural and should be known before anyone expects otherwise.
**`pol:seed_races` cannot pick up a settled primary.** The Senate side reads
`db/seed_data/senate_2026.yml`, a hand-verified committed list last touched in
Phase 2 (`fbd6b96`); no scraper updates it. The House side re-reads the 2024
results page, whose numbers are historical and do not move. So the task is
idempotent by construction, and re-running it after a primary resolves
**nothing** unless a human edits the YAML first.

Ten races still carry `unsettled: true` in that list — **AK, DE, FL-special,
MA, MN, NH, OK, RI, SC, WY** — meaning a listed candidate is a declared
front-runner rather than a nominee. South Carolina's special primary was
2026-08-11 and South Carolina is still on that list. Reflecting these needs
either a hand-edit of the verified list or a nominee scraper, and both are
outside this phase. Recorded so the gap is visible rather than assumed closed.

### 2. `bin/rails pol:scrape` — full sweep, nothing new

| | |
|---|---|
| sources swept | **69** |
| rows fetched | **989** |
| **new polls** | **0** |
| duplicates | 979 |
| skipped | 10 |
| tables refused | 324 |
| sources with no polling section | 6 |
| outright failures | 0 |

Refusals by reason: `primary_only_table` ×172, `no_candidate_column_match`
×67, `generic_candidate_column` ×44, `aggregator_table` ×29,
`multiple_same_party_columns` ×5, `no_party_columns` ×4, `district_unresolved`
×2, `results_table` ×1 — the same distribution Phase 8 §F recorded, which is
what a healthy sweep looks like: the refusals are the parser declining primary
and aggregator tables, not failing on general-election ones.

Corpus after: **975 polls, 1,979 poll results, 154 pollsters** — unchanged.
The newest `field_end` anywhere in the corpus is **2026-08-06**, so Wikipedia
genuinely has nothing newer; the previous sweep (2026-08-11 23:47) had already
caught up.

One consequence worth naming, because it is the difference between a quiet
refresh and an expensive one: `Ingest::Scraper` calls
`Ingest.after_new_polls!` only when a sweep creates polls, and that hook
enqueues a `Forecast::RunJob` carrying the new poll ids, which on success calls
`Newsroom.after_model_run!`. **Zero new polls meant no job was enqueued**, so
this sweep left nothing armed in the queue (verified: 0 unfinished GoodJob
rows). Had it found a hundred new polls it would have queued a run that
published a hundred reactions the next time any worker started — which is the
hazard `AGENTS_DISABLED=1` covers during the run but *not* afterwards.

### 3. `bin/rails pol:model` — the current board

**Model run 19, 2026-08-12 04:54 UTC**, seed 1987458470819409855, 2.2s:

| | run 19 (current) |
|---|---|
| House D control | **93.31%** |
| House seat SD | **17.48** (range 174–336) |
| Senate D control | **40.43%** |
| Senate seat SD | **3.01** (range 39–62) |
| mean D seats (H / S) | 242.67 / 49.74 |
| generic ballot | D+6.68, 30 polls, W = 13.97 |
| t | 1.4611 |

Against run 17's 93.12% / 17.44 and 39.71% / 3.00 on the identical corpus:
the difference is one RNG seed, and it sits inside the 1.4pp run-to-run noise
floor from Phase 3 §8.2. The rake summary's mover panel says "nothing moved"
against run 18.

### Side effects

**0 dispatches** created across the whole refresh (total still 25, newest
2026-08-12 01:55 UTC, all pre-dating this work). 0 newsroom skips — nothing
even reached the kill switch this time, because nothing was queued. 0
unfinished GoodJob rows. Model runs created: 19 only.

**One thing for whoever turns the newsroom back on.** `Setting.agents_enabled?`
is still stored `true`; the whole of this phase's protection came from the
`AGENTS_DISABLED` environment variable, which is per-process. Nothing has been
changed about the stored setting — that is the editor's switch, not the
build's — but it does mean the newsroom is armed the moment a process starts
without the variable set. The standing recommendation from §F stands: gate the
cron registration in `config/initializers/good_job.rb` on something narrower
than "not test".
