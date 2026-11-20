"""Import relevant public Hyderabad civic/traffic RSS reports into road_issues.

The default source is The Hindu's Hyderabad city RSS feed. Feed entries are
news leads, not verified municipal tickets; each stored row keeps the article
URL and is marked community_pending. Only entries naming a known locality are
stored, because a city-wide story cannot safely be assigned invented point
coordinates. Set HYD_CIVIC_RSS_URLS to a comma-separated list of public RSS
feeds if additional sources are desired.
"""

from __future__ import annotations

import asyncio
import hashlib
import html
import logging
import os
import re
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path

import asyncpg
import httpx

from .database import database_url
from .migrations import apply_migrations
from .services.geocoding import find_hyderabad_locality

logger = logging.getLogger("rcmc.hyd_civic_scraper")
DEFAULT_FEEDS = (
    "https://www.thehindu.com/news/cities/Hyderabad/feeder/default.rss",
    "https://www.siasat.com/category/top-stories/feed/",
)
LIVE_HEADLINE_FALLBACKS = (
    "https://news.google.com/rss/search?q=Hyderabad+GHMC+roads+potholes+waterlogging&hl=en-IN&gl=IN&ceid=IN:en",
    "https://news.google.com/rss/search?q=Hyderabad+traffic+drainage+municipal+road&hl=en-IN&gl=IN&ceid=IN:en",
)
_RELEVANT = re.compile(
    r"\b(ghmc|pothole|waterlogging|flooding|drain|drainage|"
    r"road damage|damaged road|road repair|traffic|civic|sewage|manhole)\b",
    re.IGNORECASE,
)


