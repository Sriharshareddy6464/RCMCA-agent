from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

DEFAULT_DEMO_EMAIL = "adapalasriharshareddy@gmail.com"

# ---------------------------------------------------------------------------
# Hyderabad wards
# ---------------------------------------------------------------------------
# NOTE: ward polygons are ~1.2 km square approximations centred on each locality,
# good enough for demo-grade spatial routing. They are NOT official GHMC / CMC /
# MMC boundaries, and ward_no values are demo identifiers, not gazetted numbers.
_WARD_HALF_SPAN_DEG = 0.0055

# (ward_no, corporation, zone, ward_name, lat, lon, email tag)
_WARDS: list[tuple[int, str, str, str, float, float, str]] = [
    # GHMC
    (91, "GHMC", "Khairatabad Zone", "Khairatabad", 17.4120, 78.4600, "ghmc-khairatabad"),
    (92, "GHMC", "Khairatabad Zone", "Banjara Hills", 17.4126, 78.4482, "ghmc-banjarahills"),
    (93, "GHMC", "Khairatabad Zone", "Sanathnagar", 17.4560, 78.4440, "ghmc-sanathnagar"),
    (94, "GHMC", "Secunderabad Zone", "Tarnaka", 17.4270, 78.5320, "ghmc-tarnaka"),
    (95, "GHMC", "Charminar Zone", "Pathergatti", 17.3600, 78.4740, "ghmc-pathergatti"),
    # CMC / Cyberabad
    (201, "CMC", "Serilingampally Zone", "Kondapur", 17.4690, 78.3640, "cmc-kondapur"),
    (202, "CMC", "Serilingampally Zone", "Gachibowli", 17.4400, 78.3480, "cmc-gachibowli"),
    (203, "CMC", "Serilingampally Zone", "Madhapur", 17.4480, 78.3910, "cmc-madhapur"),
    (204, "CMC", "Kukatpally Zone", "KPHB Colony", 17.4930, 78.3990, "cmc-kphb"),
    (205, "CMC", "Qutbullapur Zone", "Jeedimetla", 17.5110, 78.4400, "cmc-jeedimetla"),
    # MMC / Malkajgiri
    (301, "MMC", "Malkajgiri Zone", "Malkajgiri", 17.4560, 78.5270, "mmc-malkajgiri"),
    (302, "MMC", "Uppal Zone", "Ramanthapur", 17.3990, 78.5410, "mmc-ramanthapur"),
    (303, "MMC", "LB Nagar Zone", "Vanasthalipuram", 17.3300, 78.5720, "mmc-vanasthalipuram"),
    (304, "MMC", "Kapra Zone", "Kapra", 17.4780, 78.5640, "mmc-kapra"),
]

_DESIGNATION = {
    "GHMC": "Zonal Commissioner",
    "CMC": "Deputy Commissioner",
    "MMC": "Municipal Commissioner (Roads & Buildings)",
}


def _demo_email(tag: str) -> str:
    """Route every authority mailbox to one inbox using Gmail +tag addressing."""
    base = os.getenv("DEMO_BASE_EMAIL", "").strip() or DEFAULT_DEMO_EMAIL
    if "@" not in base:
        base = DEFAULT_DEMO_EMAIL
    local, _, domain = base.rpartition("@")
    local = local.split("+", 1)[0]
    return f"{local}+{tag}@{domain}"


def _ward_wkt(lat: float, lon: float) -> str:
    d = _WARD_HALF_SPAN_DEG
    w, e, s, n = lon - d, lon + d, lat - d, lat + d
    return f"POLYGON(({w} {s}, {e} {s}, {e} {n}, {w} {n}, {w} {s}))"


# ---------------------------------------------------------------------------
# Seed field issues: 12 across GHMC / CMC / MMC with multi-user survey logs.
# Survey tuple: (user_index, still_present, condition_score, impact_mcq, days_ago)
# ---------------------------------------------------------------------------
_DEMO_USERS = 8


