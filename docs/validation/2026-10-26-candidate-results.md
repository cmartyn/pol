# Candidate results and ranked-choice polling repair

Status: deployed and verified in production on October 26, 2026.

[PR #50](https://github.com/cmartyn/pol/pull/50) merged normally. Release
`d4ec941d58f3ad48b5e0055fc9ee5831da28495d` is running in both web and job
containers. Production model run **1166** completed at **09:07:37 EDT**, using
the verified October 26 inputs, seed `20261026`, and 100,000 simulations per
variant.

The NYT mapper previously kept the first answer for each party. In Alaska's
four-candidate Senate polls this frequently retained Gerald Heikes or Dan J.
Sullivan and discarded incumbent Dan Sullivan. Surname-only matching could
also attach Dan J. Sullivan's result to the incumbent. False matchup conflicts
then caused the forecast to ignore otherwise usable Alaska polling.

The importer now stores every candidate's name, source ID and percentage.
Roster links require a full-name match. The modeled party margin and matchup
key both use the strongest candidate per party, independent of source order.
Different source identities sharing a surname remain different people; three
explicit, sourced aliases reconcile James/Jamie Davis, Gabe/Gabriel Vasquez,
and Thomas Roland/Thom Tillis. These aliases are recorded with primary-source
citations in `Ingest::Nyt::CandidateIdentity`.

A survey's explicitly identified final two-candidate ranked-choice round takes
precedence over earlier rounds of the same matchup and population. Pollster
house effects and the partisan-sponsor adjustment use the same selection.
First-choice results remain visible with round labels. Competing matchups and
different survey populations are not silently combined.

## Production-data verification

The authorized, private export contains only races, candidates, pollsters,
polls and poll results. The refreshed October 26 export (08:34 EDT) exactly
matches the October 25 export in all five tables: 470 races, 922 candidates,
258 pollsters, 3,168 polls and 6,726 results. During deployment the 09:00 feed
added one Nebraska Senate poll, so the production fingerprint guard stopped
the first activation before any changes. A fresh 09:02 export and isolated
replay verified that addition: 3,169 polls and 6,728 results before repair.
No accounts, subscriber records, or email delivery data were exported. Raw
exports remain git-ignored.

Reprocessing 2,087 NYT questions repairs the 2,086 historical questions; the
new Nebraska question already uses the corrected importer. The repair:

- Restores 128 candidate results across 78 questions.
- Corrects a leading party percentage in 64 questions across 17 races,
  including minor-party categories that the two-sided model does not use.
- Corrects 17 Alaska Senate questions that discarded the incumbent's share.
- Changes 66 matchup keys to agree with the retained leading candidates.
- Preserves poll IDs, original ingestion times, source rows and editor notes.
- Makes zero changes when repeated after a successful repair.

For example, [Data for Progress's October 8–16 survey](https://www.dataforprogress.org/blog/2026/10/20/every-statewide-race-in-alaska-is-close-as-7-in-10-voters-worry-about-affording-gas-and-food)
records Peltola 47, incumbent Sullivan 44, Sullivan Jr. 4 and Heikes 1 on first
choices, and Peltola 51–49 in the final round. Both rounds now retain the
correct candidates; the final round is the observation used for that survey.

On October 25's fixed input and simulation seed, the default Alaska forecast
moves from Peltola 24.98% / R+5.95 to approximately 65.94% / D+2.03. Its polling
weight changes from zero to 2.794, with seven pollsters contributing. This is
an input correction, not voter movement.

The final October 26 verification uses seed `20261026`, 100,000 simulations
and both variants. All 435 corrected House baseline snapshots remain on
revision `260fd64adae37758bd88c92db3734cc3600a51cc290bfbbbaff11938d6b04bd7`.

| Alaska Senate | Excluding partisan polls | Including adjusted partisan polls |
| --- | ---: | ---: |
| Peltola win probability | 63.293% | 65.325% |
| Mean margin | D+1.671 | D+1.932 |
| Pollster-adjusted average | D+2.624 | D+2.490 |
| Contributing pollsters | 7 | 8 |
| Effective poll weight | 2.659 | 2.797 |

The final model runs, complete per-race outputs, repair plans, and estimator
outputs are saved in the private verification directory. Small changes in
other forecasts are expected because corrected polls also change shared
pollster adjustments.

Production matches the final isolated replay across all **940 race
forecasts** and all **four chamber forecasts**. Every win/control probability
matches exactly; the largest floating-point difference in margins, weights
or interval endpoints is `2.842170943040401e-14`, below the `1e-12` tolerance.
The repaired database contains 6,856 poll results, and a second repair pass
makes zero changes. The House baseline revision remains unchanged.

## Publication and validation

Each new model run records `poll_input_revision: candidate-results-v2`.
Movement comparisons and queued articles/emails cannot cross the correction.
Historic forecasts and dispatches remain visible with correction notices.
Production refuses to publish the new revision until all stored NYT questions
have been reprocessed. Alaska's stale `unsettled` flag is also cleared.

Validation: 1,349 Rails tests / 5,413 assertions passed; RuboCop and all three
security checks passed; seed reload passed in an isolated database. Four
focused browser tests / 54 assertions passed, including both Sullivans on a
375px viewport, the complete ingestion/forecast/newsroom pipeline, and the
partisan-polls toggle. The full browser suite has the same two previously
observed failures: native-select keyboard behavior on macOS and intermittent
Senate-map hover timing. Both were already observed during the preceding
redistricting release.

GitHub Actions for PR #50 could not start because of an account billing lock,
confirmed in the check annotations for this release's exact commit. The
normal merge succeeded without an administrator override; hosted CI is not
reported as passing. Local verification is recorded separately above.

The canonical [Alaska Senate page](https://535.wtf/races/senate-2026-ak) was
verified after CDN revalidation. It shows D63% / D+1.7 by default and D65% /
D+1.9 when the partisan-internals switch is enabled. The Data for Progress
rows show 47/44/4/1 first choices and 51/49 in the final round, with both
Sullivans named separately. The false current-matchup ambiguity and unsettled
field claims are absent. The timeline and an older Alaska dispatch display
the polling correction notice. TN-9 retains its new-district baseline and
redistricting explanation. Activation did not enqueue newsroom or email jobs.

## Applying the repair

Deploy the committed release normally; its additive migration adds two nullable
poll-result fields. Review `Ingest::Nyt::Reprocess.new.call` before applying
`Ingest::Nyt::Reprocess.new.call(apply: true)`. The repair runs atomically and
does not enqueue news or emails. Clear Alaska's `unsettled` flag, then call
`Forecast::Runner` directly for both variants. Verify all 940 race forecasts
against the local replay, clear the Rails cache, and check the public pages.
