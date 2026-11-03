# Reading election-night coverage

## November 3 verification

The integrated branch run connected raw sources for **125 of 125 watchlist races** (111 House, 14 Senate), and **all 470 contests** on the frozen board. The broad watchlist is explicit in `config/election_night_watchlist.json`; it uses our own displayed probabilities to size coverage, not another forecaster's ratings.

| Watchlist source scope selected | Races |
| --- | ---: |
| Verified official county feeds | 65 |
| Whole-contest totals | 60 |
| Partial coverage only or missing | 0 |

County detail is also connected for many of the races currently displaying contest totals. All-zero county subsets cannot prove complete geography, so their validated aggregate is selected until stronger evidence is available. The [per-race CSV](research/election-night-coverage-2026-11-03.csv) separately records selected scope and available county sources. The [audit JSON](research/election-night-coverage-audit-2026-11-03.json) records source status and input hashes.

This was a pre-poll verification: all observed vote totals were zero, and no direct measurements entered the forecast. **44 races** have matched historical baselines (16 on the competitive watchlist); raw-source expansion does not automatically expand that set. The frozen development prior remains October 21 and is visibly disclosed. No production deployment or background collection was enabled.

Of 84 enabled feeds, 82 passed the final collection. Ohio's official export remains test data; Alaska's official PDF failed TLS certificate verification. Alternatives cover those races. Maryland's official source is reachable but still says `NR`; it contributes no fabricated zeros. CivicAPI and Polling Desk share an upstream and are not independent corroboration. No provider forecasts or race calls enter the model.

To regenerate an audit from the latest local snapshot without another network sweep:

```sh
bin/rails election_night:coverage > /tmp/election-night-coverage.json
```

## Field meanings

The page distinguishes a connection to raw results from evidence that directly updates the forecast. A connected feed may contain a pre-election zero scaffold or a retained, delayed snapshot. It does not prove that votes have arrived or that the model can interpret them reliably.

`coverage.competitive_races_with_raw_sources` counts competitive races with a selected whole-race source: either county detail or a contest aggregate. `competitive_races_total` is the denominator. The county and contest subtotals are displayed separately. `competitive_races_with_partial_sources` counts races served only by partial-area reports and is excluded from the connected total. The analogous all-race count is `races_with_raw_sources`.

`races_with_returns` counts races whose usable returns enter direct model conditioning. County detail alone does not establish that the current race geography matches a historical baseline, that a sufficient share of votes has arrived, or that a two-party observation model is appropriate. The page keeps this count separate and retains each race's explanation when a direct update is withheld.

Race rows show the selected raw source scope beneath Observed votes:

| `raw_coverage_level` | Display | Meaning |
| --- | --- | --- |
| `county` | County detail | A whole-race county source or nonzero county totals reconciled with the publisher's race aggregate; not an independently verified historical district manifest. |
| `contest` | Contest total | Whole-race candidate totals without a usable geographic breakdown. |
| `partial` | Partial coverage | Some reporting areas only. Their total is not represented as the whole race. |
| `none` | No raw source | No validated raw source available. |

When `has_raw_source` is false, Observed votes displays an em dash even if an older/internal numeric field contains zero. A connected source with a real zero displays `0`. Older snapshots without `has_raw_source` retain their existing numeric display for compatibility. `raw_source_stale` appends “delayed” to the coverage label while preserving the last known count. `raw_source_ids` identifies the source records chosen by the resolver; provider aggregates and their county components are never added together.

Healthy whole-race sources take priority over retained snapshots from failed or stale sources. Within each group, county detail takes priority over a contest total; registry order resolves ties. Retained whole-race totals remain preferable to partial-area totals. Duplicate county rows likewise prefer healthy sources. An all-zero county subset always reconciles to a zero aggregate, so reconciliation alone cannot establish its geographic completeness: the resolver displays the contest total unless county coverage is independently established. Available county rows remain available for geographic validation without creating a new model manifest.

Freshness describes collection health, not a guarantee that the publisher has reported new votes. Some official feeds omit a reliable publication timestamp, and a successful download can still contain an unchanged old scaffold. The resolver does not reorder healthy sources by publication age; the displayed publication time and source notes expose the known limits. A retained snapshot is marked delayed, but a repeatedly fetched old publisher snapshot may still be marked retrieved.

The model's “Estimate uses” column remains separate: Returns + prior, Related races + prior, Prior only, or Uncontested. Seeing a raw count does not imply direct evidence was used.
