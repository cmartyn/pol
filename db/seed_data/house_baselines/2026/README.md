# 2026 House baselines

Retrieved and verified October 25, 2026. The manifest pins the public source URLs,
worksheet ranges, adoption dates, operative plans and SHA-256 checksums.

Numerical source: Jeff Singer, Daniel Donner and David Nir, **The Downballot's
2020 & 2024 presidential election results for congressional districts used in
the 2026 elections** (The Downballot, 2026). See
[The Downballot's data hub](https://the-db.co/presbycd).
The two CSVs retain the publisher's rounded 2024 Harris, Trump and total votes,
on the new and old congressional lines respectively. At-large seats use `1`.
Margins are `100 * (Harris - Trump) / total`, not two-party-normalized margins.
Totals are the publisher's reported totals, including other votes; we do not
reconstruct or alter their write-in/third-party conventions. The source's
precinct allocations are estimates, not official congressional presidential
returns. We use 2024 consistently; many new-line rows lack 2020 data.

Boundary authority: [Census 120th Congress documentation](https://www.census.gov/programs-surveys/decennial-census/about/rdo/congressional-districts.html),
including the October 7, 2026 Missouri correction. `boundary_audit.csv` compares
whole-block memberships from the 119th and 120th block equivalency ZIPs. The
audit covers all 435 districts, uses state files in preference to national rows,
and records block counts and order-independent SHA-256 fingerprints. The only
split block noted by Census is in Colorado and is unchanged across the plans.
Reproduce it with `script/audit_house_boundaries.py` and the manifest's ZIPs.

| State | Districts with changed block assignments |
| --- | ---: |
| AL | 4 |
| CA | 48 |
| FL | 23 |
| LA | 6 |
| NC | 2 |
| OH | 13 |
| TN | 8 |
| TX | 37 |
| UT | 4 |
| Total | 145 |

Do not identify redistricting by changes in vote totals. CA-34, CA-36, CA-43
and OH-03 have small numerical revisions but unchanged block assignments.
CA-11, CA-15, FL-03 and FL-06 have changed block assignments but identical
reported votes. The boundary audit decides which method to use. This includes
small boundary changes even where their electoral effect is negligible.
Missouri retains the 2024 baseline and 119th geometry: Census warns that its
120th geometry has not yet been corrected, although the block files have.

`Forecast::HouseBaselines` validates the entire catalog before use. The release
is deployed as one artifact, so a partial database import is impossible and
historical reseeding cannot overwrite corrections. Changed districts use the
presidential margin minus the national presidential margin plus the current
generic ballot. Unchanged districts retain the House-result method. Every run
saves its revision and typed baseline values; missing inputs fail the run.

Poll eligibility accepts explicit, sourced `raw_payload.district_plan` evidence
(`id` and `source_url`), or the NYT feed's assignment to the same cycle, state,
district and general election when the entire field period is after adoption.
The latter is an aggregator assignment, not independent voter-file verification.
An explicit different plan always overrides the feed. Earlier, straddling,
manual and unresolved samples require explicit evidence. This policy is shared
by averaging, house effects, internals calibration and scatter charts. Polls
remain in the public table with an exclusion reason.
Editors can record or clear sourced plan evidence in the existing admin poll
form. Editing that evidence preserves the original feed payload. Selecting a
plan without a verification source excludes the sample until the source is added.

Updates require a new reviewed source snapshot and manifest revision. Never
edit a stored race's historical House margin to simulate a presidential input.
`bin/rails pol:audit_baselines` validates and prints all district decisions;
`bin/rails pol:compare_baselines` performs read-only paired simulations and
prints a JSON report without model runs, forecasts, dispatches or queued jobs.
