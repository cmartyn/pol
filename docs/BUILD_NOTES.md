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
   party-only matching, which is the best available.
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
7. **Pollster names.** Standalone partisan tags are stripped before
   canonicalisation, so `Tulchin Research (D)` and `Tulchin Research` are the
   same pollster. The unmodified cell text is preserved in `raw_payload`.
8. **Provenance.** `source_url` is the article URL plus the enclosing section's
   anchor (`...#Polling_3`). Those anchors were checked against the *rendered*
   page, not just Parsoid — `id="Polling_3"` exists on both, so the links land
   on the right table. `raw_payload` keeps every cell of the row, keyed by
   column label.
9. **House baselines.** `2024 United States House of Representatives elections`
   carries one table per state with a Candidates cell like
   `▌Y Barry Moore (Republican) 78.5% ▌Tom Holmes (Democratic) 21.5%`.
   Percentages are summed *by party*, which is what makes Louisiana's jungle
   primary (three Republicans on one line) come out right. Where a cell spells
   out ranked-choice rounds, only the deciding round is counted — summing
   Alaska's first round *and* its instant runoff put that district's two-party
   total at 195.8%.
10. **Structural rows.** Blank separator rows and the "Primary elections are
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
| `house_results_2024.html` | Alabama (rowspan + safe seats), Alaska (ranked choice), Louisiana (jungle primary), Washington (top-two, incl. a race with no Republican) |
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
| Imputed baselines | **45 (10%)** — comfortably under the 15% ceiling |
| Candidates seeded | 66 |
| Warnings | none |

The 45 imputed districts: AL-3, AL-4, AL-5, CA-12, CA-16, CA-20, CA-34, CA-37,
FL-20, IL-15, IL-16, KY-4, KY-5, LA-4, MA-1, MA-2, MA-3, MA-4, MA-5, MA-6,
MA-7, MN-1, MN-2, MN-3, MN-4, MN-5, MN-6, MN-7, MN-8, MS-3, NV-2, NC-3, NC-6,
OK-3, PA-3, TX-1, TX-9, TX-11, TX-13, TX-19, TX-20, TX-25, TX-30, WA-4, WA-9.
Every one is a district where a major party did not field a candidate in 2024 —
safe seats, plus the California and Washington top-two races that ended with two
candidates of the same party.

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