class _TextOnly(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        self.parts.append(data)


def _plain_text(value: str) -> str:
    parser = _TextOnly()
    parser.feed(value or "")
    return re.sub(r"\s+", " ", html.unescape(" ".join(parser.parts))).strip()


def _child_text(item: ET.Element, *names: str) -> str:
    for name in names:
        node = item.find(name)
        if node is not None and node.text:
            return node.text.strip()
    # RSS extensions often use namespace-qualified tags such as content:encoded.
    wanted = set(names)
    for node in item.iter():
        if node.tag.rsplit("}", 1)[-1] in wanted and node.text:
            return node.text.strip()
    return ""


def _category(text: str) -> tuple[str, int]:
    value = text.casefold()
    if any(word in value for word in ("waterlog", "waterlogging", "flood", "stagnant water")):
        return "waterlogging", 3
    if "pothole" in value:
        return "pothole", 3
    if "manhole" in value or "open drain" in value:
        return "open_manhole", 4
    if any(word in value for word in ("sewage", "drain", "nala", "nalla")):
        return "other", 3
    if any(word in value for word in ("damaged road", "road damage", "road repair")):
        return "damaged_surface", 3
    return "other", 2


def _feed_urls() -> list[str]:
    configured = os.getenv("HYD_CIVIC_RSS_URLS", "").strip()
    values = [*DEFAULT_FEEDS, *(configured.split(",") if configured else [])]
    return list(dict.fromkeys(url.strip() for url in values if url.strip()))


async def _upsert_article(
    pool, title: str, summary: str, link: str, *, search_scoped: bool = False
) -> bool:
    if not title or not link:
        return False
    article_text = f"{title}. {summary}".strip()
    if not search_scoped and not _RELEVANT.search(article_text):
        return False
    locality = find_hyderabad_locality(article_text)
    if locality is None:
        logger.info("Skipping civic article without a named locality: %s", title[:120])
        return False

    category, severity = _category(article_text)
    digest = hashlib.sha256(link.strip().encode("utf-8")).hexdigest()[:40]
    # Keep the RSS-provided summary short and retain the original article link.
    description = f"News report: {title.strip()}. {_plain_text(summary)[:700]} Source: {link}"
    async with pool.acquire() as connection:
        await connection.execute(
            """
            INSERT INTO road_issues (
                category, severity, confidence_score, report_count, description,
                location, source, external_ticket_id, status, source_url, corporation,
                zone, ward_no, ward_name, authority_designation, authority_email,
                impact_mcq
            )
            SELECT $1::hazard_category, $2::smallint, 1.0, 1, $3::text,
                   ST_SetSRID(ST_MakePoint($4::float8, $5::float8), 4326),
                   'civic_news_scraper', $7::text, 'community_pending'::hazard_status, $6::text,
                   w.corporation, w.zone, w.ward_no, w.ward_name,
                   w.authority_designation, w.authority_email,
                   'news_report; commuter impact requires field verification'
            FROM hyd_wards AS w
            ORDER BY NOT ST_Contains(
                w.geom,
                ST_SetSRID(ST_MakePoint($4::float8, $5::float8), 4326)
            ), w.geom <-> ST_SetSRID(ST_MakePoint($4::float8, $5::float8), 4326)
            LIMIT 1
            ON CONFLICT (source, external_ticket_id)
                WHERE external_ticket_id IS NOT NULL
            DO UPDATE SET
                category = EXCLUDED.category,
                severity = EXCLUDED.severity,
                description = EXCLUDED.description,
                source_url = EXCLUDED.source_url,
                location = EXCLUDED.location,
                corporation = EXCLUDED.corporation,
                zone = EXCLUDED.zone,
                ward_no = EXCLUDED.ward_no,
                ward_name = EXCLUDED.ward_name,
                authority_designation = EXCLUDED.authority_designation,
                authority_email = EXCLUDED.authority_email,
                status = CASE WHEN road_issues.status = 'resolved'
                              THEN road_issues.status ELSE EXCLUDED.status END,
                updated_at = NOW()
            """,
            category,
            severity,
            description[:1200],
            locality["longitude"],
            locality["latitude"],
            link.strip(),
            digest,
        )
    return True


async def _scrape_feed(pool, client: httpx.AsyncClient, feed_url: str, *, search_scoped=False) -> int:
    response = await client.get(feed_url)
    response.raise_for_status()
    root = ET.fromstring(response.content)
    items = [node for node in root.iter() if node.tag.rsplit("}", 1)[-1] in {"item", "entry"}]
    imported = 0
    for item in items:
        title = _child_text(item, "title")
        summary = _child_text(item, "description", "summary", "encoded", "content")
        link = _child_text(item, "link")
        if not link:
            link_node = next(
                (node for node in item if node.tag.rsplit("}", 1)[-1] == "link"),
                None,
            )
            if link_node is not None:
                link = link_node.attrib.get("href", "")
        if await _upsert_article(pool, title, summary, link, search_scoped=search_scoped):
            imported += 1
    return imported


async def scrape_feeds(pool) -> int:
    """Fetch public local RSS sources, using live Google News queries as fallback."""
    async with httpx.AsyncClient(
        timeout=httpx.Timeout(6.0), follow_redirects=True,
        headers={"User-Agent": "RCMC-Hyderabad-Civic-News-Scraper/1.0"},
    ) as client:
        async def scrape_group(urls: tuple[str, ...] | list[str], *, search_scoped=False) -> int:
            results = await asyncio.gather(
                *(
                    _scrape_feed(pool, client, url, search_scoped=search_scoped)
                    for url in urls
                ),
                return_exceptions=True,
            )
            count = 0
            for url, result in zip(urls, results):
                if isinstance(result, asyncio.CancelledError):
                    raise result
                if isinstance(result, Exception):
                    logger.warning("RSS feed fetch failed url=%s error=%s", url, type(result).__name__)
                else:
                    count += result
            return count

        total = await scrape_group(_feed_urls())
        if total == 0:
            total = await scrape_group(LIVE_HEADLINE_FALLBACKS, search_scoped=True)
    return total


async def scrape_once() -> int:
    pool = await asyncpg.create_pool(database_url(), min_size=1, max_size=3)
    migration_dir = Path(__file__).resolve().parents[2] / "db" / "migrations"
    try:
        await apply_migrations(pool, migration_dir)
        return await scrape_feeds(pool)
    finally:
        await pool.close()


if __name__ == "__main__":
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
    count = asyncio.run(scrape_once())
    logger.info("Imported or refreshed %d Hyderabad civic news issue(s)", count)
