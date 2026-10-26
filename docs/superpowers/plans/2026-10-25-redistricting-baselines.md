# Correct House forecasts after redistricting

**Status:** Deployed and verified in production; corrected run 1158
**Date:** October 25, 2026
**Decision owner:** Chase
**Scope:** Correct the 2026 House forecast, prevent recurrence, and explain the correction to readers. Production deployment was subsequently authorized and completed; see the release report below.

Implementation results and the remaining release steps are recorded in
[`docs/validation/2026-10-25-redistricting.md`](../../validation/2026-10-25-redistricting.md).
The implementation uses a validated immutable catalog rather than new database
fields and an importer: the whole source revision ships atomically, typed inputs
are snapshotted on each run, and historical reseeding cannot overwrite them.
The Census block audit, rather than vote-total differences, identifies 145 seats.
Poll eligibility accepts explicit plan evidence or the NYT's current-election
assignment after map adoption; the latter is documented as a source assignment,
not an independent voter-file audit. The checklist below preserves the original
proposed sequence, not a claim that production release steps have been executed.

## Recommended decision

Make the district plan an explicit forecast input. For districts whose electorate changed, replace the old House-result prior with 2024 presidential performance calculated on the operative 2026 boundaries and normalized against the national presidential result. Preserve the existing House-result method for districts verified as unchanged. Require a traceable, verified baseline for every seat before publishing House control.

**User decision:** Skip temporary withholding, warning modes, and an intermediate containment release. Prioritize getting corrected predictions working as soon as possible. Keep the current site operating while preparing and validating the correction, then publish the corrected forecasts together. Source verification, correct model arithmetic, and a controlled before/after comparison remain part of the fix.

Use the smallest durable implementation: typed baseline metadata on existing race records, a versioned source manifest, an atomic importer, and baseline snapshots on model runs. A separate release-management schema or general draft/publication workflow is not a prerequisite; the comparison can compute without writing public forecast records.

## What we verified

- `Ingest::SeedRaces#seed_house` assigns 2024 results to 2026 races by district number. Reseeding overwrites the baseline, including a manually corrected number.
- `Forecast::RaceModel#house_prior` uses that baseline plus national House swing and an open-seat adjustment. It has no district-plan check, and a missing baseline falls back to zero.
- `Ingest::BoundarySync` updates a separate geometry table. Matching district counts do not establish that forecast inputs represent the same electorate.
- `Forecast.latest_for_races` and public controllers select the latest successful run. A successful comparison run would currently become public.
- Newsroom jobs can turn a large correction into a movement story. Existing pollster-exclusion safeguards provide a useful pattern for distinguishing input changes from electoral movement.
- Model runs save parameters and the random seed, but do not freeze the complete baseline and poll inputs needed for a reproducible before/after comparison.

## Data sources and remaining verification

