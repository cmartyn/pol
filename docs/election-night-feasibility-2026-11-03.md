# Election-night chamber needles: feasibility

> **Superseded recommendation:** The user's requirement is our own model using direct official returns. The [follow-up direct-source investigation](election-night-direct-sources-2026-11-03.md) verifies current exports covering 661 local jurisdictions in five states and recommends an independent pipeline. The provider-first discussion below is retained as the initial assessment, not the current recommendation.

Investigated November 3, 2026, before polls closed, for 535.wtf. This is a research and implementation recommendation, not a deployed feature. Estimates below are engineering judgments; vendor access, pricing, and activation times remain unconfirmed.

**Decision**

A page showing the live probability of Democratic control of each chamber is technically feasible. For tonight, the strongest route is to license an existing election-night forecast and display it with clear attribution. Decision Desk HQ's Pulse is the most relevant product found. Its public material establishes that an election-night forecast exists, but does not establish that a new customer can obtain live House and Senate chamber probabilities today.

Building our own calibrated national model from partial returns is a separate, substantial project. Our existing forecast is a useful prior and already models correlated outcomes. It does not yet infer the remaining vote or learn from returns. A working dial would take much less time than earning confidence in the numbers driving it.

If no suitable licensed forecast is available, launch a results dashboard with the final pre-election forecast clearly identified, or a deliberately limited scenario tool. Neither should be presented as a model that has incorporated partial election returns. A market-driven probability display is another possible product, subject to display rights; it should explicitly identify its probabilities as market-implied.

**What the Times-style product actually needs**