def _demo_user(index: int):
    return uuid5(NAMESPACE_URL, f"rcmc-demo-surveyor-{index}")


_SEED_ISSUES = [
    {
        "ticket": "FS-GHMC-001", "ward": 91, "category": "pothole", "severity": 4,
        "report_count": 2, "d_lat": 0.0021, "d_lon": -0.0018, "days": 9,
        "description": "Cluster of deep potholes on the service road near Khairatabad flyover; two-wheelers swerve into the main lane.",
        "impact": "vehicle_damage",
        "surveys": [(0, True, 4, "vehicle_damage", 8), (1, True, 5, "injury_risk", 6), (2, True, 4, "vehicle_damage", 2)],
    },
    {
        "ticket": "FS-GHMC-002", "ward": 92, "category": "waterlogging", "severity": 3,
        "report_count": 2, "d_lat": -0.0015, "d_lon": 0.0012, "days": 5,
        "description": "Water stagnates ankle-deep at the Road No. 12 junction for hours after moderate rain; storm drain inlet is silted.",
        "impact": "slows_traffic",
        "surveys": [(3, True, 3, "slows_traffic", 4), (4, True, 3, "slows_traffic", 3)],
    },
    {
        "ticket": "FS-GHMC-003", "ward": 94, "category": "damaged_surface", "severity": 3,
        "report_count": 1, "d_lat": 0.0010, "d_lon": 0.0030, "days": 12,
        "description": "Cracked and uneven carriageway near Tarnaka junction after a utility trench cut was patched poorly.",
        "impact": "slows_traffic",
        "surveys": [(5, True, 3, "slows_traffic", 11), (6, True, 3, "vehicle_damage", 7)],
    },
    {
        "ticket": "FS-GHMC-004", "ward": 95, "category": "other", "severity": 4,
        "report_count": 3, "d_lat": -0.0020, "d_lon": -0.0025, "days": 14,
        "description": "Sewage overflowing from a choked line onto the road near Pathergatti market; stench and standing wastewater.",
        "impact": "ecosystem_sewage",
        "surveys": [(1, True, 4, "ecosystem_sewage", 13), (2, True, 5, "ecosystem_sewage", 9), (7, True, 4, "ecosystem_sewage", 3)],
    },
    {
        "ticket": "FS-CMC-001", "ward": 202, "category": "waterlogging", "severity": 3,
        "report_count": 4, "d_lat": 0.0030, "d_lon": 0.0010, "days": 10,
        "description": "Recurring waterlogging on the Gachibowli service road below the IT corridor underpass; reported repeatedly after every shower.",
        "impact": "blocks_road",
        "surveys": [(0, True, 4, "blocks_road", 9), (3, True, 3, "blocks_road", 8), (5, True, 4, "slows_traffic", 4), (6, True, 3, "blocks_road", 1)],
    },
    {
        "ticket": "FS-CMC-002", "ward": 203, "category": "pothole", "severity": 2,
        "report_count": 1, "d_lat": -0.0010, "d_lon": -0.0020, "days": 6,
        "description": "Medium pothole in the left lane of the Madhapur main road near a bus stop; patch has started to wash out.",
        "impact": "slows_traffic",
        "surveys": [(2, True, 2, "slows_traffic", 5)],
    },
    {
        "ticket": "FS-CMC-003", "ward": 204, "category": "open_manhole", "severity": 3,
        "report_count": 1, "d_lat": 0.0020, "d_lon": 0.0015, "days": 0,
        "description": "Manhole cover missing on an internal KPHB Colony road; unmarked and hard to see after dark.",
        "impact": "injury_risk",
        "surveys": [],
    },
    {
        "ticket": "FS-CMC-004", "ward": 205, "category": "waterlogging", "severity": 3,
        "report_count": 2, "d_lat": -0.0025, "d_lon": 0.0022, "days": 11,
        "description": "Nala overflow spills over the Jeedimetla approach road, carrying industrial runoff into the adjacent low-lying area.",
        "impact": "ecosystem_sewage",
        "surveys": [(4, True, 4, "ecosystem_sewage", 10), (7, True, 4, "ecosystem_sewage", 5)],
    },
    {
        "ticket": "FS-MMC-001", "ward": 301, "category": "pothole", "severity": 3,
        "report_count": 2, "d_lat": 0.0012, "d_lon": -0.0030, "days": 8,
        "description": "Large pothole on the Malkajgiri main road near the railway underpass; vehicles brake hard before it.",
        "impact": "vehicle_damage",
        "surveys": [(1, True, 3, "vehicle_damage", 7), (6, True, 3, "slows_traffic", 2)],
    },
    {
        "ticket": "FS-MMC-002", "ward": 302, "category": "broken_divider", "severity": 4,
        "report_count": 2, "d_lat": -0.0018, "d_lon": 0.0008, "days": 13,
        "description": "Median divider broken and leaning into the carriageway on the Ramanthapur stretch; exposed rebar at wheel height.",
        "impact": "injury_risk",
        "surveys": [(0, True, 4, "injury_risk", 12), (4, True, 5, "injury_risk", 6)],
    },
    {
        "ticket": "FS-MMC-003", "ward": 303, "category": "other", "severity": 2,
        "report_count": 1, "d_lat": 0.0025, "d_lon": -0.0010, "days": 0,
        "description": "Construction debris piled on the carriageway edge in Vanasthalipuram, narrowing the lane.",
        "impact": "slows_traffic",
        "surveys": [],
    },
    {
        "ticket": "FS-MMC-004", "ward": 304, "category": "damaged_surface", "severity": 2,
        "report_count": 1, "d_lat": 0.0008, "d_lon": 0.0020, "days": 20,
        "description": "Eroded asphalt edge on a Kapra connector road; since relaid by the corporation according to residents.",
        "impact": "no_impact",
        "surveys": [(2, False, None, None, 6), (3, False, None, None, 5), (5, False, None, None, 4)],
    },
]

