# Reading election-night coverage

## November 3 CivicAPI-primary verification

CivicAPI is the primary raw-results source for all **470 races**: 435 House and 35 Senate. Official state and county sources remain fallbacks and cross-checks. The frozen competitive watchlist contains **125 races** (111 House, 14 Senate); its membership is explicit in `config/election_night_watchlist.json` and uses our own displayed probabilities to size coverage.

The fresh collection snapshot at **15:29:47 Eastern on November 3** produced the counts below. All 470 races selected CivicAPI as their primary source. The [CivicAPI-primary coverage audit](research/election-night-civic-primary-coverage-2026-11-03.json) records the exact snapshot, source status and input hashes.

| Coverage measure | All races | Competitive watchlist |
| --- | ---: | ---: |
| Selected whole-race raw source | 470 / 470 | 125 / 125 |
| Matched historical baseline eligible for direct conditioning | 265 | 70 |
| Remaining-vote estimate available | 465 | — |
| Actual direct measurements | 0 | 0 |

| Competitive raw scope selected | Races |
| --- | ---: |
| County detail with established race scope | 72 |
| Whole-contest totals | 53 |
| Partial coverage only or missing | 0 |

All accepted current counts were **zero**. These checks establish pre-poll availability and model plumbing, not election-night update reliability or historical calibration. The frozen development prior remains October 21 and is visibly disclosed. No production deployment or background collection was enabled.

The separate [full CivicAPI validation audit](research/election-night-civic-full-validation-2026-11-03.json) validated all 470 full-race endpoints: 410 new requests and 60 reparsed earlier archives. **466 feeds provide county detail**, totaling 6,159 county-equivalent rows. Mississippi's four House feeds provide contest totals only. Available county rows are not the same as independently established complete race geography: an all-zero subset also sums to a zero contest total. That is why available county detail exceeds the selected county-level scope above.

Remaining-vote estimates describe **candidate votes under turnout assumptions**, not an official inventory of uncounted ballots. An aggregate historical comparison can support a displayed estimate without providing county evidence for the forecast. Alaska and Maine estimates remain unavailable because ranked-choice round meaning is not modeled. Direct conditioning requires complete matched geography, a suitable partisan baseline and sufficient returns; broader raw coverage or a remaining-vote estimate does not relax those gates.

The earlier [coverage CSV](research/election-night-coverage-2026-11-03.csv) and [84-source audit](research/election-night-coverage-audit-2026-11-03.json) describe the **superseded 14:43 Eastern integration check**, before CivicAPI became primary and historical coverage expanded. Their 65 county / 60 contest watchlist split and 44 historical baselines are historical audit results, not the current configuration.

Of **494 configured source records**, **492 passed collection**. The official Ohio export remains rejected as test data, and Alaska's PDF request failed TLS certificate verification. Maryland's House response is reachable but contains `NR` rather than counts. These are distinct from a validated zero scaffold; CivicAPI supplies the displayed totals for those races. Consult the current primary audit for per-source health. CivicAPI and PollingDesk share an upstream and are not independent corroboration. No provider forecast probabilities, race calls or modeled remaining-vote estimates enter our model.

Final application verification passed **1,609 tests and 6,848 assertions**. To regenerate coverage from the latest local snapshot without another network sweep:

```sh
bin/rails election_night:coverage > /tmp/election-night-coverage.json
```

## Field meanings

The page separates raw-result availability, historical matching, remaining-vote estimates and actual model evidence. A connected feed may contain a pre-election zero scaffold or a retained, delayed snapshot. It does not prove that votes have arrived or that the model can interpret them reliably.

`coverage.races_with_raw_sources` and `competitive_races_with_raw_sources` count races with a selected whole-race source: county detail or a contest aggregate. `competitive_races_total` is the watchlist denominator. The county and contest subtotals describe selected scope, not every geographic row available from every source. `competitive_races_with_partial_sources` is excluded from the connected total.

`races_with_baselines` and `competitive_races_with_baselines` count matched historical baselines that have passed the geography and matchup gates for direct conditioning. They do not establish enough counted votes to update the forecast. `races_with_returns` counts actual direct observations. The page retains each race's explanation when conditioning is withheld.

`races_with_outstanding_estimates` counts races with a displayed `outstanding_votes` estimate. That object includes its county/contest scope, historical turnout basis, counted candidate votes, estimated remaining votes and assumption-based scenario range. It excludes the internal margin measurement. An available contest-level estimate is not a substitute for a county manifest. The displayed estimate subtracts the same counted total shown in the race row, even if separate model evidence comes from another publisher.

Race rows show the selected raw source scope beneath Observed votes:

| `raw_coverage_level` | Display | Meaning |
| --- | --- | --- |
| `county` | County detail | A whole-race county source supported by an independent manifest, or positive county counts reconciled to the publisher's aggregate. This alone does not establish unchanged historical district lines or direct-model eligibility. |
| `contest` | Contest total | Whole-race candidate totals without an established complete county breakdown for selection. Available county rows may still exist. |
| `partial` | Partial coverage | Some reporting areas only; their total is not represented as the whole race. |
| `none` | No raw source | No validated raw source available. |

When `has_raw_source` is false, Observed votes displays an em dash even if an older/internal numeric field contains zero. A connected source with a real zero displays `0`. `raw_source_stale` appends “delayed” while preserving the last known count. `raw_source_ids` identifies the selected publishers, and `raw_source_fallback` identifies fallback selection. Aggregates, county components and publisher mirrors are never added together.

## Selection, freshness and model evidence

Healthy whole-race sources take priority over retained snapshots from failed or stale sources. Within that health group, explicit registry priority comes first: a healthy CivicAPI aggregate precedes an official fallback's county detail. At equal priority, complete county scope precedes an aggregate; registry order resolves ties. Retained whole-race totals remain preferable to partial-area totals.

Direct evidence uses one complete, historically matched publisher snapshot. `model_source_ids` can therefore differ from `raw_source_ids` when a fallback supplies model geography while the primary supplies displayed totals. The resolver does not fill a primary's missing counties with overlapping fallback versions and call the mixture complete. If two rows from one source normalize to the same county for the same race, that source's entire race geography is withheld; a valid aggregate and clean fallback remain usable. The source/race rejection is retained for audit.

Freshness describes **retrieval health**, not a guarantee that the publisher has reported new votes. A healthy HTTP response can repeatedly return an old CivicAPI report, including a zero scaffold, while an official source already has positive counts. That does not currently trigger automatic fallback. The available official times often describe file generation or election metadata, rather than when the race's count batch changed; several lack a trustworthy UTC timestamp. The resolver therefore does not infer newer counts from retrieval time, a later export timestamp or a larger vote total. Corrections can reduce counts.

Publication times and source notes expose this limitation, but source review remains necessary during live counting. A retained failed snapshot is marked delayed; an unchanged report repeatedly retrieved successfully can still be marked healthy. PollingDesk cannot independently corroborate CivicAPI because it shares the same upstream.

The model's “Estimate uses” column remains separate: Returns + prior, Related races + prior, Prior only, or Uncontested. Seeing raw counts or estimated remaining votes does not imply that a direct observation entered the forecast.
