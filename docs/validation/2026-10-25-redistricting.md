# Redistricting correction: implementation and validation

October 25, 2026. **Deployed and verified in production.** Corrected run 1158
published at 20:44:46 Eastern, with all 435 House districts in both variants.
The complete map refresh also succeeded, including Missouri's restored lines.

## Coverage and sources

The Census 119th/120th congressional block equivalency files identify **145
changed districts**: AL 4, CA 48, FL 23, LA 6, NC 2, OH 13, TN 8, TX 37 and UT 4.
The other 290 districts retain their existing House-result method. The audit
compares territory across all 435 districts; it does not infer redistricting
from district numbers or differences in vote totals.

- [Census congressional redistricting documentation](https://www.census.gov/programs-surveys/decennial-census/about/rdo/congressional-districts.html), including the October 7 Missouri correction, establishes the operative assignments. Missouri keeps its old baseline and 119th map geometry because Census's 120th geometry still depicts the rejected plan.
- [The Downballot](https://the-db.co/presbycd), by Jeff Singer, Daniel Donner and David Nir, supplies 2024 presidential votes on the 2026 lines. The source is an allocation of precinct votes, not official congressional presidential returns. Margins use all reported votes, including other candidates, rather than two-party normalization.
- The [manifest](../../db/seed_data/house_baselines/2026/manifest.yml) records official plan sources, adoption dates, worksheet ranges, checksums and verification date. The [source notes](../../db/seed_data/house_baselines/2026/README.md) describe conventions and edge cases. Small source tables and the 435-row boundary audit are committed; the large Census ZIPs are not.

CA-34, CA-36, CA-43 and OH-03 have small vote-data revisions but unchanged
territory. CA-11, CA-15, FL-03 and FL-06 have changed block assignments but
identical reported presidential totals. The block audit correctly distinguishes
these cases. Re-running `script/audit_house_boundaries.py` against the pinned
Census ZIPs reproduced the committed audit byte for byte.

## What changed

`Forecast::HouseBaselines` resolves a typed baseline from an immutable catalog.
All source files must pass checksums, unique-seat coverage, per-state counts and
vote-total checks. The changed-seat manifest must agree with the boundary audit.
Production forecasting requires all 435 House seats and fails visibly on missing
historical inputs. A legacy reseed can update historical race data but cannot
overwrite a corrected presidential baseline.

For unchanged districts, the prior remains:

```text
2024 House margin - 2024 national House margin
  + current national environment + existing open-seat adjustment
```

For changed districts, it becomes:

```text
100 × (Harris votes - Trump votes) / all votes
  - 2024 national presidential margin + current national environment
```

The national presidential reference remains the existing D−R parameter, −1.5.
The presidential input contains no former House incumbent's performance, so it
does not receive the old open-seat subtraction. Poll blending and uncertainty
parameters are unchanged.

Both forecast variants use the same saved baseline snapshot. Each run records
the method, plan, source, vote totals, national reference, as-of date and revision.
The catalog ships as one artifact, replacing the proposed database fields and
importer without requiring a schema migration.

A shared poll eligibility check applies to averaging, pollster effects,
internal-poll calibration and scatter charts. It accepts sourced explicit plan
evidence, or NYT's assignment to the same cycle/state/district/general election
when the entire field period follows map adoption. **The NYT rule is an
aggregator assignment, not an independent voter-file audit.** Earlier,
straddling and unresolved samples require explicit evidence. An explicit
different plan overrides the feed. Admin editors can record that evidence;
excluded polls remain visible with a reason.

Race pages, the House table and methodology identify the input and its source.
Historical chart changes are labeled for affected districts. Movement stories
cannot compare different baseline revisions, and queued stories or emails based
on an old revision are rejected after a corrected run succeeds. Older affected
dispatches retain their original text and receive a correction note after that
point. This implementation does not send a correction email.

## Paired simulation results

The comparison used a separate local database populated from public historical
election data and the [NYT House](https://www.nytimes.com/newsgraphics/polls/house.csv)
and [Senate](https://www.nytimes.com/newsgraphics/polls/senate.csv) feeds retrieved
October 25. It contains 435 House races, 35 Senate races, 1,243 House-feed
questions (including generic ballot) and 810 Senate-feed questions.

**These are validation results, not the current production forecast.** No live
candidate flags, manual polls or pollster exclusions were exported. The fresh
public seed also lacks production candidate/retirement/uncontested adjustments.
The numbers below cannot be substituted for a production House-control result.

`Forecast::BaselineComparison` uses a read-only, repeatable-read transaction and
does not invoke the publishing runner. Both calculations use one input snapshot,
the same race order, October 25 as-of date, seed `20261025`, and **100,000
simulations per calculation**. Both use the new poll eligibility policy so the
paired difference isolates baseline replacement. The only excluded public
House question was a CA-48 sample from October 26, 2025, outside the current
averaging window. No current-window feed questions failed the source-assignment
rule.

| Public validation result | Old baseline | Corrected baseline |
| --- | ---: | ---: |
| TN-9 mean margin, excluding internals | D+56.84 | R+11.01 |
| TN-9 Republican win probability, excluding internals | 0% | 92.499% |
| TN-9 mean margin, including adjusted internals | D+56.10 | R+11.04 |
| TN-9 Republican win probability, including adjusted internals | 0% | 92.538% |
| House mean Democratic seats, excluding internals | 246.272 | 243.449 |
| House Democratic control, excluding internals | 99.436% | 97.128% |
| House mean Democratic seats, including adjusted internals | 246.326 | 243.565 |
| House Democratic control, including adjusted internals | 99.366% | 96.970% |

TN-9's source row contains 124,805 Harris votes, 192,867 Trump votes and 321,897
total votes. Its presidential margin is R+21.144; its national-relative lean is
R+19.644. With the validation corpus's default national environment of D+8.637,
the prior is R+11.007. Its default variant has no eligible district-poll weight.
The corrected 90% simulated margin interval is R+23.69 to D+1.66.

All 145 changed House means changed. **All 290 unchanged House districts and
all 35 Senate races retained exactly identical means, probabilities and
intervals** in each paired simulation. The validation database had zero model
runs, forecasts and dispatches before and after the comparison.

Artifacts:

- [Every House race, both variants](2026-10-25-redistricting-comparison.csv): 870 rows with old/new inputs, means, probabilities and intervals.
- [Comparison summary](2026-10-25-redistricting-summary.json): source checksums, frozen-input digest, baseline revision, TN-9 and chamber results.
- The full public input snapshot is retained locally in ignored `tmp/redistricting_sources/public_comparison.json`; production snapshots should not be committed.

## Production-input verification

After explicit authorization, a read-only, repeatable-read transaction exported
the forecast inputs from production revision
`2bc3267dd941d89408760c8dae2b6ef531fd9109` at 20:32:57 Eastern on October 25.
The snapshot contains 470 races, 922 candidates, 258 pollsters, 3,168 polls and
6,726 poll results. It includes the live candidate flags, manual records and
pollster exclusions missing from the public-data exercise. Production model
parameters exactly match the local configuration.

The raw export and full comparison are private, git-ignored local files. Only
the [aggregate production summary](2026-10-25-production-summary.json), source
digest and forecast outputs are versioned. The verification database is separate
from development, tests and production. The paired comparison creates no model
runs, forecasts, dispatches or delivery jobs.

Both variants were compared at 100,000 simulations using October 25 and seed
`20261025`. All 145 affected means changed; all 290 unchanged House districts
and 35 Senate races remained identical in the paired calculation. Twelve old
polls fail the new geography rule, but none is in the 120-day extended window.
Running the original production code's estimators against the same snapshot
also produced identical pollster effects and internal-poll calibration, so those
older exclusions introduce no additional change through shared bias estimates.

| Production-input result | Old baseline | Corrected baseline |
| --- | ---: | ---: |
| TN-9 mean margin, excluding internals | D+56.86 | R+10.99 |
| TN-9 Republican win probability, excluding internals | 0% | 92.463% |
| TN-9 mean margin, including adjusted internals | D+56.12 | R+11.02 |
| TN-9 Republican win probability, including adjusted internals | 0% | 92.511% |
| House mean Democratic seats, excluding internals | 246.350 | 243.532 |
| House Democratic control, excluding internals | 99.450% | 97.159% |
| House mean Democratic seats, including adjusted internals | 246.382 | 243.630 |
| House Democratic control, including adjusted internals | 99.372% | 97.000% |

These production-snapshot calculations supersede the public-data exercise for
release verification. A published run can differ if its date, inputs or seed
change before activation.

## Historical uncertainty diagnostic

The Downballot's old-lines workbook provides 2020 presidential returns
reaggregated onto the boundaries used for the 2024 House election. Across 398
districts with both major parties in the 2024 House results, the diagnostic
predicts the House margin using the 2020 presidential lean plus the realized
2024 national House environment. It excludes 37 uncontested or same-party races.

| Diagnostic | Value |
| --- | ---: |
| Mean error, actual minus predicted | +1.51 points |
| Mean absolute error | 4.34 points |
| Root mean squared error | 5.61 points |
| Residual standard deviation | 5.40 points |
| Coverage of current nominal 90% interval | 94.72% |
| Coverage of current nominal 50% interval | 65.58% |

The current marginal error scale is approximately 7.28 points before the
remaining-time multiplier. This limited check does not support reducing
uncertainty; district sigma stays at 6 points and all other scales stay unchanged.
The [district residuals](2026-10-25-presidential-proxy.csv) allow the metrics to be
recomputed.

This is a conditional proxy diagnostic, **not a prospective forecast backtest**:
it uses the realized national environment, a four-year presidential-to-House
comparison rather than a two-year midterm, and does not test candidate selection,
poll blending or full chamber calibration. It is not a claim of 2026 accuracy.

## Verification and activation

Verification used isolated databases; no test used production data.

- Rails: **1,334 tests, 5,349 assertions, zero failures/errors**, including the
  follow-up Census vintage-selection regression checks.
- Ruby style: 376 files, zero offenses. Full Brakeman: zero errors/warnings.
  Bundler and importmap vulnerability audits passed.
- `db:seed:replant` passed in the isolated test database.
- Census audit reproduction matched the committed CSV byte for byte.
- Focused browser coverage: **8 tests, 66 assertions, zero failures/errors**,
  including the forecasting/newsroom pipeline, chart interactions and the new
  mobile redistricting case.
- Full browser suite: 16 tests, 141 assertions, two failures. The keyboard
  matchup-filter failure also occurs on unchanged HEAD (full baseline suite:
  15 tests, 136 assertions, one failure). A Senate map-hover failure in the
  corrected full run passed in the focused rerun; it remains an intermittent
  browser-suite limitation. The full browser suite is therefore not green.
- `git diff --check` passed. No migration or new runtime dependency is required.

Useful commands (run in the intended environment):

```sh
bin/rails pol:audit_baselines
AS_OF=2026-10-25 SEED=20261025 N_SIMS=100000 bin/rails pol:compare_baselines > comparison.json
python3 script/audit_house_boundaries.py cd119.zip cd120.zip > boundary_audit.csv
```

Release record:

1. [PR 48](https://github.com/cmartyn/pol/pull/48) merged the main correction.
   Image `c0b77dbae9092a72ad68257bb009c4263566d96c` deployed through Kamal's
   health-checked rollout. Production run **1158** used the verified baseline
   revision and seed, publishing 940 race forecasts and four chamber forecasts
   atomically. Calling the runner directly did not enqueue correction emails.
2. All 940 published probabilities exactly match the production-snapshot
   comparison. Percentiles agree within `7.2e-15` points, consistent with
   floating-point rounding across platforms. TN-9's published simulated mean
   is **R+11.0349**, with **92.463% Republican win probability** in the default
   variant; the adjusted-internals variant is R+11.0684 and 92.511% Republican.
3. The first map refresh found two identically named historical Census layers
   and refused the ambiguous selection before writing anything. [PR 49](https://github.com/cmartyn/pol/pull/49)
   adds explicit vintage selection, with a duplicate-layer regression fixture.
   The final deployed image is `dae74e58bb83c6fe65b5c8eac271b7214f015fd9`.
   Refreshing all boundaries then succeeded: **435 districts, 51 state/DC
   outlines, 124,506 points**. All eight Missouri districts use the ACS 2025
   group's 119th congressional geometry; other districts use the 120th layer.
4. Application caches were cleared. The Cloudflare connector lacks the
   `cache.purge` scope, so a manual edge purge was unavailable. Canonical race
   URLs in all nine affected states returned HTTP 200 with the corrected
   baseline and run timestamp after normal edge revalidation. TN-9's two
   variants, the complete House table/control totals, dated timeline correction
   and historical TN-9 dispatch correction were also verified in the browser.
5. Hosted GitHub Actions never started because the account is locked by a
   billing issue. This is recorded as an infrastructure limitation, not a
   successful CI run. Deployment used the locally verified release and normal
   merge path, without overriding branch protections. The local browser-suite
   limitations above remain separate from the hosted billing issue.

The initial export was blocked by automatic approval review because it could
include private polling records. The user subsequently authorized the production
export and deployment explicitly. The export and comparison above completed
under that authorization without exposing raw records in Git or tool output.