# Twenty mapped Hyderabad road stretches, each with five distinct condition
# reports below. Coordinates are approximate points for demo/test data; these
# rows retain source='demo_seed' and are not represented as verified tickets.
# Tuple: road/landmark, locality, corporation, zone, latitude, longitude, mail tag, local detail.
_HYD_CORRIDORS = [
    ("ISB Road, Gachibowli", "Gachibowli", "CMC", "Serilingampally Zone", 17.4405, 78.3472, "cmc-gachibowli", "the Wipro Circle service lane"),
    ("Durgam Cheruvu Cable Bridge approach", "Madhapur", "CMC", "Serilingampally Zone", 17.4320, 78.3910, "cmc-madhapur", "the Jubilee Enclave turn"),
    ("Madhapur Cyber Towers junction", "Madhapur", "CMC", "Serilingampally Zone", 17.4434, 78.3772, "cmc-madhapur", "the Cyber Towers bus stop"),
    ("Kukatpally Y-Junction", "Kukatpally", "CMC", "Kukatpally Zone", 17.4935, 78.3995, "cmc-kukatpally", "the JNTU-bound slip lane"),
    ("Miyapur Metro Pillar 612", "Miyapur", "CMC", "Serilingampally Zone", 17.4964, 78.3565, "cmc-miyapur", "the station-side bus bay"),
    ("Banjara Hills Road No. 12", "Banjara Hills", "GHMC", "Khairatabad Zone", 17.4142, 78.4487, "ghmc-banjarahills", "the KBR Park approach"),
    ("Jubilee Hills Checkpost junction", "Jubilee Hills", "GHMC", "Khairatabad Zone", 17.4312, 78.4078, "ghmc-jubileehills", "the Film Nagar turn"),
    ("Tarnaka Flyover stretch", "Tarnaka", "GHMC", "Secunderabad Zone", 17.4275, 78.5325, "ghmc-tarnaka", "the Habsiguda-bound merge"),
    ("Secunderabad Station Road", "Secunderabad", "GHMC", "Secunderabad Zone", 17.4340, 78.5010, "ghmc-secunderabad", "the station forecourt bus stop"),
    ("Begumpet SP Road", "Begumpet", "GHMC", "Secunderabad Zone", 17.4437, 78.4621, "ghmc-begumpet", "the Prakash Nagar crossing"),
    ("Ameerpet Metro stretch", "Ameerpet", "GHMC", "Khairatabad Zone", 17.4373, 78.4480, "ghmc-ameerpet", "the Maitrivanam bus bay"),
    ("Uppal Ring Road", "Uppal", "MMC", "Uppal Zone", 17.4050, 78.5590, "mmc-uppal", "the Nagole-bound service lane"),
    ("LB Nagar X-Roads", "LB Nagar", "MMC", "LB Nagar Zone", 17.3453, 78.5520, "mmc-lbnagar", "the Victoria Memorial turn"),
    ("Saidabad-Chanchalguda corridor", "Saidabad", "GHMC", "Charminar Zone", 17.3690, 78.5050, "ghmc-saidabad", "the Chanchalguda junction"),
    ("Aramghar X-Roads", "Aramghar", "GHMC", "Rajendranagar Zone", 17.3210, 78.4310, "ghmc-aramghar", "the airport-bound slip road"),
    ("Mehdipatnam PVNR Expressway ramp", "Mehdipatnam", "GHMC", "Khairatabad Zone", 17.3930, 78.4400, "ghmc-mehdipatnam", "the Gudimalkapur-side ramp"),
    ("Malkajgiri Anutex junction", "Malkajgiri", "MMC", "Malkajgiri Zone", 17.4560, 78.5270, "mmc-malkajgiri", "the Anutex shopping complex entrance"),
    ("ECIL X-Roads", "ECIL", "MMC", "Kapra Zone", 17.4780, 78.5630, "mmc-ecil", "the A.S. Rao Nagar-bound crossing"),
    ("Kompally NH-44 service road", "Kompally", "MMC", "Alwal Zone", 17.5370, 78.4880, "mmc-kompally", "the Suchitra-bound service lane"),
    ("Jeedimetla approach road", "Jeedimetla", "CMC", "Qutbullapur Zone", 17.5110, 78.4400, "cmc-jeedimetla", "the industrial estate bus stop"),
]

