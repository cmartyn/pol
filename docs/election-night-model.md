# Independent live inference model

`ElectionNight::Nowcast` implements an experimental joint Gaussian update. It consumes our frozen pre-election prior and estimates of final race margins derived from reported votes. It does not consume another forecaster's probabilities or race calls.

## Measurement contract

Each observation contains `race_key`, `observed_margin`, `sigma`, `counted_fraction` and `source_ids`. `observed_margin` is an estimate of the **final side-A-minus-side-B margin in percentage points**, after accounting for which geographic units have reported. It is not the raw reported margin. Its `sigma` expresses the remaining-vote, geography, turnout and measurement uncertainty. The upstream observation builder must construct that estimate; this engine does not infer ballot completion from votes or precinct counts.

Only one aggregate measurement per race is accepted in a run. Repeated updates replace that measurement; they must never be appended as independent observations. Duplicate race measurements, unknown race keys, zero coverage, negative uncertainty and nonfinite numbers are rejected. Races without adequate direct evidence get no observation.

The counted fraction is diagnostic, not a second confidence weight. This avoids applying reporting completeness twice after the upstream measurement uncertainty has already incorporated it. The default measurement standard deviation is inflated by 1.5 and floored at 2 percentage points. These conservative assumptions are visible in diagnostics and configurable in the frozen prior, with inflation at least 1 and floor at least 1. They are not empirically calibrated constants.

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
- Direct Senate evidence requires the race's county set to equal the complete statewide manifest, not merely that every currently present row has a baseline. Direct House evidence requires an exact match to the historical district's county manifest and independently verified unchanged district boundaries. A county with only one current House contest is not assumed unsplit: another contest may be omitted. Redrawn districts and districts without historical manifests receive only shared updates until independently validated current geography is available.
- This Gaussian two-side approximation is not an RCV transfer model. Alaska and Maine direct first-choice observations must remain excluded until separately supported. Independents require explicit candidate/caucus mapping.
- The published payload reports prior age and warns when the frozen forecast predates first poll close by more than 24 hours. This is disclosure, not a claim that the model somehow refreshed uncovered races. Future and post-cutoff priors are invalid; a prolonged count does not itself make a recent election-day prior stale.
- Mathematical correctness is not election-night calibration. Historical reporting-sequence replays, residual checks and sensitivity analyses are still required before describing probabilities as validated.

## Verification

The pure math tests compare single- and two-measurement posterior means and variances against closed-form calculations, verify shared-effect propagation and correlated seat distributions, distinguish candidate party from caucus, check reproducibility and ensure invalid or duplicate evidence is refused. Run without a database:

    bundle exec ruby test/lib/election_night/nowcast_test.rb

A local November 3 benchmark used the stored 470-race prior, 90 synthetic observations across NC/AZ/GA/VA/TX, 65 active factors and 10,000 joint draws. It completed in 8.035 seconds; both chamber histograms contained exactly 10,000 worlds. This is a local synthetic workload, not a production benchmark or a test against actual reported votes. The local prior was dated October 21 and is not a substitute for freezing a current pre-election run before public operation.
