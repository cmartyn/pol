# Independent live inference model

`ElectionNight::Nowcast` implements an experimental joint Gaussian update. It consumes our frozen pre-election prior and estimates of final race margins derived from reported votes. It does not consume another forecaster's probabilities or race calls.

## Measurement contract

Each observation contains `race_key`, `observed_margin`, `sigma`, `counted_fraction` and `source_ids`. `observed_margin` is an estimate of **final (side A minus side B) / all candidate votes, in percentage points**, after accounting for which geographic units have reported. This matches the frozen prior's margin convention. It is not the raw reported margin. Its `sigma` expresses the remaining-vote, geography, turnout and measurement uncertainty. The upstream observation builder must construct that estimate; this engine does not infer ballot completion from votes or precinct counts.

Only one aggregate measurement per race is accepted in a run. Repeated updates replace that measurement; they must never be appended as independent observations. Duplicate race measurements, unknown race keys, zero coverage, negative uncertainty and nonfinite numbers are rejected. Races without adequate direct evidence get no observation.

The counted fraction is diagnostic, not a second confidence weight. This avoids applying reporting completeness twice after the upstream measurement uncertainty has already incorporated it. The default measurement standard deviation is inflated by 1.5 and floored at 2 percentage points. These conservative assumptions are visible in diagnostics and configurable in the frozen prior, with inflation at least 1 and floor at least 1. They are not empirically calibrated constants.

## Raw sources and historical geography

CivicAPI is the primary collection path, using a pinned catalog of 435 House and 35 Senate full-race endpoints. It remains a secondary publisher of raw returns; priority does not turn it into an election authority. The collector gives it priority 0, at most two concurrent requests, and a minimum 180-second interval per endpoint. Official feeds provide priority-10 fallback and independent cross-check material at minimum 600-second intervals. Other alternatives have priorities 20 and 30. PollingDesk and CivicAPI share an upstream and must not be counted as independent evidence. See [source policy](election-night-sources.md).

`HistoricalBaselines` loads frozen raw 2024 presidential counties and actual House district-county portions, separate 2022 turnout rows, and current-boundary presidential contest aggregates. Checksums, candidate sums, county FIPS, and source citations are checked before use. Complete Senate manifests require an exact match to independently archived Census county inventories, with explicit Connecticut legacy-county and Hawaii reporting-consolidation rules. Historical House sums are compared with the Clerk's official candidate totals; districts with material discrepancies are withheld. The [historical dataset documentation](../db/seed_data/election_night/README.md) records the sources, tolerance and remaining limitations.

Direct evidence must come from **one coherent publisher snapshot whose county set exactly matches the independent manifest**. Missing primary counties cannot be filled with overlapping fallback versions. A fully matching fallback snapshot can be used separately. House inference additionally requires independently verified unchanged boundaries and actual historical district portions; whole-county presidential counts and current-boundary contest aggregates cannot substitute for them. A reconciled zero county subset alone establishes no completeness. Raw display coverage and direct model eligibility are separate outcomes.

The historical House race as a whole must give each major party at least 5% of all candidate votes; strongly partisan counties are not excluded individually. A direct measurement additionally requires 5,000 counted two-party votes, 50% represented historical geography, and a lower counted-fraction bound of at least 15%. That last gate divides counted candidate votes by the scenario range's **upper** projected-turnout bound, not the point projection.

## Outstanding candidate votes and final-margin projection

`OutstandingVotes` projects candidate votes still to be reported, including minor candidates. It does not estimate a physical inventory of ballots, which can contain undervotes, overvotes or contests for which a ballot is ineligible. No provider's expected vote, percent reporting, completion flag or race call enters this calculation.

For each matched unit, the turnout anchor is a verified 2022 total when available; the current integration uses only independently complete, matching **2022 Senate county** anchors. Historical House turnout is retained but is not admitted merely because county names match: 2022-to-current district boundaries need separate verification. Otherwise the explicit fallback is **75% of that unit's 2024 all-candidate vote total**. The point projection retains an unresolved tail above counted votes and grows when turnout exceeds its anchor. It is a historical-anchor point projection, not the mean or median of the scenario distribution and not proof of completion.

Shared and local turnout scenarios produce a 5th–95th percentile range, expanded to include the deterministic point. Counted votes stay fixed; only remaining votes receive projected margins. County performance is compared with its own historical baseline, aligned to our prior, then combined with a robust common swing and county-specific residual. Reporting-order and turnout errors remain wide. The result supplies a final all-candidate margin estimate and uncertainty to `Nowcast`, after the observation eligibility gates pass. The bands are **assumption-based scenarios**, not calibrated confidence intervals. Detailed parameters, denominator definitions and tests are in [outstanding-vote estimation](election-night-outstanding-votes.md).

Aggregate-only raw counts can receive explicitly labeled turnout diagnostics when a compatible contest total exists, including 2024 presidential totals reaggregated to current House lines. Such diagnostics do not create county evidence, bypass redistricting checks or directly condition the needle.

## Joint model

For race r, the final margin is:

    m_r = mu_r + a_r' z + e_r
    z ~ Normal(0, I)
    e_r ~ Normal(0, sigma_r²)
    y_r = m_r + reporting_bias_state[r] + measurement_error_r

