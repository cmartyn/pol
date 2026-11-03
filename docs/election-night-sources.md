# Election-night source adapters

Implemented on `codex/election-night-needle`, November 3, 2026. These adapters read raw candidate vote totals. They never import win probabilities, forecasts or a provider's modeled vote-remaining estimate.

## Collection priority and cadence

The pinned `config/election_night_civic_races.json` catalog contains 435 House and 35 Senate full-race endpoint identities. It is a discovery catalog, not a declaration that every endpoint is healthy, geographically complete or eligible to move the model. Every response still passes election, candidate and geography validation.

| Collection path | Priority | Minimum request interval | Concurrency/scope |
| --- | ---: | ---: | --- |
| CivicAPI full-race catalog | 0 | 180 seconds per endpoint | Two simultaneous requests; primary raw counts |
| Official state and county feeds | 10 | 600 seconds | Sequential large exports; fallback and independent cross-checks |
| Iowa Ledger | 20 | 180 seconds | Secondary aggregate fallback |
| PollingDesk | 30 | 300 seconds | Aggregate fallback sharing CivicAPI's upstream |

Source health takes precedence over configured priority: retained stale/error data must not hide a healthy fallback. A healthy primary contest aggregate can remain the displayed total even when a fallback supplies county detail. Direct inference separately chooses a single coherent publisher snapshot with the complete expected geography. It never fills a primary's missing counties with overlapping fallback versions. Minimum intervals throttle requests; they do not promise that a publisher updates that frequently or that a complete sweep finishes within the interval.

## Official fallback source families

`config/election_night_sources.yml` is the authority for enabled URLs, source priority, companion metadata, request intervals and historical baselines. The table describes implemented adapters and their scope; it is not a final count of operational or model-ready races. Dated audits under `docs/research/` record the inspected responses, hashes and unresolved gaps. A successfully parsed zero scaffold establishes format and election identity, not later election-night update reliability.

| Source | Raw geographic scope | Identity and baseline notes |
| --- | --- | --- |
| North Carolina SBE | Senate and House county totals aggregated from precinct rows | Dated official ZIP; official 2024 president and actual House county portions |
| Arizona SOS | House county portions | Dated Enhanced Voting export; historical presidential county compilation |
| Georgia SOS | Senate and House county portions | Dated Enhanced Voting export; official 2024 president and House county portions |
| Virginia ELECT | Senate and House county/city portions | Independent cities remain distinct; official 2024 president and House county portions |
| Texas SOS | Senate and House county portions | Base64 county JSON requires dated companion metadata; historical presidential county compilation |
| Florida Division of Elections | Senate and House county portions | Dated official tab file and official 2024 president/House file; FL-10 absent from the inspected current export |
| California SOS | House county portions | Companion endpoint index supplies the general-election date missing from results JSON; new district boundaries need compatible history |
| Washington SOS | House county portions | Dated Enhanced Voting export with Washington-specific office and party labels |
| Arkansas SOS | Senate and House county portions | Tally election-info metadata binds UUID, date, party IDs, county names and vote methods to the raw export |
| Indiana SOS | House county portions | Official settings select the current A/B data version; county totals reconcile with district and statewide summaries |
| Nebraska SOS | Senate and House contest aggregates | Official page supplies date; pinned contest/candidate IDs validate the CSV. `map=CTY` does not make these county data |
| Alaska Division of Elections | Senate and House statewide first-choice aggregates | Dated official summary PDF; ranked-choice transfers are not represented |
| Louisiana SOS | Senate parish totals | Date-specific Senate CSV requires official metadata identifying the pinned election; no House coverage is claimed by this adapter |
| Maryland SBE | House district aggregates when reported | State HTML identifies election/office; `NR` remains unavailable, never zero |
| Ohio SOS | County totals when a production file appears | Inspected XML says `IsTest="true"` and is rejected; historical presidential county compilation available |
| Michigan county clerks | Kent and Kalamazoo county portions only | Dated official exports; Kent has official historical president and House portions |
| New York county board | Rockland portion of NY-17 | Exact candidate-name matching consolidates fusion ballot lines; no complete district manifest implied |
| New Jersey county clerks | Atlantic, Ocean and Gloucester county portions | Versioned Clarity summary and settings fetched together; inspected Morris test version is not usable |
| Missouri county authority | St. Charles portions of MO-02/MO-03 | CSV plus dated official election-page metadata; voting-method totals reconcile |

