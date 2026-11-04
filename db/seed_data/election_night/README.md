# Frozen historical raw votes for election night

These files contain **vote counts, not predictions**. They are inputs to our own
geographic comparison and turnout estimator. They do not replace the frozen
pre-election prior or establish current district boundaries.

The checked-in set contains:

| Data | Positive reporting units | Races/states |
| --- | ---: | ---: |
| 2024 presidential county results | 3,111 | 49 states |
| 2024 House county portions | 3,621 | 419 districts |
| 2022 House/Senate general-election county portions | 5,059 | 439 races (27 Senate) |

`HistoricalBaselines` verifies the manifest's SHA-256 hashes, dates, vote sums,
unique county/race identities, state FIPS, and source IDs before exposing any
rows. It also reads the separately maintained, checksum-pinned
`house_baselines/2026/presidential_2024.csv`: those 435 results are **contest
aggregates on current boundaries**, useful for broad turnout diagnostics only.
They never create county manifests.
The returned `current_lines_catalog` provenance includes that separate
catalog's manifest hash, raw-total hash, source revision and citation. The
combined historical `revision` changes when either manifest changes, so an
aggregate turnout diagnostic remains reproducible even when the county bundle
itself is unchanged.

## Provenance

The principal source is Paul Heideman's [U.S. county-level election results,
1990–2024, v1.0.0](https://doi.org/10.5281/zenodo.22976553), published September
26, 2026 under CC BY 4.0. The author compiles official state results, MIT
Election Data and Science Lab raw returns, and documented historical sources.
The [release](https://github.com/pmheideman/us-county-election-results/releases/tag/v1.0.0)
contains candidate-level rows and an extensive source catalog; we use its
candidate-level file, **not the county House summary**, which combines
different districts. `source_catalog.json` retains the original source records
for 2022 and 2024, including original publisher, locator, method and caveats.

Hawaii's four presidential reporting counties and three known incomplete
presidential counties (Jackson MO, Cumberland ME and Providence RI) use [Tony
McGovern's raw 2024 county compilation](https://github.com/tonmcg/US_County_Level_Election_Results_08-24).
That publisher identifies Fox News as its 2024 source. These replacements are
explicitly flagged and retain their own citation. We do not use its Alaska
House-district rows as if they were counties.

`manifest.json` records exact upstream URLs, retrieval date, publisher hashes,
normalization details and omissions. `validation.json` records the independent
aggregate comparison with the [Clerk's 2024 official election statistics](https://clerk.house.gov/member_info/electionInfo/2024/statistics2024.pdf)
and [2022 statistics](https://clerk.house.gov/member_info/electionInfo/2022/statistics2022.pdf).
These official candidate lists are used for validation, not to fabricate missing
county votes. Candidate lists are preferable to the Clerk's recapitulation
tables, which sometimes include blank and invalid ballots.

## Admission and geographic rules

County membership is checked independently of election totals. The frozen
`county_roster.json` retains the Census Bureau's [2020 county inventory](https://www2.census.gov/geo/docs/reference/codes2020/national_county2020.txt)
and [2024 Gazetteer county inventory](https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2024_Gazetteer/2024_Gaz_counties_national.zip).
The loader requires an exact state FIPS set match. A missing county, however
small its vote total, moves that state into `unverified_state_manifests` and
removes its complete state manifest. This check is separate from the aggregate
vote tolerance below.

The explicit exceptions are Connecticut's eight historical counties, retained
as that geography rather than the nine 2024 planning regions, and Hawaii's
Kalawao-to-Maui consolidation documented on page 37 of the [official 2024
election audit manual](https://elections.hawaii.gov/wp-content/uploads/2024-Elections-Audit.pdf).
The compilation's obsolete Oglala Lakota FIPS `46113` is corrected to the
Census code `46102` without reallocating any votes.

We require each party's county sum to agree with the Clerk's named-candidate
total within `max(100 votes, 0.5% of that party's votes)`. The tolerance permits
small differences between late and final raw returns; it is an assumption,
not proof that every county allocation is certified. Ten 2024 House races fail
this comparison and are omitted: CA-13, CA-23, ME-01, ME-02, MO-05, NY-17,
NY-25, OR-05, RI-01 and WA-04. Several contain substantial missing votes.
Alaska and Hawaii House races are absent from the compilation; FL-20, OK-03
and TX-04 have no usable district result in this source. The remaining 419
districts include unopposed or same-party contests; the observation builder
must still reject historically noncompetitive partisan baselines.

Fusion ballot lines follow the same named candidate's major-party line. A
different candidate on the Working Families or another minor-party line stays
in `other_votes`. We omit write-ins with no allocatable House district and
report their state totals in the manifest. Some House total-vote baselines
therefore omit a small number of unallocated write-ins. Democratic and
Republican vote counts are unaffected by these omissions, but the all-candidate
denominator can be slightly understated.

House rows are actual district portions of counties. A county appearing in
only one current return feed is never taken as proof that it is unsplit.
Zero-vote export cross-products (notably Ohio's all-districts/all-counties
matrix) are removed because they do not establish district membership. Live
county sets must match the historical set exactly, and direct House inference
still requires an independent unchanged-boundary check from the prior.

Alaska has no verified county-equivalent baseline in this set. Connecticut's
eight historical counties cannot be silently converted to nine planning
regions. Hawaii's four election reporting counties include Kalawao in another
reporting unit. Virginia's independent cities remain distinct from same-name
counties. Ranked-choice races remain outside direct Gaussian inference.

The 2022 rows are general-election votes only; Georgia's separate runoff is
excluded. 2022 House totals are **not automatically attached** to 2024 rows:
a further 2022-to-current boundary check is required. Senate county turnout can
be matched by a complete independently consistent county scaffold. Raw totals
and projected final margins include all candidates; two-party counts remain
separate for minimum-evidence gates and represented-geography weights.
`turnout_state_manifests` exposes the 25 complete 2022 Senate state inventories;
`unverified_turnout_state_manifests` identifies Idaho's missing Oneida County
and New York's missing Chemung County. Those two omissions fall within the
aggregate vote tolerance but fail the independent geographic completeness check.

## Rebuilding

Download the pinned release's `us_county_results_long.csv` and `SOURCES.csv`,
the McGovern 2024 CSV and both Clerk PDFs to a chosen prefix, for example:

```text
/tmp/pol-history-us_county_results_long.csv
/tmp/pol-history-SOURCES.csv
/tmp/pol-history-tonmcg.csv
/tmp/pol-history-clerk2024.pdf
/tmp/pol-history-clerk2022.pdf
/tmp/pol-history-census-counties2020.txt
/tmp/pol-history-census-counties2024.zip
/tmp/pol-history-census-counties2024.txt
/tmp/pol-history-hawaii-audit.pdf
```

The exact URLs and SHA-256 values are in `manifest.json`. Verify these hashes
before rebuilding, especially the mutable McGovern URL. Extract each Clerk PDF
with `pdftotext -layout` into `clerk2024.txt`/`clerk2022.txt` using the same
prefix. Extract the Gazetteer ZIP's `2024_Gaz_counties_national.txt` to the
listed `census-counties2024.txt` path, then run:

```sh
python3 script/build_election_night_history.py --input-prefix /tmp/pol-history-
```

The builder checks the pinned long-file release hash, performs candidate fusion
normalization and official aggregate comparisons, writes sorted normalized
CSVs, and produces the checksummed manifest. Review changes to the validation
report and source catalog whenever replacing this frozen release. No download
or regeneration occurs during a live election-night collection.
