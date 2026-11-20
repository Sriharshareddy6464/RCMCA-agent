from __future__ import annotations

import asyncio
import difflib
import re
import time
import unicodedata

import httpx

# Locality centre coordinates are for quick route/search resolution, not parcel
# level addresses or official municipal boundary data. Corporation labels are
# the application's operating-area labels (GHMC, Cyberabad CMC, and MMC).
_LOCALITY_ROWS = [
    # GHMC core and western/southern localities
    ("Abids", "GHMC", 17.3890, 78.4760), ("Aghapura", "GHMC", 17.3850, 78.4590),
    ("Ameerpet", "GHMC", 17.4375, 78.4483), ("Amberpet", "GHMC", 17.3960, 78.5130),
    ("Aramghar", "GHMC", 17.3200, 78.4310), ("Attapur", "GHMC", 17.3670, 78.4310),
    ("Bahadurpura", "GHMC", 17.3500, 78.4560), ("Banjara Hills", "GHMC", 17.4126, 78.4482),
    ("Begumpet", "GHMC", 17.4440, 78.4670), ("Chaderghat", "GHMC", 17.3760, 78.4930),
    ("Charminar", "GHMC", 17.3616, 78.4747), ("Chilkalguda", "GHMC", 17.4340, 78.5080),
    ("Dilsukhnagar", "GHMC", 17.3688, 78.5247), ("Falaknuma", "GHMC", 17.3300, 78.4670),
    ("Film Nagar", "GHMC", 17.4140, 78.4070), ("Golconda", "GHMC", 17.3830, 78.4010),
    ("Habsiguda", "GHMC", 17.4220, 78.5430), ("Himayatnagar", "GHMC", 17.4010, 78.4830),
    ("Jubilee Hills", "GHMC", 17.4325, 78.4071), ("Kachiguda", "GHMC", 17.3910, 78.4940),
    ("Karkhana", "GHMC", 17.4650, 78.5020), ("Khairatabad", "GHMC", 17.4120, 78.4600),
    ("Koti", "GHMC", 17.3850, 78.4860), ("Lakdikapul", "GHMC", 17.4020, 78.4650),
    ("Langar Houz", "GHMC", 17.3790, 78.4140), ("Mallepally", "GHMC", 17.3840, 78.4640),
    ("Mehdipatnam", "GHMC", 17.3930, 78.4400), ("Musheerabad", "GHMC", 17.4140, 78.4960),
    ("Nampally", "GHMC", 17.3920, 78.4740), ("Narayanguda", "GHMC", 17.3970, 78.4900),
    ("Padmarao Nagar", "GHMC", 17.4240, 78.5050), ("Panjagutta", "GHMC", 17.4250, 78.4510),
    ("Patny", "GHMC", 17.4420, 78.4980), ("Saidabad", "GHMC", 17.3630, 78.5050),
    ("Sanathnagar", "GHMC", 17.4560, 78.4440), ("Secunderabad", "GHMC", 17.4399, 78.4983),
    ("Shalibanda", "GHMC", 17.3540, 78.4770), ("Somajiguda", "GHMC", 17.4230, 78.4590),
    ("Srinagar Colony", "GHMC", 17.4260, 78.4350), ("Tarnaka", "GHMC", 17.4270, 78.5320),
    ("Tolichowki", "GHMC", 17.4000, 78.4140), ("Yousufguda", "GHMC", 17.4340, 78.4260),
    # Cyberabad / western growth corridor
    ("Ameenpur", "CMC", 17.5310, 78.3260), ("Bachupally", "CMC", 17.5480, 78.3650),
    ("Bollaram", "CMC", 17.5430, 78.3750), ("Bowrampet", "CMC", 17.5700, 78.3570),
    ("Chandanagar", "CMC", 17.4930, 78.3230), ("Chintal", "CMC", 17.5050, 78.4440),
    ("Durgam Cheruvu", "CMC", 17.4320, 78.3910), ("Financial District", "CMC", 17.4140, 78.3400),
    ("Gachibowli", "CMC", 17.4400, 78.3480), ("Gajularamaram", "CMC", 17.5260, 78.4240),
    ("Hafeezpet", "CMC", 17.4860, 78.3630), ("Hitech City", "CMC", 17.4430, 78.3770),
    ("IDA Bollaram", "CMC", 17.5560, 78.3580), ("JNTU", "CMC", 17.4930, 78.3910),
    ("Khajaguda", "CMC", 17.4140, 78.3670), ("Kokapet", "CMC", 17.3910, 78.3380),
    ("Kondapur", "CMC", 17.4690, 78.3640), ("KPHB", "CMC", 17.4930, 78.3990),
    ("KPHB Colony", "CMC", 17.4930, 78.3990), ("Kukatpally", "CMC", 17.4930, 78.3990),
    ("Lingampally", "CMC", 17.4890, 78.3150), ("Madhapur", "CMC", 17.4480, 78.3910),
    ("Madeenaguda", "CMC", 17.4950, 78.3370), ("Manikonda", "CMC", 17.4060, 78.3830),
    ("Masjid Banda", "CMC", 17.4650, 78.3630), ("Miyapur", "CMC", 17.4960, 78.3560),
    ("Moosapet", "CMC", 17.4670, 78.4250), ("Nanakramguda", "CMC", 17.4170, 78.3400),
    ("Nallagandla", "CMC", 17.4750, 78.3150), ("Narsingi", "CMC", 17.3830, 78.3590),
    ("Patancheru", "CMC", 17.5330, 78.2650), ("Pragathi Nagar", "CMC", 17.5230, 78.3960),
    ("Quthbullapur", "CMC", 17.5010, 78.4540), ("Raidurg", "CMC", 17.4300, 78.3820),
    ("RC Puram", "CMC", 17.5170, 78.2850), ("Serilingampally", "CMC", 17.4810, 78.3180),
    ("Shaikpet", "CMC", 17.4020, 78.4140), ("Suraram", "CMC", 17.5370, 78.4550),
    ("Tellapur", "CMC", 17.4640, 78.2950),
    # Malkajgiri / eastern and north-eastern growth corridor
    ("Alwal", "MMC", 17.5000, 78.5080), ("Anandbagh", "MMC", 17.4610, 78.5390),
    ("AS Rao Nagar", "MMC", 17.4780, 78.5600), ("Boduppal", "MMC", 17.4130, 78.5830),
    ("Cherlapally", "MMC", 17.4700, 78.6100), ("ECIL", "MMC", 17.4780, 78.5630),
    ("Ghatkesar", "MMC", 17.4500, 78.6850), ("Kapra", "MMC", 17.4780, 78.5640),
    ("Keesara", "MMC", 17.5230, 78.6590), ("Kompally", "MMC", 17.5370, 78.4880),
    ("LB Nagar", "MMC", 17.3450, 78.5520), ("Lalapet", "MMC", 17.4350, 78.5260),
    ("Mallapur", "MMC", 17.4520, 78.5770), ("Malkajgiri", "MMC", 17.4560, 78.5270),
    ("Medipally", "MMC", 17.4240, 78.6070), ("Marredpally", "MMC", 17.4490, 78.5060),
    ("Moula Ali", "MMC", 17.4620, 78.5540), ("Nacharam", "MMC", 17.4350, 78.5580),
    ("Nagole", "MMC", 17.3710, 78.5650), ("Neredmet", "MMC", 17.4900, 78.5360),
    ("Old Bowenpally", "MMC", 17.4730, 78.4760), ("Peerzadiguda", "MMC", 17.3990, 78.5900),
    ("Ramanthapur", "MMC", 17.3990, 78.5410), ("Sainikpuri", "MMC", 17.4900, 78.5480),
    ("Secunderabad Station", "MMC", 17.4340, 78.5010), ("Uppal", "MMC", 17.4050, 78.5590),
    ("Vanasthalipuram", "MMC", 17.3300, 78.5720),
]

