import json
import shutil
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sync_buzzsprout as syncer


PROJECT_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"


class BuzzsproutSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent)
        self.work = Path(self.temp.name)
        self.archive = self.work / "episodes.json"
        self.index = self.work / "podcast-index.html"
        self.pages = self.work / "episodes"
        shutil.copyfile(PROJECT_ROOT / "content" / "episodes.json", self.archive)
        self.index.write_text(
            '<div class="episode-grid">\n'
            f"{syncer.MANAGED_START}{syncer.MANAGED_END}"
            '<article class="episode-card">manual episode</article>\n</div>',
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp.cleanup()

    def run_fixture(self, name):
        return syncer.sync(
            feed_file=FIXTURES / name,
            archive_path=self.archive,
            index_path=self.index,
            episodes_dir=self.pages,
        )

    def test_import_duplicate_detection_and_manual_content_preservation(self):
        before = json.loads(self.archive.read_text(encoding="utf-8"))
        manual_17 = next(entry for entry in before["episodes"] if entry["episode_number"] == 17)
        result = self.run_fixture("buzzsprout-sample.xml")
        archive = json.loads(self.archive.read_text(encoding="utf-8"))
        new_items = [entry for entry in archive["episodes"] if entry["guid"] == "buzzsprout-18000018"]
        self.assertEqual(result["added"], 2)
        self.assertEqual(len(new_items), 1)
        self.assertEqual(new_items[0]["episode_number"], 18)
        self.assertEqual(new_items[0]["published_at"], "2026-10-08T16:00:00Z")
        self.assertEqual(new_items[0]["audio_url"], "https://www.buzzsprout.com/2606659/episodes/18000018-a-sample-new-holotable.mp3")
        minimal = next(entry for entry in archive["episodes"] if entry["guid"] == "buzzsprout-19000019")
        self.assertEqual(minimal["episode_number"], 19)
        self.assertEqual(minimal["audio_url"], "")
        updated_17 = next(entry for entry in archive["episodes"] if entry["episode_number"] == 17)
        self.assertEqual(updated_17["description"], manual_17["description"])
        self.assertEqual(updated_17["audio_url"], manual_17["audio_url"])
        self.assertIn("buzzsprout-17000017", updated_17["alternate_guids"])
        self.assertTrue((self.pages / "episode-18.html").exists())
        self.assertTrue((self.pages / "episode-19.html").exists())
        rendered_index = self.index.read_text(encoding="utf-8")
        self.assertLess(rendered_index.index("EPISODE 19"), rendered_index.index("EPISODE 18"))
        self.assertIn('href="episodes/episode-18.html"', rendered_index)
        before_repeat = self.archive.read_bytes()
        index_before_repeat = self.index.read_bytes()
        repeated = self.run_fixture("buzzsprout-sample.xml")
        self.assertEqual(repeated["added"], 0)
        self.assertEqual(self.archive.read_bytes(), before_repeat)
        self.assertEqual(self.index.read_bytes(), index_before_repeat)

    def test_rss_disappearance_does_not_remove_saved_episodes(self):
        self.run_fixture("buzzsprout-sample.xml")
        # A valid feed with no items must not remove feed-imported or manual history.
        empty_feed = self.work / "empty.xml"
        empty_feed.write_text('<rss version="2.0"><channel><title>Holotable Chaos</title></channel></rss>', encoding="utf-8")
        syncer.sync(feed_file=empty_feed, archive_path=self.archive, index_path=self.index, episodes_dir=self.pages)
        archive = json.loads(self.archive.read_text(encoding="utf-8"))
        numbers = {entry["episode_number"] for entry in archive["episodes"]}
        self.assertEqual(numbers, set(range(1, 20)))
        self.assertIn('href="episodes/episode-18.html"', self.index.read_text(encoding="utf-8"))

    def test_malformed_feed_and_network_failure_leave_outputs_unchanged(self):
        bad_feed = self.work / "bad.xml"
        bad_feed.write_text("<rss><channel>", encoding="utf-8")
        before = {path: path.read_bytes() for path in (self.archive, self.index)}
        with self.assertRaises(syncer.FeedError):
            syncer.sync(feed_file=bad_feed, archive_path=self.archive, index_path=self.index, episodes_dir=self.pages)
        after = {path: path.read_bytes() for path in (self.archive, self.index)}
        self.assertEqual(before, after)
        self.assertFalse(self.pages.exists())
        with mock.patch("urllib.request.urlopen", side_effect=syncer.urllib.error.URLError("offline")):
            with self.assertRaises(syncer.FeedError):
                syncer.sync(archive_path=self.archive, index_path=self.index, episodes_dir=self.pages)
        self.assertEqual(before, {path: path.read_bytes() for path in (self.archive, self.index)})


if __name__ == "__main__":
    unittest.main()
