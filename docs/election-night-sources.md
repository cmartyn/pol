# Election-night source adapters

Implemented on `codex/election-night-needle`, November 3, 2026. These adapters read raw candidate vote totals. They never import win probabilities, forecasts or a provider's modeled vote-remaining estimate.

## Sources enabled in the registry

`config/election_night_sources.yml` contains current URLs, optional companion metadata, conservative request intervals and historical baselines. Current samples were downloaded before polls closed; the eight accepted feeds showed zero votes. Ohio's ninth configured feed was explicitly marked as test data and was rejected. Successful parsing establishes the schema, not election-night update reliability.

| Source | Current parsed coverage | Historical baseline |
| --- | --- | --- |
| North Carolina SBE | 215 county/race units across 100 counties, Senate and House | Official 2024 precinct file aggregated to counties: 100 presidential units / 5,699,141 votes; also actual county portions of 2024 House districts |
| Arizona SOS | 30 county/House units across 15 counties | Raw 2024 presidential county compilation: 15 counties / 3,389,319 votes |
| Georgia SOS | 340 county/race units across 159 counties | Official 2024 export: 159 presidential units / 5,250,066 votes; also actual county portions of House districts |
| Virginia ELECT | 278 county/city/race units across 133 localities | Official 2024 export: 133 presidential units / 4,505,941 votes; also actual county portions of House districts |
| Texas SOS | 564 county/race units across 254 counties | Raw 2024 presidential county compilation: 254 counties / 11,380,105 votes |
| Kent County, Michigan | Three county/race units: Senate, MI-02, MI-03 | Official 2024 export: 372,930 presidential votes; actual county portions of MI-02 and MI-03 |
| Iowa Ledger | All five federal contests, statewide/district totals only | No county breakdown; remains an explicit aggregate-only source |
| Florida Division of Elections | 165 county/race units across all 67 counties; Senate and 27 House contests | Official 2024 file: 67 presidential units / 10,893,752 votes; 94 actual county portions of House districts |
| Ohio SOS — awaiting production file | Current XML has `IsTest="true"` and is rejected; structural rehearsal covers 88 counties | Raw 2024 presidential county compilation: 88 counties / 5,765,017 votes |

County presidential baselines alone do **not** establish the historic vote inside a congressional district that splits the county. The `house_units` output preserves actual 2024 district portions where official files provide them. Consumers must still check district-boundary compatibility for 2026. Historical candidate effects and presidential-to-midterm turnout changes remain modeling assumptions, not observations in these files.

## Additional sources when officials' websites are inaccessible

