# Build notes

Every real-world fact this project bakes into code or config is verified against a
source at build time and recorded here with its URL. Organised by phase.

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

11. **Race order is part of the seed.** Draws come off one Box–Muller stream, so
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

98 new tests (the suite goes 191 → 289), all off fixtures and hand arithmetic;
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