Use [The Downballot's current data hub](https://www.the-downballot.com/p/the-downballots-calculations-of-presidential) as the proposed numerical source. Its linked [Vote totals worksheet](https://docs.google.com/spreadsheets/d/1eZfaFI-c-PFOoKx1-zZA2MP0_dxRq_LVK0re3BOQqy0/edit?gid=1491069057) was inspected through the Google Sheets connector on October 25:

- 435 unique districts across 50 states, with complete 2024 Democratic, Republican, and total vote fields.
- TN-09: Harris 124,805; Trump 192,867; total 321,897. The all-vote D-minus-R margin is -21.1440 percentage points.
- 173 rows lack 2020 results. Do not silently average one year for some districts and two for others.
- The worksheet includes incumbents; those fields are not the source for 2026 nominees.

This verifies availability and basic completeness, not the legal validity of every plan or the accuracy of every row. During implementation, archive the source revision, verify the operative plans against official state election/legislative sources, and cross-check changed districts against [Redistricting Data Hub's change reports](https://redistrictingdatahub.org/reports/district-change-analysis/), including its [Tennessee report](https://redistrictingdatahub.org/dataset/tennessee-120th-congressional-district-change-report/). RDH reports use two-party shares; normalize denominators before comparing them with the Downballot's all-vote margins. Resolve disagreements rather than averaging sources.

The initial audit queue is AL, CA, FL, LA, NC, OH, TN, TX, and UT, based on the [October AP overview](https://apnews.com/article/c26a343527d6d3da51abffec2da94088). Check all 50 state plans and all 435 races. Missouri illustrates why an enacted map is insufficient: later court decisions can restore earlier lines. The approved plan manifest, not a hard-coded state list or a July data release, must determine eligibility.

Keep attribution, original files, retrieval time, worksheet/tab identifiers, checksums, and the publisher's denominator/write-in conventions. Store source snapshots outside git if large; small derived tabular manifests and test fixtures can be versioned. Do not commit real district geometry.

## Model specification

Use percentage points throughout, positive for Democrats. Preserve the application's current all-vote D-minus-R convention; its parser subtracts reported party percentages rather than renormalizing to two parties.

For a verified unchanged district:

```text
prior = 2024 House margin - 2024 national House margin
        + current national environment + existing open-seat adjustment
```

For a changed district:

```text
district_pres_margin = 100 * (Harris votes - Trump votes) / total votes
district_lean = district_pres_margin - 2024 national presidential margin
prior = district_lean + current national environment
```

The current national presidential parameter is -1.5 points. With the inspected TN-9 row, its relative lean would be approximately -19.64 points. Adding the live national environment produces a prior, not a win probability or a final forecast. The existing poll blend and correlated simulation still follow.

Do not put -21.14 into `baseline_margin` and keep subtracting the national House margin. Store the method and its national reference explicitly. A presidential prior contains no retiring incumbent's House performance, so the old open-seat subtraction must not carry over. Use no candidate adjustment for this new method in the first release; any later incumbency adjustment needs evidence appropriate to redrawn districts.

Keep poll weights and sponsor treatment unchanged. Check the uncertainty of the presidential proxy against historical elections on matching boundaries. If the existing district error understates observed errors, introduce a documented method-specific uncertainty term before release. Do not tighten uncertainty as part of this repair or tune it to produce a desired TN-9 rating.

## Options considered

| Option | Assessment |
| --- | --- |
| Manually overwrite TN-9 | Small change, but misses other affected seats, loses provenance, and can be undone by reseeding. Reject. |
| Reaggregate past House votes onto new districts | Geographic relevance improves, but votes came from different candidate contests and sometimes uncontested elections. Not the preferred initial baseline. |
| Add the presidential old-to-new delta to each old House margin | Retains the old district's candidate-specific performance despite major changes in electorate. Avoid for the initial correction. |
| Presidential prior for verified changed districts | Complete proposed 2024 source, explicit statistical interpretation, limited changes elsewhere. Recommended, with validation and source-specific uncertainty review. |
| Presidential priors for all 435 districts | Consistent framework and potential improvement for imputed baselines, but changes many unaffected races. Evaluate separately after this correction. |

## Implementation sequence

### 1. Assemble the corrected inputs

- [ ] Produce an audit table for every House race: operative plan, whether territory changed, existing baseline/method, source, verification state, poll-plan status, and blockers.
- [ ] Track unresolved inputs in the audit report while verifying them. Use official assignment data or a documented plan crosswalk to identify unchanged territory; district numbers and simplified geometry hashes are insufficient.
- [ ] Start with Tennessee to prove the import and formula end to end, then apply the same process to every affected state before the corrected House release.
- [ ] Keep this work internal: no temporary forecast hiding, pause notices, warning modes, or interim changes to public charts and newsroom availability.

### 2. Import sourced, versioned baselines

- [ ] Create a versioned manifest of district plans: state, election cycle, stable plan identifier, official source, legal/effective status, and verification timestamp. Associate displayed boundaries and race inputs with these identifiers using the existing records.
- [ ] Add the baseline fields needed on existing race records: plan identifier, election year, method (`house_result`, `imputed_house_result`, or `presidential_lean`), forecast input, national reference, source reference/checksum, and verification metadata. Preserve raw vote inputs in the archived source and versioned import manifest.
- [ ] Give the manifest an immutable revision identifier and content digest, selecting exactly one baseline for each of 435 seats. Retain existing `baseline_margin` as historical data during migration, not as a silent model fallback. Separate baseline-release tables and an admin approval workflow can follow if operations require them.
- [ ] Implement a dry-run importer that produces validation errors and a per-race diff before applying anything. Enforce unique seats, correct per-state counts, numeric/nonnegative vote fields, valid totals and margins, plan matches, complete coverage, and declared units. Normalize `AK-AL` and other at-large labels to the app's district convention.
- [ ] Preserve unchanged historical/imputed baselines only after their territory is verified. Use the presidential method for changed districts. Missing data or an unresolved plan is an explicit blocker.
- [ ] Verify the manifest and run the comparison before applying it. Import the complete correction transactionally; source refreshes produce new versioned manifests and must pass the same checks.
- [ ] Restrict legacy seeding to historical data and board creation. Corrections require a sourced manifest revision rather than silently replacing a live number. Re-running seeds must preserve approved forecast inputs.

### 3. Make forecasts and polls use the correct electorate

- [ ] Resolve House priors through a dedicated baseline resolver and the typed formulas above. Missing/mismatched inputs must never fall back to zero or to the old electorate.
- [ ] Associate House poll eligibility with a district plan and verification evidence. Check poll documentation, especially polls near map changes or litigation. Dates alone do not prove which electorate was sampled.
- [ ] Keep old-plan and unresolved-plan polls visible with a reason, but exclude them from current averages, blending, pollster-effect estimation, and internal-poll calibration. Apply the same eligibility policy in both variants and in public charts.
- [ ] Capture immutable run inputs: baseline release, per-race baseline values/plan/method, model version, candidates and flags, as-of date, poll measurements and eligibility decisions, parameters, and seed. A poll ID alone is insufficient if its result can later be edited.
- [ ] Recheck current plan/release eligibility before publication. An input change during computation cannot result in a public run for a superseded electorate.

### 4. Compare corrected predictions before applying them

- [ ] Extract or reuse the calculation path in a command that does not persist model-run/forecast rows or enqueue newsroom jobs. Do not use the ordinary successful-run path for an experiment, because it would publish the result.
- [ ] Run original and corrected baselines against one frozen set of polls, candidates, parameters, as-of date, and seed. Save the comparison report locally without changing active inputs, the live forecast, stories, or email queues.
- [ ] Keep the full race order stable in paired simulations. Do not remove seats and then interpret changed random draws as model effects.
- [ ] Report each affected race's old/new input, prior, blended mean, interval and probability; provide state summaries and the aggregate seat/control delta. Include both internal-poll variants and explicit coverage failures.
- [ ] Require complete eligible House coverage before applying and publishing the correction. A failed comparison or incomplete import leaves production unchanged; never produce the aggregate by dropping unresolved seats or counting them as certain wins.

### 5. Validate the statistical change and the release behavior

- [ ] Golden input checks for TN-9 and several changed districts in both partisan directions, plus unchanged and at-large districts. Recompute source margins from vote totals; compare independent sources on the same denominator.
- [ ] Formula tests prove presidential priors use the presidential national reference and do not inherit the old open-seat adjustment. A TN-9 fixture verifies the sourced prior calculation; it must not assert a politically desired winner.
- [ ] Prove reseeding cannot revert approved baselines; partial/duplicate/mismatched imports are atomic failures; old-plan polls cannot enter any estimation path.
- [ ] Prove the comparison command changes no active data and creates no public forecast or newsroom/email work. Test failed and partial imports, and verify that both variants use the same complete input revision.
- [ ] With the same frozen inputs/seed, unchanged districts retain their means and Senate outputs remain unchanged by baseline replacement. Audit any changes caused by the separate poll-eligibility correction instead of attributing them to redistricting arithmetic.
- [ ] Run an out-of-sample historical check using presidential data and congressional outcomes on matching district lines, with only information available before the target election. Evaluate margin error and interval coverage against the current method; show sensitivity to the new method's uncertainty.
- [ ] Run focused Minitest suites during implementation; finish with repository CI, including browser tests, on an isolated test database. Fixtures must not fetch the network or rely on production data.

### 6. Publish the correction with an audit trail

- [ ] Apply the verified manifest under the model-run concurrency guard, then run and publish the complete corrected forecast through the existing transactional path. If a run already in flight captured older inputs, ensure it cannot subsequently replace the corrected run. Invalidate application caches and purge affected edge pages; inspect TN-9, representative other districts, the House aggregate, maps, mobile views, and both variants.
- [ ] Explain the active baseline's year, election type, district plan, and source on race pages. Replace the ambiguous House-table label “2024 baseline” with labels that distinguish historical results from current forecast inputs.
- [ ] Add a dated correction to the TN-9 dispatch and audit other published claims affected by the same inputs. Preserve original publication history. Draft public correction text separately; do not send a subscriber email as a side effect of this data migration.
- [ ] Label the change in timelines as a model/data correction. Introduce a comparison fingerprint covering baseline release, model method, and poll-eligibility policy; movers and newsroom comparisons must not cross incompatible fingerprints.
- [ ] At corrected publication, reject queued forecast stories based on superseded baseline revisions, and recheck the revision immediately before publishing or sending them. This prevents stale stories after the correction without an interim newsroom shutdown.
- [ ] Update methodology, README, and build notes with source attribution, formulas, remaining imputation limits, and the measured House-control change.
- [ ] Add checks to existing ingest/model jobs for plan mismatches, incomplete releases, and stale provenance. Fail publication visibly and record actionable reasons. Source updates require verification before activation.
- [ ] After release, preserve the latest successfully corrected forecasts if a later run fails. Rollback must retain compatible corrected inputs; restoring the known-invalid 2024 baselines is not a valid data rollback.

## Main code touchpoints

| Area | Existing files and proposed additions |
| --- | --- |
| Inputs and schema | `Race`, `Boundary`, `Poll`; minimal typed metadata, a versioned plan/baseline manifest, and source snapshots |
| Imports | `app/lib/ingest/seed_races.rb`, `boundary_sync.rb`; new baseline importer; `lib/tasks/pol.rake` |
| Model | `app/lib/forecast/race_model.rb`, `averager.rb`, `house_effects.rb`, `internals.rb`, `runner.rb`; shared baseline/eligibility resolver |
| Comparison and runs | `app/models/model_run.rb`, `app/jobs/forecast/run_job.rb`, and runner calculation extraction; input fingerprints and a comparison command that does not persist public records |
| Public views | Home/race controllers, House table, map forecast lookup, timeline/movers, methodology, cache keys |
| Newsroom | `app/lib/newsroom.rb`, context/movement/writer checks, daily brief and reaction jobs, dispatch display and delivery eligibility |
| Verification | Existing corresponding model, ingest, integration, cache and system test suites; new source fixtures and comparison report |

## Delivery boundaries and completion criteria

The first deliverable is an implementation that calculates corrected predictions for every affected district, with sourced inputs and regression tests. Follow with the frozen-input comparison and source/uncertainty checks, then publish the complete corrected House forecast and its explanation. Include reseeding protection and correction-aware newsroom comparisons in that release. Do not schedule a separate containment deployment or make a general publication-system redesign a dependency. No new services or a live GIS calculation pipeline are required for the initial fix.

Completion means every House seat has an approved baseline compatible with its operative plan; both forecast variants consume that revision; no known old-plan poll contaminates the current model; comparison runs do not publish; subsequent seeding/runs preserve the correction; and the before/after report and published explanation identify the correction's actual effects. A change in TN-9's displayed winner alone does not satisfy these criteria.

The implementation and production release report supersede this proposal's original verification queue. The authorized live-input comparison, deployment, complete corrected run, Missouri boundary refresh and live-page checks are complete. The report records the unavailable manual edge purge and GitHub billing lock, alongside successful local validation and live cache revalidation. The historical proxy diagnostic documents its limits; it is not a full prospective calibration backtest.
