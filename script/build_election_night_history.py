#!/usr/bin/env python3
"""Freeze raw historical votes, never forecasts or whole-county House imputations.

See db/seed_data/election_night/README.md for the pinned downloads. Usage:
  python3 script/build_election_night_history.py --input-prefix /tmp/pol-history-
The Clerk PDF text inputs are produced with pdftotext -layout.
"""
import argparse
import collections
import csv
import hashlib
import json
import pathlib
import re

RELEASE = "https://github.com/pmheideman/us-county-election-results/releases/download/v1.0.0/"
TON_URL = "https://raw.githubusercontent.com/tonmcg/US_County_Level_Election_Results_08-24/master/2024_US_County_Level_Presidential_Results.csv"
AT_LARGE = {"AK", "DE", "ND", "SD", "VT", "WY"}
RAW_SHA = "da8736c5e6e288b603c2b8a148333ecb3f6363cd6df3521a432fd2e128dfbd04"
COUNTS = ["dem_votes", "rep_votes", "other_votes", "total_votes"]
FIELDS = ["race_key", "state", "county_fips", "county_name", *COUNTS,
          "geography_year", "source_ids", "quality_flags"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clerk_totals(path, state_names):
    """Read candidate lists, not recapitulation totals (which include blank ballots).

    The few indented fusion-party lines are assigned to the preceding named
    candidate. Unknown names/party lines clear that association. RCV totals are
    deliberately not repaired or substituted for first-round county votes.
    """
    totals = collections.defaultdict(lambda: {"dem_votes": 0, "rep_votes": 0})
    state, office, district, last_party = None, None, None, None
    fusion = {"Working Families", "Conservative", "Independent", "Common Sense",
              "Common Sense Suffolk", "Conservative, Common Sense"}
    for raw in path.read_text().splitlines():
        line = raw.strip().removeprefix("\f").strip()
        name = line.split("—")[0].strip()
        if name in state_names:
            state = state_names[name]
            continue
        if name in {"DISTRICT OF COLUMBIA", "AMERICAN SAMOA", "GUAM", "NORTHERN MARIANA ISLANDS", "PUERTO RICO", "VIRGIN ISLANDS"}:
            state, office = None, None
            continue
        if "FOR UNITED STATES REPRESENTATIVE" in line:
            office = "house"
            if state in AT_LARGE:
                district = "00"
        elif "FOR UNITED STATES SENATOR" in line:
            office, district = "senate", "S"
        elif "FOR PRESIDENTIAL ELECTORS" in line:
            office, district = "president", "P"
        elif "Recapitulation" in line:
            office = None
        if not state or not office:
            continue
        match = re.match(r"\s*(?:(\d+)\.\s*)?(.+?)\s*\.{3,}\s*([\d,]+)\s*$", raw)
        if not match:
            continue
        number, candidate, votes = match.groups()
        if office == "house" and number:
            district = number.zfill(2)
        if district is None:
            continue
        key = (state, office, district)
        votes = int(votes.replace(",", ""))
        if re.search(r", Republican\b", candidate) or (office == "president" and (candidate == "Republican" or "(Republican Party Candidate)" in candidate)):
            last_party = "rep_votes"
        elif re.search(r", Democrat(?:ic)?\b", candidate) or (office == "president" and (candidate == "Democratic" or "(Democratic Party Candidate)" in candidate)):
            last_party = "dem_votes"
        elif office == "president" or candidate not in fusion:
            last_party = None
        if last_party:
            totals[key][last_party] += votes
    return dict(totals)


def normalized(rows):
    # Party labels describe ballot lines. Count NY/CT fusion lines toward the
    # same candidate's major-party total rather than treating them as opponents.
    affiliations = collections.defaultdict(set)
    for row in rows:
        if row["party_group"] in {"DEM", "REP"}:
            affiliations[(row["year"], row["office"], row["state_po"], row["district"], row["candidate"])].add(row["party_group"])
    result = {}
    omitted = collections.Counter()
    for row in rows:
        state, office, district = row["state_po"], row["office"], row["district"]
        if office == "house" and (not district or (district == "00" and state not in AT_LARGE)):
            omitted[(row["year"], state)] += int(row["votes"])
            continue  # Unallocated write-ins must not be assigned to a district.
        suffix = "AL" if office == "house" and state in AT_LARGE else district if office == "house" else "P" if office == "president" else "S"
        # Shannon/Oglala Lakota was renamed and recoded in 2015; the raw
        # compilation sometimes retains the superseded code with its new name.
        fips = "46102" if row["county_fips"] == "46113" else row["county_fips"]
        key = (row["year"], f"{state}-{suffix}", fips)
        value = result.setdefault(key, {"race_key": key[1], "state": state,
            "county_fips": fips, "county_name": row["county_name"],
            **dict.fromkeys(COUNTS, 0), "geography_year": int(row["year"]),
            "source_ids": set(), "quality_flags": set()})
        assert value["county_name"] == row["county_name"], key
        party = row["party_group"]
        major = affiliations[(row["year"], office, state, district, row["candidate"])]
        if party == "OTHER" and len(major) == 1:
            party = next(iter(major))
        field = {"DEM": "dem_votes", "REP": "rep_votes"}.get(party, "other_votes")
        value[field] += int(row["votes"])
        value["total_votes"] += int(row["votes"])
        value["source_ids"].add(f"heideman:{row['source']}:{office}")
        if row["quality_flag"]:
            value["quality_flags"].add(row["quality_flag"])
        if fips != row["county_fips"]:
            value["quality_flags"].add("obsolete_fips_46113_corrected_to_46102")
    return result, omitted


def validate_races(rows, official, year):
    grouped = collections.defaultdict(list)
    for row in rows:
        grouped[row["race_key"]].append(row)
    records, excluded = [], set()
    for race, units in sorted(grouped.items()):
        state, district = race.split("-")
        office = "president" if district == "P" else "senate" if district == "S" else "house"
        expected = official.get((state, office, "00" if district == "AL" else district))
        actual = {field: sum(u[field] for u in units) for field in COUNTS[:2]}
        failed = not expected or any(abs(actual[field] - expected[field]) > max(100, expected[field] * 0.005) for field in actual)
        # Statewide independent Senate candidates do not match major-party sums;
        # preserve their votes in other_votes but do not turn them into D or R.
        if failed:
            excluded.add(race)
        records.append({"year": year, "race_key": race, "county_units": len(units),
                        "actual": actual, "clerk": expected, "accepted": not failed})
    return records, excluded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-prefix", required=True)
    parser.add_argument("--output", default="db/seed_data/election_night")
    args = parser.parse_args()
    path = lambda name: pathlib.Path(args.input_prefix + name)
    out = pathlib.Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    assert sha(path("us_county_results_long.csv")) == RAW_SHA, "Unrecognized upstream release"
    all_rows = list(csv.DictReader(path("us_county_results_long.csv").open()))
    states = {r["state"].upper(): r["state_po"] for r in all_rows}
    states.update({"ALASKA": "AK", "HAWAII": "HI"})
    selected = [r for r in all_rows if r["stage"] == "general" and
                ((r["year"] == "2024" and r["office"] in {"president", "house"}) or
                 (r["year"] == "2022" and r["office"] in {"house", "senate"}))]
    units, omitted = normalized(selected)
    # Some state exports contain every district x county combination filled
    # with zeroes. Zero-vote combinations establish no district geography.
    zero_units = [v for v in units.values() if v["total_votes"] == 0]
    units = {k: v for k, v in units.items() if v["total_votes"] > 0}
    pres = [v for (y, race, _), v in units.items() if y == "2024" and race.endswith("-P")]
    house = [v for (y, race, _), v in units.items() if y == "2024" and not race.endswith("-P")]
    midterm = [v for (y, _, _), v in units.items() if y == "2022"]

    # The compilation omits Kansas City votes and some late Maine/Rhode Island
    # presidential counts. Use separately published raw county totals for these
    # counties and Hawaii; never import Alaska's House-district pseudo-counties.
    replacements = {"29095", "23005", "44007"}
    pres = [r for r in pres if r["county_fips"] not in replacements]
    for row in csv.DictReader(path("tonmcg.csv").open()):
        if row["county_fips"] not in replacements and row["state_name"] != "Hawaii":
            continue
        state = states[row["state_name"].upper()]
        dem, rep, total = (int(row[key]) for key in ["votes_dem", "votes_gop", "total_votes"])
        pres.append({"race_key": f"{state}-P", "state": state, "county_fips": row["county_fips"],
            "county_name": row["county_name"], "dem_votes": dem, "rep_votes": rep,
            "other_votes": total - dem - rep, "total_votes": total, "geography_year": 2024,
            "source_ids": {"tonmcg:president:2024"}, "quality_flags": {"secondary_county_replacement"}})

    validation, excluded = [], {}
    official24 = clerk_totals(path("clerk2024.txt"), states)
    official22 = clerk_totals(path("clerk2022.txt"), states)
    for name, rows, official, year in [("president_2024", pres, official24, 2024),
                                      ("house_2024", house, official24, 2024),
                                      ("turnout_2022", midterm, official22, 2022)]:
        checks, bad = validate_races(rows, official, year)
        validation.extend(checks)
        excluded[name] = sorted(bad)
    # Keep a state's county geography even if a presidential aggregate comparison
    # is outside tolerance, but withhold its vote baseline until repaired.
    pres = [r for r in pres if r["race_key"] not in excluded["president_2024"]]
    house = [r for r in house if r["race_key"] not in excluded["house_2024"]]
    midterm = [r for r in midterm if r["race_key"] not in excluded["turnout_2022"]]
    datasets = {"county_president_2024.csv": pres, "house_county_2024.csv": house, "turnout_2022.csv": midterm}
    sources = [r for r in csv.DictReader(path("SOURCES.csv").open()) if r["year"] in {"2022", "2024"}]
    (out / "source_catalog.json").write_text(json.dumps(sources, indent=2) + "\n")
    (out / "validation.json").write_text(json.dumps(validation, indent=2) + "\n")
    roster = {"2020": collections.defaultdict(list), "2024": collections.defaultdict(list)}
    for row in csv.DictReader(path("census-counties2020.txt").open(), delimiter="|"):
        if row["STATE"] in states.values():
            roster["2020"][row["STATE"]].append({"county_fips": row["STATEFP"] + row["COUNTYFP"], "county_name": row["COUNTYNAME"]})
    for row in csv.DictReader(path("census-counties2024.txt").open(), delimiter="\t"):
        if row["USPS"] in states.values():
            roster["2024"][row["USPS"]].append({"county_fips": row["GEOID"], "county_name": row["NAME"]})
    (out / "county_roster.json").write_text(json.dumps(roster, indent=2) + "\n")
    files = {}
    for filename, rows in datasets.items():
        with (out / filename).open("w") as stream:
            writer = csv.DictWriter(stream, fieldnames=FIELDS, lineterminator="\n")
            writer.writeheader()
            for row in sorted(rows, key=lambda r: (r["race_key"], r["county_fips"])):
                writer.writerow({**row, "source_ids": "|".join(sorted(row["source_ids"])),
                                 "quality_flags": "|".join(sorted(row["quality_flags"]))})
        files[filename] = {"sha256": sha(out / filename), "rows": len(rows), "races": len({r["race_key"] for r in rows})}
    for filename in ["source_catalog.json", "validation.json", "county_roster.json"]:
        files[filename] = {"sha256": sha(out / filename)}
    upstream = [{"url": RELEASE + "us_county_results_long.csv", "sha256": RAW_SHA,
                 "publisher": "Paul Heideman", "release": "v1.0.0", "published_at": "2026-09-26T11:40:59Z",
                 "citation": "https://doi.org/10.5281/zenodo.22976553", "license": "CC BY 4.0"},
                {"url": RELEASE + "SOURCES.csv", "sha256": sha(path("SOURCES.csv"))},
                {"url": TON_URL, "sha256": sha(path("tonmcg.csv")), "publisher": "Tony McGovern; raw Fox News results compilation"}]
    upstream += [{"url": f"https://clerk.house.gov/member_info/electionInfo/{year}/statistics{year}.pdf",
                  "sha256": sha(path(f"clerk{year}.pdf")), "text_sha256": sha(path(f"clerk{year}.txt")),
                  "publisher": "Clerk of the U.S. House of Representatives"} for year in [2022, 2024]]
    upstream += [{"url": "https://www2.census.gov/geo/docs/reference/codes2020/national_county2020.txt",
                  "sha256": sha(path("census-counties2020.txt")), "publisher": "U.S. Census Bureau"},
                 {"url": "https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2024_Gazetteer/2024_Gaz_counties_national.zip",
                  "sha256": sha(path("census-counties2024.zip")), "text_sha256": sha(path("census-counties2024.txt")), "publisher": "U.S. Census Bureau"},
                 {"url": "https://elections.hawaii.gov/wp-content/uploads/2024-Elections-Audit.pdf",
                  "sha256": sha(path("hawaii-audit.pdf")), "page": 37, "publisher": "Hawaii Office of Elections",
                  "note": "For election administration, Kalawao is included in Maui."}]
    manifest = {"schema_version": 1, "election_date": "2024-11-05", "midterm_election_date": "2022-11-08",
                "retrieved_at": "2026-11-03", "files": files, "upstream": upstream, "excluded_races": excluded,
                "zero_vote_combinations_removed": len(zero_units),
                "geography_validation": {"method": "Exact FIPS set match with independent Census 2020 and 2024 county inventories; current rows must match the same reporting units.",
                    "exceptions": {"CT": "Eight historical counties matched to Census2020, not interchangeable with nine Census2024 planning regions.",
                        "HI": "Census county15005 Kalawao consolidated into reporting county15009 Maui per official election audit manual page37.",
                        "SD": "Obsolete source FIPS46113 corrected to46102 (Oglala Lakota, renamed2015), with no boundary allocation."}},
                "unallocated_house_other_votes": [{"year": int(y), "state": s, "votes": n} for (y, s), n in sorted(omitted.items())],
                "validation": "County sums must match Clerk major-party candidate totals within max(100 votes, 0.5% per party). Fusion ballot lines assigned to their major-party candidate. No geographic compatibility with 2026 is implied.",
                "limitations": ["Alaska has no verified county-equivalent presidential baseline here.",
                    "Connecticut reports eight historical counties; these cannot be interchanged with its nine planning regions.",
                    "Hawaii has four election reporting counties; Kalawao is not a separate reporting unit.",
                    "House rows are actual 2024 district-county portions, never whole-county estimates. Changed districts remain ineligible for geographic inference.",
                    "2022 House turnout cannot be used without an independent 2022-to-current boundary check.",
                    "Some unallocated write-ins are omitted from House other_votes; no blank or invalid ballots are counted.",
                    "Zero-vote district-county combinations are excluded: export cross-products do not prove geographic membership.",
                    "Aggregate validation detects missing votes but does not independently certify each county allocation."]}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"files": files, "excluded": excluded}, indent=2))


if __name__ == "__main__":
    main()