_HYD_REPORT_VARIANTS = [
    (
        "pothole", 2, "community_pending", "slows_traffic",
        "A shallow pothole has opened on {road} near {detail}; residents report that two-wheelers are moving around it into the next lane.",
    ),
    (
        "damaged_surface", 3, "resolved", "no_impact",
        "The broken asphalt reported on {road} by {detail} was patched during a follow-up visit; nearby commuters say the repaired section is passable and the report is marked resolved.",
    ),
    (
        "waterlogging", 3, "active_hazard", "slows_traffic",
        "After evening showers, rainwater remains across the kerb lane on {road} near {detail}; traffic slows while the storm-water inlet drains down.",
    ),
    (
        "open_manhole", 4, "active_hazard", "injury_risk",
        "A displaced manhole cover leaves a drop in the wheel path on {road} beside {detail}; drivers are steering into adjacent traffic to avoid it.",
    ),
    (
        "other", 3, "active_hazard", "ecosystem_sewage",
        "A choked nala is spilling wastewater onto {road} near {detail}; the wet carriageway and strong odour are affecting pedestrians and commuters.",
    ),
]


async def ensure_hyd_demo_issues(connection) -> int:
    """Idempotently ensure 100 descriptive Hyderabad corridor seed records."""
    current = await connection.fetchval(
        """SELECT COUNT(*) FROM road_issues
           WHERE source = 'demo_seed' AND external_ticket_id LIKE 'HYD-ROAD-%'"""
    )
    if current >= 100:
        return int(current)

    now = datetime.now(timezone.utc)
    for corridor_index, corridor in enumerate(_HYD_CORRIDORS, start=1):
        road, locality, corporation, zone, latitude, longitude, tag, detail = corridor
        designation = f"{_DESIGNATION[corporation]}, {zone} ({corporation})"
        for variant_index, (category, severity, status, impact, template) in enumerate(
            _HYD_REPORT_VARIANTS, start=1
        ):
            ticket = f"HYD-ROAD-{corridor_index:02d}-{variant_index}"
            offset = (variant_index - 3) * 0.00018
            description = template.format(road=road, detail=detail)
            await connection.execute(
                """
                INSERT INTO road_issues (
                    category, severity, confidence_score, report_count, description,
                    location, source, external_ticket_id, status, impact_mcq,
                    corporation, zone, ward_name, authority_designation,
                    authority_email, created_at, source_url
                ) VALUES (
                    $1::hazard_category, $2::smallint, 1.0, 1, $3,
                    ST_SetSRID(ST_MakePoint($4::float8, $5::float8), 4326),
                    'demo_seed', $6, $7::hazard_status, $8,
                    $9, $10, $11, $12, $13,
                    $14::timestamptz, NULL
                )
                ON CONFLICT (source, external_ticket_id)
                    WHERE external_ticket_id IS NOT NULL
                DO UPDATE SET
                    category = EXCLUDED.category,
                    severity = EXCLUDED.severity,
                    description = EXCLUDED.description,
                    location = EXCLUDED.location,
                    status = EXCLUDED.status,
                    impact_mcq = EXCLUDED.impact_mcq,
                    corporation = EXCLUDED.corporation,
                    zone = EXCLUDED.zone,
                    ward_name = EXCLUDED.ward_name,
                    authority_designation = EXCLUDED.authority_designation,
                    authority_email = EXCLUDED.authority_email
                """,
                category, severity, description,
                longitude + offset, latitude + offset,
                ticket, status, impact,
                corporation, zone, locality, designation, _demo_email(tag),
                now - timedelta(days=(corridor_index + variant_index) % 24),
            )
    return 100