HYDERABAD_LOCALITIES: dict[str, dict] = {
    _name.casefold(): {
        "display_name": _name,
        "corporation": _corp,
        "latitude": _lat,
        "longitude": _lon,
    }
    for _name, _corp, _lat, _lon in _LOCALITY_ROWS
}

LOCALITY_ALIASES = {
    "hi tech city": "hitech city", "hitec city": "hitech city",
    "k p h b": "kphb", "kphb colony": "kphb", "lb nagar": "lb nagar",
    "rc puram": "rc puram", "ramachandrapuram": "rc puram",
    "malkajgiri railway station": "malkajgiri", "cyberabad": "gachibowli",
    "cyberabad cmc": "gachibowli", "cyberabad municipal corporation": "gachibowli",
    "greater hyderabad": "khairatabad", "greater hyderabad municipal corporation": "khairatabad",
    "ghmc": "khairatabad", "ghmc headquarters": "khairatabad",
    "cyber towers": "hitech city", "gachibowli stadium": "gachibowli",
    "financial district": "financial district", "malkajgiri mmc": "malkajgiri",
    "ecil x roads": "ecil",
    "durgam cheruvu cable bridge": "durgam cheruvu",
}

_request_lock = asyncio.Lock()
_last_request_at = 0.0
_minimum_interval_seconds = 1.1  # Keep public Nominatim use below one request/second.