The [Iowa Ledger results page](https://iowaledger.com/results/) was accessible even though the official results root returned 403 to this client. Its public browser script identifies [a raw JSON endpoint](https://iowaledger.com/results/2026.json), which was successfully retrieved and parsed. The document identifies the 2026 general election, links [the official upstream election](https://electionresults.iowa.gov/IA/127077/), records upstream and publisher timestamps, and provides each candidate's actual vote total. The adapter ignores its `leader`/share presentation fields. It is a secondary publisher of official counts, not an independent collection of county returns and not another forecasting model. The feed has no county vote splits, and “counties reporting” must never be substituted for votes counted.

For Arizona, Texas and Ohio historical gaps, [Tony McGovern's public county-results repository](https://github.com/tonmcg/US_County_Level_Election_Results_08-24) provides a [2024 raw-count CSV](https://raw.githubusercontent.com/tonmcg/US_County_Level_Election_Results_08-24/master/2024_US_County_Level_Presidential_Results.csv). The publisher describes the 2024 data as collected from Fox News and explicitly does not claim to be the authoritative source. Its county counts and current official county names were checked for complete joins in AZ, TX and OH. This is a disclosed historical-data fallback. Preserve the downloaded bytes and checksum when initializing baselines; the branch name `master` is mutable. No forecasts or modeled percentages are consumed from the compilation.

Florida illustrates why a failed results homepage is not the end of the investigation. The state Downloads page returned 403, but [SignalData's Florida results page](https://signaldata.org/elections/2026/fl/results/) linked the exact [official tab-delimited results file](https://flelectionfiles.floridados.gov/enightfilespublic/20261103_ElecResultsFL.txt), which downloaded successfully. Its [2024 counterpart](https://flelectionfiles.floridados.gov/enightfilespublic/20241105_ElecResultsFL.txt) also works. The adapter reads those state files directly. FL-10 is absent from the current file; a missing contest is not interpreted as a call, a vote total or a completed race. The state file contains neither a publication timestamp nor an expected-vote estimate.

[Open America's public results API](https://openamerica.io/elections/api/) was also reachable, but its 2026 House and Senate feeds had empty race collections and no publication time when checked. Its historical 2024 House data includes Florida, but not Kansas. It was not enabled as a current source. [The People's Tally open-data page](https://thepeoplestally.com/open-data/) and its advertised raw file returned 403 and were not used. These are recorded access findings, not a claim that an unverified alternate feed fills coverage gaps.

[watch.vote's API documentation](https://watch.vote/docs/api-reference/elections) offers raw result routes, but its Iowa endpoint returned 403. It was not enabled. Kent County's public export supplies a working Michigan county fallback, but covers only one county; it must not stand in for the whole Michigan Senate electorate. The source audit's remaining state gaps still apply. No access control was bypassed and no publisher was contacted.

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

Senate keys end in `-S`; congressional keys have two-digit districts. The county key is uppercase with the ` COUNTY` suffix removed, preserving independent-city suffixes. `&` and `AND` are normalized to match the historical/current King and Queen County name change. Votes remain integer counts; blank, negative, fractional or nonnumeric totals raise `Base::InvalidData`.

`Texas#parse(body, metadata:)` additionally requires the raw companion election metadata. The county payload has no election date, so a URL alone is insufficient. The adapter checks the decoded `Home.ElecDate`, decodes the base64 county JSON, and verifies contest totals against candidates. Its source timestamp lacks a UTC offset; it is preserved as `source_time_text`, with `published_at` left null rather than inventing a timezone.

`parse_baselines(body)` selects the 2024-11-05 presidential contest regardless of the current adapter constructor date and returns the same county vote fields under `units`, with race keys ending `-P`. Enhanced Voting, North Carolina and Florida additionally return `house_units` for actual 2024 congressional county portions. AZ/TX/OH specify `baseline_adapter: county_baseline` in the registry. The CSV's year is established by its configured, inspected 2024 dataset; it is never used as a live-results adapter.

## Counting and validation decisions

- Enhanced Voting reads county-level candidate `voteCount` exactly once. It does not add statewide summaries, precinct details or voting-method subgroups on top of those counts. County-hosted exports use the root only when there are no child localities.
- North Carolina sums `Total Votes` across precinct/candidate rows. The vote-method columns are already included. Both real and administrative precincts are retained because centralized absentee reporting can be in administrative units. Duplicate candidate/precinct rows are rejected. ZIP data is streamed through `unzip` using argv, without extracting archive paths, with an expanded-size cap and an exact expected member name. CSV rows are parsed incrementally so unrelated local contests are discarded immediately; current and historical normalized outputs were checked for exact equality against the original parser.
- Texas reads candidate `V` and does not add `EV` to it. The exact method split is not inferred.
- Florida reads the tab-delimited `CanVotes` once per candidate/county/contest. Embedded quotation marks in candidate names are literal text. It validates row dates, district identifiers and matching county coverage across candidates, with no addition of precinct counts.
- Ohio's [NIST-format XML download](https://liveresults.ohiosos.gov/Api/v1/download?filename=VSSC1622XmlFileBlob) must have an explicit production flag (`IsTest="false"` or `"0"`), the correct election date, state FIPS and namespace. Only county reporting units with `IsElectoralDistrict="false"` and `VoteCounts Type="Total"` count. Its similarly named county electoral-scope units and statewide totals are excluded. DTDs, duplicate candidate counts and mismatched candidate county coverage are rejected. The actual downloaded test file was rejected; a synthetic flag change used only in a local structural check does not qualify it as production coverage.
- No adapter infers finality from all precincts or counties reporting. Later mail, provisional or corrected ballots remain possible; `complete` stays false. No race calls are made here.
- Corrected totals can decrease. Parsers validate each complete snapshot, rather than imposing monotonic counts that would reject legitimate corrections.
- The collector must enforce source-wide expected county coverage, poll-opening rules, stale/future timestamps, error retention and atomic publication. An isolated county or aggregate-only record does not establish complete statewide observation.
- Party buckets retain minor-party votes under `other_votes`. They are not assigned to Democratic or Republican caucuses. Mapping independent candidates and ranked-choice transfers requires separate modeling and roster work.

## Verification

Parser tests cover double counting, source/contest schemas, wrong election dates, test flags, duplicate rows, malformed/negative counts, county name aliases, third-party totals, independent-city keys, and actual congressional portions in historical data. The focused command is:

```sh
bundle exec ruby test/lib/election_night/sources/adapters_test.rb
```

The focused suite has 16 tests and 76 assertions. The parsers were also run against seven accepted current official files, the Iowa alternative JSON, NC's 2024 ZIP, GA/VA/Kent's official 2024 exports, Florida's current/historical tab files, and the AZ/TX/OH fallback historical CSV. Ohio's actual test XML was checked for rejection. Large raw downloads remain outside Git; the collector owns versioned storage and replay.
