import json
import shutil
import sys
import tempfile
import unittest
from datetime import date, datetime, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sync_events_calendar as syncer


FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"


class EventsCalendarSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent)
        self.work = Path(self.temp.name)
        self.archive = self.work / "events.json"
        self.page = self.work / "resources.html"
        self.archive.write_text(json.dumps({"schema_version": 1, "source_url": syncer.FEED_URL, "last_successful_refresh": "2026-10-11T12:00:00Z", "events": [{"uid": None, "title": "legacy snapshot", "start_date": "2026-10-13", "end_date": None}]}), encoding="utf-8")
        self.page.write_text(f'<section>{syncer.MANAGED_START}{syncer.MANAGED_END}<aside>preserve me</aside></section>', encoding="utf-8")
        self.now = datetime(2026, 10, 12, 14, 30, tzinfo=timezone.utc)

    def tearDown(self):
        self.temp.cleanup()

    def test_fixture_parses_names_dates_and_optional_metadata(self):
        events = syncer.parse_ics((FIXTURES / "swgohevents-sample.ics").read_bytes(), today=date(2026, 10, 12))
        self.assertEqual([event["title"] for event in events], ["Defense of Dathomir", "Discarded Doctrine"])
        self.assertNotIn("Old event", [event["title"] for event in events])
        defense = events[0]
        self.assertEqual(defense["start_date"], "2026-10-13")
        self.assertEqual(defense["end_date"], "2026-10-13")
        self.assertEqual(defense["category"], "Heroic Battle")
        self.assertIn("Mother Talzin Shards", defense["description"])
        self.assertEqual(defense["url"], "https://swgohevents.com/event/defense-of-dathomir")
        executor = events[1]
        self.assertEqual(executor["start_date"], "2026-10-15")
        self.assertEqual(executor["end_date"], "2026-10-16")
        self.assertEqual(executor["start_datetime"], "2026-10-15T12:00:00-07:00")

    def test_saved_calendar_render_omits_expired_events_but_keeps_future_and_end_date_events(self):
        payload = {
            "last_successful_refresh": "2026-10-11T12:00:00Z",
            "events": [
                {"title": "Baylan Skoll", "start_date": "2025-10-28", "end_date": "2025-10-28"},
                {"title": "Ended multi-day event", "start_date": "2026-10-09", "end_date": "2026-10-11"},
                {"title": "Ends today", "start_date": "2026-10-11", "end_date": "2026-10-12"},
                {"title": "Rebel Roundup", "start_date": "2026-10-21", "end_date": "2026-10-21"},
            ],
        }
        rendered = syncer.render_calendar(payload, now=self.now)
        self.assertNotIn("Baylan Skoll", rendered)
        self.assertNotIn("Ended multi-day event", rendered)
        self.assertIn("Ends today", rendered)
        self.assertIn("Rebel Roundup", rendered)
        self.assertIn("Last successful feed refresh", rendered)

    def test_sync_deduplicates_by_stable_uid_and_updates_changed_dates(self):
        syncer.sync(feed_file=FIXTURES / "swgohevents-sample.ics", archive_path=self.archive, page_path=self.page, now=self.now, today=date(2026, 10, 12))
        first = json.loads(self.archive.read_text(encoding="utf-8"))
        first_ids = {event["uid"] for event in first["events"]}
        self.assertEqual(len(first_ids), 2)
        self.assertEqual(first["last_successful_refresh"], "2026-10-12T14:30:00Z")
        first_render = self.page.read_text(encoding="utf-8")
        self.assertIn("Oct 12, 2026 14:30 UTC", first_render)
        self.assertIn("Defense of Dathomir", first_render)

        changed_feed = self.work / "changed.ics"
        contents = (FIXTURES / "swgohevents-sample.ics").read_text(encoding="utf-8")
        contents = contents.replace("DTSTART;VALUE=DATE:20261013", "DTSTART;VALUE=DATE:20261014").replace("DTEND;VALUE=DATE:20261014", "DTEND;VALUE=DATE:20261015")
        changed_feed.write_text(contents, encoding="utf-8")
        second = syncer.sync(feed_file=changed_feed, archive_path=self.archive, page_path=self.page, now=self.now, today=date(2026, 10, 12))
        updated = json.loads(self.archive.read_text(encoding="utf-8"))
        defense = next(event for event in updated["events"] if event["uid"] == "event-20261013-defense@example.test")
        self.assertEqual(len(updated["events"]), 2)
        self.assertEqual(defense["start_date"], "2026-10-14")
        self.assertEqual(second["added"], 0)
        repeated = syncer.sync(feed_file=FIXTURES / "swgohevents-sample.ics", archive_path=self.archive, page_path=self.page, now=self.now, today=date(2026, 10, 12))
        self.assertEqual(repeated["added"], 0)
        self.assertEqual(len(json.loads(self.archive.read_text(encoding="utf-8"))["events"]), 2)
        rendered = self.page.read_text(encoding="utf-8")
        self.assertIn("Last successful feed refresh", rendered)
        self.assertIn("preserve me", rendered)

    def test_empty_malformed_or_incomplete_feed_keeps_previous_data_and_page(self):
        before = (self.archive.read_bytes(), self.page.read_bytes())
        for content in (
            b"not an icalendar file",
            b"BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n",
            b"BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Missing identity and date\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
        ):
            feed = self.work / "bad.ics"
            feed.write_bytes(content)
            with self.assertRaises(syncer.FeedError):
                syncer.sync(feed_file=feed, archive_path=self.archive, page_path=self.page, now=self.now, today=date(2026, 10, 12))
            self.assertEqual((self.archive.read_bytes(), self.page.read_bytes()), before)

    def test_failed_network_request_and_dry_run_do_not_mutate_files(self):
        before = (self.archive.read_bytes(), self.page.read_bytes())
        with mock.patch("urllib.request.urlopen", side_effect=syncer.urllib.error.URLError("offline")):
            with self.assertRaises(syncer.FeedError):
                syncer.sync(archive_path=self.archive, page_path=self.page, now=self.now, today=date(2026, 10, 12))
        self.assertEqual((self.archive.read_bytes(), self.page.read_bytes()), before)

        result = syncer.sync(feed_file=FIXTURES / "swgohevents-sample.ics", archive_path=self.archive, page_path=self.page, now=self.now, today=date(2026, 10, 12), dry_run=True)
        self.assertTrue(result["dry_run"])
        self.assertEqual((self.archive.read_bytes(), self.page.read_bytes()), before)


if __name__ == "__main__":
    unittest.main()
