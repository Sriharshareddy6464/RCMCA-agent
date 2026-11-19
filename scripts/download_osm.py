"""Download Geofabrik's Southern Zone extract used to build the local OSRM graph."""

from __future__ import annotations

import sys
import urllib.request
from pathlib import Path

URL = "https://download.geofabrik.de/asia/india/southern-zone-latest.osm.pbf"
OUTPUT = Path(__file__).resolve().parents[1] / "osrm-data" / "southern-zone-latest.osm.pbf"


def main() -> int:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    if OUTPUT.exists() and OUTPUT.stat().st_size:
        print(f"Using existing extract: {OUTPUT} ({OUTPUT.stat().st_size:,} bytes)")
        return 0

    partial = OUTPUT.with_suffix(OUTPUT.suffix + ".part")
    request = urllib.request.Request(URL, headers={"User-Agent": "RCMCA-local-dev/0.1"})
    try:
        with urllib.request.urlopen(request, timeout=90) as response, partial.open("wb") as out:
            total = int(response.headers.get("Content-Length", "0"))
            copied = 0
            while chunk := response.read(1024 * 1024):
                out.write(chunk)
                copied += len(chunk)
                if total:
                    print(f"\rDownloaded {copied / total:.0%} ({copied:,}/{total:,} bytes)", end="")
        partial.replace(OUTPUT)
        print(f"\nSaved extract to {OUTPUT}")
        return 0
    except Exception as exc:
        partial.unlink(missing_ok=True)
        print(f"OSM download failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
