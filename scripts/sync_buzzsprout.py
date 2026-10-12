#!/usr/bin/env python3
"""Merge Buzzsprout RSS episodes into the permanent static site archive.

Run from any directory with: python scripts/sync_buzzsprout.py
For offline checks: python scripts/sync_buzzsprout.py --feed-file scripts/fixtures/buzzsprout-sample.xml
"""

from __future__ import annotations

import argparse
import email.utils
import html
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_PATH = ROOT / "content" / "episodes.json"
PODCAST_INDEX = ROOT / "podcast" / "index.html"
EPISODES_DIR = ROOT / "podcast" / "episodes"
FEED_URL = "https://rss.buzzsprout.com/2606659.rss"
MANAGED_START = "<!-- BUZZSPROUT_IMPORTS_START -->"
MANAGED_END = "<!-- BUZZSPROUT_IMPORTS_END -->"
NS = {
    "itunes": "http://www.itunes.com/dtds/podcast-1.0.dtd",
    "content": "http://purl.org/rss/1.0/modules/content/",
}


class FeedError(Exception):
    """An unavailable, invalid, or unusable RSS feed."""


class TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        value = " ".join(data.split())
        if value:
            self.parts.append(value)


def plain_text(value: str | None) -> str:
    if not value:
        return ""
    parser = TextExtractor()
    parser.feed(html.unescape(value))
    parser.close()
    return " ".join(" ".join(parser.parts).split())


def child_text(parent: ET.Element, path: str) -> str:
    child = parent.find(path, NS)
    return (child.text or "").strip() if child is not None else ""


def parse_date(value: str) -> str | None:
    if not value:
        return None
    try:
        parsed = email.utils.parsedate_to_datetime(value)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    except (TypeError, ValueError, OverflowError):
        return None


def episode_number(item: ET.Element, title: str) -> int | None:
    number = child_text(item, "itunes:episode")
    if number.isdigit() and int(number) > 0:
        return int(number)
    match = re.search(r"\b(?:episode|ep\.?)[\s#:-]*(\d+)\b", title, re.IGNORECASE)
    return int(match.group(1)) if match else None


def parse_feed(xml_bytes: bytes) -> list[dict[str, Any]]:
    """Parse RSS 2.0 before any archive or site file is modified."""
    if re.search(br"<!\s*(?:DOCTYPE|ENTITY)\b", xml_bytes, re.IGNORECASE):
        raise FeedError("The feed contains a prohibited XML declaration.")
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError as exc:
        raise FeedError(f"The RSS feed is malformed: {exc}") from exc
    if root.tag != "rss":
        raise FeedError("The response is not an RSS 2.0 feed.")
    channel = root.find("channel")
    if channel is None:
        raise FeedError("The RSS feed is missing its channel.")

    items: list[dict[str, Any]] = []
    for position, item in enumerate(channel.findall("item")):
        title = child_text(item, "title")
        enclosure = item.find("enclosure")
        audio_url = enclosure.get("url", "").strip() if enclosure is not None else ""
        link = child_text(item, "link")
        guid = child_text(item, "guid") or audio_url or link
        if not title or not guid:
            # An item without an identity or title cannot be safely archived.
            continue
        description = (
            child_text(item, "content:encoded")
            or child_text(item, "itunes:summary")
            or child_text(item, "description")
        )
        artwork_element = item.find("itunes:image", NS)
        artwork = artwork_element.get("href", "").strip() if artwork_element is not None else ""
        items.append(
            {
                "guid": guid,
                "episode_number": episode_number(item, title),
                "title": plain_text(title),
                "description": plain_text(description),
                "published_at": parse_date(child_text(item, "pubDate")),
                "audio_url": audio_url,
                "audio_type": enclosure.get("type", "").strip() if enclosure is not None else "",
                "duration": child_text(item, "itunes:duration") or None,
                "link": link,
                "artwork_url": artwork,
                "_position": position,
            }
        )
    if not items and channel.findall("item"):
        raise FeedError("The RSS feed has items, but none have a usable title and stable identifier.")
    return items