The shared vector z contains national, optional Census division, state effects, and a separate reporting-bias factor for each state contributing observations. The final-margin loading excludes reporting-bias factors; the measurement loading includes them. Reporting bias has a default standard deviation of 4 percentage points, configurable as `sigma_reporting_bias`. It allows several House and Senate estimates based on similarly biased early batches to move together without all of that movement being interpreted as a real voter swing. Race-specific error remains separate. Errors are expressed in the orientation used by the existing forecast: side A is the Democratic or anti-Republican side. The prior builder must preserve that orientation.

After integrating out e_r, each observation has conditional variance v_r = sigma_r² + measurement_sigma_r². With measurement loadings b_r (which include reporting bias), the shared posterior precision and information vector are:

    P = I + sum(b_r b_r' / v_r)
    h = sum(b_r (y_r - mu_r) / v_r)
    z | y ~ Normal(P⁻¹ h, P⁻¹)

A Cholesky factorization of P supports the posterior solution and draws. At most about 110 shared factors are required, rather than a dense 470-race covariance matrix. Given each shared draw, the observed race's remaining independent error is sampled from its Gaussian conditional distribution after subtracting the reporting-bias draw from its measurement. Unobserved races retain their independent prior error but share the updated national, division and state effects, never the reporting-bias draw itself. Thus evidence can move an unobserved race without falsely labeling it as directly observed.

All House and Senate seats are counted in the same simulated world. Candidate party controls the race-win probabilities; caucus controls seat totals. An uncommitted independent can leave both chamber-control probabilities below a combined 100%. Senate holdovers and each party's control threshold come from the frozen prior. The caller must provide the complete eligible race board; this pure engine also permits smaller boards for focused tests and does not invent missing seats.

## Publication semantics and limits

- `returns_updated` means that race supplied a direct measurement; `shared_update` means other returns updated shared factors. `prior_only` means there were no return observations; `uncontested` preserves the pre-election roster's explicit uncontested designation.
- Even a counted fraction of 1 is a noisy observation, not a call. The engine never creates an official winner designation from reporting completeness.
- Deterministic seeds and canonical race/observation order make identical inputs produce identical outputs. Analytic posterior margin means prevent sampling noise being shown as margin movement. Probability and seat estimates still have Monte Carlo error; 10,000 draws have a worst-case probability standard error of about 0.5 percentage points.
- Conditional measurement independence after shared state reporting bias is still an approximation, especially where estimates overlap particular counties. Reporting bias and the 1.5 inflation mitigate overconfidence but do not reproduce every residual dependence. They also intentionally preserve uncertainty even as estimated turnout approaches its assumed denominator; that denominator is not proof that all ballots are counted.
- Historical precinct/county shifts, vote methods, turnout, redistricting and reporting order belong in the measurement builder. Poor geographic matching cannot be repaired by this engine.
- The final-margin projection uses the frozen prior to align historical geography. Feeding that derived estimate back into the joint model is an approximation, not an independent raw measurement; sparse-return gates and conservative uncertainty remain necessary.
- Direct Senate evidence requires the race's county set to equal the complete statewide manifest, not merely that every currently present row has a baseline. Direct House evidence requires an exact match to the historical district's county manifest and independently verified unchanged district boundaries. A county with only one current House contest is not assumed unsplit: another contest may be omitted. Redrawn districts and districts without historical manifests receive only shared updates until independently validated current geography is available.
- This Gaussian two-side approximation is not an RCV transfer model. Alaska and Maine direct first-choice observations must remain excluded until separately supported. Independents require explicit candidate/caucus mapping.
- The published payload reports prior age and warns when the frozen forecast predates first poll close by more than 24 hours. This is disclosure, not a claim that the model somehow refreshed uncovered races. Future and post-cutoff priors are invalid; a prolonged count does not itself make a recent election-day prior stale.
- Mathematical correctness is not election-night calibration. Historical reporting-sequence replays, residual checks and sensitivity analyses are still required before describing probabilities as validated.

## Verification

The pure math tests compare single- and two-measurement posterior means and variances against closed-form calculations, verify shared-effect propagation and correlated seat distributions, distinguish candidate party from caucus, check reproducibility and ensure invalid or duplicate evidence is refused. Run without a database:

    bundle exec ruby test/lib/election_night/nowcast_test.rb

The [November 3, 15:29:47 Eastern integrated audit](research/election-night-civic-primary-coverage-2026-11-03.json) records raw sources for all 470 races, matched direct-update baselines for 265 races (70 of 125 on the competitive watchlist), and remaining-vote diagnostics for 465. All accepted current counts were zero, so there were no direct observations. The remaining diagnostics comprise 289 county estimates and 176 contest estimates; 14 Senate races use verified 2022 county turnout anchors. Baseline availability and turnout diagnostics are not direct evidence by themselves.

A normalized-source-cache replay reproduced the same race and chamber outputs with 10,000 joint simulations in 8.693 seconds, without network requests. This was not a raw-response reparse, historical reporting-sequence backtest or cold-network benchmark. Primary fetch timestamps in the live pass spanned approximately 252 seconds, so the 180-second per-source minimum interval does not imply a full-board refresh every three minutes. Earlier synthetic and limited-source benchmarks remain prior development checks. The audit retains an October 21 development prior and is not a substitute for freezing a current pre-election run before public operation.