In a direct interview, NYT graphics editor Wilson Andrews described starting with expectations for counties or precincts, then learning from reported performance to forecast similar areas and the remaining vote. He also described reporting beyond AP's feed to establish what ballots remain. That is materially more than putting a gauge on the current leader. The Times distinguishes its live forecast from a race call. [Interview with the NYT's election graphics editor](https://reutersinstitute.politics.ox.ac.uk/news/moving-needle-how-new-york-times-aims-guide-readers-through-americas-most-uncertain-election).

The required calculation is:

1. Freeze an identified pre-election prior and the contest/candidate roster.
2. Receive timestamped results by reporting geography and, where available, voting method.
3. Estimate both the quantity and partisan composition of outstanding ballots, with uncertainty.
4. Update race outcomes and shared national/state errors jointly as informative returns arrive.
5. Simulate the unresolved seats together, add settled seats and Senate holdovers, and count how often each chamber's control threshold is reached.

Under the app's configured 2026 rules, the thresholds are 218 House seats and 51 Democratic-caucus Senate seats. The Senate prior contains 34 Democratic-caucus and 31 Republican holdovers; re-audit that roster before activation. Candidate party and caucus affiliation must remain separate, including an unresolved outcome if an uncommitted independent holds the balance. JD Vance remains the vice president. [White House biography](https://www.whitehouse.gov/administration/jd-vance/).

An early urban vote dump is not a random sample of the whole electorate. Nor does “60% of precincts reporting” necessarily mean “60% of ballots counted.” AP explains why it estimates expected votes instead, and why its percentage can fall when the turnout estimate increases. [AP's explanation of expected vote](https://apnews.com/article/dbf56f63d08d57c839d91bdb9a98ed19).

Summing race win probabilities gives expected seats, not the probability of a majority. Treating races as independent also loses the common errors that matter to chamber control. Buying individual race probabilities would therefore not, by itself, remove the need for a chamber model or joint simulation output.

**Data-source assessment**

| Source | Verified offering | Fit and unresolved questions |
| --- | --- | --- |
| Decision Desk HQ | Results via API or embeds; pre-election House/Senate and chamber forecasts; Pulse election-night forecast. | Best first inquiry for a ready-made live forecast. Confirm Pulse's 2026 chamber coverage, API/embedding options, publication rights, activation, price, and support. The pre-election chamber product does not prove that Pulse includes chamber probabilities. |
| Associated Press | Election results API with vote counts, race calls, reporting units and expected-vote information. AP explicitly lists all 435 House and 35 Senate contests for this election. | Strong national results source for our own future model. Requires an API key and agreement. Detailed coverage and permitted uses depend on the package. A results feed does not supply our missing inference model. |
| Official election authorities | Public results and some machine-readable feeds. | Useful for targeted coverage and reconciliation. A national system requires many adapters and reporting arrangements. |
| Kalshi | Existing 2026 chamber-control markets and documented unauthenticated market-data endpoints. | Technically a route to market-implied gauges. Public API access does not establish permission to republish data; confirm the applicable API/display license. Contract definitions, quote age and spreads also matter. |
| Small public aggregators | watch.vote documents 2026 results routes with source metadata. | Interesting lead for a results dashboard, not a verified national forecasting feed. Documentation says the routes carry no odds. Coverage, rights and live payloads were not validated. |

Sources: [DDHQ products](https://www.decisiondeskhq.com/products), [DDHQ's explanation of Pulse](https://www.decisiondeskhq.com/faq), [AP's 2026 coverage announcement](https://www.ap.org/media-center/press-releases/2026/ap-announces-2026-midterm-election-plans/), [AP API access](https://developer.ap.org/ap-elections-api/docs/Getting_Started.htm), [Kalshi market-data documentation](https://docs.kalshi.com/getting_started/quick_start_market_data), [watch.vote documentation](https://watch.vote/docs/api-reference/elections).

No verified public, self-service price or same-day activation promise was found for the AP or DDHQ packages required here. Budget for a quote; do not use anecdotes about another customer's pricing. Public viewing access to DDHQ's dashboard is not evidence of API or redistribution entitlement.

AP's response schema includes reporting-unit timestamps, candidate identifiers, vote counts, expected-vote percentages, call reversals, runoff flags and ranked-choice fields. Its documentation explicitly notes gaps in vote-type coverage and that some expected-vote estimates are unavailable at finer geographic levels. A license is not a guarantee of complete precinct-by-vote-method data nationwide. [AP response specification](https://developer.ap.org/ap-elections-api/docs/Elections_Response_Data_Elements.htm).

For an AP integration, request updates through the returned `nextrequest` URL; an unchanged response can contain only that link. Full-fetch clients can use ETags. Quotas are assigned to the API key, so a proposed polling cadence must respect the actual subscription. [Update protocol](https://developer.ap.org/ap-elections-api/docs/Receiving_Election_Updates.htm), [query quotas](https://developer.ap.org/ap-elections-api/docs/Working_with_Query_Quotas.htm).

AP changed its vote-type model for election events on and after August 4, 2026. Implementing from an old election tutorial without checking current fields would be a concrete integration risk. [AP release notes](https://developer.ap.org/ap-elections-api/docs/Release_Notes.htm).

Examples of official-source variation:

- California documents public, unauthenticated JSON results endpoints with optional CSV for supported requests. Its guide contains historical examples; November contest IDs and current responses still need verification. [California data-feed guide](https://cms.cdn.sos.ca.gov/media/3-api-documentation-v3.pdf).
- North Carolina provides an election-night dashboard and an election-download interface. [NCSBE results](https://www.ncsbe.gov/results-data/election-results), [downloads](https://er.ncsbe.gov/downloads.html).
- New Jersey explicitly says the state division does not publish results on election night and directs readers to county websites. This illustrates why “scrape the 50 state sites” is not a complete nationwide plan. [New Jersey election-night results](https://www.nj.gov/state/elections/election-night-results.shtml).

Kalshi has specific [House](https://kalshi.com/markets/controlh/house-winner/controlh-2026) and [Senate](https://kalshi.com/markets/controls/senate-winner/controls-2026) contracts. The Senate page specifies media consensus with a fallback tied to the president pro tempore's party on February 1, 2027. Such contract definitions are not identical to simply counting election-night seats. Its linked website data terms restrict public display and redistribution without authorization; the applicable permission for our intended API use is unresolved. [Kalshi data terms](https://kalshi-public-docs.s3.amazonaws.com/kalshi-data-terms-of-service.pdf).

Do not plan around undocumented newspaper results JSON. Technical accessibility establishes neither a stable integration contract nor a publication license. Our existing NYT polling CSV integration does not establish an entitlement to NYT live returns or its Needle outputs.

**What this repository already provides**

| Existing component | Reusable capability | Gap for election night |
| --- | --- | --- |
| `Forecast::RaceModel` | Race priors, polling estimates, candidate party/caucus mapping. | No likelihood for partial returns; models two sides rather than full ranked-ballot transfers. |
| `Forecast::Simulator` | Shared national, division and state errors; seat histograms; control thresholds. | Shared errors are drawn from prior assumptions, not inferred from observed returns. |
| `Forecast::Runner` and `ModelRun` | Parameter/seed records, atomic publication and concurrency protection. | No election-result snapshot lineage or separate election-night run type. |
| `ChamberForecast` and site charts | Storage and presentation of chamber probabilities and seat distributions. | Need a clearly distinguished live series and explicit source/model timestamps. |
| GoodJob, Postgres, deployed Rails app | Existing scheduled ingestion and serving infrastructure. | Need a dedicated, bounded update path and capacity verification. |
| House baseline work | District-level historical comparisons on the app's 2026 map. | No complete county-within-district or precinct baselines for interpreting incoming returns. |

The schema has `poll_results`, which are survey responses, not election vote totals. No returns/reporting-unit/call-event pipeline was found in the reviewed code.

Performance matters: `config/model_params.yml` sets 100,000 simulations per variant, with two variants per run. The recorded production median is 133 seconds across 230 runs, and the deployment notes describe a shared 2 GB droplet. This is repository evidence, not a new production benchmark. The README's older “about two seconds” description should not guide an election-night cadence.

`Forecast::RunJob` also wakes the automated newsroom after a successful run. A live-results feature should have its own publication path so frequent result changes do not accidentally invoke polling-oriented articles or emails. Freeze the identified pre-election baseline used by the live feature; do not let subsequent poll cron runs overwrite its meaning.

**Proposed implementation**

For a vendor-powered first version, create an `/election-night` page with two gauges, probability history, called-seat counts, a list of pivotal unresolved races, and source/freshness labels. Display provider probabilities directly with attribution. Do not label them as the existing 535 model's calculations.

Use one server-side ingestion job, archive each source revision, validate it, and atomically publish a compact snapshot. Clients can poll the cached snapshot every 15–30 seconds; the source polling frequency depends on its permitted cadence. A webpage refresh is not evidence that the upstream data changed. Track upstream report time, retrieval time, last successful source check and model computation time separately.

Support a visible paused/stale state, a last-good snapshot and a manual pause control. Distinguish a healthy feed with no new votes from a failed feed. Preserve corrections, legitimate decreases in vote totals and reversed calls in the history. Normalize provider race/candidate IDs, special elections and districts explicitly; never join only on candidate display names.

For our own model later, add geography-specific turnout and vote-share distributions, reporting-order/vote-method effects, and posterior updating of shared errors. The House needs county-within-district or precinct mappings on the correct 2026 lines. Carry uncertainty for unsupported voting systems or unresolved runoffs; a first-choice leader is not automatically a ranked-choice winner. Persist the prior inputs and each result revision so any published estimate can be replayed.

The Washington Post publishes an election-night model that estimates outstanding votes and their partisan split using historical baselines and demographic features. It is a useful engineering reference, not a supplied national live feed; data preparation, integration, license review and validation remain necessary. [Published model and documentation](https://github.com/washingtonpost/elex-live-model/blob/main/README.md).

DDHQ's research also illustrates why partially reported units require special treatment: geography and vote-method composition can bias them, and the model described in its paper uses sufficiently complete units to learn about others. The paper concerns a live primary model; it is supporting research, not a specification for every 2026 Pulse output. [DDHQ research paper](https://hdsr.mitpress.mit.edu/pub/zr6hjsfl/release/1).

**Effort and launch choices**

These are rough estimates for a developer familiar with this repository, after usable data access and sample payloads exist. They exclude contracting and any vendor activation delay.

| Version | Approximate engineering effort | Assessment for tonight |
| --- | --- | --- |
| Licensed provider embed, if the desired chamber product is available | A few hours | Plausible, conditional on access and scope. |
| Custom page consuming ready-made chamber probabilities | About 1–2 working days; a reduced version could take several hours | Possible only with immediate access and a narrow scope. |
| Results dashboard plus clearly labeled pre-election probabilities | Roughly 1–2 days with a normalized feed; longer with many custom state adapters | A reduced/manual version is plausible. This does not update probabilities from partial returns. |
| Called seats plus pre-election simulations for unresolved races | Roughly 1–3 days including call/correction handling | A scenario estimate, not a fully conditioned live forecast. Must disclose that calls do not teach the remaining races about common error. |
| Our own calibrated House and Senate model driven by partial returns | Several weeks at minimum, potentially longer for data assembly and validation | Not a credible same-day launch. |

A successful replay is the main gate for publishing our own probabilities. Use timestamped historical election-night snapshots, not just randomly ordered final county totals. Evaluate probability calibration, interval coverage, early/late counting bias and robustness to delayed/revised feeds. Include missing geography, vote-type gaps, special elections, caucus ambiguity, RCV/runoffs and call retractions. Benchmark the intended cadence on representative infrastructure. Additional Monte Carlo draws do not fix model misspecification.

**Concrete next decision**

First seek a DDHQ quote for public use on 535.wtf covering (a) live House and Senate chamber probabilities or the joint simulation output needed to derive them, (b) results and attributed calls, (c) current payloads and test access, (d) update limits and support, and (e) activation today. [DDHQ contact page](https://www.decisiondeskhq.com/contact).

For a model we own, seek the corresponding AP or DDHQ detailed-results package plus historical timestamped snapshots and geography coverage. AP publishes an elections API inquiry contact in its [overview](https://developer.ap.org/ap-elections-api/AP_Elections_API_Overview.pdf).

If a ready-made forecast cannot be obtained in time, use a clearly labeled results/pre-election page tonight and defer our own live needle. This is a data and validation dependency, not a limitation of Rails or the gauge UI.

**Verification limits**

Reviewed local code and public primary-source documentation, plus a direct interview with the NYT operator. No provider was contacted, no subscription was purchased, no credential store was inspected and no production state was changed. AP/DDHQ authenticated payloads were not tested. The web research tool could not retrieve the attempted Kalshi market API payloads or watch.vote results payload, so those endpoints are documented candidates rather than tested integrations. NYT pages were blocked to the research tool; the interview supplies the operator's account of its approach. This investigation does not certify nationwide free-feed coverage or forecast calibration.
