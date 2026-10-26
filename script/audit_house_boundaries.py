"""Reproduce boundary_audit.csv from the two Census ZIPs (no GIS dependencies).

python3 script/audit_house_boundaries.py cd119.zip cd120.zip > boundary_audit.csv
Use the source URLs and checksums in the baseline manifest. No geometry is saved.
"""

import collections
import csv
import hashlib
import io
import sys
import zipfile


def memberships(path, congress):
    totals = collections.defaultdict(lambda: [0, 0])
    with zipfile.ZipFile(path) as archive:
        overrides = {}
        for name in archive.namelist():
            if name.startswith("National") or not name.endswith(".txt"):
                continue
            with archive.open(name) as source:
                first = next(csv.DictReader(io.TextIOWrapper(source)))
                overrides[first["GEOID"][:2]] = name

        for name in [f"NationalCD{congress}.txt", *overrides.values()]:
            with archive.open(name) as source:
                for row in csv.DictReader(io.TextIOWrapper(source)):
                    geoid, district = row["GEOID"], row["CDFP"]
                    if district in ("98", "ZZ"):
                        continue
                    if name.startswith("National") and geoid[:2] in overrides:
                        continue
                    total = totals[(geoid[:2], district)]
                    total[0] += 1
                    # Count + order-independent fingerprint of block membership.
                    total[1] ^= int.from_bytes(hashlib.sha256(geoid.encode()).digest())
    if len(totals) != 435:
        raise ValueError(f"Expected 435 districts in {path}, got {len(totals)}")
    return totals


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    old, new = memberships(sys.argv[1], 119), memberships(sys.argv[2], 120)
    if old.keys() != new.keys():
        raise ValueError("District identifiers disagree between sources")
    writer = csv.writer(sys.stdout)
    writer.writerow([
        "state_fips", "district", "old_block_count", "new_block_count",
        "old_membership_sha256_xor", "new_membership_sha256_xor", "changed",
    ])
    for key in sorted(old):
        a, b = old[key], new[key]
        writer.writerow([
            *key, a[0], b[0], f"{a[1]:064x}", f"{b[1]:064x}", str(a != b).lower(),
        ])