async def _seed_wards(connection) -> None:
    for ward_no, corp, zone, name, lat, lon, tag in _WARDS:
        await connection.execute(
            """
            INSERT INTO hyd_wards (
                ward_no, corporation, zone, ward_name,
                authority_designation, authority_email, geom
            ) VALUES ($1, $2, $3, $4, $5, $6, ST_GeomFromText($7, 4326))
            ON CONFLICT (ward_no) DO UPDATE SET
                corporation = EXCLUDED.corporation,
                zone = EXCLUDED.zone,
                ward_name = EXCLUDED.ward_name,
                authority_designation = EXCLUDED.authority_designation,
                authority_email = EXCLUDED.authority_email,
                geom = EXCLUDED.geom
            """,
            ward_no, corp, zone, name,
            f"{_DESIGNATION[corp]}, {zone} ({corp})",
            _demo_email(tag),
            _ward_wkt(lat, lon),
        )


async def _seed_field_issues(connection) -> None:
    centres = {w[0]: (w[4], w[5]) for w in _WARDS}
    now = datetime.now(timezone.utc)
    for item in _SEED_ISSUES:
        lat0, lon0 = centres[item["ward"]]
        surveys = item["surveys"]
        confirms = sum(1 for s in surveys if s[1])
        resolves = len(surveys) - confirms
        confidence = 1.0 + 0.5 * confirms - 0.75 * resolves
        status = (
            "resolved" if confidence <= 0.0
            else "active_hazard" if confidence > 1.0
            else "community_pending"
        )
        issue_id = await connection.fetchval(
            """
            INSERT INTO road_issues (
                category, severity, confidence_score, report_count, description,
                location, source, external_ticket_id, status, impact_mcq,
                image_urls, corporation, zone, ward_no, ward_name,
                authority_designation, authority_email, created_at
            )
            SELECT $1::hazard_category, $2::smallint, $3::double precision,
                   $4::int, $5::text,
                   ST_SetSRID(ST_MakePoint($6::float8, $7::float8), 4326),
                   'field_survey', $8::text, $9::hazard_status, $10::text,
                   '[]'::jsonb, w.corporation, w.zone, w.ward_no, w.ward_name,
                   w.authority_designation, w.authority_email, $11::timestamptz
            FROM hyd_wards w WHERE w.ward_no = $12::int
            ON CONFLICT (source, external_ticket_id)
                WHERE external_ticket_id IS NOT NULL DO NOTHING
            RETURNING id
            """,
            item["category"], item["severity"], confidence, item["report_count"],
            item["description"], lon0 + item["d_lon"], lat0 + item["d_lat"],
            item["ticket"], status, item["impact"],
            now - timedelta(days=item["days"]), item["ward"],
        )
        if issue_id is None:  # already seeded on a previous start
            continue
        for user_idx, present, score, impact, days_ago in surveys:
            await connection.execute(
                """
                INSERT INTO verification_votes (
                    issue_id, user_id, vote_type, still_present,
                    condition_score, impact_mcq, created_at
                ) VALUES ($1, $2, $3::verification_vote_type, $4, $5, $6, $7)
                ON CONFLICT (issue_id, user_id) DO NOTHING
                """,
                issue_id, _demo_user(user_idx % _DEMO_USERS),
                "CONFIRM" if present else "RESOLVED", present, score, impact,
                now - timedelta(days=days_ago),
            )