County presidential baselines alone do **not** establish the historic vote inside a congressional district that splits the county. The `house_units` output preserves actual 2024 district portions where official files provide them. Consumers must still check district-boundary compatibility for 2026. Historical candidate effects and presidential-to-midterm turnout changes remain modeling assumptions, not observations in these files.

## Secondary raw counts and shared upstreams

[CivicAPI](https://civicapi.org/) is the primary raw-count collection path and a secondary publisher, supplying full-race responses with candidate counts and, where available, county-equivalent results. The adapter uses the full-race endpoint, validates United States/state/office/district/general-election identity and requires an explicit `test_data: false`. It does not use search or national-summary responses as complete candidate rosters. County detail is accepted only when candidate identities align with the full race and every candidate's county sum matches the contest total. If detail is absent or fails reconciliation, the validated contest aggregate remains available and county detail is withheld.

Reconciliation of all-zero county rows is not proof of a complete county manifest: an arbitrary subset also sums to zero. Those rows remain separately available detail, while the selected raw coverage stays contest-level unless independent geography establishes completeness. The coverage audit lists available county units separately from selected scope.

[PollingDesk's results catalog](https://polling-desk.com/results) is a lower-priority aggregate fallback. Its CSV identifies **CivicAPI as its upstream**, so CivicAPI and PollingDesk are two delivery paths for the same source, not independent corroboration. The CSV lacks explicit election-date and test-data fields. Its general-election identity is based on the inspected, pinned 2026 catalog, supported by cycle/race identifiers, candidate records and required upstream attribution. The adapter discloses that limitation and marks all records aggregate-only; a current fetch date does not establish election identity. Recheck the publisher context if the catalog changes.

Neither adapter imports forecast probabilities, winner/call fields, modeled expected vote, percent-reporting fields or chamber-control estimates. Raw-result selection chooses one coherent total for each race; county portions, statewide summaries and publisher mirrors are never added together. County detail that reconciles with a secondary publisher's total still does not supply the independent geographic manifest and historical match required for direct model conditioning.

The [Iowa Ledger results page](https://iowaledger.com/results/) was accessible even though the official results root returned 403 to this client. Its public browser script identifies [a raw JSON endpoint](https://iowaledger.com/results/2026.json), which was successfully retrieved and parsed. The document identifies the 2026 general election, links [the official upstream election](https://electionresults.iowa.gov/IA/127077/), records upstream and publisher timestamps, and provides each candidate's actual vote total. The adapter ignores its `leader`/share presentation fields. It is a secondary publisher of official counts, not an independent collection of county returns and not another forecasting model. The feed has no county vote splits, and “counties reporting” must never be substituted for votes counted.

For Arizona, Texas and Ohio historical gaps, [Tony McGovern's public county-results repository](https://github.com/tonmcg/US_County_Level_Election_Results_08-24) provides a [2024 raw-count CSV](https://raw.githubusercontent.com/tonmcg/US_County_Level_Election_Results_08-24/master/2024_US_County_Level_Presidential_Results.csv). The publisher describes the 2024 data as collected from Fox News and explicitly does not claim to be the authoritative source. Its county counts and current official county names were checked for complete joins in AZ, TX and OH. This is a disclosed historical-data fallback. Preserve the downloaded bytes and checksum when initializing baselines; the branch name `master` is mutable. No forecasts or modeled percentages are consumed from the compilation.

## Frozen historical baselines

The nationwide fallback is now `ElectionNight::HistoricalBaselines`, backed by checked-in raw counts and provenance under `db/seed_data/election_night`. Existing official historical adapters remain available. The frozen loader adds 2024 presidential counties, actual 2024 House district-county portions and separate 2022 House/Senate turnout rows from [Paul Heideman's documented raw-results compilation](https://doi.org/10.5281/zenodo.22976553). Hawaii presidential counties and specified incomplete presidential counties use the separately attributed McGovern compilation. The loader verifies file hashes, vote arithmetic, source IDs and county identities; live collection does not download or regenerate this dataset.

The frozen compilation's House totals must pass an independent comparison against the Clerk's official candidate totals. Complete statewide manifests are separately checked against archived Census county inventories, so a small missing county cannot pass merely because its votes fall within the aggregate tolerance. Connecticut's historical counties and newer planning regions remain distinct; Hawaii's official Kalawao-to-Maui reporting consolidation is explicit. Invalid or incomplete state manifests are exposed separately and cannot establish direct Senate coverage. The dataset's [README and provenance manifest](../db/seed_data/election_night/README.md) explain exclusions, fusion-line normalization, omitted unallocated write-ins and the corrected South Dakota county code.

Current-line House presidential totals from the existing pinned boundary catalog are exposed only as contest aggregates for turnout diagnostics. They never become county baselines. Direct House inference still requires the prior's independently verified unchanged-boundary flag plus actual historical district portions. For outstanding-vote anchors, the current integration admits only verified complete 2022 Senate county geography; a matching 2022 House county name is insufficient boundary evidence. Where no admitted midterm anchor exists, our estimator explicitly assumes 75% of 2024 all-candidate votes and gives a scenario range. See [model assumptions](election-night-model.md) and [outstanding-vote methodology](election-night-outstanding-votes.md).

The historical partisan gate applies to the whole House race: each major party must have at least 5% of all candidate votes. Individual strongly partisan counties remain eligible. Before a matched snapshot creates a measurement, it must also clear the minimum vote and represented-geography gates and have at least a 15% **lower** counted-fraction bound, using the upper projected-turnout scenario. A sufficient point estimate alone does not pass that gate.

## Additional access findings

Florida illustrates why a failed results homepage is not the end of the investigation. The state Downloads page returned 403, but [SignalData's Florida results page](https://signaldata.org/elections/2026/fl/results/) linked the exact [official tab-delimited results file](https://flelectionfiles.floridados.gov/enightfilespublic/20261103_ElecResultsFL.txt), which downloaded successfully. Its [2024 counterpart](https://flelectionfiles.floridados.gov/enightfilespublic/20241105_ElecResultsFL.txt) also works. The adapter reads those state files directly. FL-10 is absent from the current file; a missing contest is not interpreted as a call, a vote total or a completed race. The state file contains neither a publication timestamp nor an expected-vote estimate.

[Open America's public results API](https://openamerica.io/elections/api/) was also reachable, but its 2026 House and Senate feeds had empty race collections and no publication time when checked. Its historical 2024 House data includes Florida, but not Kansas. It was not enabled as a current source. [The People's Tally open-data page](https://thepeoplestally.com/open-data/) and its advertised raw file returned 403 and were not used. These are recorded access findings, not a claim that an unverified alternate feed fills coverage gaps.

[watch.vote's API documentation](https://watch.vote/docs/api-reference/elections) offers raw result routes, but its Iowa endpoint returned 403. It was not enabled. County-only Michigan, New Jersey, New York and Missouri feeds remain partial even when they are the most authoritative local counts. Official access gaps, including blocked Colorado, Montana and South Carolina routes, are recorded in the regional audits; a secondary raw fallback does not turn those routes into verified official access. No access control was bypassed and no publisher was contacted.

## Adapter interface

Each class lives under `ElectionNight::Sources` and is constructed with `state:` and optional `election_date:` (default `2026-11-03`). `parse(body)` returns a string-keyed hash:

```json
{
  "election_date": "2026-11-03",
  "published_at": "2026-11-04T02:00:00Z",
  "test": false,
  "units": [
    {
      "race_key": "GA-S",
      "unit_key": "FULTON",
      "dem_votes": 600,
      "rep_votes": 400,
      "other_votes": 10,
      "total_votes": 1010,
      "complete": false
    }
  ]
}
```

Senate keys end in `-S`; congressional keys use two-digit districts or `-AL`. The county key is uppercase with the ` COUNTY` suffix removed, preserving independent-city suffixes. `&` and `AND` are normalized to match the historical/current King and Queen County name change. Votes remain integer counts; blank, negative, fractional or nonnumeric totals raise `Base::InvalidData`. `NR`, missing values and test results never become zero votes. Maryland explicitly returns unavailable-race reasons for `NR`; a source can be reachable while its contests remain unreported.

Contest aggregates use `aggregate_only: true` and `geography_level: "contest"`. CivicAPI can return county `units` and separate `aggregate_units` in the same response; consumers must choose the appropriate scope instead of summing both. `county_totals_match_aggregate` records candidate-level reconciliation, not an independent verification of a county manifest. Alaska additionally marks `first_choice_only: true`.

`Texas#parse(body, metadata:)` additionally requires the raw companion election metadata. The county payload has no election date, so a URL alone is insufficient. The adapter checks the decoded `Home.ElecDate`, decodes the base64 county JSON, and verifies contest totals against candidates. Its source timestamp lacks a UTC offset; it is preserved as `source_time_text`, with `published_at` left null rather than inventing a timezone.

California, Arkansas, Indiana, Nebraska, Louisiana, Clarity county and St. Charles adapters also require their configured companion metadata. Its meaning differs by publisher: an election index, election-info object, settings file or official page. California uses the dated official endpoint index; Arkansas uses the same election UUID in the full export and election-info response. Indiana resolves `VersionType` from settings, and Clarity resolves `current_ver.txt`; the collector substitutes the same validated version token into results and metadata URLs. Raw bodies, metadata and version responses each receive archived hashes so a replay can reconstruct the binding.

`parse_baselines(body)` selects the 2024-11-05 presidential contest regardless of the current adapter constructor date and returns the same county vote fields under `units`, with race keys ending `-P`. Enhanced Voting, North Carolina and Florida additionally return `house_units` for actual 2024 congressional county portions. AZ/TX/OH specify `baseline_adapter: county_baseline` in the registry. The CSV's year is established by its configured, inspected 2024 dataset; it is never used as a live-results adapter.

## Counting and validation decisions

- Enhanced Voting reads county-level candidate `voteCount` exactly once. It does not add statewide summaries, precinct details or voting-method subgroups on top of those counts. County-hosted exports use the root only when there are no child localities.
- North Carolina sums `Total Votes` across precinct/candidate rows. The vote-method columns are already included. Both real and administrative precincts are retained because centralized absentee reporting can be in administrative units. Duplicate candidate/precinct rows are rejected. ZIP data is streamed through `unzip` using argv, without extracting archive paths, with an expanded-size cap and an exact expected member name. CSV rows are parsed incrementally so unrelated local contests are discarded immediately; current and historical normalized outputs were checked for exact equality against the original parser.
- Texas reads candidate `V` and does not add `EV` to it. The exact method split is not inferred.
- Florida reads the tab-delimited `CanVotes` once per candidate/county/contest. Embedded quotation marks in candidate names are literal text. It validates row dates, district identifiers and matching county coverage across candidates, with no addition of precinct counts.
- Ohio's [NIST-format XML download](https://liveresults.ohiosos.gov/Api/v1/download?filename=VSSC1622XmlFileBlob) must have an explicit production flag (`IsTest="false"` or `"0"`), the correct election date, state FIPS and namespace. Only county reporting units with `IsElectoralDistrict="false"` and `VoteCounts Type="Total"` count. Its similarly named county electoral-scope units and statewide totals are excluded. DTDs, duplicate candidate counts and mismatched candidate county coverage are rejected. The actual downloaded test file was rejected; a synthetic flag change used only in a local structural check does not qualify it as production coverage.
- California ignores districtwide summaries when county portions are present. Washington maps `(Prefers Democratic Party)` and `(Prefers Republican Party)` explicitly. New York assigns a fusion ballot line to a major-party candidate only when the normalized candidate name matches exactly within that contest; unrelated minor-party votes remain separate.
- Arkansas sums only the metadata-identified Absentee, Election Day and Early Voting components. A standalone Total Votes field is accepted separately; mixed totals and components, duplicate methods or unknown/missing methods fail validation. County totals exclude nested precincts. Party IDs are resolved through metadata, not guessed from candidate-name prefixes.
- Indiana follows the current A/B version instead of pinning yesterday's file. Nebraska's CSV generation time is diagnostic only, not a new vote-report timestamp. The Louisiana adapter accepts the pinned Senate office and complete parish scaffold; it does not fabricate House rows.
- Alaska extracts the first federal-contest pages of the official PDF with `pdftotext`, supplied by `poppler-utils`. Candidate sums must match the printed totals. Missing party labels and independent candidates remain `other_votes`; first-choice totals cannot establish ranked-choice outcomes. Missing PDF tooling or a changed layout fails the source rather than supplying empty counts.
- No adapter infers finality from all precincts or counties reporting. Later mail, provisional or corrected ballots remain possible; `complete` stays false. No race calls are made here.
- Corrected totals can decrease. Parsers validate each complete snapshot, rather than imposing monotonic counts that would reject legitimate corrections.
- The collector validates configured expected counties/races and retains source/version provenance. Poll timing, source freshness and model eligibility remain separate checks. An isolated county, aggregate-only record or secondary county reconciliation does not establish complete statewide modeling geography. Expanded raw coverage does not relax direct-model gates.
- Party buckets retain minor-party votes under `other_votes`. They are not assigned to Democratic or Republican caucuses. Mapping independent candidates and ranked-choice transfers requires separate modeling and roster work.

## Verification

Parser tests cover double counting, source/contest schemas, companion metadata, version changes, wrong election dates, test flags, duplicate rows, malformed/negative counts, county aliases, fusion lines, third-party totals, independent-city keys, PDF first-choice limits, `NR`, and actual congressional portions in historical data. Run the election-night test directory, including the source-specific test files:

```sh
bin/rails test test/lib/election_night
```

Dated regional audit files record actual URL/status pairs, election identity, hashes, local samples, parsed race IDs, geographic scope and unresolved gaps. They distinguish accessible zero scaffolds, unreported values, rejected tests and blocked downloads. Integration counts and performance measurements must be taken from a run against the current registry, not reused from an earlier smaller collection. Large raw downloads remain outside Git; the collector owns versioned storage and replay.

The November 3 **14:43:29 Eastern** check predates the full CivicAPI catalog, revised priorities and frozen nationwide historical loader. Its source, geographic and direct-baseline counts are **superseded for the current implementation**. In that earlier run Ohio was rejected as test data, Alaska's official PDF failed certificate verification, and Maryland's inspected House values were `NR`; those dated findings must be rechecked against the current run rather than treated as current health. TLS verification was not disabled.

The current [Civic-primary coverage audit](research/election-night-civic-primary-coverage-2026-11-03.json) binds the **November 3, 15:29:47 Eastern** snapshot to its Civic catalog, frozen prior, historical revision and input hashes. It records **470/470 raw-covered races**, including **125/125 competitive races**, all selected from CivicAPI. Selected raw scope is 290 county-level and 180 contest-level races; the competitive subset is 72 county-level and 53 contest-level. All accepted current counts were zero. Complete matched direct-update baselines were available for 265 races, including 70 competitive races; there were no direct observations. Remaining-vote diagnostics were available for 465 races, a separate measure from direct evidence.

Of 494 collected source records, 492 had status `ok`. Ohio remained rejected as test data and Alaska's official PDF failed TLS certificate verification; neither failed fallback displaced the healthy primary. The 470 primary fetch timestamps spanned **15:25:24–15:29:36 Eastern**, approximately 252 seconds. This exceeds the 180-second minimum request interval and is not a promise of three-minute end-to-end freshness. A normalized-source-cache replay reproduced race/chamber outputs without network access; it did not reparse every raw response or establish live-count accuracy.

The earlier [coverage CSV](research/election-night-coverage-2026-11-03.csv) and [provenance audit](research/election-night-coverage-audit-2026-11-03.json) remain **prior-audit artifacts**. Their older source priorities, geographic counts and performance measurements must not be presented as the current audit. The new audit contains source provenance and validation results, not provider forecasts or model probabilities.
