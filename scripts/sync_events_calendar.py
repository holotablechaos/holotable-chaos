#!/usr/bin/env python3
"""Import the published SWGoH Events iCalendar feed into the static Resources page."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


ROOT = Path(__file__).resolve().parents[1]
CONTENT_PATH = ROOT / "content" / "events.json"
RESOURCES_PAGE = ROOT / "resources" / "index.html"
FEED_URL = "https://swgohevents.com/ical"
MANAGED_START = "<!-- EVENTS_CALENDAR_START -->"
MANAGED_END = "<!-- EVENTS_CALENDAR_END -->"
MAX_FEED_BYTES = 5 * 1024 * 1024


class FeedError(Exception):
    """An unavailable, malformed, or incomplete calendar response."""


def _unescape_ical(value: str) -> str:
    return re.sub(r"\\([nN,;\\])", lambda match: {"n": "\n", "N": "\n"}.get(match.group(1), match.group(1)), value).strip()


def _unfold(text: str) -> list[str]:
    lines: list[str] = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line.startswith((" ", "\t")) and lines:
            lines[-1] += line[1:]
        else:
            lines.append(line)
    return lines


def _parse_property(line: str) -> tuple[str, dict[str, str], str] | None:
    if ":" not in line:
        return None
    left, value = line.split(":", 1)
    parts = left.split(";")
    key = parts[0].upper()
    params: dict[str, str] = {}
    for part in parts[1:]:
        if "=" in part:
            name, parameter = part.split("=", 1)
            params[name.upper()] = parameter.strip('"')
    return key, params, value


def _parse_ical_datetime(value: str, params: dict[str, str]) -> tuple[str, str | None, bool]:
    """Return display date, normalized datetime when present, and all-day flag."""
    if params.get("VALUE", "").upper() == "DATE" or re.fullmatch(r"\d{8}", value):
        parsed_date = datetime.strptime(value[:8], "%Y%m%d").date()
        return parsed_date.isoformat(), None, True
    match = re.fullmatch(r"(\d{8})T(\d{6})(Z)?", value)
    if not match:
        raise ValueError(f"unsupported iCalendar date/time value {value!r}")
    parsed = datetime.strptime(match.group(1) + match.group(2), "%Y%m%d%H%M%S")
    zone = params.get("TZID")
    if match.group(3):
        parsed = parsed.replace(tzinfo=timezone.utc)
    elif zone:
        try:
            parsed = parsed.replace(tzinfo=ZoneInfo(zone))
        except ZoneInfoNotFoundError:
            # Preserve the source wall-clock date/time if the feed's custom zone is unavailable locally.
            pass
    iso_value = parsed.isoformat(timespec="seconds")
    if match.group(3):
        iso_value = iso_value.replace("+00:00", "Z")
    return parsed.date().isoformat(), iso_value, False


def _parse_duration(value: str) -> timedelta:
    match = re.fullmatch(r"P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", value)
    if not match:
        raise ValueError(f"unsupported iCalendar duration {value!r}")
    weeks, days, hours, minutes, seconds = (int(part or 0) for part in match.groups())
    return timedelta(weeks=weeks, days=days, hours=hours, minutes=minutes, seconds=seconds)


def _event_is_upcoming(event: dict[str, Any], current_day: date) -> bool:
    """Keep events whose inclusive end date (or start date when absent) is today or later."""
    last_day = event.get("end_date") or event["start_date"]
    return date.fromisoformat(last_day) >= current_day


def _is_permanent_baylan_event(event: dict[str, Any]) -> bool:
    """Exclude the permanent Baylan Skoll Epic Confrontation from scheduled events."""
    normalized_title = re.sub(r"[^a-z0-9]+", " ", event.get("title", "").casefold()).strip()
    if normalized_title in {"baylan skoll", "baylan skoll epic confrontation"}:
        return True
    parsed_url = urlsplit(event.get("url", ""))
    return (
        parsed_url.hostname is not None
        and parsed_url.hostname.casefold() in {"swgohevents.com", "www.swgohevents.com"}
        and parsed_url.path.rstrip("/").casefold() == "/event/baylan-skoll"
    )


def _display_event_title(event: dict[str, Any]) -> str:
    """Remove a category suffix when the source duplicates it in SUMMARY."""
    title = event["title"].strip()
    category = event.get("category", "").strip()
    if category:
        title = re.sub(rf"\s+[-–—]\s+{re.escape(category)}\s*$", "", title, flags=re.IGNORECASE).strip()
    return title


def parse_ics(feed_bytes: bytes, today: date | None = None) -> list[dict[str, Any]]:
    """Parse a calendar feed and return validated upcoming VEVENT entries."""
    if len(feed_bytes) > MAX_FEED_BYTES:
        raise FeedError("The iCalendar response exceeded the 5 MB safety limit.")
    try:
        text = feed_bytes.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise FeedError("The iCalendar response is not valid UTF-8 text.") from exc
    lines = _unfold(text)
    if "BEGIN:VCALENDAR" not in {line.upper() for line in lines} or "END:VCALENDAR" not in {line.upper() for line in lines}:
        raise FeedError("The response is not a complete iCalendar calendar.")

    blocks: list[list[str]] = []
    current: list[str] | None = None
    for line in lines:
        upper = line.upper()
        if upper == "BEGIN:VEVENT":
            if current is not None:
                raise FeedError("The iCalendar feed has nested event records.")
            current = []
        elif upper == "END:VEVENT":
            if current is None:
                raise FeedError("The iCalendar feed has an unmatched event terminator.")
            blocks.append(current)
            current = None
        elif current is not None:
            current.append(line)
    if current is not None:
        raise FeedError("The iCalendar feed ends inside an event record.")
    if not blocks:
        raise FeedError("The iCalendar feed contains no events; saved calendar data was kept.")

    current_day = today or datetime.now(timezone.utc).date()
    events: list[dict[str, Any]] = []
    for position, block in enumerate(blocks):
        props: dict[str, list[tuple[dict[str, str], str]]] = {}
        for line in block:
            parsed = _parse_property(line)
            if parsed:
                key, params, value = parsed
                props.setdefault(key, []).append((params, value))

        def value_of(key: str) -> tuple[dict[str, str], str] | None:
            values = props.get(key, [])
            return values[0] if values else None

        uid_prop, summary_prop, start_prop = value_of("UID"), value_of("SUMMARY"), value_of("DTSTART")
        if not uid_prop or not summary_prop or not start_prop:
            raise FeedError(f"Calendar event {position + 1} is missing a UID, SUMMARY, or DTSTART.")
        uid = _unescape_ical(uid_prop[1])
        title = _unescape_ical(summary_prop[1])
        url_prop = value_of("URL")
        event_url = _unescape_ical(url_prop[1]) if url_prop else ""
        if not uid or not title:
            raise FeedError(f"Calendar event {position + 1} has a blank UID or title.")
        if _is_permanent_baylan_event({"title": title, "url": event_url}):
            continue
        try:
            start_date, start_datetime, all_day = _parse_ical_datetime(start_prop[1], start_prop[0])
            end_prop = value_of("DTEND")
            duration_prop = value_of("DURATION")
            end_date: str | None = None
            end_datetime: str | None = None
            if end_prop:
                end_date, end_datetime, _ = _parse_ical_datetime(end_prop[1], end_prop[0])
                if all_day:
                    # RFC 5545 defines DTEND as a non-inclusive end for all-day events.
                    end_date = (date.fromisoformat(end_date) - timedelta(days=1)).isoformat()
            elif duration_prop:
                duration = _parse_duration(duration_prop[1])
                start_dt = datetime.combine(date.fromisoformat(start_date), datetime.min.time())
                end_date = (start_dt + duration - (timedelta(days=1) if all_day and duration else timedelta(0))).date().isoformat()
            if end_date and end_date < start_date:
                raise ValueError("event end precedes its start")
        except (ValueError, OverflowError) as exc:
            raise FeedError(f"Calendar event {uid!r} has an invalid date: {exc}") from exc

        recurrence = value_of("RECURRENCE-ID")
        recurrence_suffix = _unescape_ical(recurrence[1]) if recurrence else ""
        identity = uid + ("#" + recurrence_suffix if recurrence_suffix else "")
        category_values = [_unescape_ical(value) for _, value in props.get("CATEGORIES", []) if value]
        description_prop = value_of("DESCRIPTION")
        status_prop = value_of("STATUS")
        events.append({
            "uid": identity,
            "title": title,
            "start_date": start_date,
            "end_date": end_date,
            "start_datetime": start_datetime,
            "end_datetime": end_datetime,
            "all_day": all_day,
            "category": ", ".join(category_values),
            "reward": "",
            "description": _unescape_ical(description_prop[1]) if description_prop else "",
            "url": event_url,
            "status": _unescape_ical(status_prop[1]).upper() if status_prop else "CONFIRMED",
        })

    unique: dict[str, dict[str, Any]] = {}
    for event in events:
        unique[event["uid"]] = event
    upcoming = [event for event in unique.values() if _event_is_upcoming(event, current_day)]
    if not upcoming:
        raise FeedError("The calendar contains no upcoming events; saved calendar data was kept.")
    return sorted(upcoming, key=lambda event: (event["start_date"], event["title"].casefold(), event["uid"]))


def read_feed(url: str = FEED_URL, feed_file: Path | None = None) -> bytes:
    if feed_file:
        try:
            data = feed_file.read_bytes()
        except OSError as exc:
            raise FeedError(f"Could not read calendar fixture {feed_file}: {exc}") from exc
        if len(data) > MAX_FEED_BYTES:
            raise FeedError("The iCalendar fixture exceeded the 5 MB safety limit.")
        return data
    request = urllib.request.Request(url, headers={"User-Agent": "HolotableChaosCalendarSync/1.0 (+https://swgohevents.com/ical/info)", "Accept": "text/calendar"})
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            if response.status < 200 or response.status >= 300:
                raise FeedError(f"SWGoH Events returned HTTP {response.status}.")
            data = response.read(MAX_FEED_BYTES + 1)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise FeedError(f"Could not fetch SWGoH Events iCalendar feed: {exc}") from exc
    if len(data) > MAX_FEED_BYTES:
        raise FeedError("The iCalendar response exceeded the 5 MB safety limit.")
    return data


def read_archive(path: Path = CONTENT_PATH) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise FeedError(f"Could not read saved events: {exc}") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("events"), list):
        raise FeedError("Saved calendar content has an invalid structure.")
    return payload


def _escape_html(value: str) -> str:
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;").replace("'", "&#x27;")


def render_calendar(payload: dict[str, Any], now: datetime | None = None) -> str:
    current = now or datetime.now(timezone.utc)
    current_day = current.astimezone(timezone.utc).date() if current.tzinfo else current.date()
    # Saved snapshots can outlive their last refresh. Filter at render time as well
    # as import time so expired entries never remain in the upcoming list.
    events = [
        event for event in payload["events"]
        if not _is_permanent_baylan_event(event) and _event_is_upcoming(event, current_day)
    ]
    lines: list[str] = []
    for event in events:
        start = date.fromisoformat(event["start_date"])
        end = date.fromisoformat(event["end_date"]) if event.get("end_date") else None
        date_label = start.strftime("%b %d").upper()
        if end and end > start:
            date_label += "–" + end.strftime("%b %d").upper()
        title = _escape_html(_display_event_title(event))
        if event.get("url", "").startswith(("https://", "http://")):
            title_html = f'<a href="{_escape_html(event["url"])}" target="_blank" rel="noopener noreferrer">{title}</a>'
        else:
            title_html = title
        datetime_attr = event.get("start_datetime") or start.isoformat()
        lines.append(f'<article class="event-row"><time datetime="{_escape_html(datetime_attr)}"><span>{_escape_html(date_label)}</span></time><div><h3>{title_html}</h3></div></article>')

    successful = payload.get("last_successful_refresh")
    if successful:
        stamp = datetime.fromisoformat(successful.replace("Z", "+00:00"))
        if stamp.tzinfo is None:
            stamp = stamp.replace(tzinfo=timezone.utc)
        local_stamp = stamp.astimezone(ZoneInfo("America/New_York"))
        label = local_stamp.strftime("%b %d, %Y %I:%M %p %Z")
        refresh = f'<p class="episode-description calendar-refresh">Last successful feed refresh: <time datetime="{_escape_html(successful)}">{_escape_html(label)}</time>.</p>'
    else:
        snapshot = payload.get("snapshot_as_of")
        snapshot_note = f' Saved snapshot dated {_escape_html(snapshot)}.' if snapshot else ""
        refresh = f'<p class="episode-description calendar-refresh calendar-refresh-pending">Automatic feed refresh has not succeeded yet; showing the saved calendar snapshot.{snapshot_note}</p>'
    month_label = current.strftime("%B %Y").upper()
    return (
        f'<p class="card-kicker">{_escape_html(month_label)} / GAME EVENTS</p>\n'
        '<h2 id="events-calendar-title">Upcoming SWGoH Events</h2>\n'
        f'{refresh}\n'
        f'<div class="events-list" aria-label="Upcoming events">{"\n            ".join(lines)}</div>\n'
        f'<p class="calendar-source">Schedule from <a href="https://swgohevents.com/upcoming" target="_blank" rel="noopener noreferrer">SWGoH Events ↗</a>. Dates can change; verify event details with the source.</p>'
    )


def _write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile("wb", dir=path.parent, delete=False) as handle:
            handle.write(data)
            temporary = handle.name
        os.replace(temporary, path)
    except OSError:
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass
        raise


def _replace_calendar(html: str, replacement: str) -> str:
    if html.count(MANAGED_START) != 1 or html.count(MANAGED_END) != 1:
        raise FeedError("Resources page must contain exactly one events-calendar marker pair.")
    start = html.index(MANAGED_START) + len(MANAGED_START)
    end = html.index(MANAGED_END)
    if end < start:
        raise FeedError("Events-calendar markers are out of order.")
    return html[:start] + "\n          " + replacement + "\n          " + html[end:]


def sync(
    *,
    feed_file: Path | None = None,
    archive_path: Path = CONTENT_PATH,
    page_path: Path = RESOURCES_PAGE,
    now: datetime | None = None,
    today: date | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Validate a complete feed before replacing the saved catalog and rendered calendar."""
    source_bytes = read_feed(feed_file=feed_file)
    events = parse_ics(source_bytes, today=today)
    old = read_archive(archive_path)
    try:
        page = page_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise FeedError(f"Could not read Resources page: {exc}") from exc
    timestamp = (now or datetime.now(timezone.utc)).astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    updated = {"schema_version": 1, "source_url": FEED_URL, "last_successful_refresh": timestamp, "snapshot_as_of": old.get("snapshot_as_of"), "events": events}
    rendered = _replace_calendar(page, render_calendar(updated, now=now))
    if not dry_run:
        _write_atomic(archive_path, (json.dumps(updated, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
        _write_atomic(page_path, rendered.encode("utf-8"))
    return {"events": events, "added": len({e["uid"] for e in events} - {e.get("uid") for e in old["events"]}), "refreshed_at": timestamp, "dry_run": dry_run}


def render_saved_calendar(*, archive_path: Path = CONTENT_PATH, page_path: Path = RESOURCES_PAGE) -> None:
    """Render the saved calendar snapshot without contacting the source."""
    archive = read_archive(archive_path)
    try:
        page = page_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise FeedError(f"Could not read Resources page: {exc}") from exc
    updated_page = _replace_calendar(page, render_calendar(archive))
    _write_atomic(page_path, updated_page.encode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Refresh the Holotable Chaos events calendar from the published SWGoH Events ICS feed.")
    parser.add_argument("--feed-file", type=Path, help="Use a local ICS file instead of the live feed.")
    parser.add_argument("--dry-run", action="store_true", help="Parse and preview the feed without changing files.")
    parser.add_argument("--render-saved", action="store_true", help="Rebuild Resources page from saved events without contacting the feed.")
    args = parser.parse_args()
    if args.render_saved:
        try:
            render_saved_calendar()
        except (FeedError, OSError) as exc:
            print(f"Could not render saved calendar: {exc}", file=sys.stderr)
            return 1
        print("Rendered Resources page from the saved events snapshot; no feed request was made.")
        return 0
    try:
        result = sync(feed_file=args.feed_file, dry_run=args.dry_run)
    except (FeedError, OSError) as exc:
        print(f"Events calendar refresh failed; saved calendar was kept: {exc}", file=sys.stderr)
        return 1
    print(f"Validated {len(result['events'])} upcoming events; {result['added']} new event IDs. " + ("No files changed (dry run)." if args.dry_run else f"Last successful refresh: {result['refreshed_at']}"))
    for event in result["events"]:
        print(f"{event['start_date']}  {event['title']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