async def _apply_geo_and_survey_schema(connection) -> None:
    await connection.execute(
        """
        CREATE TABLE IF NOT EXISTS hyd_wards (
            ward_no INT PRIMARY KEY,
            corporation VARCHAR(16) NOT NULL,
            zone VARCHAR(64) NOT NULL,
            ward_name VARCHAR(128) NOT NULL,
            authority_designation VARCHAR(256) NOT NULL,
            authority_email VARCHAR(256) NOT NULL,
            geom GEOMETRY(Polygon, 4326) NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_hyd_wards_geom ON hyd_wards USING GIST (geom);

        ALTER TABLE road_issues
            ADD COLUMN IF NOT EXISTS corporation VARCHAR(16),
            ADD COLUMN IF NOT EXISTS zone VARCHAR(64),
            ADD COLUMN IF NOT EXISTS ward_no INT,
            ADD COLUMN IF NOT EXISTS ward_name VARCHAR(128),
            ADD COLUMN IF NOT EXISTS authority_designation VARCHAR(256),
            ADD COLUMN IF NOT EXISTS authority_email VARCHAR(256),
            ADD COLUMN IF NOT EXISTS status_color VARCHAR(8) NOT NULL DEFAULT 'GREEN'
                CHECK (status_color IN ('GREEN', 'BLUE', 'YELLOW', 'ORANGE', 'RED')),
            ADD COLUMN IF NOT EXISTS impact_mcq TEXT,
            ADD COLUMN IF NOT EXISTS source_url TEXT,
            ADD COLUMN IF NOT EXISTS image_urls JSONB NOT NULL DEFAULT '[]'::jsonb;

        ALTER TABLE verification_votes
            ADD COLUMN IF NOT EXISTS still_present BOOLEAN,
            ADD COLUMN IF NOT EXISTS condition_score SMALLINT
                CHECK (condition_score BETWEEN 1 AND 5),
            ADD COLUMN IF NOT EXISTS impact_mcq TEXT;

        CREATE INDEX IF NOT EXISTS idx_road_issues_ward ON road_issues (ward_no);

        -- BLUE resolved > RED ecosystem/sewage/nala > ORANGE severe or ignored
        -- > YELLOW active ongoing > GREEN newly registered.
        CREATE OR REPLACE FUNCTION rcmc_status_color(
            p_status TEXT, p_severity INT, p_report_count INT,
            p_description TEXT, p_impact TEXT
        ) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
            SELECT CASE
                WHEN p_status = 'resolved' THEN 'BLUE'
                WHEN COALESCE(p_impact, '') ~* '(ecosystem|sewage|sewer|nala)'
                  OR COALESCE(p_description, '')
                        ~* '\\m(ecosystem|sewage|sewerage|sewer|nala|nalla)\\M'
                    THEN 'RED'
                WHEN p_severity >= 4 OR p_report_count >= 3 THEN 'ORANGE'
                WHEN p_status IN ('active_hazard', 'verified_ghmc') THEN 'YELLOW'
                ELSE 'GREEN'
            END
        $$;

        CREATE OR REPLACE FUNCTION trg_road_issues_status_color()
        RETURNS TRIGGER AS $$
        BEGIN
            NEW.status_color := rcmc_status_color(
                NEW.status::text, NEW.severity, NEW.report_count,
                NEW.description, NEW.impact_mcq
            );
            RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;

        DROP TRIGGER IF EXISTS trg_road_issues_status_color ON road_issues;
        CREATE TRIGGER trg_road_issues_status_color
            BEFORE INSERT OR UPDATE ON road_issues
            FOR EACH ROW EXECUTE FUNCTION trg_road_issues_status_color();
        """
    )
    # Remove rows from the earlier generic demo generator when upgrading an
    # existing database. The replacement Hyderabad corridor seeds are loaded
    # by db/init/002_seed_demo.sql and are explicitly illustrative, not official.
    await connection.execute(
        """
        DELETE FROM road_issues
        WHERE source = 'demo_seed'
          AND description LIKE 'Synthetic demo road issue #%'
        """
    )
    await _seed_wards(connection)

    # Backfill rows created before these columns existed (no-op on later starts).
    await connection.execute(
        """
        UPDATE road_issues AS r
        SET corporation = w.corporation, zone = w.zone, ward_no = w.ward_no,
            ward_name = w.ward_name,
            authority_designation = w.authority_designation,
            authority_email = w.authority_email
        FROM hyd_wards AS w
        WHERE r.ward_no IS NULL
          AND w.ward_no = (
              SELECT n.ward_no FROM hyd_wards AS n
              ORDER BY NOT ST_Contains(n.geom, r.location), n.geom <-> r.location
              LIMIT 1
          )
        """
    )
    await connection.execute(
        """
        UPDATE road_issues
        SET status_color = rcmc_status_color(
            status::text, severity, report_count, description, impact_mcq)
        WHERE status_color IS DISTINCT FROM rcmc_status_color(
            status::text, severity, report_count, description, impact_mcq)
        """
    )
    await _seed_field_issues(connection)
    await ensure_hyd_demo_issues(connection)


async def apply_migrations(pool, migration_dir: Path) -> None:
    if not migration_dir.exists():
        return
    base_schema = migration_dir.parent / "init" / "001_schema.sql"
    async with pool.acquire() as connection:
        async with connection.transaction():
            await connection.execute("SELECT pg_advisory_xact_lock(731904222)")
            if base_schema.exists():
                await connection.execute(base_schema.read_text(encoding="utf-8"))
            await connection.execute(
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    name TEXT PRIMARY KEY,
                    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
            applied = {
                row["name"]
                for row in await connection.fetch("SELECT name FROM schema_migrations")
            }
            for migration in sorted(migration_dir.glob("*.sql")):
                if migration.name in applied:
                    continue
                await connection.execute(migration.read_text(encoding="utf-8"))
                await connection.execute(
                    "INSERT INTO schema_migrations (name) VALUES ($1)", migration.name
                )
            await _apply_geo_and_survey_schema(connection)
