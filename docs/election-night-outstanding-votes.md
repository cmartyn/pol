# Experimental outstanding-vote estimation

`ElectionNight::OutstandingVotes` estimates **candidate votes still to be reported in a contest**, not the number of physical ballots in an election office. Blank votes, undervotes, overvotes, and ballots ineligible for the contest do not appear in candidate totals. This distinction applies to both its historical turnout anchors and its live counted-vote denominator.

The class uses current raw candidate counts, matched historical candidate counts, and our frozen race prior. It never reads provider expected votes, percentages reporting, race calls, forecasts, or `complete` flags. Its uncertainty bands are assumption-based scenarios, not empirically validated confidence intervals. Historical election-night replay calibration remains necessary.

## Why this differs from a fixed turnout denominator

Election officials document that reporting precincts and counted ballots are different quantities. San Bernardino County explains that precinct reporting can reach 100% while additional mail and provisional ballots remain to be counted. The EAC likewise distinguishes unofficial election-night totals from the subsequent canvass. Those facts support keeping uncertainty after a historical turnout estimate is reached; they do not supply a numerical estimate of outstanding votes. [San Bernardino County explanation](https://elections.sbcounty.gov/elections/2026/0602/resultexplanation/), [EAC canvass guidance](https://www.eac.gov/election-officials/election-results-canvass-and-certification).

Reporting order also varies by geography and voting method. MIT Election Lab describes differences among early, mail, and in-person reporting and documents partisan shifts during the count. We therefore adjust for historical geography, retain shared reporting-order error, and avoid treating observed votes as a random sample. Matching counties cannot identify an unreported voting-method mix within a county. [MIT Election Lab's reporting research](https://electionlab.mit.edu/research/election-return-reporting).

These sources motivate the safeguards. **All numerical parameters below are our explicit experimental assumptions**, not estimates borrowed from a publisher or parameters fitted to those sources.

## Input and output contract

```ruby
ElectionNight::OutstandingVotes.new(
  matched: [[current_row, historical_row, historical_two_party_total], ...],
  race_prior: { "race_key" => "NC-S", "mu" => 1.5 },
  midterm_totals: { "WAKE" => 400_000 }, # optional; caller verifies geography
  seed: 5352026,
  draws: 256
).call
```

Each current and historical row has the same `unit_key`, integer `dem_votes`, `rep_votes`, and `total_votes`. `other_votes`, if present, must reconcile with the total; otherwise it is the nonnegative difference. The third tuple element must equal historical Democratic plus Republican votes. Historical two-party totals must be positive. Duplicate/mismatched units and malformed counts fail closed. A permissive one-trillion-vote per-unit ceiling rejects corrupted integers that could overflow scenario arithmetic. A House row must be the actual county portion of the relevant district, unless the caller is deliberately producing an aggregate-only diagnostic and withholding direct inference.

Optional 2022 totals are keyed by normalized unit name. The caller must independently establish that they refer to the same county or district portion: matching strings alone do not prove unchanged district boundaries. Unknown or zero-valued midterm anchors are rejected. A historical race can be useful for total turnout without being a useful partisan comparison, so the caller remains responsible for uncontested-race and completeness checks.

Race and unit outputs include `counted_votes`, `projected_total_votes`, `remaining_votes`, their `_low`/`_high` bands, and `counted_fraction` with its band. The `projected_total_votes` field is a **deterministic historical-anchor point projection**, not a conditional mean or median of the scenario distribution. Race metadata identifies it as `point_kind: "historical_anchor_with_unresolved_tail"`. Counts include minor candidates; `counted_two_party_votes` is separately exposed for observation eligibility. `represented_fraction` weights counties with at least 100 two-party votes by their historical two-party totals. Per-unit `turnout_basis` distinguishes a verified 2022 anchor from the 2024 fallback, and `turnout_overshoot` flags counts above the original anchor.

`measurement` is absent until at least one unit has 100 two-party votes. When present it contains `observed_margin`, `sigma`, `counted_fraction`, source IDs, and a margin band. The margin is final **(Democratic minus Republican) / all candidate votes**, in percentage points, matching the repository's historical/polling margin convention. The caller must still apply complete-geography, minimum-vote, historical-line compatibility, third-party-share, and candidate-identity gates before passing it to `Nowcast`. The class does not authorize direct inference for RCV, independents, or aggregate diagnostics.

## Turnout point projection and scenarios

For unit i, let H be its historical 2024 total, C its currently counted candidate total, and A its turnout anchor. A is the independently matched 2022 total when available; otherwise A = 0.75 H. The fallback is explicit, not treated as an observed midterm turnout ratio. Different verified 2022 county anchors can therefore produce different turnout ratios within the same race.

The deterministic point is:

    overshoot = max(log(C / A), 0), with overshoot = 0 when C = 0
    T_point = max(A, C × (1.10 + 0.10 × overshoot))
    remaining_point = T_point − C

The 10% unresolved-tail reserve is deliberately conservative and uncalibrated. It prevents a historical anchor from becoming an assertion that counting is complete. It may overestimate remaining votes late in the count; an independently validated ballot inventory or completion mechanism is needed to replace it. Counts above A expand both the point and uncertainty instead of forcing the estimated counted fraction toward 100%.

Turnout scenarios have lognormal marginals centered on A, truncated strictly above C. Shared standard-normal scenarios couple units so uncertainty does not disappear merely because a race contains many counties. Each marginal is lower-truncated using its log survival probability, which remains numerically stable even after large turnout overshoots. The construction preserves a shared turnout copula after applying each lower bound; it is **not** a joint Bayesian posterior update that learns other counties' turnout from an early-reporting county.

| Parameter | Assumption |
| --- | --- |
| Shared turnout log standard deviation | 0.20 |
| Local log standard deviation with verified 2022 anchor | 0.18 |
| Local log standard deviation with 2024 fallback | 0.25 |
| Overshoot dispersion increment | 0.5 × max(log(C/A), 0) |
| Scenario band | 5th–95th sample percentiles, expanded to include the deterministic point |

The marginal log standard deviation is the root-sum-square of shared and local scales plus the overshoot increment. The shared Gaussian coefficient is 0.20 divided by that total standard deviation; the remaining coefficient is local. Aggregate bands come from sums within the same scenarios, not from adding unit percentile endpoints. Fraction bands reverse the total endpoints: C/T_high through C/T_low. Remaining totals are always nonnegative, and no positive counted fraction is reported as exactly 1.

## Final-margin projection

Historical county margins use all candidate votes. A bounded additive shift aligns their turnout-anchor-weighted average with the frozen race prior; it is solved after limiting county margins to −100 through +100 so a highly polarized county cannot break that alignment. For each reporting county, the observed raw margin is compared with its own shifted historical margin. A weighted-median-centered, 20-point winsorized average estimates the common residual swing. Weights are counted candidate votes capped at the county turnout anchor, so a turnout overshoot cannot give a county unlimited influence. This correction addresses geographic mix; it cannot establish that a county's first batch is representative of its later batches.

For remaining votes, a reporting county's residual blends with the common swing using n/(n+1000), where n is its two-party counted vote. Counties below 100 two-party votes use the common swing. Counted Democratic-minus-Republican votes stay fixed. Only remaining votes are projected, and each resulting margin is bounded to its physical −100 to +100 range.

The point margin is evaluated directly, without simulation noise. For example, with equally sized historical urban 80/20 and rural 20/80 counties, prior margin zero, and only urban 40,000/10,000 reported, the point remains exactly zero. The raw reported 60-point urban margin does not itself create a race-wide swing.

Scenarios vary turnout and the margin of remaining votes. They include a shared reporting-order error with standard deviation `8 + 8 × (1 − represented_fraction) + 0.5 × residual_dispersion` percentage points, plus unit error `6 + 6 × (1 − unit_counted_fraction)`. `sigma` is the root-mean-square scenario deviation around the deterministic final-margin point, floored at 4 points; using deviation around the point also retains uncertainty when scenario asymmetry moves the scenario mean. `Nowcast` independently applies its existing measurement inflation and state reporting-bias factor. These conservative layers are assumptions, not calibration claims.

## Limits and validation still required

- A historical county/district mismatch invalidates geographic inference. The pure estimator cannot discover that mismatch from matching names.
- A turnout anchor is not a voter file, returned-ballot inventory, or count of ballots awaiting processing. Population change, competitive contests, suppression/expansion of turnout, and reporting corrections can all move actual totals.
- Voting-method order can bias every county in the same direction. Robust residual aggregation and broad error terms reduce sensitivity but do not identify or eliminate that bias.
- The deterministic point uses our frozen prior to align geography; it is not statistically independent of that prior. Reconditioning this derived measurement is an approximation, especially with sparse returns. Existing eligibility gates and uncertainty inflation remain required.
- All-zero historical comparisons, incomplete historical candidate rosters, and unverified redistricting allocations must be excluded or explicitly marked as aggregate diagnostics by the caller. RCV rounds require their own count semantics.
- The tests establish arithmetic, denominator, determinism, geography, nonnegative tails, and uncertainty safeguards. They do not establish electoral calibration. Backtests must include archived reporting sequences, interval coverage, turnout overshoots, method-specific batches, and sensitivity to every numeric assumption above.

Run the pure tests without a database:

```sh
bundle exec ruby test/lib/election_night/outstanding_votes_test.rb
```