def read_feed(url: str, feed_file: Path | None = None) -> bytes:
    if feed_file:
        try:
            return feed_file.read_bytes()
        except OSError as exc:
            raise FeedError(f"Could not read fixture {feed_file}: {exc}") from exc
    request = urllib.request.Request(url, headers={"User-Agent": "HolotableChaosRSSSync/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            if response.status < 200 or response.status >= 300:
                raise FeedError(f"RSS server returned HTTP {response.status}.")
            data = response.read(10 * 1024 * 1024 + 1)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise FeedError(f"Could not fetch Buzzsprout RSS: {exc}") from exc
    if len(data) > 10 * 1024 * 1024:
        raise FeedError("The RSS response exceeded the 10 MB safety limit.")
    return data


def read_archive(path: Path = ARCHIVE_PATH) -> dict[str, Any]:
    try:
        archive = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise FeedError(f"Could not read the permanent episode archive: {exc}") from exc
    if not isinstance(archive, dict) or not isinstance(archive.get("episodes"), list):
        raise FeedError("The permanent episode archive has an invalid structure.")
    return archive


def _clean_summary(description: str) -> str:
    if not description:
        return "Listen to the latest Holotable Chaos episode."
    if len(description) <= 210:
        return description
    return description[:207].rsplit(" ", 1)[0].rstrip(" .,;:") + "…"


def _find_match(episodes: list[dict[str, Any]], item: dict[str, Any]) -> dict[str, Any] | None:
    guid = item["guid"]
    number = item.get("episode_number")
    def title_key(value: str) -> str:
        value = re.sub(r"^(?:episode|ep\.?)\s*\d+\s*[:—–-]?\s*", "", value, flags=re.IGNORECASE)
        return re.sub(r"[^a-z0-9]+", "", value.lower())

    current_title_key = title_key(item["title"])
    for episode in episodes:
        if guid == episode.get("guid") or guid in episode.get("alternate_guids", []):
            return episode
    # Pre-GUID catalog entries and feed records from a republished item can
    # still be associated by matching number and title, never by number alone.
    for episode in episodes:
        existing_title = title_key(episode.get("title", ""))
        same_title = current_title_key and current_title_key == existing_title
        same_number = number and episode.get("episode_number") == number
        if same_title and (same_number or not number):
            return episode
    return None


def merge_items(archive: dict[str, Any], feed_items: list[dict[str, Any]]) -> tuple[dict[str, Any], list[dict[str, Any]], int]:
    episodes = archive["episodes"]
    by_guid: dict[str, dict[str, Any]] = {}
    for episode in episodes:
        if episode.get("guid"):
            by_guid[episode["guid"]] = episode
        for alias in episode.get("alternate_guids", []):
            by_guid[alias] = episode

    additions: list[dict[str, Any]] = []
    updated = 0
    used_numbers = {int(entry.get("episode_number", 0)) for entry in episodes}
    max_number = max(used_numbers, default=0)
    seen_in_feed: set[str] = set()
    ordered = sorted(
        feed_items,
        key=lambda entry: (entry.get("published_at") or "9999-12-31T23:59:59Z", entry["_position"]),
    )
    for item in ordered:
        guid = item["guid"]
        if guid in seen_in_feed:
            continue
        seen_in_feed.add(guid)
        match = _find_match(episodes, item)
        if match:
            if guid != match.get("guid") and guid not in match.setdefault("alternate_guids", []):
                match["alternate_guids"].append(guid)
                updated += 1
            for field in ("published_at", "description", "audio_url", "audio_type", "duration", "link", "artwork_url"):
                if not match.get(field) and item.get(field):
                    match[field] = item[field]
                    updated += 1
            continue

        requested_number = item.get("episode_number")
        if requested_number and int(requested_number) not in used_numbers:
            max_number = max(max_number, int(requested_number))
            assigned_number = int(requested_number)
        else:
            max_number += 1
            while max_number in used_numbers:
                max_number += 1
            assigned_number = max_number
        used_numbers.add(assigned_number)
        new_episode = {
            "guid": guid,
            "alternate_guids": [],
            "episode_number": assigned_number,
            "title": item["title"],
            "description": item.get("description", ""),
            "summary": _clean_summary(item.get("description", "")),
            "published_at": item.get("published_at"),
            "audio_url": item.get("audio_url", ""),
            "audio_type": item.get("audio_type", ""),
            "duration": item.get("duration"),
            "link": item.get("link", ""),
            "artwork_url": item.get("artwork_url", ""),
            "source": "buzzsprout",
        }
        episodes.append(new_episode)
        additions.append(new_episode)
        by_guid[guid] = new_episode

    archive["episodes"] = sorted(
        episodes,
        key=lambda entry: (entry.get("published_at") or "0000-01-01T00:00:00Z", entry.get("episode_number", 0)),
        reverse=True,
    )
    return archive, additions, updated


def _write_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", newline="\n", dir=path.parent, delete=False) as temporary:
            temporary.write(content)
            temporary_name = temporary.name
        os.replace(temporary_name, path)
    except OSError:
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
        raise


def save_archive(archive: dict[str, Any], path: Path = ARCHIVE_PATH) -> None:
    text = json.dumps(archive, ensure_ascii=False, indent=2) + "\n"
    _write_atomic(path, text)


def render_archive_cards(episodes: list[dict[str, Any]]) -> str:
    imported = [episode for episode in episodes if episode.get("source") == "buzzsprout"]
    imported.sort(key=lambda episode: (episode.get("published_at") or "0000-01-01T00:00:00Z", episode.get("episode_number", 0)), reverse=True)
    cards = []
    for episode in imported:
        number = int(episode["episode_number"])
        title = html.escape(episode.get("title") or f"Episode {number}")
        summary = html.escape(episode.get("summary") or _clean_summary(episode.get("description", "")))
        cards.append(
            f'<article class="episode-card"><span class="card-kicker">EPISODE {number}</span>'
            f'<h2>{title}</h2><p class="episode-description">{summary}</p>'
            f'<a class="transcript-link" href="episodes/episode-{number}.html">Open episode <span aria-hidden="true">↗</span></a></article>'
        )
    return "\n          ".join(cards)


def update_index(episodes: list[dict[str, Any]], path: Path = PODCAST_INDEX) -> None:
    current = path.read_text(encoding="utf-8")
    if current.count(MANAGED_START) != 1 or current.count(MANAGED_END) != 1:
        raise FeedError("The podcast archive is missing its RSS-managed episode markers.")
    start = current.index(MANAGED_START) + len(MANAGED_START)
    end = current.index(MANAGED_END)
    if end < start:
        raise FeedError("The podcast archive markers are out of order.")
    generated = render_archive_cards(episodes)
    replacement = "\n          " + generated + "\n          " if generated else "\n          "
    updated = current[:start] + replacement + current[end:]
    _write_atomic(path, updated)


def validate_index(path: Path = PODCAST_INDEX) -> None:
    current = path.read_text(encoding="utf-8")
    if current.count(MANAGED_START) != 1 or current.count(MANAGED_END) != 1:
        raise FeedError("The podcast archive is missing its RSS-managed episode markers.")
    if current.index(MANAGED_END) < current.index(MANAGED_START):
        raise FeedError("The podcast archive markers are out of order.")


def _episode_page(episode: dict[str, Any]) -> str:
    number = int(episode["episode_number"])
    title = episode.get("title") or f"Episode {number}"
    description = episode.get("description") or "Listen to the latest Holotable Chaos episode."
    safe_title = html.escape(title)
    safe_description = html.escape(description, quote=True)
    audio_url = html.escape(episode.get("audio_url", ""), quote=True)
    audio_type = html.escape(episode.get("audio_type", ""), quote=True)
    description_block = f"<p>{html.escape(description)}</p>" if description else ""
    audio_block = (
        f'<audio class="episode-audio" controls preload="metadata" aria-label="Play episode {number}">'
        f'<source src="{audio_url}"{f" type=\"{audio_type}\"" if audio_type else ""} />'
        "Your browser does not support audio playback.</audio>"
        if audio_url
        else '<p class="episode-description">The audio link is not available in the feed metadata.</p>'
    )
    published = episode.get("published_at")
    date_block = f'<p class="episode-date">Published <time datetime="{html.escape(published, quote=True)}">{html.escape(published[:10])}</time></p>' if published else ""
    external_link = episode.get("link", "")
    episode_link_block = (
        f'<p><a class="card-link" href="{html.escape(external_link, quote=True)}" target="_blank" rel="noopener noreferrer">View episode on Buzzsprout <span aria-hidden="true">↗</span></a></p>'
        if external_link.startswith(("https://", "http://"))
        else ""
    )
    return f'''<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="theme-color" content="#07111f" />
    <meta name="description" content="{safe_description}" />
    <title>Episode {number} — {safe_title} — Holotable Chaos</title>
    <link rel="stylesheet" href="../../styles.css" />
  </head>
  <body>
    <header class="site-header">
      <a class="brand" href="../../index.html" aria-label="Holotable Chaos home"><span class="brand-mark" aria-hidden="true">HC</span><span class="brand-name">HOLOTABLE <b>CHAOS</b></span></a>
      <nav aria-label="Main navigation"><a href="../index.html">Podcast</a><a href="../../resources/index.html">SWGoH Resources</a><a href="../../community/index.html">Community</a><a href="../../about/index.html">About</a></nav>
      <a class="discord-link" href="https://discord.gg/4HNxXZBkbf" target="_blank" rel="noopener noreferrer">Join our Discord <span aria-hidden="true">↗</span></a>
    </header>
    <main>
      <section class="page-intro"><p class="eyebrow"><span></span> THE SHOW / EPISODE {number}</p><h1>{safe_title}</h1>{description_block}{date_block}{episode_link_block}<p><a class="card-link" href="../index.html">← Back to all episodes</a></p></section>
      <section class="page-content" aria-label="Episode {number} player"><article class="episode-card"><span class="card-kicker">LISTEN TO THE EPISODE</span>{audio_block}</article></section>
    </main>
    <footer><a class="brand" href="../../index.html"><span class="brand-mark" aria-hidden="true">HC</span><span class="brand-name">HOLOTABLE <b>CHAOS</b></span></a><span>Because Nothing Ever Goes to Plan</span><span>© 2026 Holotable Chaos</span></footer>
    <script src="../playback-progress.js"></script>
  </body>
</html>
'''


def add_pages(additions: list[dict[str, Any]], episodes_dir: Path = EPISODES_DIR) -> int:
    created = 0
    for episode in additions:
        number = int(episode["episode_number"])
        path = episodes_dir / f"episode-{number}.html"
        if path.exists():
            # Never replace or regenerate a page that may have been hand edited.
            continue
        _write_atomic(path, _episode_page(episode))
        created += 1
    return created


def sync(url: str = FEED_URL, feed_file: Path | None = None, archive_path: Path = ARCHIVE_PATH,
         index_path: Path = PODCAST_INDEX, episodes_dir: Path = EPISODES_DIR, dry_run: bool = False) -> dict[str, int]:
    feed_items = parse_feed(read_feed(url, feed_file))  # Validate the complete feed before loading/writing outputs.
    archive = read_archive(archive_path)
    merged, additions, updated = merge_items(archive, feed_items)
    validate_index(index_path)
    existing_numbers = {
        int(item["episode_number"]) for item in merged["episodes"] if item.get("source") == "manual"
    }
    conflicts = [item["episode_number"] for item in additions if item["episode_number"] in existing_numbers]
    if conflicts:
        raise FeedError(f"New RSS episode number conflicts with a manually maintained episode: {conflicts}")
    page_conflicts = [
        int(item["episode_number"])
        for item in additions
        if (episodes_dir / f"episode-{int(item['episode_number'])}.html").exists()
    ]
    if page_conflicts:
        raise FeedError(f"An episode page already exists outside the permanent archive: {page_conflicts}")
    if not dry_run:
        # New pages are created only when absent; existing episode pages are immutable to this sync.
        add_pages(additions, episodes_dir)
        update_index(merged["episodes"], index_path)
        save_archive(merged, archive_path)
    return {"feed_items": len(feed_items), "added": len(additions), "metadata_filled": updated, "archived": len(merged["episodes"])}


def main() -> int:
    parser = argparse.ArgumentParser(description="Import new Buzzsprout episodes into the permanent Holotable Chaos archive.")
    parser.add_argument("--url", default=FEED_URL, help="RSS feed URL (defaults to the Holotable Chaos Buzzsprout feed).")
    parser.add_argument("--feed-file", type=Path, help="Read RSS from a local fixture instead of the network.")
    parser.add_argument("--dry-run", action="store_true", help="Parse and merge in memory without changing files.")
    args = parser.parse_args()
    try:
        result = sync(args.url, args.feed_file, dry_run=args.dry_run)
    except FeedError as exc:
        print(f"RSS sync stopped safely: {exc}", file=sys.stderr)
        return 1
    action = "would add" if args.dry_run else "added"
    print(f"Feed items: {result['feed_items']}; {action}: {result['added']}; metadata fields filled: {result['metadata_filled']}; permanent archive entries: {result['archived']}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
