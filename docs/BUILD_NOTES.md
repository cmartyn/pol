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

## B–F

Filled in as the ingestion code lands (fetcher, seeds, parsers, fixtures, live run).