def normalize_locality(value: str) -> str:
    normalized = unicodedata.normalize("NFKD", value).casefold()
    normalized = "".join(c for c in normalized if not unicodedata.combining(c))
    normalized = re.sub(r"[^\w\s]", " ", normalized)
    words = [w for w in normalized.split() if w not in {"hyderabad", "telangana", "india"}]
    return " ".join(words)


def resolve_hyderabad_locality(value: str, *, fuzzy: bool = True) -> dict | None:
    """Return a local gazetteer point; fuzzy matching is deliberately conservative."""
    key = normalize_locality(value)
    if not key:
        return None
    key = LOCALITY_ALIASES.get(key, key)
    place = HYDERABAD_LOCALITIES.get(key)
    if place:
        return dict(place, resolution="local_gazetteer")
    if fuzzy:
        nearest = difflib.get_close_matches(key, HYDERABAD_LOCALITIES, n=1, cutoff=0.82)
        if nearest:
            return dict(HYDERABAD_LOCALITIES[nearest[0]], resolution="local_gazetteer_fuzzy")
    return None


def find_hyderabad_locality(value: str) -> dict | None:
    """Find a gazetteer locality mentioned in a sentence, preferring longer names."""
    normalized = normalize_locality(value)
    if not normalized:
        return None
    names = sorted(HYDERABAD_LOCALITIES, key=len, reverse=True)
    for alias, target in sorted(LOCALITY_ALIASES.items(), key=lambda pair: len(pair[0]), reverse=True):
        if re.search(rf"(?<!\w){re.escape(alias)}(?!\w)", normalized):
            return dict(HYDERABAD_LOCALITIES[target], resolution="local_gazetteer")
    for key in names:
        if re.search(rf"(?<!\w){re.escape(key)}(?!\w)", normalized):
            return dict(HYDERABAD_LOCALITIES[key], resolution="local_gazetteer")
    return None


def _query_key(locality: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", locality).casefold().split())


async def geocode_locality(
    pool, client: httpx.AsyncClient, locality: str, *, timeout_seconds: float = 4.0
) -> dict | None:
    """Resolve from the local gazetteer/cache, then Nominatim within a hard deadline."""
    global _last_request_at

    local = resolve_hyderabad_locality(locality)
    if local:
        return local
    query = " ".join(locality.split())
    key = _query_key(query)
    if not key:
        return None

    async with pool.acquire() as connection:
        cached = await connection.fetchrow(
            "SELECT latitude, longitude, display_name FROM geocode_cache WHERE query_key = $1", key
        )
    if cached:
        return dict(cached)

    async def lookup_remote() -> dict | None:
        nonlocal query, key
        global _last_request_at
        async with _request_lock:
            async with pool.acquire() as connection:
                cached_row = await connection.fetchrow(
                    "SELECT latitude, longitude, display_name FROM geocode_cache WHERE query_key = $1", key
                )
            if cached_row:
                return dict(cached_row)

            wait_seconds = _minimum_interval_seconds - (time.monotonic() - _last_request_at)
            if wait_seconds > 0:
                # Respect Nominatim's cadence without letting a route request wait
                # indefinitely; the enclosing timeout also bounds lock contention.
                await asyncio.sleep(wait_seconds)
            _last_request_at = time.monotonic()
            response = await client.get(
                "/search",
                params={"q": f"{query}, Hyderabad, Telangana, India", "format": "jsonv2", "limit": 1},
                timeout=httpx.Timeout(timeout_seconds),
            )
            response.raise_for_status()
            results = response.json()
            if not results:
                return None
            result = results[0]
            geocoded = {
                "latitude": float(result["lat"]),
                "longitude": float(result["lon"]),
                "display_name": result.get("display_name", query),
            }
            async with pool.acquire() as connection:
                await connection.execute(
                    """INSERT INTO geocode_cache
                       (query_key, query_text, latitude, longitude, display_name)
                       VALUES ($1, $2, $3, $4, $5)
                       ON CONFLICT (query_key) DO NOTHING""",
                    key, query, geocoded["latitude"], geocoded["longitude"], geocoded["display_name"],
                )
            return geocoded

    try:
        return await asyncio.wait_for(lookup_remote(), timeout=max(0.1, timeout_seconds))
    except asyncio.TimeoutError:
        return None
